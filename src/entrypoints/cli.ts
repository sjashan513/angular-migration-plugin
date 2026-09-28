import { ApplicationError } from "../application/application-error.js";

export interface CliUseCases {
  inspect(projectRoot: string): Promise<unknown>;
  discover(projectRoot: string, targetMajor: number): Promise<unknown>;
  approveRuntime(
    projectRoot: string,
    targetMajor: number,
    proposalHash: string,
    confirmed: boolean,
  ): Promise<unknown>;
  baselineDependencyContext(
    projectRoot: string,
    runId: string,
  ): Promise<unknown>;
  approveBaselineDependencies(
    projectRoot: string,
    runId: string,
    proposalHash: string,
    confirmed: boolean,
  ): Promise<unknown>;
  skipCheck(
    projectRoot: string,
    runId: string,
    checkId: string,
    reason: string,
    confirmed: boolean,
  ): Promise<unknown>;
  repairContext(projectRoot: string, runId: string): Promise<unknown>;
  recordRepair(projectRoot: string, runId: string): Promise<unknown>;
  documentationResearchContext(
    projectRoot: string,
    runId: string,
  ): Promise<unknown>;
  recordDocumentationResearch(
    projectRoot: string,
    runId: string,
  ): Promise<unknown>;
  documentationPublishContext(
    projectRoot: string,
    runId: string,
  ): Promise<unknown>;
  publishDocumentation(
    projectRoot: string,
    runId: string,
    proposalHash: string,
    confirmed: boolean,
  ): Promise<unknown>;
  start(projectRoot: string, targetMajor: number): Promise<unknown>;
  run(projectRoot: string, runId: string): Promise<unknown>;
  status(projectRoot: string): Promise<unknown>;
}

export interface CliResponse {
  readonly schemaVersion: 1;
  readonly ok: boolean;
  readonly status: "success" | "blocked" | "failed";
  readonly data: unknown;
  readonly error: { readonly code: string; readonly message: string } | null;
}

export interface CliDispatchResult {
  readonly response: CliResponse;
  readonly stdout: string;
  readonly exitCode: 0 | 1 | 2;
}

const MAX_CLI_OUTPUT_BYTES = 1_048_576;

export async function dispatchCli(
  arguments_: readonly string[],
  useCases: CliUseCases,
): Promise<CliDispatchResult> {
  try {
    const request = parseRequest(arguments_);
    const result = await dispatchRequest(request, useCases);
    const status = resultStatus(request, result);
    return response(status, publicData(request, result), null);
  } catch (error) {
    const failure = safeFailure(error);
    return response(failure.status, null, failure.error);
  }
}

