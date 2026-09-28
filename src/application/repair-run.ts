import { decideRunTransition } from "../domain/run-state.js";
import { ApplicationError } from "./application-error.js";
import type { ValueHasher } from "./ports/project-discovery.js";
import type {
  ProjectFingerprintReader,
  RunLock,
  RunOperation,
  RunOperationExecutor,
  RunRecordStore,
} from "./ports/run-lifecycle.js";
import { readValidatedRunRecord, sealRunRecord } from "./start-run.js";

const MAX_REPAIR_FILES = 20;
const MAX_REPAIR_BYTES = 1_048_576;
const MAX_REPAIR_ATTEMPTS = 3;
const MAX_RUN_REPAIR_ATTEMPTS = 5;
const FORBIDDEN_PATHS = [
  ".git/**",
  ".angular-migration/**",
  "package.json",
  "package-lock.json",
  "npm-shrinkwrap.json",
  "yarn.lock",
  "pnpm-lock.yaml",
  "scripts/**",
  "hooks.json",
  "agents/**",
  "docs/**",
  "**/.npmrc",
  "**/.env*",
  "**/*.pem",
  "**/*.key",
  "**/*.pfx",
  "**/*.p12",
];

export interface RepairFilePatch {
  readonly path: string;
  readonly content: string;
}

export interface RepairPatchLease {
  rollback(): Promise<void>;
}

export interface RepairPatchWriter {
  apply(
    projectRoot: string,
    files: readonly RepairFilePatch[],
  ): Promise<RepairPatchLease>;
}

export interface RepairRunPorts {
  readonly records: RunRecordStore;
  readonly lock: RunLock;
  readonly fingerprints: ProjectFingerprintReader;
  readonly operations: RunOperationExecutor;
  readonly patches: RepairPatchWriter;
  readonly hasher: ValueHasher;
}

export interface RepairContext {
  readonly schemaVersion: 1;
  readonly runId: string;
  readonly projectId: string;
  readonly fingerprint: string;
  readonly stage: "validate";
  readonly failedCheck: string;
  readonly attempt: number;
  readonly maxAttempts: 3;
  readonly maxRunAttempts: 5;
  readonly allowedPaths: readonly ["src/**/*"];
  readonly forbiddenPaths: readonly string[];
  readonly diagnostic: { readonly code: string; readonly message: string };
  readonly submissionPath: string;
}

export async function getRepairContext(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: RepairRunPorts,
): Promise<RepairContext> {
  const record = await readActiveRepairRecord(request, ports);
  return createContext(record, request.projectRoot, ports);
}

