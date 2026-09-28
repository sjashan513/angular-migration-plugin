import { decideRunTransition } from "../domain/run-state.js";
import { ApplicationError } from "./application-error.js";
import type { ValueHasher } from "./ports/project-discovery.js";
import type {
  ProjectFingerprintReader,
  RunLock,
  RunRecordStore,
} from "./ports/run-lifecycle.js";
import { readValidatedRunRecord, sealRunRecord } from "./start-run.js";

const SKIPPABLE_BASELINE_CHECKS = new Set([
  "typecheck",
  "lint",
  "unit-test",
  "e2e",
]);
const CRITICAL_CHECKS = new Set(["install", "dependency-tree", "build"]);

export async function approveCheckSkip(
  request: {
    readonly projectRoot: string;
    readonly runId: string;
    readonly checkId: string;
    readonly reason: string;
    readonly confirmed: boolean;
  },
  ports: {
    readonly records: RunRecordStore;
    readonly lock: RunLock;
    readonly fingerprints: ProjectFingerprintReader;
    readonly hasher: ValueHasher;
  },
): Promise<{
  readonly runId: string;
  readonly status: "running";
  readonly stage: "baseline";
  readonly checkId: string;
  readonly reason: string;
}> {
  if (
    !request ||
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0 ||
    typeof request.runId !== "string" ||
    typeof request.checkId !== "string" ||
    typeof request.reason !== "string" ||
    request.reason.trim().length === 0 ||
    request.reason.length > 2000 ||
    request.confirmed !== true
  ) {
    throw new ApplicationError(
      request?.confirmed === true
        ? "skip_request_invalid"
        : "confirmation_required",
      request?.confirmed === true
        ? "A check id and a reason of at most 2000 characters are required."
        : "Skipping a project check requires explicit confirmation.",
      "blocked",
    );
  }
  if (CRITICAL_CHECKS.has(request.checkId)) {
    throw new ApplicationError(
      "critical_check_cannot_be_skipped",
      "Install, dependency-tree, and build checks cannot be skipped.",
      "blocked",
    );
  }
  if (!SKIPPABLE_BASELINE_CHECKS.has(request.checkId)) {
    throw new ApplicationError(
      "check_not_skippable",
      "The requested check is not in the baseline skip allowlist.",
      "blocked",
    );
  }

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

  let failure: unknown;
  try {
    const stored = await ports.records.read(request.projectRoot);
    if (stored === null) {
      throw new ApplicationError(
        "run_not_found",
        "No run exists for this project.",
        "blocked",
      );
    }
    const record = await readValidatedRunRecord(stored, ports.hasher);
    const latest = record.checkpoints.at(-1);
    if (record.state.runId !== request.runId) {
      throw new ApplicationError(
        "run_context_mismatch",
        "The skip does not belong to the current run.",
        "blocked",
      );
    }
    if (
      record.state.status !== "blocked" ||
      record.state.stage !== "baseline" ||
      latest?.phase !== "before" ||
      latest.operationId !== `baseline-${request.checkId}` ||
      record.diagnostic === null ||
      !record.discoveryPlan.checks.some(
        (check) =>
          check.id === request.checkId &&
          check.status === "configured" &&
          check.executable === "npm",
      )
    ) {
      throw new ApplicationError(
        "skip_context_unavailable",
        "A skip requires the matching configured baseline check to be blocked.",
        "blocked",
      );
    }
    const fingerprint = await ports.fingerprints.readFingerprint(
      request.projectRoot,
    );
    if (fingerprint !== latest.projectFingerprint) {
      throw new ApplicationError(
        "project_fingerprint_changed",
        "Project inputs changed after the failed check.",
        "blocked",
      );
    }
    const transition = decideRunTransition(
      record.state,
      { status: "running", stage: "baseline" },
      "human-confirmed-retry",
    );
    if (transition.outcome !== "allowed") {
      throw new ApplicationError(
        "skip_transition_rejected",
        "The blocked run cannot resume under the current state policy.",
        "blocked",
      );
    }
    const checkpoint = {
      sequence: record.checkpoints.length,
      stage: "baseline" as const,
      operationId: latest.operationId,
      phase: "skipped" as const,
      projectFingerprint: fingerprint,
      idempotencyKey: `${record.state.runId}:baseline:${latest.operationId}:skipped`,
    };
    const { recordHash: _previousHash, ...unsignedRecord } = record;
    const content = {
      ...unsignedRecord,
      state: transition.value,
      diagnostic: null,
      checkpoints: [...record.checkpoints, checkpoint],
      events: [
        ...record.events,
        {
          sequence: record.events.length,
          type: "check-skipped" as const,
          stage: "baseline" as const,
          status: "running" as const,
          revision: transition.value.revision,
          skip: {
            checkId: request.checkId,
            reason: request.reason.trim(),
            confirmed: true as const,
          },
        },
      ],
    };
    const updated = await sealRunRecord(content, ports.hasher);
    await ports.records.write(request.projectRoot, updated);
  } catch (error) {
    failure = error;
  }

  const release = await lease.release();
  if (release.kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed.",
    );
  }
  if (failure !== undefined) throw failure;
  return {
    runId: request.runId,
    status: "running",
    stage: "baseline",
    checkId: request.checkId,
    reason: request.reason.trim(),
  };
}
