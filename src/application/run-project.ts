import { decideRunTransition, type RunStage } from "../domain/run-state.js";
import { parseExactSemverVersion } from "../domain/semver-constraints.js";
import { ApplicationError } from "./application-error.js";
import type { ValueHasher } from "./ports/project-discovery.js";
import type { ProjectFactsReader } from "./ports/project-facts-reader.js";
import type {
  ProjectFingerprintReader,
  RunLock,
  RunOperation,
  RunOperationExecutor,
  RunRecord,
  RunRecordStore,
} from "./ports/run-lifecycle.js";
import { readValidatedRunRecord, sealRunRecord } from "./start-run.js";

export interface RunProjectPorts {
  readonly records: RunRecordStore;
  readonly lock: RunLock;
  readonly facts: ProjectFactsReader;
  readonly fingerprints: ProjectFingerprintReader;
  readonly operations: RunOperationExecutor;
  readonly hasher: ValueHasher;
}

export async function runProject(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: RunProjectPorts,
): Promise<RunRecord> {
  if (
    !request ||
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0 ||
    typeof request.runId !== "string" ||
    request.runId.trim().length === 0
  ) {
    throw new ApplicationError(
      "run_request_invalid",
      "A project root and run id are required.",
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
    const stored = await ports.records.read(request.projectRoot);
    if (stored === null) {
      throw new ApplicationError(
        "run_not_found",
        "No run exists for this project.",
      );
    }
    let record = await readValidatedRunRecord(stored, ports.hasher);
    if (record.state.runId !== request.runId) {
      throw new ApplicationError(
        "run_context_mismatch",
        "The requested run id does not match the active run.",
      );
    }
    if (record.state.status !== "running") {
      result = record;
    } else {
      record = await verifyCurrentRunContext(
        record,
        request.projectRoot,
        ports,
      );
      if (record.state.status !== "running") {
        result = record;
      } else {
        result = await executeStages(record, request.projectRoot, ports);
      }
    }
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

async function verifyCurrentRunContext(
  record: RunRecord,
  projectRoot: string,
  ports: RunProjectPorts,
): Promise<RunRecord> {
  const latest = record.checkpoints.at(-1);
  if (latest?.phase === "before") {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "operation_outcome_ambiguous",
      message:
        "An operation has no verified after-checkpoint; automatic retry is unsafe.",
    });
  }
  let facts;
  let fingerprint: string;
  try {
    [facts, fingerprint] = await Promise.all([
      ports.facts.readProjectFacts(projectRoot),
      ports.fingerprints.readFingerprint(projectRoot),
    ]);
  } catch {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "project_state_unavailable",
      message: "Current project state could not be verified safely.",
    });
  }
  if (facts.projectId !== record.state.projectId) {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "project_identity_changed",
      message: "The project identity differs from the one bound to this run.",
    });
  }
  const expectedMajor =
    record.state.stage === "update-angular" &&
    latest?.stage === "update-angular" &&
    latest.phase === "after"
      ? record.state.targetMajor
      : [
            "update-dependencies",
            "install",
            "validate",
            "document",
            "done",
          ].includes(record.state.stage)
        ? record.state.targetMajor
        : record.state.sourceMajor;
  if (facts.angularMajor !== expectedMajor) {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "project_major_unexpected",
      message:
        "The project Angular major does not match the last verified stage.",
    });
  }
  const expectedFingerprint =
    latest?.projectFingerprint ?? record.discoveryPlan.inputFingerprint;
  if (!isSha256(fingerprint) || fingerprint !== expectedFingerprint) {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "project_fingerprint_changed",
      message: "Project inputs changed outside the last verified checkpoint.",
    });
  }
  return record;
}

