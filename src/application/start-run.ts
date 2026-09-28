import { createAngularMajor, createProjectId } from "../domain/identity.js";
import { createInitialRunState, isValidRunState } from "../domain/run-state.js";
import { parseExactSemverVersion } from "../domain/semver-constraints.js";
import { ApplicationError } from "./application-error.js";
import {
  readValidatedDiscoveryRecord,
  type DiscoveryRecord,
} from "./discover-project.js";
import type {
  DiscoveryRecordStore,
  ProjectDiscoveryReader,
  ValueHasher,
} from "./ports/project-discovery.js";
import type {
  RunIdGenerator,
  RunLock,
  RunRecord,
  RunRecordStore,
} from "./ports/run-lifecycle.js";

export interface StartRunPorts {
  readonly reader: ProjectDiscoveryReader;
  readonly discoveries: DiscoveryRecordStore;
  readonly runRecords: RunRecordStore;
  readonly lock: RunLock;
  readonly ids: RunIdGenerator;
  readonly hasher: ValueHasher;
}

export async function startRun(
  request: { readonly projectRoot: string; readonly targetMajor: number },
  ports: StartRunPorts,
): Promise<RunRecord> {
  if (
    !request ||
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0 ||
    !Number.isSafeInteger(request.targetMajor)
  ) {
    throw new ApplicationError(
      "start_request_invalid",
      "A project root and target major are required.",
    );
  }

  const lease = await ports.lock.acquire(request.projectRoot);
  if (lease.kind !== "acquired") {
    throw new ApplicationError(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended"
        ? "Another controller operation owns this project."
        : "Project lock ownership requires recovery.",
    );
  }

  let result: RunRecord | undefined;
  let failure: unknown;
  try {
    const current = await ports.reader.read(
      request.projectRoot,
      request.targetMajor,
    );
    const context = readCurrentContext(current);
    const storedPlan = await ports.discoveries.read(request.projectRoot);
    const plan = await readValidatedDiscoveryRecord(
      storedPlan,
      {
        projectId: context.projectId,
        inputFingerprint: context.inputFingerprint,
        targetMajor: request.targetMajor,
      },
      ports.hasher,
    );
    assertStartablePlan(plan, context);

    const previous = await ports.runRecords.read(request.projectRoot);
    if (previous !== null) {
      const oldRun = await readValidatedRunRecord(previous, ports.hasher);
      if (oldRun.state.status !== "completed") {
        throw new ApplicationError(
          "run_already_active",
          "The existing run must reach a terminal state before another can start.",
        );
      }
    }

    result = await createRunRecord(plan, ports.ids, ports.hasher);
    await ports.runRecords.write(request.projectRoot, result);
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
  return result!;
}

export async function readValidatedRunRecord(
  value: unknown,
  hasher: ValueHasher,
): Promise<RunRecord> {
  if (!isRunRecord(value)) {
    throw new ApplicationError(
      "run_record_invalid",
      "The persisted run record is invalid.",
    );
  }
  const { recordHash, ...content } = value;
  if ((await hasher.hash(content)) !== recordHash) {
    throw new ApplicationError(
      "run_record_integrity_failed",
      "The persisted run record has been altered.",
    );
  }
  await readValidatedDiscoveryRecord(
    value.discoveryPlan,
    {
      projectId: value.state.projectId,
      inputFingerprint: value.discoveryPlan.inputFingerprint,
      targetMajor: value.state.targetMajor,
    },
    hasher,
  );
  if (
    value.state.projectId !== value.discoveryPlan.projectId ||
    value.state.sourceMajor !== value.discoveryPlan.sourceMajor ||
    value.state.targetMajor !== value.discoveryPlan.targetMajor
  ) {
    throw new ApplicationError(
      "run_record_context_mismatch",
      "The run and discovery plan do not describe the same migration.",
    );
  }
  return value;
}

async function createRunRecord(
  plan: DiscoveryRecord,
  ids: RunIdGenerator,
  hasher: ValueHasher,
): Promise<RunRecord> {
  const state = createInitialRunState({
    runId: ids.create(),
    projectId: plan.projectId,
    sourceMajor: plan.sourceMajor,
    targetMajor: plan.targetMajor,
  });
  const content = {
    schemaVersion: 1 as const,
    state,
    discoveryPlan: plan,
    events: [
      {
        sequence: 0,
        type: "run-started" as const,
        stage: state.stage,
        status: state.status,
        revision: state.revision,
      },
    ],
    checkpoints: [],
    diagnostic: null,
  };
  return sealRunRecord(content, hasher);
}

export async function sealRunRecord(
  content: Omit<RunRecord, "recordHash">,
  hasher: ValueHasher,
): Promise<RunRecord> {
  return { ...content, recordHash: await hasher.hash(content) };
}

function readCurrentContext(value: unknown): {
  readonly projectId: string;
  readonly inputFingerprint: string;
  readonly sourceMajor: number;
  readonly gitStatus: string;
  readonly runtimeCandidates: readonly unknown[];
} {
  if (
    !isRecord(value) ||
    typeof value.projectId !== "string" ||
    !/^sha256:[a-f0-9]{64}$/.test(value.projectId) ||
    typeof value.inputFingerprint !== "string" ||
    !/^sha256:[a-f0-9]{64}$/.test(value.inputFingerprint) ||
    !Number.isSafeInteger(value.sourceMajor) ||
    !Array.isArray(value.runtimeCandidates)
  ) {
    throw new ApplicationError(
      "project_context_invalid",
      "The current project context is invalid.",
    );
  }
  try {
    createProjectId(value.projectId);
    createAngularMajor(value.sourceMajor);
  } catch {
    throw new ApplicationError(
      "project_context_invalid",
      "The current project identity or Angular major is invalid.",
    );
  }
  return {
    projectId: value.projectId,
    inputFingerprint: value.inputFingerprint,
    sourceMajor: value.sourceMajor,
    gitStatus: typeof value.gitStatus === "string" ? value.gitStatus : "",
    runtimeCandidates: value.runtimeCandidates,
  };
}

function assertStartablePlan(
  plan: DiscoveryRecord,
  context: ReturnType<typeof readCurrentContext>,
): void {
  if (plan.status !== "ready" || plan.runtimePlan.status !== "ready") {
    throw new ApplicationError(
      "discovery_not_ready",
      "Only a ready discovery plan can start a run.",
    );
  }
  if (context.gitStatus !== "clean") {
    throw new ApplicationError(
      "project_not_clean",
      "The project Git working tree must be clean at run start.",
    );
  }
  if (context.sourceMajor !== plan.sourceMajor) {
    throw new ApplicationError(
      "project_major_mismatch",
      "The current Angular major differs from the discovery plan.",
    );
  }
  const selected = plan.runtimePlan.selected;
  const available = context.runtimeCandidates.some((candidate) => {
    if (!isRecord(candidate) || candidate.status !== "installed") return false;
    const node = parseExactSemverVersion(candidate.nodeVersion);
    const npm = parseExactSemverVersion(candidate.npmVersion);
    return (
      node?.version === selected?.nodeVersion &&
      npm?.version === selected?.npmVersion
    );
  });
  if (!selected || selected.status !== "installed" || !available) {
    throw new ApplicationError(
      "planned_runtime_unavailable",
      "The exact planned Node/npm runtime is no longer available.",
    );
  }
}

function isRunRecord(value: unknown): value is RunRecord {
  return Boolean(
    isRecord(value) &&
    value.schemaVersion === 1 &&
    isValidPersistedRunState(value.state) &&
    Array.isArray(value.events) &&
    value.events.every(isRunEvent) &&
    value.events.every((event, index) => event.sequence === index) &&
    hasValidEventSequence(value.events, value.state) &&
    Array.isArray(value.checkpoints) &&
    value.checkpoints.every(isRunCheckpoint) &&
    value.checkpoints.every(
      (checkpoint, index) => checkpoint.sequence === index,
    ) &&
    hasValidCheckpointPairs(value.checkpoints) &&
    isRecord(value.discoveryPlan) &&
    (value.diagnostic === null || isSafeDiagnostic(value.diagnostic)) &&
    typeof value.recordHash === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(value.recordHash),
  );
}

function isValidPersistedRunState(value: unknown): value is RunRecord["state"] {
  return Boolean(
    isRecord(value) &&
    isValidRunState(value as RunRecord["state"]) &&
    typeof value.runId === "string" &&
    /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value.runId) &&
    typeof value.projectId === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(value.projectId) &&
    Number.isSafeInteger(value.sourceMajor) &&
    Number.isSafeInteger(value.targetMajor) &&
    value.targetMajor === value.sourceMajor + 1 &&
    Number.isSafeInteger(value.revision) &&
    value.revision >= 0,
  );
}

