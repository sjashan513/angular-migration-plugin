import { ApplicationError } from "./application-error.js";
import type { ValueHasher } from "./ports/project-discovery.js";
import type {
  RunProjectContextReader,
  RunStatusStore,
} from "./ports/run-lifecycle.js";
import { readValidatedRunRecord } from "./start-run.js";

export interface RunStatus {
  readonly schemaVersion: 1;
  readonly runId: string;
  readonly status: string;
  readonly stage: string;
  readonly sourceMajor: number;
  readonly targetMajor: number;
  readonly revision: number;
  readonly nextAction: "run" | "human-intervention" | "documentation" | "none";
  readonly diagnostic: {
    readonly code: string;
    readonly message: string;
  } | null;
}

export async function getRunStatus(
  request: { readonly projectRoot: string },
  ports: {
    readonly records: RunStatusStore;
    readonly context: RunProjectContextReader;
    readonly hasher: ValueHasher;
  },
): Promise<RunStatus> {
  if (
    !request ||
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0
  ) {
    throw new ApplicationError(
      "status_request_invalid",
      "A project root is required to read run status.",
    );
  }
  const value = await ports.records.read(request.projectRoot);
  if (value === null) {
    throw new ApplicationError(
      "run_not_found",
      "No run exists for this project.",
    );
  }
  const record = await readValidatedRunRecord(value, ports.hasher);
  const state = record.state;
  let diagnostic: RunStatus["diagnostic"] = null;
  let nextAction: RunStatus["nextAction"] =
    state.status === "running"
      ? "run"
      : state.status === "verified"
        ? "documentation"
        : state.status === "completed"
          ? "none"
          : "human-intervention";
  const latest = record.checkpoints.at(-1);
  if (
    (state.status === "running" || state.status === "verified") &&
    latest?.phase === "before"
  ) {
    nextAction = "human-intervention";
    diagnostic = {
      code: "operation_outcome_ambiguous",
      message: "An operation has no verified after-checkpoint.",
    };
  } else if (state.status === "running" || state.status === "verified") {
    try {
      const [facts, fingerprint] = await Promise.all([
        ports.context.readProjectFacts(request.projectRoot),
        ports.context.readFingerprint(request.projectRoot),
      ]);
      const expectedMajor = expectedAngularMajor(record);
      const expectedFingerprint =
        latest?.projectFingerprint ?? record.discoveryPlan.inputFingerprint;
      if (facts.projectId !== state.projectId) {
        diagnostic = {
          code: "project_identity_changed",
          message: "The current project identity differs from the run.",
        };
      } else if (facts.angularMajor !== expectedMajor) {
        diagnostic = {
          code: "project_major_unexpected",
          message:
            "The current Angular major differs from the last checkpoint.",
        };
      } else if (
        !/^sha256:[a-f0-9]{64}$/.test(fingerprint) ||
        fingerprint !== expectedFingerprint
      ) {
        diagnostic = {
          code: "project_fingerprint_changed",
          message: "Project inputs changed after the last verified checkpoint.",
        };
      }
    } catch {
      diagnostic = {
        code: "project_state_unavailable",
        message: "Current project state could not be verified safely.",
      };
    }
    if (diagnostic) nextAction = "human-intervention";
  }
  return {
    schemaVersion: 1,
    runId: state.runId,
    status: state.status,
    stage: state.stage,
    sourceMajor: state.sourceMajor,
    targetMajor: state.targetMajor,
    revision: state.revision,
    nextAction,
    diagnostic,
  };
}

function expectedAngularMajor(
  record: Awaited<ReturnType<typeof readValidatedRunRecord>>,
): number {
  return [
    "update-dependencies",
    "install",
    "validate",
    "document",
    "done",
  ].includes(record.state.stage) ||
    (record.state.stage === "update-angular" &&
      record.checkpoints.at(-1)?.stage === "update-angular" &&
      record.checkpoints.at(-1)?.phase === "after")
    ? record.state.targetMajor
    : record.state.sourceMajor;
}