async function executeStages(
  initial: RunRecord,
  projectRoot: string,
  ports: RunProjectPorts,
): Promise<RunRecord> {
  let record = initial;
  while (record.state.status === "running") {
    const stage = record.state.stage;
    const operations = buildOperations(record, stage);
    const latest = record.checkpoints.at(-1);
    let startAt = 0;
    if (latest?.stage === stage) {
      if (latest.phase === "before") {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "operation_outcome_ambiguous",
          message:
            "An operation has no verified after-checkpoint; automatic retry is unsafe.",
        });
      }
      const completedIndex = operations.findIndex(
        (operation) => operation.id === latest.operationId,
      );
      if (completedIndex < 0) {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "checkpoint_operation_invalid",
          message: "The last checkpoint does not match the current stage plan.",
        });
      }
      startAt = completedIndex + 1;
    }

    for (let index = startAt; index < operations.length; index += 1) {
      const operation = operations[index];
      let beforeFingerprint: string;
      try {
        beforeFingerprint =
          await ports.fingerprints.readFingerprint(projectRoot);
      } catch {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "project_state_unavailable",
          message:
            "Current project state could not be verified before an operation.",
        });
      }
      const prior = record.checkpoints.at(-1);
      const expected =
        prior?.projectFingerprint ?? record.discoveryPlan.inputFingerprint;
      if (beforeFingerprint !== expected) {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "project_fingerprint_changed",
          message:
            "Project inputs changed outside the last verified checkpoint.",
        });
      }
      record = await saveCheckpoint(record, projectRoot, ports, {
        operation,
        phase: "before",
        fingerprint: beforeFingerprint,
        startStage: !record.events.some(
          (event) => event.type === "stage-started" && event.stage === stage,
        ),
      });

      let operationResult;
      try {
        operationResult = await ports.operations.execute(
          projectRoot,
          operation,
        );
      } catch {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "operation_outcome_unconfirmed",
          message:
            "An operation failed before its postcondition could be confirmed.",
        });
      }
      if (operationResult.outcome !== "passed") {
        if (
          stage === "validate" &&
          operation.id.startsWith("validate-") &&
          operationResult.outcome === "blocked" &&
          operationResult.diagnostic.code === "process_nonzero_exit"
        ) {
          return finishRun(
            record,
            projectRoot,
            ports,
            "needs-repair",
            operationResult.diagnostic,
          );
        }
        return finishRun(
          record,
          projectRoot,
          ports,
          operationResult.outcome,
          operationResult.diagnostic,
        );
      }

      let afterFingerprint: string;
      try {
        afterFingerprint =
          await ports.fingerprints.readFingerprint(projectRoot);
      } catch {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "postcondition_unconfirmed",
          message:
            "The operation passed but its resulting project state is unavailable.",
        });
      }
      if (!isSha256(afterFingerprint)) {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "postcondition_invalid",
          message: "The operation returned an invalid project fingerprint.",
        });
      }
      record = await saveCheckpoint(record, projectRoot, ports, {
        operation,
        phase: "after",
        fingerprint: afterFingerprint,
        startStage: false,
      });
    }

    record = await completeStage(record, stage, projectRoot, ports);
  }
  return record;
}

function buildOperations(record: RunRecord, stage: RunStage): RunOperation[] {
  const nodeVersion = record.discoveryPlan.runtimePlan.selected?.nodeVersion;
  if (!nodeVersion || !parseExactSemverVersion(nodeVersion)) {
    throw new ApplicationError(
      "planned_runtime_invalid",
      "The run does not contain an exact planned Node runtime.",
    );
  }
  const packages = record.discoveryPlan.packages.map(
    ({ name, targetVersion }) => ({
      name,
      targetVersion,
    }),
  );
  const process = (
    id: string,
    executable: string,
    arguments_: readonly string[],
    timeoutMs: number,
    postcondition: RunOperation["postcondition"],
    expectedPackages: RunOperation["packages"] = [],
  ): RunOperation => ({
    id,
    kind: "process",
    stage,
    executable,
    arguments: arguments_,
    nodeVersion,
    timeoutMs,
    postcondition,
    packages: expectedPackages,
  });
  const packagePin = (): RunOperation => ({
    id: "pin-target-packages",
    kind: "pin-packages",
    stage,
    executable: null,
    arguments: [],
    nodeVersion,
    timeoutMs: 30_000,
    postcondition: "target-packages-declared",
    packages,
  });
  switch (stage) {
    case "baseline":
      return [
        process(
          "baseline-install",
          "npm",
          ["ci"],
          600_000,
          "package-metadata-stable",
        ),
        process(
          "baseline-dependency-tree",
          "npm",
          ["ls", "--all"],
          300_000,
          "dependency-tree",
        ),
        ...configuredCheckOperations(record, stage, process),
      ];
    case "resolve":
      return [
        {
          id: "verify-discovery-plan",
          kind: "verify-plan",
          stage,
          executable: null,
          arguments: [],
          nodeVersion,
          timeoutMs: 1,
          postcondition: "verify-plan",
          packages,
        },
      ];
    case "update-angular": {
      const core = packages.find((item) => item.name === "@angular/core");
      const cli = packages.find((item) => item.name === "@angular/cli");
      if (!core || !cli) {
        throw new ApplicationError(
          "angular_cli_metadata_missing",
          "The immutable discovery plan must include exact Angular core and CLI versions.",
        );
      }
      return [
        process(
          "angular-core-cli-update",
          "npm",
          [
            "exec",
            "--",
            "ng",
            "update",
            `@angular/core@${core.targetVersion}`,
            `@angular/cli@${cli.targetVersion}`,
          ],
          600_000,
          "target-packages-locked",
          [core, cli],
        ),
      ];
    }
    case "update-dependencies":
      return [
        packagePin(),
        process(
          "update-lockfile",
          "npm",
          ["install", "--package-lock-only", "--ignore-scripts"],
          600_000,
          "target-packages-locked",
          packages,
        ),
      ];
    case "install":
      return [
        process(
          "install-clean",
          "npm",
          ["ci"],
          600_000,
          "package-metadata-stable",
        ),
        process(
          "install-dependency-tree",
          "npm",
          ["ls", "--all"],
          300_000,
          "dependency-tree",
        ),
      ];
    case "validate":
      return configuredCheckOperations(record, stage, process);
    default:
      throw new ApplicationError(
        "run_stage_invalid",
        "The current run stage cannot execute in this lifecycle step.",
      );
  }
}