function isRunEvent(value: unknown): value is RunRecord["events"][number] {
  return Boolean(
    isRecord(value) &&
    Number.isSafeInteger(value.sequence) &&
    [
      "run-started",
      "stage-started",
      "stage-completed",
      "stage-blocked",
      "stage-failed",
      "check-skipped",
      "stage-needs-repair",
      "repair-accepted",
      "repair-rejected",
      "baseline-dependency-approval-started",
      "baseline-dependency-approval-failed",
      "baseline-dependencies-approved",
      "documentation-research-recorded",
      "documentation-publish-started",
      "documentation-published",
    ].includes(String(value.type)) &&
    [
      "baseline",
      "resolve",
      "update-angular",
      "update-dependencies",
      "install",
      "validate",
      "document",
      "done",
    ].includes(String(value.stage)) &&
    [
      "running",
      "needs-repair",
      "verified",
      "completed",
      "blocked",
      "failed",
    ].includes(String(value.status)) &&
    Number.isSafeInteger(value.revision) &&
    value.revision >= 0 &&
    (value.type !== "check-skipped" || isCheckSkipDetails(value.skip)) &&
    (value.type === "check-skipped" || value.skip === undefined) &&
    (["repair-accepted", "repair-rejected"].includes(String(value.type))
      ? isRepairEventDetails(value.repair)
      : value.repair === undefined) &&
    ([
      "baseline-dependency-approval-started",
      "baseline-dependency-approval-failed",
      "baseline-dependencies-approved",
    ].includes(String(value.type))
      ? isBaselineApprovalDetails(value.baselineApproval)
      : value.baselineApproval === undefined) &&
    ([
      "documentation-research-recorded",
      "documentation-publish-started",
      "documentation-published",
    ].includes(String(value.type))
      ? isDocumentationEventDetails(value.documentation)
      : value.documentation === undefined),
  );
}

