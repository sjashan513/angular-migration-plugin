import { parseExactSemverVersion } from "../domain/semver-constraints.js";
import { ApplicationError } from "./application-error.js";
import {
  discoverProject,
  type DiscoverProjectPorts,
  type DiscoveryRecord,
} from "./discover-project.js";
import type {
  ExactRuntimeInstaller,
  RuntimeInstallApprovalResult,
  RuntimeInstallAuditEvent,
  RuntimeInstallAuditStore,
} from "./ports/approvals.js";
import type { RunLock, RunRecordStore } from "./ports/run-lifecycle.js";
import { readValidatedRunRecord } from "./start-run.js";

export interface ApproveRuntimeInstallPorts extends DiscoverProjectPorts {
  readonly runRecords: RunRecordStore;
  readonly lock: RunLock;
  readonly installer: ExactRuntimeInstaller;
  readonly audit: RuntimeInstallAuditStore;
}

export async function approveRuntimeInstall(
  request: {
    readonly projectRoot: string;
    readonly targetMajor: number;
    readonly proposalHash: string;
    readonly confirmed: boolean;
  },
  ports: ApproveRuntimeInstallPorts,
): Promise<RuntimeInstallApprovalResult> {
  if (
    !request ||
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0 ||
    !Number.isSafeInteger(request.targetMajor) ||
    typeof request.proposalHash !== "string" ||
    !/^sha256:[a-f0-9]{64}$/.test(request.proposalHash) ||
    request.confirmed !== true
  ) {
    throw new ApplicationError(
      request?.confirmed === true
        ? "runtime_approval_request_invalid"
        : "confirmation_required",
      request?.confirmed === true
        ? "A current runtime proposal hash is required."
        : "Runtime installation requires explicit confirmation.",
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

  let result: RuntimeInstallApprovalResult | undefined;
  let failure: unknown;
  try {
    await assertNoActiveRun(request.projectRoot, ports);
    const history = await readAuditHistory(request.projectRoot, ports);
    if (history.pending) {
      throw new ApplicationError(
        "runtime_install_recovery_required",
        "A previous runtime installation has an unconfirmed outcome.",
        "blocked",
      );
    }

    const plan = await discoverProject(request, ports);
    if (plan.planHash !== request.proposalHash) {
      throw new ApplicationError(
        "runtime_proposal_stale",
        "The runtime proposal changed; review the current discovery before approving it.",
        "blocked",
      );
    }
    const nodeVersion = plan.runtimePlan.selected?.nodeVersion;
    if (
      plan.status !== "runtime-install-required" ||
      plan.runtimePlan.status !== "runtime-install-required" ||
      plan.runtimePlan.selected?.status !== "missing" ||
      !nodeVersion ||
      !parseExactSemverVersion(nodeVersion)
    ) {
      throw new ApplicationError(
        "runtime_install_not_required",
        "The current discovery has no exact missing-runtime proposal.",
        "blocked",
      );
    }
    if (history.events.some((event) => event.proposalHash === plan.planHash)) {
      throw new ApplicationError(
        "runtime_install_already_attempted",
        "This runtime proposal was already attempted and cannot be replayed.",
        "blocked",
      );
    }

    const started = await createAuditEvent(
      history.events,
      plan,
      nodeVersion,
      "started",
      ports,
    );
    await ports.audit.write(request.projectRoot, [...history.events, started]);

    let installOutcome: "installed" | "failed";
    try {
      installOutcome = await ports.installer.install(
        request.projectRoot,
        nodeVersion,
      );
    } catch {
      installOutcome = "failed";
    }
    if (installOutcome !== "installed") {
      await appendAuditOutcome(
        request.projectRoot,
        [...history.events, started],
        plan,
        nodeVersion,
        "failed",
        ports,
      );
      throw new ApplicationError(
        "runtime_install_failed",
        "The approved exact runtime could not be installed and verified.",
        "blocked",
      );
    }

    let refreshed: DiscoveryRecord;
    try {
      refreshed = await discoverProject(request, ports);
    } catch {
      await appendAuditOutcome(
        request.projectRoot,
        [...history.events, started],
        plan,
        nodeVersion,
        "failed",
        ports,
      );
      throw new ApplicationError(
        "runtime_install_unverified",
        "The installed runtime could not be verified by a fresh discovery.",
        "blocked",
      );
    }
    if (
      refreshed.status !== "ready" ||
      refreshed.runtimePlan.status !== "ready" ||
      refreshed.runtimePlan.selected?.nodeVersion !== nodeVersion ||
      refreshed.runtimePlan.selected.status !== "installed"
    ) {
      await appendAuditOutcome(
        request.projectRoot,
        [...history.events, started],
        plan,
        nodeVersion,
        "failed",
        ports,
      );
      throw new ApplicationError(
        "runtime_install_unverified",
        "The installed runtime does not satisfy the current Node and npm constraints.",
        "blocked",
      );
    }
    await appendAuditOutcome(
      request.projectRoot,
      [...history.events, started],
      plan,
      nodeVersion,
      "installed",
      ports,
    );
    result = {
      status: "installed",
      proposalHash: plan.planHash,
      nodeVersion,
      discovery: refreshed,
    };
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

async function assertNoActiveRun(
  projectRoot: string,
  ports: ApproveRuntimeInstallPorts,
): Promise<void> {
  const stored = await ports.runRecords.read(projectRoot);
  if (stored === null) return;
  const run = await readValidatedRunRecord(stored, ports.hasher);
  if (run.state.status !== "completed") {
    throw new ApplicationError(
      "run_already_active",
      "Runtime installation cannot run while a migration run is active.",
      "blocked",
    );
  }
}

async function readAuditHistory(
  projectRoot: string,
  ports: ApproveRuntimeInstallPorts,
): Promise<{
  readonly events: readonly RuntimeInstallAuditEvent[];
  readonly pending: boolean;
}> {
  const value = await ports.audit.read(projectRoot);
  if (value === null) return { events: [], pending: false };
  if (!Array.isArray(value)) return invalidAudit();
  const events: RuntimeInstallAuditEvent[] = [];
  let pending: RuntimeInstallAuditEvent | undefined;
  for (const item of value) {
    if (!isAuditEvent(item) || item.sequence !== events.length)
      return invalidAudit();
    const { eventHash, ...content } = item;
    if (
      item.previousHash !== (events.at(-1)?.eventHash ?? null) ||
      (await ports.hasher.hash(content)) !== eventHash
    ) {
      return invalidAudit();
    }
    if (item.outcome === "started") {
      if (pending) return invalidAudit();
      pending = item;
    } else {
      if (
        !pending ||
        pending.projectId !== item.projectId ||
        pending.inputFingerprint !== item.inputFingerprint ||
        pending.proposalHash !== item.proposalHash ||
        pending.nodeVersion !== item.nodeVersion
      ) {
        return invalidAudit();
      }
      pending = undefined;
    }
    events.push(item);
  }
  return { events, pending: pending !== undefined };
}

async function createAuditEvent(
  events: readonly RuntimeInstallAuditEvent[],
  plan: DiscoveryRecord,
  nodeVersion: string,
  outcome: RuntimeInstallAuditEvent["outcome"],
  ports: ApproveRuntimeInstallPorts,
): Promise<RuntimeInstallAuditEvent> {
  const content = {
    sequence: events.length,
    projectId: plan.projectId,
    inputFingerprint: plan.inputFingerprint,
    proposalHash: plan.planHash,
    nodeVersion,
    outcome,
    previousHash: events.at(-1)?.eventHash ?? null,
  };
  return { ...content, eventHash: await ports.hasher.hash(content) };
}

async function appendAuditOutcome(
  projectRoot: string,
  events: readonly RuntimeInstallAuditEvent[],
  plan: DiscoveryRecord,
  nodeVersion: string,
  outcome: "installed" | "failed",
  ports: ApproveRuntimeInstallPorts,
): Promise<void> {
  const event = await createAuditEvent(
    events,
    plan,
    nodeVersion,
    outcome,
    ports,
  );
  await ports.audit.write(projectRoot, [...events, event]);
}

function isAuditEvent(value: unknown): value is RuntimeInstallAuditEvent {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const event = value as RuntimeInstallAuditEvent;
  return (
    Number.isSafeInteger(event.sequence) &&
    typeof event.projectId === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(event.projectId) &&
    typeof event.inputFingerprint === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(event.inputFingerprint) &&
    typeof event.proposalHash === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(event.proposalHash) &&
    typeof event.nodeVersion === "string" &&
    parseExactSemverVersion(event.nodeVersion) !== null &&
    ["started", "installed", "failed"].includes(event.outcome) &&
    (event.previousHash === null ||
      (typeof event.previousHash === "string" &&
        /^sha256:[a-f0-9]{64}$/.test(event.previousHash))) &&
    typeof event.eventHash === "string" &&
    /^sha256:[a-f0-9]{64}$/.test(event.eventHash)
  );
}

function invalidAudit(): never {
  throw new ApplicationError(
    "runtime_install_audit_invalid",
    "Runtime installation audit history is invalid or corrupted.",
    "blocked",
  );
}