function parseRequest(arguments_: readonly string[]):
  | { readonly command: "inspect" | "status"; readonly projectRoot: string }
  | {
      readonly command: "discover" | "start";
      readonly projectRoot: string;
      readonly targetMajor: number;
    }
  | {
      readonly command: "approve-runtime";
      readonly projectRoot: string;
      readonly targetMajor: number;
      readonly proposalHash: string;
      readonly confirmed: true;
    }
  | {
      readonly command: "approve-baseline-dependencies";
      readonly projectRoot: string;
      readonly runId: string;
      readonly proposalHash: string;
      readonly confirmed: true;
    }
  | {
      readonly command: "skip-check";
      readonly projectRoot: string;
      readonly runId: string;
      readonly checkId: string;
      readonly reason: string;
      readonly confirmed: true;
    }
  | {
      readonly command: "run";
      readonly projectRoot: string;
      readonly runId: string;
    }
  | {
      readonly command:
        | "documentation-research-context"
        | "record-documentation-research"
        | "documentation-publish-context";
      readonly projectRoot: string;
      readonly runId: string;
    }
  | {
      readonly command: "publish-documentation";
      readonly projectRoot: string;
      readonly runId: string;
      readonly proposalHash: string;
      readonly confirmed: true;
    }
  | {
      readonly command:
        | "repair-context"
        | "record-repair"
        | "baseline-dependency-context";
      readonly projectRoot: string;
      readonly runId: string;
    } {
  if (!Array.isArray(arguments_) || arguments_.length === 0) {
    throw usageError("cli_command_required", "A command is required.");
  }
  const command = arguments_[0];
  if (
    ![
      "inspect",
      "discover",
      "start",
      "approve-runtime",
      "approve-baseline-dependencies",
      "baseline-dependency-context",
      "skip-check",
      "repair-context",
      "record-repair",
      "documentation-research-context",
      "record-documentation-research",
      "documentation-publish-context",
      "publish-documentation",
      "run",
      "status",
    ].includes(command)
  ) {
    throw usageError(
      "cli_command_unknown",
      "The requested command is not supported.",
    );
  }
  const values = new Map<string, string>();
  for (let index = 1; index < arguments_.length; index += 1) {
    const option = arguments_[index];
    if (!option.startsWith("--")) {
      throw usageError(
        "cli_option_invalid",
        "CLI options require a name and value.",
      );
    }
    const name = option.slice(2);
    if (
      ![
        "project-root",
        "target-major",
        "run-id",
        "plan-hash",
        "proposal-hash",
        "confirmed",
        "check-id",
        "reason",
      ].includes(name)
    ) {
      throw usageError(
        "cli_option_unknown",
        "The requested option is not supported.",
      );
    }
    if (index + 1 >= arguments_.length) {
      throw usageError(
        "cli_option_invalid",
        "CLI options require a name and value.",
      );
    }
    const value = arguments_[++index];
    if (!value || value.startsWith("--") || values.has(name)) {
      throw usageError(
        "cli_option_invalid",
        "CLI options must have one non-empty value.",
      );
    }
    values.set(name, value);
  }
  const projectRoot = values.get("project-root");
  if (!projectRoot) {
    throw usageError(
      "cli_project_root_required",
      "--project-root is required.",
    );
  }
  if (["inspect", "status"].includes(command)) {
    if (values.size !== 1) {
      throw usageError(
        "cli_option_unexpected",
        "The command received an unsupported option.",
      );
    }
    return { command: command as "inspect" | "status", projectRoot };
  }
  if (command === "approve-baseline-dependencies") {
    const runId = values.get("run-id");
    const proposalHash = values.get("proposal-hash");
    if (
      values.size !== 4 ||
      !runId ||
      !proposalHash ||
      !/^sha256:[a-f0-9]{64}$/.test(proposalHash) ||
      values.get("confirmed") !== "true"
    ) {
      throw usageError(
        "cli_baseline_approval_invalid",
        "Baseline dependency approval requires a run, proposal hash, and --confirmed true.",
      );
    }
    return {
      command,
      projectRoot,
      runId,
      proposalHash,
      confirmed: true,
    };
  }
  if (command === "publish-documentation") {
    const runId = values.get("run-id");
    const proposalHash = values.get("proposal-hash");
    if (
      values.size !== 4 ||
      !runId ||
      !proposalHash ||
      !/^sha256:[a-f0-9]{64}$/.test(proposalHash) ||
      values.get("confirmed") !== "true"
    ) {
      throw usageError(
        "cli_documentation_approval_invalid",
        "Documentation publishing requires a run, current proposal hash, and --confirmed true.",
      );
    }
    return { command, projectRoot, runId, proposalHash, confirmed: true };
  }
  if (
    [
      "run",
      "repair-context",
      "record-repair",
      "baseline-dependency-context",
      "documentation-research-context",
      "record-documentation-research",
      "documentation-publish-context",
    ].includes(command)
  ) {
    const runId = values.get("run-id");
    if (values.size !== 2 || !runId) {
      throw usageError(
        "cli_run_id_required",
        "--run-id is required for this command.",
      );
    }
    if (command === "run") return { command, projectRoot, runId };
    return { command, projectRoot, runId };
  }
  if (command === "skip-check") {
    const runId = values.get("run-id");
    const checkId = values.get("check-id");
    const reason = values.get("reason");
    if (
      values.size !== 5 ||
      !runId ||
      !checkId ||
      !reason ||
      reason.length > 2000 ||
      values.get("confirmed") !== "true"
    ) {
      throw usageError(
        "cli_skip_request_invalid",
        "Skipping a check requires run id, check id, reason, and --confirmed true.",
      );
    }
    return { command, projectRoot, runId, checkId, reason, confirmed: true };
  }
  const targetText = values.get("target-major");
  if (command === "approve-runtime") {
    const proposalHash = values.get("plan-hash");
    if (
      values.size !== 4 ||
      !targetText ||
      !/^(?:0|[1-9]\d*)$/.test(targetText) ||
      !Number.isSafeInteger(Number(targetText)) ||
      !proposalHash ||
      !/^sha256:[a-f0-9]{64}$/.test(proposalHash) ||
      values.get("confirmed") !== "true"
    ) {
      throw usageError(
        "cli_runtime_approval_invalid",
        "Runtime approval requires a target, current plan hash, and --confirmed true.",
      );
    }
    return {
      command,
      projectRoot,
      targetMajor: Number(targetText),
      proposalHash,
      confirmed: true,
    };
  }
  if (
    values.size !== 2 ||
    !targetText ||
    !/^(?:0|[1-9]\d*)$/.test(targetText) ||
    !Number.isSafeInteger(Number(targetText))
  ) {
    throw usageError(
      "cli_target_major_invalid",
      "A valid --target-major is required.",
    );
  }
  return {
    command: command as "discover" | "start",
    projectRoot,
    targetMajor: Number(targetText),
  };
}