function isRunCheckpoint(
  value: unknown,
): value is RunRecord["checkpoints"][number] {
  return Boolean(
    isRecord(value) &&
    Number.isSafeInteger(value.sequence) &&
    [
      "baseline",
      "resolve",
      "update-angular",
      "update-dependencies",
      "install",
      "validate",
      "document",
      "done",
    ].includes(String(value.stage)) &&
    typeof value.operationId === "string" &&
    /^[a-z][a-z0-9-]{0,63}$/.test(value.operationId) &&
    (value.phase === "before" ||
      value.phase === "after" ||
      value.phase === "skipped") &&
    typeof value.projectFingerprint === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(value.projectFingerprint) &&
    typeof value.idempotencyKey === "string" &&
    /^[0-9a-f-]{36}:[a-z-]+:[a-z][a-z0-9-]{0,63}:(?:before|after|skipped)$/.test(
      value.idempotencyKey,
    ),
  );
}

function hasValidCheckpointPairs(
  checkpoints: readonly RunRecord["checkpoints"][number][],
): boolean {
  let pending: RunRecord["checkpoints"][number] | undefined;
  let previousStageIndex = -1;
  const keys = new Set<string>();
  for (const checkpoint of checkpoints) {
    const stageIndex = RUN_STAGE_ORDER.indexOf(checkpoint.stage);
    if (
      stageIndex < previousStageIndex ||
      stageIndex > previousStageIndex + 1
    ) {
      return false;
    }
    previousStageIndex = stageIndex;
    if (keys.has(checkpoint.idempotencyKey)) return false;
    keys.add(checkpoint.idempotencyKey);
    if (checkpoint.phase === "before") {
      if (pending) return false;
      pending = checkpoint;
      continue;
    }
    if (
      !pending ||
      pending.stage !== checkpoint.stage ||
      pending.operationId !== checkpoint.operationId
    ) {
      return false;
    }
    pending = undefined;
  }
  return true;
}

