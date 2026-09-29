import { decideRunTransition } from "../domain/run-state.js";
import {
  isValidSemverRange,
  parseExactSemverVersion,
  satisfiesAllSemverRanges,
} from "../domain/semver-constraints.js";
import { ApplicationError } from "./application-error.js";
import type {
  BaselineDependencyInstaller,
  BaselineDependencyProposalPackage,
  BaselineDependencyProposalReader,
} from "./ports/approvals.js";
import type { ValueHasher } from "./ports/project-discovery.js";
import type {
  ProjectFingerprintReader,
  RunLock,
  RunRecordStore,
} from "./ports/run-lifecycle.js";
import { readValidatedRunRecord, sealRunRecord } from "./start-run.js";

export interface BaselineDependencyContext {
  readonly schemaVersion: 1;
  readonly runId: string;
  readonly projectId: string;
  readonly fingerprint: string;
  readonly failedCheck: "dependency-tree";
  readonly packages: readonly BaselineDependencyProposalPackage[];
  readonly proposalHash: string;
}

export interface BaselineDependencyPorts {
  readonly records: RunRecordStore;
  readonly lock: RunLock;
  readonly fingerprints: ProjectFingerprintReader;
  readonly proposals: BaselineDependencyProposalReader;
  readonly installer: BaselineDependencyInstaller;
  readonly hasher: ValueHasher;
}

export async function getBaselineDependencyContext(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: BaselineDependencyPorts,
): Promise<BaselineDependencyContext> {
  const run = await readBaselineFailure(request, ports);
  return createProposal(request.projectRoot, run, ports);
}

