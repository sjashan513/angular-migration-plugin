export type InfrastructureErrorCode =
  | "project_root_invalid"
  | "project_path_invalid"
  | "project_path_outside_root"
  | "project_file_read_failed"
  | "project_json_invalid"
  | "project_facts_invalid"
  | "project_write_failed"
  | "write_outcome_unconfirmed"
  | "lock_recovery_required"
  | "registry_metadata_unavailable"
  | "registry_metadata_invalid"
  | "git_inspection_failed"
  | "discovery_record_invalid"
  | "run_record_invalid"
  | "runtime_install_audit_invalid"
  | "repair_patch_failed"
  | "repair_rollback_unconfirmed"
  | "repair_submission_invalid"
  | "repair_submission_missing"
  | "hook_runtime_unavailable"
  | "documentation_submission_invalid"
  | "documentation_submission_missing"
  | "documentation_record_invalid"
  | "documentation_output_invalid"
  | "documentation_publish_conflict"
  | "documentation_rollback_unconfirmed"
  | "hash_input_invalid";

export class InfrastructureError extends Error {
  constructor(
    readonly code: InfrastructureErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "InfrastructureError";
  }
}