async function dispatchRequest(
  request: ReturnType<typeof parseRequest>,
  useCases: CliUseCases,
): Promise<unknown> {
  switch (request.command) {
    case "inspect":
      return useCases.inspect(request.projectRoot);
    case "discover":
      return useCases.discover(request.projectRoot, request.targetMajor);
    case "start":
      return useCases.start(request.projectRoot, request.targetMajor);
    case "approve-runtime":
      return useCases.approveRuntime(
        request.projectRoot,
        request.targetMajor,
        request.proposalHash,
        request.confirmed,
      );
    case "baseline-dependency-context":
      return useCases.baselineDependencyContext(
        request.projectRoot,
        request.runId,
      );
    case "approve-baseline-dependencies":
      return useCases.approveBaselineDependencies(
        request.projectRoot,
        request.runId,
        request.proposalHash,
        request.confirmed,
      );
    case "skip-check":
      return useCases.skipCheck(
        request.projectRoot,
        request.runId,
        request.checkId,
        request.reason,
        request.confirmed,
      );
    case "repair-context":
      return useCases.repairContext(request.projectRoot, request.runId);
    case "record-repair":
      return useCases.recordRepair(request.projectRoot, request.runId);
    case "documentation-research-context":
      return useCases.documentationResearchContext(
        request.projectRoot,
        request.runId,
      );
    case "record-documentation-research":
      return useCases.recordDocumentationResearch(
        request.projectRoot,
        request.runId,
      );
    case "documentation-publish-context":
      return useCases.documentationPublishContext(
        request.projectRoot,
        request.runId,
      );
    case "publish-documentation":
      return useCases.publishDocumentation(
        request.projectRoot,
        request.runId,
        request.proposalHash,
        request.confirmed,
      );
    case "run":
      return useCases.run(request.projectRoot, request.runId);
    case "status":
      return useCases.status(request.projectRoot);
  }
}

function resultStatus(
  command: ReturnType<typeof parseRequest>,
  value: unknown,
): CliResponse["status"] {
  if (!isRecord(value)) return "success";
  if (command.command === "discover") {
    return value.status === "ready" ? "success" : "blocked";
  }
  if (
    command.command === "status" &&
    value.nextAction === "human-intervention"
  ) {
    return "blocked";
  }
  if (command.command === "run" && isRecord(value.state)) {
    if (
      value.state.status === "blocked" ||
      value.state.status === "needs-repair"
    ) {
      return "blocked";
    }
    if (value.state.status === "failed") return "failed";
  }
  return "success";
}

function publicData(
  request: ReturnType<typeof parseRequest>,
  value: unknown,
): unknown {
  if (
    (request.command === "start" || request.command === "run") &&
    isRecord(value) &&
    isRecord(value.state)
  ) {
    return {
      runId: value.state.runId,
      status: value.state.status,
      stage: value.state.stage,
    };
  }
  return value;
}