function hasValidEventSequence(
  events: readonly RunRecord["events"][number][],
  state: RunRecord["state"],
): boolean {
  if (
    events.length === 0 ||
    events[0].type !== "run-started" ||
    events[0].stage !== "baseline" ||
    events[0].status !== "running" ||
    events[0].revision !== 0
  ) {
    return false;
  }
  let stage: RunRecord["state"]["stage"] = "baseline";
  let status: RunRecord["state"]["status"] = "running";
  let revision = 0;
  let stageStarted = false;
  let terminal = false;
  let pendingBaselineApproval:
    | RunRecord["events"][number]["baselineApproval"]
    | undefined;
  let pendingDocumentationPublication:
    | RunRecord["events"][number]["documentation"]
    | undefined;
  let documentationPublished = false;
  for (const event of events.slice(1)) {
    if (event.type === "documentation-research-recorded") {
      if (
        !isDocumentationEventDetails(event.documentation) ||
        event.documentation.outcome !== "research-recorded" ||
        !["running", "verified"].includes(status) ||
        event.stage !== stage ||
        event.status !== status ||
        event.revision !== revision ||
        pendingDocumentationPublication
      ) {
        return false;
      }
      continue;
    }
    if (event.type === "documentation-publish-started") {
      if (
        status !== "verified" ||
        stage !== "document" ||
        event.stage !== stage ||
        event.status !== status ||
        event.revision !== revision ||
        !isDocumentationEventDetails(event.documentation) ||
        event.documentation.outcome !== "publish-started" ||
        pendingDocumentationPublication ||
        documentationPublished
      ) {
        return false;
      }
      pendingDocumentationPublication = event.documentation;
      continue;
    }
    if (event.type === "documentation-published") {
      if (
        status !== "verified" ||
        stage !== "document" ||
        event.stage !== stage ||
        event.status !== status ||
        event.revision !== revision ||
        !isDocumentationEventDetails(event.documentation) ||
        event.documentation.outcome !== "published" ||
        !matchesDocumentationPublication(
          pendingDocumentationPublication,
          event.documentation,
        )
      ) {
        return false;
      }
      pendingDocumentationPublication = undefined;
      documentationPublished = true;
      continue;
    }
    if (terminal) {
      if (
        event.type === "baseline-dependency-approval-started" &&
        status === "blocked" &&
        stage === "baseline" &&
        event.stage === stage &&
        event.status === "blocked" &&
        event.revision === revision &&
        isBaselineApprovalDetails(event.baselineApproval) &&
        event.baselineApproval.outcome === "started" &&
        !pendingBaselineApproval
      ) {
        pendingBaselineApproval = event.baselineApproval;
        continue;
      }
      if (
        event.type === "baseline-dependency-approval-failed" &&
        status === "blocked" &&
        stage === "baseline" &&
        event.stage === stage &&
        event.status === "blocked" &&
        event.revision === revision &&
        isBaselineApprovalDetails(event.baselineApproval) &&
        event.baselineApproval.outcome === "failed" &&
        matchesBaselineApproval(pendingBaselineApproval, event.baselineApproval)
      ) {
        pendingBaselineApproval = undefined;
        continue;
      }
      if (
        event.type === "baseline-dependencies-approved" &&
        status === "blocked" &&
        stage === "baseline" &&
        event.stage === stage &&
        event.status === "running" &&
        event.revision === revision + 1 &&
        isBaselineApprovalDetails(event.baselineApproval) &&
        event.baselineApproval.outcome === "installed" &&
        matchesBaselineApproval(
          pendingBaselineApproval,
          event.baselineApproval,
        ) &&
        event.baselineApproval.packageStateHash !== null
      ) {
        pendingBaselineApproval = undefined;
        status = "running";
        revision += 1;
        terminal = false;
        continue;
      }
      if (event.type === "repair-rejected" && status === "needs-repair") {
        if (
          event.stage !== stage ||
          event.status !== "needs-repair" ||
          event.revision !== revision ||
          !isRepairEventDetails(event.repair) ||
          event.repair.outcome !== "rejected"
        ) {
          return false;
        }
        continue;
      }
      if (
        event.stage !== stage ||
        event.revision !== revision + 1 ||
        !(
          (event.type === "check-skipped" &&
            status === "blocked" &&
            event.status === "running" &&
            isCheckSkipDetails(event.skip)) ||
          (event.type === "repair-accepted" &&
            status === "needs-repair" &&
            event.status === "running" &&
            isRepairEventDetails(event.repair) &&
            event.repair.outcome === "accepted")
        )
      ) {
        return false;
      }
      status = event.status;
      revision += 1;
      terminal = false;
      continue;
    }
    if (event.type === "stage-started") {
      if (
        stageStarted ||
        status !== "running" ||
        event.stage !== stage ||
        event.status !== status ||
        event.revision !== revision
      ) {
        return false;
      }
      stageStarted = true;
      continue;
    }
    if (event.type === "stage-completed") {
      if (
        !stageStarted ||
        event.stage !== stage ||
        event.revision !== revision + 1 ||
        event.status !== (stage === "validate" ? "verified" : "running")
      ) {
        return false;
      }
      status = event.status;
      revision += 1;
      stage = nextRunStage(stage);
      stageStarted = false;
      continue;
    }
    if (
      !["stage-blocked", "stage-failed", "stage-needs-repair"].includes(
        event.type,
      ) ||
      event.stage !== stage ||
      event.status !==
        (event.type === "stage-blocked"
          ? "blocked"
          : event.type === "stage-failed"
            ? "failed"
            : "needs-repair") ||
      event.revision !== revision + 1
    ) {
      return false;
    }
    status = event.status;
    revision += 1;
    terminal = true;
  }
  return (
    stage === state.stage &&
    status === state.status &&
    revision === state.revision &&
    (pendingBaselineApproval === undefined ||
      (status === "blocked" &&
        events.at(-1)?.type === "baseline-dependency-approval-started")) &&
    (pendingDocumentationPublication === undefined ||
      (status === "verified" &&
        events.at(-1)?.type === "documentation-publish-started"))
  );
}

