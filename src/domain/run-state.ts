import { createAngularTransition } from "./angular-transition.js";
import { DomainError } from "./domain-error.js";
import {
  createProjectId,
  createRunId,
  type AngularMajor,
  type ProjectId,
  type RunId,
} from "./identity.js";

export const RUN_STATE_SCHEMA_VERSION = 1;

export type RunStatus =
  | "running"
  | "needs-repair"
  | "verified"
  | "completed"
  | "blocked"
  | "failed";

export type RunStage =
  | "baseline"
  | "resolve"
  | "update-angular"
  | "update-dependencies"
  | "install"
  | "validate"
  | "document"
  | "done";

export interface RunState {
  readonly schemaVersion: typeof RUN_STATE_SCHEMA_VERSION;
  readonly runId: RunId;
  readonly projectId: ProjectId;
  readonly sourceMajor: AngularMajor;
  readonly targetMajor: AngularMajor;
  readonly status: RunStatus;
  readonly stage: RunStage;
  readonly revision: number;
}

export type RunTransitionEvidence =
  | "none"
  | "human-confirmed-retry"
  | "repair-verified"
  | "documentation-completed";

export type DomainDecision<T> =
  | { readonly outcome: "allowed"; readonly value: T }
  | { readonly outcome: "rejected"; readonly error: DomainError }
  | { readonly outcome: "requires-human-action"; readonly error: DomainError };

export function createInitialRunState(input: {
  readonly runId: unknown;
  readonly projectId: unknown;
  readonly sourceMajor: unknown;
  readonly targetMajor: unknown;
}): RunState {
  const transition = createAngularTransition(
    input.sourceMajor,
    input.targetMajor,
  );

  return {
    schemaVersion: RUN_STATE_SCHEMA_VERSION,
    runId: createRunId(input.runId),
    projectId: createProjectId(input.projectId),
    ...transition,
    status: "running",
    stage: "baseline",
    revision: 0,
  };
}

export function decideRunTransition(
  state: RunState,
  next: { readonly status: RunStatus; readonly stage: RunStage },
  evidence: RunTransitionEvidence = "none",
): DomainDecision<RunState> {
  if (!isValidRunState(state)) {
    return rejected(
      "invalid_run_state",
      "invalid-state",
      "Run schema, status, and stage must form a valid state.",
    );
  }

  if (
    !Number.isSafeInteger(state.revision) ||
    state.revision < 0 ||
    state.revision === Number.MAX_SAFE_INTEGER
  ) {
    return rejected(
      "invalid_run_revision",
      "invalid-state",
      "Run revision must be a non-negative safe integer.",
    );
  }

  try {
    createAngularTransition(state.sourceMajor, state.targetMajor);
  } catch (error) {
    if (error instanceof DomainError) return { outcome: "rejected", error };
    throw error;
  }

  const sameStage = state.stage === next.stage;
  const allowed = (): DomainDecision<RunState> => ({
    outcome: "allowed",
    value: { ...state, ...next, revision: state.revision + 1 },
  });

  if (
    state.status === "running" &&
    next.status === "running" &&
    NEXT_STAGE[state.stage] === next.stage &&
    evidence === "none"
  ) {
    return allowed();
  }
  if (
    state.status === "running" &&
    next.status === "needs-repair" &&
    sameStage &&
    REPAIRABLE_STAGES.has(state.stage) &&
    evidence === "none"
  ) {
    return allowed();
  }
  if (
    state.status === "running" &&
    ["blocked", "failed"].includes(next.status) &&
    sameStage &&
    evidence === "none"
  ) {
    return allowed();
  }
  if (
    state.status === "needs-repair" &&
    next.status === "running" &&
    sameStage
  ) {
    return evidence === "repair-verified"
      ? allowed()
      : requiresAction(
          "repair_verification_required",
          "Repair must pass its verification gate before the run resumes.",
        );
  }
  if (state.status === "blocked" && next.status === "running" && sameStage) {
    return evidence === "human-confirmed-retry"
      ? allowed()
      : requiresAction(
          "retry_confirmation_required",
          "A blocked run requires explicit human confirmation before retry.",
        );
  }
  if (
    state.status === "running" &&
    state.stage === "validate" &&
    next.status === "verified" &&
    next.stage === "document" &&
    evidence === "none"
  ) {
    return allowed();
  }
  if (
    state.status === "verified" &&
    state.stage === "document" &&
    next.status === "completed" &&
    next.stage === "done"
  ) {
    return evidence === "documentation-completed"
      ? allowed()
      : requiresAction(
          "documentation_completion_required",
          "The run can complete only after documentation is recorded as complete.",
        );
  }

  return rejected(
    "invalid_run_transition",
    "invalid-state",
    "The requested run state transition is not allowed.",
  );
}

const NEXT_STAGE: Partial<Record<RunStage, RunStage>> = {
  baseline: "resolve",
  resolve: "update-angular",
  "update-angular": "update-dependencies",
  "update-dependencies": "install",
  install: "validate",
};

const REPAIRABLE_STAGES = new Set<RunStage>(["update-angular", "validate"]);
const RUNNING_STAGES = new Set<RunStage>([
  "baseline",
  "resolve",
  "update-angular",
  "update-dependencies",
  "install",
  "validate",
]);

export function isValidRunState(state: RunState): boolean {
  if (state.schemaVersion !== RUN_STATE_SCHEMA_VERSION) return false;

  switch (state.status) {
    case "running":
      return RUNNING_STAGES.has(state.stage);
    case "needs-repair":
      return REPAIRABLE_STAGES.has(state.stage);
    case "verified":
      return state.stage === "document";
    case "completed":
      return state.stage === "done";
    case "blocked":
    case "failed":
      return state.stage !== "done";
  }
}

function rejected(
  code: "invalid_run_state" | "invalid_run_revision" | "invalid_run_transition",
  category: "invalid-state",
  message: string,
): DomainDecision<never> {
  return {
    outcome: "rejected",
    error: new DomainError(code, category, message),
  };
}

function requiresAction(
  code:
    | "retry_confirmation_required"
    | "repair_verification_required"
    | "documentation_completion_required",
  message: string,
): DomainDecision<never> {
  return {
    outcome: "requires-human-action",
    error: new DomainError(code, "human-action-required", message),
  };
}
