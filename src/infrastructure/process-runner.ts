import {
  spawn,
  type ChildProcess,
  type SpawnOptions,
} from "node:child_process";

const MAX_ARGUMENTS = 256;
const MAX_ARGUMENT_LENGTH = 32_768;
const MAX_ARGUMENT_BYTES = 1_048_576;
const MAX_ENVIRONMENT_ENTRIES = 256;
const MAX_ENVIRONMENT_BYTES = 65_536;
const MAX_CAPTURED_OUTPUT_BYTES = 1_048_576;
const MAX_TIMEOUT_MS = 600_000;
const MAX_TERMINATION_GRACE_MS = 30_000;

export interface ProcessRequest {
  readonly executable: string;
  readonly arguments: readonly string[];
  readonly cwd: string;
  readonly env: Readonly<Record<string, string>>;
  readonly timeoutMs: number;
  readonly terminationGraceMs: number;
  readonly maxOutputBytes: number;
}

interface CapturedOutput {
  readonly stdout: string;
  readonly stderr: string;
  readonly stdoutTruncated: boolean;
  readonly stderrTruncated: boolean;
}

type ProcessOutcome =
  | { readonly kind: "exited"; readonly exitCode: number }
  | { readonly kind: "signaled"; readonly signal: NodeJS.Signals }
  | { readonly kind: "timed-out"; readonly terminated: boolean }
  | { readonly kind: "spawn-failed"; readonly errorCode: string }
  | { readonly kind: "process-error"; readonly errorCode: string }
  | { readonly kind: "invalid-request"; readonly reason: string };

export type ProcessResult = CapturedOutput & ProcessOutcome;

export async function runProcess(
  request: ProcessRequest,
  spawnProcess: typeof spawn = spawn,
): Promise<ProcessResult> {
  const invalidReason = validateRequest(request);
  if (invalidReason)
    return emptyResult({ kind: "invalid-request", reason: invalidReason });

  const stdout = new BoundedOutput(request.maxOutputBytes);
  const stderr = new BoundedOutput(request.maxOutputBytes);
  let child: ChildProcess;
  try {
    const options: SpawnOptions = {
      cwd: request.cwd,
      env: { ...request.env },
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    };
    child = spawnProcess(request.executable, [...request.arguments], options);
  } catch (error) {
    return emptyResult({ kind: "spawn-failed", errorCode: errorCode(error) });
  }

  return new Promise((resolve) => {
    let finished = false;
    let spawned = false;
    let timedOut = false;
    let childErrorCode: string | undefined;
    let timeoutTimer: NodeJS.Timeout | undefined;
    let escalationTimer: NodeJS.Timeout | undefined;
    let terminationTimer: NodeJS.Timeout | undefined;

    const output = (): CapturedOutput => ({
      stdout: redactOutput(stdout.text(), request.cwd),
      stderr: redactOutput(stderr.text(), request.cwd),
      stdoutTruncated: stdout.truncated,
      stderrTruncated: stderr.truncated,
    });
    const finish = (result: ProcessResult): void => {
      if (finished) return;
      finished = true;
      clearTimeout(timeoutTimer);
      clearTimeout(escalationTimer);
      clearTimeout(terminationTimer);
      resolve({ ...output(), ...result });
    };

    child.stdout?.on("data", (chunk: Buffer | string) => stdout.append(chunk));
    child.stderr?.on("data", (chunk: Buffer | string) => stderr.append(chunk));
    child.once("spawn", () => {
      spawned = true;
    });
    child.once("error", (error: NodeJS.ErrnoException) => {
      const code = errorCode(error);
      if (!spawned) {
        finish({ ...output(), kind: "spawn-failed", errorCode: code });
      } else {
        childErrorCode = code;
      }
    });
    child.once("close", (exitCode, signal) => {
      if (timedOut) {
        finish({ ...output(), kind: "timed-out", terminated: true });
      } else if (childErrorCode) {
        finish({
          ...output(),
          kind: "process-error",
          errorCode: childErrorCode,
        });
      } else if (signal) {
        finish({ ...output(), kind: "signaled", signal });
      } else if (exitCode !== null) {
        finish({ ...output(), kind: "exited", exitCode });
      } else {
        finish({
          ...output(),
          kind: "process-error",
          errorCode: "UNKNOWN_PROCESS_OUTCOME",
        });
      }
    });

    timeoutTimer = setTimeout(() => {
      timedOut = true;
      try {
        child.kill("SIGTERM");
      } catch {
        // Escalation below remains the bounded fallback.
      }
      escalationTimer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          // Report unconfirmed termination after the final bounded wait.
        }
        terminationTimer = setTimeout(() => {
          finish({ ...output(), kind: "timed-out", terminated: false });
        }, request.terminationGraceMs);
      }, request.terminationGraceMs);
    }, request.timeoutMs);
  });
}