export async function recordRepair(
  request: {
    readonly projectRoot: string;
    readonly runId: string;
    readonly submission: unknown;
  },
  ports: RepairRunPorts,
): Promise<{
  readonly runId: string;
  readonly status: "running";
  readonly stage: "validate";
  readonly attempt: number;
  readonly changedPaths: readonly string[];
  readonly verification: "passed";
}> {
  const lease = await ports.lock.acquire(request.projectRoot);
  if (lease.kind !== "acquired") {
    throw new ApplicationError(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended"
        ? "Another controller operation owns this project."
        : "Project lock ownership requires recovery.",
      "blocked",
    );
  }
  let result:
    | {
        readonly runId: string;
        readonly status: "running";
        readonly stage: "validate";
        readonly attempt: number;
        readonly changedPaths: readonly string[];
        readonly verification: "passed";
      }
    | undefined;
  let failure: unknown;
  let patchLease: RepairPatchLease | undefined;
  try {
    let record = await readActiveRepairRecord(request, ports);
    const context = await createContext(record, request.projectRoot, ports);
    const submission = validateSubmission(request.submission, context);
    const submissionHash = await ports.hasher.hash(request.submission);
    if (
      record.events.some(
        (event) => event.repair?.submissionHash === submissionHash,
      )
    ) {
      throw blocked(
        "repair_submission_replayed",
        "This repair submission was already processed.",
      );
    }

    patchLease = await ports.patches.apply(
      request.projectRoot,
      submission.files,
    );
    const operation = repairOperation(record, context.failedCheck);
    let verificationPassed = false;
    try {
      verificationPassed =
        (await ports.operations.execute(request.projectRoot, operation))
          .outcome === "passed";
    } catch {
      verificationPassed = false;
    }
    const afterFingerprint = verificationPassed
      ? await ports.fingerprints
          .readFingerprint(request.projectRoot)
          .catch(() => "")
      : "";
    if (
      !verificationPassed ||
      !/^sha256:[a-f0-9]{64}$/.test(afterFingerprint)
    ) {
      await patchLease.rollback();
      patchLease = undefined;
      record = await appendRepairEvent(
        record,
        request.projectRoot,
        {
          attempt: context.attempt,
          fingerprint: context.fingerprint,
          submissionHash,
          changedPaths: submission.files.map(({ path: file }) => file),
          outcome: "rejected",
        },
        ports,
      );
      throw blocked(
        "repair_verification_failed",
        "The controller's original validation gate did not pass after repair.",
      );
    }

    const transition = decideRunTransition(
      record.state,
      { status: "running", stage: "validate" },
      "repair-verified",
    );
    if (transition.outcome !== "allowed") {
      await patchLease.rollback();
      patchLease = undefined;
      throw blocked(
        "repair_transition_rejected",
        "The verified repair cannot resume the current run state.",
      );
    }
    const latest = record.checkpoints.at(-1)!;
    const checkpoint = {
      sequence: record.checkpoints.length,
      stage: "validate" as const,
      operationId: latest.operationId,
      phase: "after" as const,
      projectFingerprint: afterFingerprint,
      idempotencyKey: `${record.state.runId}:validate:${latest.operationId}:after`,
    };
    const { recordHash: _oldHash, ...unsigned } = record;
    const updated = await sealRunRecord(
      {
        ...unsigned,
        state: transition.value,
        diagnostic: null,
        checkpoints: [...record.checkpoints, checkpoint],
        events: [
          ...record.events,
          {
            sequence: record.events.length,
            type: "repair-accepted",
            stage: "validate",
            status: "running",
            revision: transition.value.revision,
            repair: {
              attempt: context.attempt,
              fingerprint: context.fingerprint,
              submissionHash,
              changedPaths: submission.files.map(({ path: file }) => file),
              outcome: "accepted",
            },
          },
        ],
      },
      ports.hasher,
    );
    await ports.records.write(request.projectRoot, updated);
    patchLease = undefined;
    result = {
      runId: request.runId,
      status: "running",
      stage: "validate",
      attempt: context.attempt,
      changedPaths: submission.files.map(({ path: file }) => file),
      verification: "passed",
    };
  } catch (error) {
    if (patchLease) {
      try {
        await patchLease.rollback();
      } catch {
        failure = blocked(
          "repair_rollback_unconfirmed",
          "Repair rollback could not be verified; human recovery is required.",
        );
      }
    }
    failure ??= error;
  }

  const release = await lease.release();
  if (release.kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed.",
    );
  }
  if (failure !== undefined) throw failure;
  return result!;
}

async function readActiveRepairRecord(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: RepairRunPorts,
) {
  if (
    !request ||
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0 ||
    typeof request.runId !== "string" ||
    request.runId.trim().length === 0
  ) {
    throw blocked(
      "repair_request_invalid",
      "A project root and run id are required.",
    );
  }
  const stored = await ports.records.read(request.projectRoot);
  if (stored === null)
    throw blocked("run_not_found", "No run exists for this project.");
  const record = await readValidatedRunRecord(stored, ports.hasher);
  const latest = record.checkpoints.at(-1);
  if (
    record.state.runId !== request.runId ||
    record.state.status !== "needs-repair" ||
    record.state.stage !== "validate" ||
    record.diagnostic?.code !== "process_nonzero_exit" ||
    latest?.stage !== "validate" ||
    latest.phase !== "before" ||
    !latest.operationId.startsWith("validate-")
  ) {
    throw blocked(
      "repair_context_unavailable",
      "Repair requires a blocked configured validation check in the active run.",
    );
  }
  return record;
}