function isCheckSkipDetails(value: unknown): boolean {
  return Boolean(
    isRecord(value) &&
    typeof value.checkId === "string" &&
    /^[a-z][a-z0-9-]{0,63}$/.test(value.checkId) &&
    typeof value.reason === "string" &&
    value.reason.trim().length > 0 &&
    value.reason.length <= 2000 &&
    value.confirmed === true,
  );
}

function isRepairEventDetails(
  value: unknown,
): value is NonNullable<RunRecord["events"][number]["repair"]> {
  return Boolean(
    isRecord(value) &&
    Number.isSafeInteger(value.attempt) &&
    value.attempt >= 1 &&
    value.attempt <= 3 &&
    typeof value.fingerprint === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(value.fingerprint) &&
    typeof value.submissionHash === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(value.submissionHash) &&
    Array.isArray(value.changedPaths) &&
    value.changedPaths.length > 0 &&
    value.changedPaths.every(
      (file) =>
        typeof file === "string" &&
        /^src\/[A-Za-z0-9._/-]+$/.test(file) &&
        !file.split("/").includes(".."),
    ) &&
    ["accepted", "rejected"].includes(String(value.outcome)),
  );
}

function isBaselineApprovalDetails(
  value: unknown,
): value is NonNullable<RunRecord["events"][number]["baselineApproval"]> {
  return Boolean(
    isRecord(value) &&
    typeof value.proposalHash === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(value.proposalHash) &&
    Array.isArray(value.packages) &&
    value.packages.length > 0 &&
    value.packages.every(
      (item: unknown) =>
        isRecord(item) &&
        typeof item.name === "string" &&
        /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(item.name) &&
        !item.name.startsWith("@angular/") &&
        typeof item.version === "string" &&
        parseExactSemverVersion(item.version)?.version === item.version,
    ) &&
    ["started", "failed", "installed"].includes(String(value.outcome)) &&
    (value.packageStateHash === null ||
      (typeof value.packageStateHash === "string" &&
        /^sha256:[a-f0-9]{64}$/.test(value.packageStateHash))),
  );
}

