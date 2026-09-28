export type DomainErrorCode =
  | "invalid_project_id"
  | "invalid_run_id"
  | "invalid_run_state"
  | "invalid_angular_major"
  | "non_sequential_angular_major"
  | "invalid_run_revision"
  | "invalid_run_transition"
  | "retry_confirmation_required"
  | "repair_verification_required"
  | "documentation_completion_required";

export type DomainErrorCategory =
  | "invalid-input"
  | "invalid-identity"
  | "policy-violation"
  | "invalid-state"
  | "human-action-required";

export class DomainError extends Error {
  constructor(
    readonly code: DomainErrorCode,
    readonly category: DomainErrorCategory,
    message: string,
  ) {
    super(message);
    this.name = "DomainError";
  }
}