async function createContext(
  record: Awaited<ReturnType<typeof readValidatedRunRecord>>,
  projectRoot: string,
  ports: RepairRunPorts,
): Promise<RepairContext> {
  const latest = record.checkpoints.at(-1)!;
  const fingerprint = await ports.fingerprints.readFingerprint(projectRoot);
  if (fingerprint !== latest.projectFingerprint) {
    throw blocked(
      "repair_fingerprint_stale",
      "Project inputs changed after the failed validation check.",
    );
  }
  const attempts = record.events.filter((event) => event.repair).length;
  const fingerprintAttempts = record.events.filter(
    (event) => event.repair?.fingerprint === fingerprint,
  ).length;
  if (
    fingerprintAttempts >= MAX_REPAIR_ATTEMPTS ||
    attempts >= MAX_RUN_REPAIR_ATTEMPTS
  ) {
    throw blocked(
      "repair_attempts_exhausted",
      "The repair attempt limit for this run has been reached.",
    );
  }
  const checkId = latest.operationId.slice("validate-".length);
  const check = record.discoveryPlan.checks.find(
    (item) => item.id === checkId && item.status === "configured",
  );
  if (!check || check.executable !== "npm") {
    throw blocked(
      "repair_scope_unknown",
      "The failed check has no safe repair contract.",
    );
  }
  return {
    schemaVersion: 1,
    runId: record.state.runId,
    projectId: record.state.projectId,
    fingerprint,
    stage: "validate",
    failedCheck: checkId,
    attempt: fingerprintAttempts + 1,
    maxAttempts: MAX_REPAIR_ATTEMPTS,
    maxRunAttempts: MAX_RUN_REPAIR_ATTEMPTS,
    allowedPaths: ["src/**/*"],
    forbiddenPaths: FORBIDDEN_PATHS,
    diagnostic: record.diagnostic!,
    submissionPath: `.angular-migration/repair-inbox/${record.state.runId}.json`,
  };
}

function validateSubmission(
  value: unknown,
  context: RepairContext,
): { readonly files: readonly RepairFilePatch[] } {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "schemaVersion",
      "runId",
      "fingerprint",
      "attempt",
      "rootCause",
      "changes",
      "evidence",
      "unresolvedWarnings",
    ])
  ) {
    throw blocked(
      "repair_submission_invalid",
      "Repair submission shape is invalid.",
    );
  }
  if (
    value.schemaVersion !== 1 ||
    value.runId !== context.runId ||
    value.fingerprint !== context.fingerprint ||
    value.attempt !== context.attempt
  ) {
    throw blocked(
      "repair_submission_stale",
      "Repair submission does not match the issued context.",
    );
  }
  if (
    typeof value.rootCause !== "string" ||
    !value.rootCause.trim() ||
    value.rootCause.length > 4000 ||
    !Array.isArray(value.changes) ||
    value.changes.length === 0 ||
    value.changes.length > MAX_REPAIR_FILES ||
    !Array.isArray(value.evidence) ||
    value.evidence.length === 0 ||
    !value.evidence.every(isRepairEvidence) ||
    !value.evidence.every((item) => item.reference === "run-diagnostic") ||
    !Array.isArray(value.unresolvedWarnings) ||
    !value.unresolvedWarnings.every(
      (item) =>
        typeof item === "string" &&
        item.trim().length > 0 &&
        item.length <= 1000,
    )
  ) {
    throw blocked(
      "repair_submission_invalid",
      "Repair submission fields are invalid.",
    );
  }
  let totalBytes = 0;
  const seen = new Set<string>();
  const files: RepairFilePatch[] = [];
  for (const change of value.changes) {
    if (
      !isRecord(change) ||
      !hasExactKeys(change, ["path", "summary", "reason", "content"]) ||
      typeof change.path !== "string" ||
      !/^src\/[A-Za-z0-9._/-]+$/.test(change.path) ||
      change.path.split("/").includes("..") ||
      /[\\:]|\0/.test(change.path) ||
      seen.has(change.path) ||
      typeof change.summary !== "string" ||
      !change.summary.trim() ||
      change.summary.length > 1000 ||
      typeof change.reason !== "string" ||
      !change.reason.trim() ||
      change.reason.length > 1000 ||
      typeof change.content !== "string" ||
      containsSensitiveText(change.content)
    ) {
      throw blocked(
        "repair_submission_invalid",
        "Repair contains an invalid or unauthorized file change.",
      );
    }
    seen.add(change.path);
    totalBytes += Buffer.byteLength(change.content, "utf8");
    if (totalBytes > MAX_REPAIR_BYTES) {
      throw blocked(
        "repair_submission_too_large",
        "Repair submission exceeds the size limit.",
      );
    }
    files.push({ path: change.path, content: change.content });
  }
  return { files };
}