export async function approveBaselineDependencies(
  request: {
    readonly projectRoot: string;
    readonly runId: string;
    readonly proposalHash: string;
    readonly confirmed: boolean;
  },
  ports: BaselineDependencyPorts,
): Promise<{
  readonly runId: string;
  readonly status: "running";
  readonly stage: "baseline";
  readonly proposalHash: string;
  readonly packageStateHash: string;
  readonly packages: readonly BaselineDependencyProposalPackage[];
}> {
  if (
    !request ||
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0 ||
    typeof request.runId !== "string" ||
    typeof request.proposalHash !== "string" ||
    !/^sha256:[a-f0-9]{64}$/.test(request.proposalHash) ||
    request.confirmed !== true
  ) {
    throw blocked(
      request?.confirmed === true
        ? "baseline_dependency_approval_invalid"
        : "confirmation_required",
      request?.confirmed === true
        ? "A current baseline dependency proposal hash is required."
        : "Baseline dependency installation requires explicit confirmation.",
    );
  }
  const lease = await ports.lock.acquire(request.projectRoot);
  if (lease.kind !== "acquired") {
    throw blocked(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended"
        ? "Another controller operation owns this project."
        : "Project lock ownership requires recovery.",
    );
  }

  let result:
    | {
        readonly runId: string;
        readonly status: "running";
        readonly stage: "baseline";
        readonly proposalHash: string;
        readonly packageStateHash: string;
        readonly packages: readonly BaselineDependencyProposalPackage[];
      }
    | undefined;
  let failure: unknown;
  try {
    let run = await readBaselineFailure(request, ports);
    const proposal = await createProposal(request.projectRoot, run, ports);
    if (proposal.proposalHash !== request.proposalHash) {
      throw blocked(
        "baseline_dependency_proposal_stale",
        "The baseline dependency proposal changed; request confirmation again.",
      );
    }
    if (
      run.events.some(
        (event) =>
          event.baselineApproval?.proposalHash === proposal.proposalHash,
      )
    ) {
      throw blocked(
        "baseline_dependency_approval_recovery_required",
        "This dependency proposal was already attempted and cannot be replayed.",
      );
    }
    const latest = run.checkpoints.at(-1)!;
    const packages = proposal.packages.map(({ name, installVersion }) => ({
      name,
      version: installVersion,
    }));
    const started = {
      sequence: run.events.length,
      type: "baseline-dependency-approval-started" as const,
      stage: "baseline" as const,
      status: "blocked" as const,
      revision: run.state.revision,
      baselineApproval: {
        proposalHash: proposal.proposalHash,
        packages,
        outcome: "started" as const,
        packageStateHash: null,
      },
    };
    run = await saveRun(
      run,
      request.projectRoot,
      { events: [...run.events, started] },
      ports,
    );

    let installed: Awaited<ReturnType<BaselineDependencyInstaller["install"]>>;
    try {
      installed = await ports.installer.install({
        projectRoot: request.projectRoot,
        runId: request.runId,
        nodeVersion: run.discoveryPlan.runtimePlan.selected!.nodeVersion,
        packages: proposal.packages,
      });
    } catch {
      installed = { outcome: "failed", packageStateHash: null };
    }
    const currentFingerprint = await ports.fingerprints
      .readFingerprint(request.projectRoot)
      .catch(() => "");
    if (
      installed.outcome !== "installed" ||
      !installed.packageStateHash ||
      !/^sha256:[a-f0-9]{64}$/.test(installed.packageStateHash) ||
      !/^sha256:[a-f0-9]{64}$/.test(currentFingerprint)
    ) {
      const failed = {
        sequence: run.events.length,
        type: "baseline-dependency-approval-failed" as const,
        stage: "baseline" as const,
        status: "blocked" as const,
        revision: run.state.revision,
        baselineApproval: {
          ...started.baselineApproval,
          outcome: "failed" as const,
          packageStateHash: installed.packageStateHash,
        },
      };
      await saveRun(
        run,
        request.projectRoot,
        { events: [...run.events, failed] },
        ports,
      );
      throw blocked(
        "baseline_dependency_install_failed",
        "Approved dependencies did not produce a verified dependency tree and controlled commit.",
      );
    }

    const transition = decideRunTransition(
      run.state,
      { status: "running", stage: "baseline" },
      "human-confirmed-retry",
    );
    if (transition.outcome !== "allowed") {
      throw blocked(
        "baseline_dependency_transition_rejected",
        "The verified dependency change cannot resume the current run.",
      );
    }
    const checkpoint = {
      sequence: run.checkpoints.length,
      stage: "baseline" as const,
      operationId: latest.operationId,
      phase: "after" as const,
      projectFingerprint: currentFingerprint,
      idempotencyKey: `${run.state.runId}:baseline:${latest.operationId}:after`,
    };
    const approved = {
      sequence: run.events.length,
      type: "baseline-dependencies-approved" as const,
      stage: "baseline" as const,
      status: "running" as const,
      revision: transition.value.revision,
      baselineApproval: {
        ...started.baselineApproval,
        outcome: "installed" as const,
        packageStateHash: installed.packageStateHash,
      },
    };
    await saveRun(
      run,
      request.projectRoot,
      {
        state: transition.value,
        diagnostic: null,
        checkpoints: [...run.checkpoints, checkpoint],
        events: [...run.events, approved],
      },
      ports,
    );
    result = {
      runId: request.runId,
      status: "running",
      stage: "baseline",
      proposalHash: proposal.proposalHash,
      packageStateHash: installed.packageStateHash,
      packages: proposal.packages,
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

async function readBaselineFailure(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: BaselineDependencyPorts,
) {
  if (
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0 ||
    typeof request.runId !== "string" ||
    request.runId.trim().length === 0
  ) {
    throw blocked(
      "baseline_dependency_request_invalid",
      "A project root and run id are required.",
    );
  }
  const stored = await ports.records.read(request.projectRoot);
  if (stored === null)
    throw blocked("run_not_found", "No run exists for this project.");
  const run = await readValidatedRunRecord(stored, ports.hasher);
  const latest = run.checkpoints.at(-1);
  if (
    run.state.runId !== request.runId ||
    run.state.status !== "blocked" ||
    run.state.stage !== "baseline" ||
    run.diagnostic?.code !== "process_nonzero_exit" ||
    latest?.stage !== "baseline" ||
    latest.operationId !== "baseline-dependency-tree" ||
    latest.phase !== "before"
  ) {
    throw blocked(
      "baseline_dependency_context_unavailable",
      "Baseline dependency approval requires a failed dependency-tree check in the active run.",
    );
  }
  if (run.events.at(-1)?.type === "baseline-dependency-approval-started") {
    throw blocked(
      "baseline_dependency_approval_recovery_required",
      "A previous dependency installation has an unconfirmed outcome.",
    );
  }
  return run;
}

async function createProposal(
  projectRoot: string,
  run: Awaited<ReturnType<typeof readValidatedRunRecord>>,
  ports: BaselineDependencyPorts,
): Promise<BaselineDependencyContext> {
  const checkpoint = run.checkpoints.at(-1)!;
  const fingerprint = await ports.fingerprints.readFingerprint(projectRoot);
  if (fingerprint !== checkpoint.projectFingerprint) {
    throw blocked(
      "baseline_dependency_context_stale",
      "Project inputs changed after the dependency-tree check failed.",
    );
  }
  const packages = validateProposalPackages(
    await ports.proposals.read(projectRoot, run),
  );
  const content = {
    schemaVersion: 1 as const,
    runId: run.state.runId,
    projectId: run.state.projectId,
    fingerprint,
    failedCheck: "dependency-tree" as const,
    packages,
  };
  const proposalHash = await ports.hasher.hash(content);
  if (!/^sha256:[a-f0-9]{64}$/.test(proposalHash)) {
    throw blocked(
      "baseline_dependency_hash_invalid",
      "The dependency proposal could not be integrity-bound.",
    );
  }
  return { ...content, proposalHash };
}

function validateProposalPackages(
  value: unknown,
): readonly BaselineDependencyProposalPackage[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 50) {
    throw blocked(
      "baseline_dependency_proposal_invalid",
      "No bounded missing-peer proposal is available.",
    );
  }
  const names = new Set<string>();
  const packages: BaselineDependencyProposalPackage[] = [];
  for (const item of value) {
    if (
      !isRecord(item) ||
      typeof item.name !== "string" ||
      !/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(item.name) ||
      item.name.startsWith("@angular/") ||
      names.has(item.name) ||
      typeof item.installVersion !== "string" ||
      parseExactSemverVersion(item.installVersion)?.version !==
        item.installVersion ||
      !Array.isArray(item.requiredRanges) ||
      item.requiredRanges.length === 0 ||
      item.requiredRanges.length > 20 ||
      !item.requiredRanges.every(isValidSemverRange) ||
      !satisfiesAllSemverRanges(item.installVersion, item.requiredRanges) ||
      !Array.isArray(item.requiredBy) ||
      item.requiredBy.length === 0 ||
      item.requiredBy.length > 100 ||
      !item.requiredBy.every(
        (parent: unknown) =>
          typeof parent === "string" &&
          parent.length <= 256 &&
          !/[\0\r\n]/.test(parent),
      )
    ) {
      throw blocked(
        "baseline_dependency_proposal_invalid",
        "The dependency proposal contains invalid or incompatible package metadata.",
      );
    }
    names.add(item.name);
    packages.push({
      name: item.name,
      installVersion: item.installVersion,
      requiredRanges: [...new Set(item.requiredRanges)].sort(),
      requiredBy: [...new Set(item.requiredBy)].sort(),
    });
  }
  return packages.sort((left, right) => left.name.localeCompare(right.name));
}

async function saveRun(
  run: Awaited<ReturnType<typeof readValidatedRunRecord>>,
  projectRoot: string,
  changes: Partial<
    Omit<Awaited<ReturnType<typeof readValidatedRunRecord>>, "recordHash">
  >,
  ports: BaselineDependencyPorts,
): Promise<Awaited<ReturnType<typeof readValidatedRunRecord>>> {
  const { recordHash: _oldHash, ...unsigned } = run;
  const updated = await sealRunRecord(
    { ...unsigned, ...changes },
    ports.hasher,
  );
  await ports.records.write(projectRoot, updated);
  return updated;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function blocked(code: string, message: string): ApplicationError {
  return new ApplicationError(code, message, "blocked");
}