function validateRequest(request: ProcessRequest): string | undefined {
  if (!request || typeof request !== "object") return "request-invalid";
  if (
    !nonEmptyString(request.executable) ||
    !nonEmptyString(request.cwd) ||
    request.executable.length > MAX_ARGUMENT_LENGTH ||
    request.cwd.length > MAX_ARGUMENT_LENGTH
  )
    return "executable-or-cwd-invalid";
  if (request.executable.includes("\0") || request.cwd.includes("\0"))
    return "executable-or-cwd-invalid";
  if (
    !Array.isArray(request.arguments) ||
    request.arguments.length > MAX_ARGUMENTS
  )
    return "arguments-invalid";
  if (
    request.arguments.some(
      (argument) =>
        typeof argument !== "string" ||
        argument.includes("\0") ||
        argument.length > MAX_ARGUMENT_LENGTH,
    ) ||
    request.arguments.reduce((size, argument) => size + argument.length, 0) >
      MAX_ARGUMENT_BYTES
  ) {
    return "arguments-invalid";
  }
  if (containsCredentialArguments(request.arguments))
    return "credentials-must-not-be-passed-as-arguments";
  if (
    !request.env ||
    typeof request.env !== "object" ||
    Object.keys(request.env).length > MAX_ENVIRONMENT_ENTRIES ||
    Object.entries(request.env).reduce(
      (size, [key, value]) =>
        size + key.length + (typeof value === "string" ? value.length : 0),
      0,
    ) > MAX_ENVIRONMENT_BYTES
  ) {
    return "environment-invalid";
  }
  if (
    Object.entries(request.env).some(
      ([key, value]) =>
        !key ||
        key.includes("=") ||
        key.includes("\0") ||
        typeof value !== "string" ||
        value.includes("\0"),
    )
  ) {
    return "environment-invalid";
  }
  if (
    !Number.isSafeInteger(request.timeoutMs) ||
    request.timeoutMs < 1 ||
    request.timeoutMs > MAX_TIMEOUT_MS
  ) {
    return "timeout-invalid";
  }
  if (
    !Number.isSafeInteger(request.terminationGraceMs) ||
    request.terminationGraceMs < 1 ||
    request.terminationGraceMs > MAX_TERMINATION_GRACE_MS
  ) {
    return "termination-grace-invalid";
  }
  if (
    !Number.isSafeInteger(request.maxOutputBytes) ||
    request.maxOutputBytes < 0 ||
    request.maxOutputBytes > MAX_CAPTURED_OUTPUT_BYTES
  ) {
    return "output-limit-invalid";
  }
  return undefined;
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function containsCredentialArguments(arguments_: readonly string[]): boolean {
  const credentialOption =
    /^--?(?:_auth(?:token)?|token|password|secret|authorization|api[-_]?key)(?:=|$)/i;
  const credentialAssignment =
    /(?:^|[^a-z0-9])(?:_auth(?:token)?|token|password|secret|authorization|api[-_]?key)\s*[:=]/i;
  const urlCredentials = /https?:\/\/[^/@\s]+:[^/@\s]+@/i;
  return arguments_.some(
    (argument, index) =>
      credentialAssignment.test(argument) ||
      urlCredentials.test(argument) ||
      /^Bearer\s+\S+/i.test(argument) ||
      (credentialOption.test(argument) &&
        (argument.includes("=") || index + 1 < arguments_.length)),
  );
}

function errorCode(error: unknown): string {
  if (
    error &&
    typeof error === "object" &&
    "code" in error &&
    typeof error.code === "string" &&
    /^[A-Z0-9_]+$/.test(error.code)
  ) {
    return error.code;
  }
  return "SPAWN_FAILED";
}

function emptyResult(result: ProcessOutcome): ProcessResult {
  return {
    ...result,
    stdout: "",
    stderr: "",
    stdoutTruncated: false,
    stderrTruncated: false,
  };
}

function redactOutput(value: string, cwd: string): string {
  const root = cwd.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return value
    .replace(new RegExp(root, "gi"), "<project-root>")
    .replace(/(https?:\/\/)[^/@\s]+@/gi, "$1[REDACTED]@")
    .replace(/(\bBearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(
      /((?:_authToken|_auth|authorization|token|password|secret|api[-_]?key)["']?\s*[:=]\s*["']?)[^\s"',;}]+["']?/gi,
      "$1[REDACTED]",
    )
    .replace(/\b[A-Za-z]:\\[^\s"'<>|]+/g, "<path>")
    .replace(/(?:^|\s)(\/(?:[^/\s]+\/)+[^\s"']*)/g, " <path>");
}

class BoundedOutput {
  private value = Buffer.alloc(0);
  truncated = false;

  constructor(private readonly limit: number) {}

  append(chunk: Buffer | string): void {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    const available = Math.max(0, this.limit - this.value.length);
    if (bytes.length > available) this.truncated = true;
    if (available > 0)
      this.value = Buffer.concat([this.value, bytes.subarray(0, available)]);
  }

  text(): string {
    return this.value.toString("utf8");
  }
}