function repairOperation(
  record: Awaited<ReturnType<typeof readValidatedRunRecord>>,
  checkId: string,
): RunOperation {
  const check = record.discoveryPlan.checks.find(
    (item) => item.id === checkId && item.status === "configured",
  );
  const nodeVersion = record.discoveryPlan.runtimePlan.selected?.nodeVersion;
  if (
    !check ||
    check.executable !== "npm" ||
    check.arguments.length !== 2 ||
    check.arguments[0] !== "run" ||
    !/^[a-zA-Z0-9:_-]+$/.test(check.arguments[1]) ||
    !nodeVersion
  ) {
    throw blocked(
      "repair_gate_invalid",
      "The original validation gate cannot be reconstructed safely.",
    );
  }
  return {
    id: `validate-${checkId}`,
    kind: "process",
    stage: "validate",
    executable: "npm",
    arguments: check.arguments,
    nodeVersion,
    timeoutMs: 600_000,
    postcondition: "exit-zero",
    packages: [],
  };
}

async function appendRepairEvent(
  record: Awaited<ReturnType<typeof readValidatedRunRecord>>,
  projectRoot: string,
  repair: NonNullable<RunEventRepair>,
  ports: RepairRunPorts,
) {
  const { recordHash: _oldHash, ...unsigned } = record;
  const updated = await sealRunRecord(
    {
      ...unsigned,
      events: [
        ...record.events,
        {
          sequence: record.events.length,
          type: "repair-rejected",
          stage: "validate",
          status: "needs-repair",
          revision: record.state.revision,
          repair,
        },
      ],
    },
    ports.hasher,
  );
  await ports.records.write(projectRoot, updated);
  return updated;
}

type RunEventRepair = import("./ports/run-lifecycle.js").RunEvent["repair"];

function isRepairEvidence(
  value: unknown,
): value is { reference: string; claim: string } {
  return Boolean(
    isRecord(value) &&
    hasExactKeys(value, ["reference", "claim"]) &&
    typeof value.reference === "string" &&
    value.reference.length > 0 &&
    typeof value.claim === "string" &&
    value.claim.trim().length > 0 &&
    value.claim.length <= 1000,
  );
}

function containsSensitiveText(value: string): boolean {
  return /(?:authorization\s*:\s*bearer\s+|(?:password|token|secret)\s*[=:]\s*|https?:\/\/[^/@\s]+:[^/@\s]+@)/i.test(
    value,
  );
}

function hasExactKeys(
  value: Record<string, unknown>,
  keys: readonly string[],
): boolean {
  return (
    Object.keys(value).length === keys.length &&
    keys.every((key) => Object.hasOwn(value, key))
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function blocked(code: string, message: string): ApplicationError {
  return new ApplicationError(code, message, "blocked");
}