function matchesBaselineApproval(
  started: RunRecord["events"][number]["baselineApproval"] | undefined,
  finished: NonNullable<RunRecord["events"][number]["baselineApproval"]>,
): boolean {
  return Boolean(
    started &&
    started.proposalHash === finished.proposalHash &&
    JSON.stringify(started.packages) === JSON.stringify(finished.packages),
  );
}

function isDocumentationEventDetails(
  value: unknown,
): value is NonNullable<RunRecord["events"][number]["documentation"]> {
  if (
    !isRecord(value) ||
    typeof value.researchHash !== "string" ||
    !/^sha256:[a-f0-9]{64}$/.test(value.researchHash)
  ) {
    return false;
  }
  if (value.outcome === "research-recorded") {
    return (
      value.proposalHash === null &&
      value.filesHash === null &&
      value.outputDirectory === null &&
      value.expectedGitSnapshot === null
    );
  }
  return (
    ["publish-started", "published"].includes(String(value.outcome)) &&
    typeof value.proposalHash === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(value.proposalHash) &&
    typeof value.filesHash === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(value.filesHash) &&
    typeof value.outputDirectory === "string" &&
    /^docs\/migration\/v[1-9]\d*$/.test(value.outputDirectory) &&
    isDocumentationGitSnapshot(value.expectedGitSnapshot)
  );
}

function isDocumentationGitSnapshot(value: unknown): boolean {
  return Boolean(
    isRecord(value) &&
    typeof value.head === "string" &&
    /^[a-f0-9]{40,64}$/.test(value.head) &&
    Array.isArray(value.changes) &&
    value.changes.length <= 2000 &&
    value.changes.every(
      (item: unknown) =>
        isRecord(item) &&
        typeof item.path === "string" &&
        item.path.length > 0 &&
        item.path.length <= 1024 &&
        !item.path.includes("\0") &&
        typeof item.status === "string" &&
        /^[ MADRCU?!]{2}$/.test(item.status),
    ),
  );
}

function matchesDocumentationPublication(
  started: RunRecord["events"][number]["documentation"] | undefined,
  published: NonNullable<RunRecord["events"][number]["documentation"]>,
): boolean {
  return Boolean(
    started &&
    started.outcome === "publish-started" &&
    started.researchHash === published.researchHash &&
    started.proposalHash === published.proposalHash &&
    started.filesHash === published.filesHash &&
    started.outputDirectory === published.outputDirectory &&
    JSON.stringify(started.expectedGitSnapshot) ===
      JSON.stringify(published.expectedGitSnapshot),
  );
}

const RUN_STAGE_ORDER: readonly RunRecord["state"]["stage"][] = [
  "baseline",
  "resolve",
  "update-angular",
  "update-dependencies",
  "install",
  "validate",
  "document",
  "done",
];

function nextRunStage(
  stage: RunRecord["state"]["stage"],
): RunRecord["state"]["stage"] {
  const index = RUN_STAGE_ORDER.indexOf(stage);
  return RUN_STAGE_ORDER[Math.min(index + 1, RUN_STAGE_ORDER.length - 1)];
}

function isSafeDiagnostic(value: unknown): value is {
  readonly code: string;
  readonly message: string;
} {
  return Boolean(
    isRecord(value) &&
    typeof value.code === "string" &&
    /^[a-z][a-z0-9_]{0,63}$/.test(value.code) &&
    typeof value.message === "string" &&
    value.message.length > 0 &&
    !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(value.message),
  );
}

function isRecord(value: unknown): value is Record<string, any> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