async function saveCheckpoint(
  record: RunRecord,
  projectRoot: string,
  ports: RunProjectPorts,
  input: {
    readonly operation: RunOperation;
    readonly phase: "before" | "after";
    readonly fingerprint: string;
    readonly startStage: boolean;
  },
): Promise<RunRecord> {
  const checkpoint = {
    sequence: record.checkpoints.length,
    stage: input.operation.stage,
    operationId: input.operation.id,
    phase: input.phase,
    projectFingerprint: input.fingerprint,
    idempotencyKey: `${record.state.runId}:${input.operation.stage}:${input.operation.id}:${input.phase}`,
  } as const;
  const events = input.startStage
    ? [
        ...record.events,
        {
          sequence: record.events.length,
          type: "stage-started" as const,
          stage: input.operation.stage,
          status: record.state.status,
          revision: record.state.revision,
        },
      ]
    : record.events;
  return persist(
    {
      ...record,
      events,
      checkpoints: [...record.checkpoints, checkpoint],
    },
    projectRoot,
    ports,
  );
}

async function completeStage(
  record: RunRecord,
  stage: RunStage,
  projectRoot: string,
  ports: RunProjectPorts,
): Promise<RunRecord> {
  const transition =
    stage === "validate"
      ? decideRunTransition(record.state, {
          status: "verified",
          stage: "document",
        })
      : decideRunTransition(record.state, {
          status: "running",
          stage: nextStage(stage),
        });
  if (transition.outcome !== "allowed") {
    throw new ApplicationError(
      "run_transition_rejected",
      "The lifecycle stage transition was rejected by the domain contract.",
    );
  }
  return persist(
    {
      ...record,
      state: transition.value,
      diagnostic: null,
      events: [
        ...record.events,
        {
          sequence: record.events.length,
          type: "stage-completed",
          stage,
          status: transition.value.status,
          revision: transition.value.revision,
        },
      ],
    },
    projectRoot,
    ports,
  );
}

async function finishRun(
  record: RunRecord,
  projectRoot: string,
  ports: RunProjectPorts,
  status: "blocked" | "failed" | "needs-repair",
  diagnostic: { readonly code: string; readonly message: string },
): Promise<RunRecord> {
  if (record.state.status !== "running") return record;
  const transition = decideRunTransition(record.state, {
    status,
    stage: record.state.stage,
  });
  if (transition.outcome !== "allowed") {
    throw new ApplicationError(
      "run_transition_rejected",
      "The lifecycle failure transition was rejected by the domain contract.",
    );
  }
  const event = {
    sequence: record.events.length,
    type:
      status === "blocked"
        ? ("stage-blocked" as const)
        : status === "failed"
          ? ("stage-failed" as const)
          : ("stage-needs-repair" as const),
    stage: record.state.stage,
    status,
    revision: transition.value.revision,
  };
  return persist(
    {
      ...record,
      state: transition.value,
      diagnostic,
      events: [...record.events, event],
    },
    projectRoot,
    ports,
  );
}

async function persist(
  content: Omit<RunRecord, "recordHash"> | RunRecord,
  projectRoot: string,
  ports: RunProjectPorts,
): Promise<RunRecord> {
  const { recordHash: _previousHash, ...unsigned } = content as RunRecord;
  const record = await sealRunRecord(unsigned, ports.hasher);
  await ports.records.write(projectRoot, record);
  return record;
}

function nextStage(stage: RunStage): RunStage {
  const next: Partial<Record<RunStage, RunStage>> = {
    baseline: "resolve",
    resolve: "update-angular",
    "update-angular": "update-dependencies",
    "update-dependencies": "install",
    install: "validate",
  };
  const result = next[stage];
  if (!result) {
    throw new ApplicationError(
      "run_stage_invalid",
      "No next technical stage exists.",
    );
  }
  return result;
}

function isSha256(value: string): boolean {
  return /^sha256:[a-f0-9]{64}$/.test(value);
}

function configuredCheckOperations(
  record: RunRecord,
  stage: RunStage,
  process: (
    id: string,
    executable: string,
    arguments_: readonly string[],
    timeoutMs: number,
    postcondition: RunOperation["postcondition"],
    packages?: RunOperation["packages"],
  ) => RunOperation,
): RunOperation[] {
  return record.discoveryPlan.checks
    .filter(
      (check) =>
        check.status === "configured" &&
        !["install", "dependency-tree"].includes(check.id),
    )
    .map((check) => {
      if (
        check.executable !== "npm" ||
        check.arguments.length !== 2 ||
        check.arguments[0] !== "run" ||
        !/^[a-zA-Z0-9:_-]+$/.test(check.arguments[1])
      ) {
        throw new ApplicationError(
          "project_check_invalid",
          "A configured project check is outside the supported npm script contract.",
        );
      }
      return process(
        `${stage === "baseline" ? "baseline" : "validate"}-${check.id}`,
        "npm",
        check.arguments,
        600_000,
        "exit-zero",
      );
    });
}