function response(
  status: CliResponse["status"],
  data: unknown,
  error: CliResponse["error"],
): CliDispatchResult {
  const result: CliResponse = {
    schemaVersion: 1,
    ok: status === "success",
    status,
    data,
    error,
  };
  let stdout = `${JSON.stringify(result)}\n`;
  if (Buffer.byteLength(stdout, "utf8") > MAX_CLI_OUTPUT_BYTES) {
    const bounded: CliResponse = {
      schemaVersion: 1,
      ok: false,
      status: "failed",
      data: null,
      error: {
        code: "cli_output_too_large",
        message: "The response exceeds the supported output limit.",
      },
    };
    return {
      response: bounded,
      stdout: `${JSON.stringify(bounded)}\n`,
      exitCode: 1,
    };
  }
  return {
    response: result,
    stdout,
    exitCode: status === "success" ? 0 : status === "blocked" ? 2 : 1,
  };
}

function safeFailure(error: unknown): {
  readonly status: "blocked" | "failed";
  readonly error: NonNullable<CliResponse["error"]>;
} {
  if (error instanceof ApplicationError) {
    return {
      status:
        error.outcome === "blocked" || isExpectedBlockCode(error.code)
          ? "blocked"
          : "failed",
      error: { code: error.code, message: error.message },
    };
  }
  if (isSafeTypedError(error)) {
    return {
      status: isExpectedBlockCode(error.code) ? "blocked" : "failed",
      error: { code: error.code, message: error.message },
    };
  }
  return {
    status: "failed",
    error: {
      code: "internal_error",
      message: "The controller could not complete the request.",
    },
  };
}

function isExpectedBlockCode(code: string): boolean {
  return new Set([
    "start_request_invalid",
    "run_request_invalid",
    "status_request_invalid",
    "non_sequential_angular_major",
    "project_root_invalid",
    "project_path_invalid",
    "project_path_outside_root",
    "project_json_invalid",
    "project_facts_invalid",
    "project_busy",
    "project_recovery_required",
    "discovery_invalid",
    "discovery_integrity_failed",
    "discovery_context_mismatch",
    "discovery_stale",
    "discovery_not_ready",
    "project_not_clean",
    "project_major_mismatch",
    "planned_runtime_unavailable",
    "planned_runtime_invalid",
    "confirmation_required",
    "runtime_approval_request_invalid",
    "runtime_proposal_stale",
    "runtime_install_not_required",
    "runtime_install_already_attempted",
    "runtime_install_recovery_required",
    "runtime_install_audit_invalid",
    "runtime_install_failed",
    "runtime_install_unverified",
    "baseline_dependency_request_invalid",
    "baseline_dependency_context_unavailable",
    "baseline_dependency_context_stale",
    "baseline_dependency_proposal_invalid",
    "baseline_dependency_proposal_stale",
    "baseline_dependency_hash_invalid",
    "baseline_dependency_approval_invalid",
    "baseline_dependency_approval_recovery_required",
    "baseline_dependency_install_failed",
    "baseline_dependency_transition_rejected",
    "skip_request_invalid",
    "critical_check_cannot_be_skipped",
    "check_not_skippable",
    "skip_context_unavailable",
    "skip_transition_rejected",
    "cli_skip_request_invalid",
    "repair_request_invalid",
    "repair_context_unavailable",
    "repair_fingerprint_stale",
    "repair_attempts_exhausted",
    "repair_scope_unknown",
    "repair_submission_invalid",
    "repair_submission_stale",
    "repair_submission_too_large",
    "repair_submission_replayed",
    "repair_verification_failed",
    "repair_transition_rejected",
    "repair_gate_invalid",
    "repair_rollback_unconfirmed",
    "project_context_invalid",
    "project_check_invalid",
    "angular_cli_metadata_missing",
    "run_already_active",
    "run_not_found",
    "run_context_mismatch",
    "run_record_invalid",
    "run_record_integrity_failed",
    "run_record_context_mismatch",
  ]).has(code);
}

function usageError(code: string, message: string): ApplicationError {
  return new ApplicationError(code, message, "blocked");
}

function isSafeTypedError(
  error: unknown,
): error is Error & { readonly code: string } {
  return Boolean(
    error instanceof Error &&
    "code" in error &&
    typeof error.code === "string" &&
    /^[a-z][a-z0-9_]{0,63}$/.test(error.code) &&
    error.message.length > 0 &&
    !/[A-Za-z]:\\[^\s]+/.test(error.message) &&
    !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(error.message),
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
