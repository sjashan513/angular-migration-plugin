import { spawn } from "node:child_process";
import path from "node:path";
import {
  runProcess,
  type ProcessRequest,
  type ProcessResult,
} from "./process-runner.js";

export interface RuntimeCommandRequest extends Omit<
  ProcessRequest,
  "executable" | "arguments"
> {
  readonly fnmExecutable: string;
  readonly nodeVersion: string;
  readonly executable: string;
  readonly arguments: readonly string[];
}

export type RuntimeNpmRequest = Omit<RuntimeCommandRequest, "executable">;
type RuntimeRunner = (request: RuntimeCommandRequest) => Promise<ProcessResult>;

const EXACT_NODE_VERSION = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/;
const npmCliPaths = new Map<string, string>();

export function runWithProjectRuntime(
  request: RuntimeCommandRequest,
  spawnProcess: typeof spawn = spawn,
): Promise<ProcessResult> {
  if (
    !request ||
    typeof request !== "object" ||
    typeof request.nodeVersion !== "string" ||
    !EXACT_NODE_VERSION.test(request.nodeVersion)
  ) {
    return Promise.resolve({
      kind: "invalid-request",
      reason: "node-version-must-be-exact",
      stdout: "",
      stderr: "",
      stdoutTruncated: false,
      stderrTruncated: false,
    });
  }
  if (
    typeof request.executable !== "string" ||
    !Array.isArray(request.arguments)
  ) {
    return Promise.resolve({
      kind: "invalid-request",
      reason: "command-invalid",
      stdout: "",
      stderr: "",
      stdoutTruncated: false,
      stderrTruncated: false,
    });
  }

  return runProcess(
    {
      executable: request.fnmExecutable,
      arguments: [
        "exec",
        "--using",
        request.nodeVersion,
        "--",
        request.executable,
        ...request.arguments,
      ],
      cwd: request.cwd,
      env: request.env,
      timeoutMs: request.timeoutMs,
      terminationGraceMs: request.terminationGraceMs,
      maxOutputBytes: request.maxOutputBytes,
    },
    spawnProcess,
  );
}

export async function runWithProjectNpm(
  request: RuntimeNpmRequest,
  runCommand: RuntimeRunner = (command) => runWithProjectRuntime(command),
): Promise<ProcessResult> {
  if (
    !request ||
    typeof request !== "object" ||
    !EXACT_NODE_VERSION.test(String(request.nodeVersion)) ||
    !Array.isArray(request.arguments) ||
    request.arguments.some((argument) => typeof argument !== "string")
  ) {
    return invalidRuntimeResult("npm-request-invalid");
  }
  const key = `${request.fnmExecutable}\0${request.nodeVersion}`;
  let npmCliPath = npmCliPaths.get(key);
  if (!npmCliPath) {
    const query = await runCommand({
      ...request,
      executable: "node",
      arguments: [
        "-p",
        "Buffer.from(require('node:path').join(require('node:path').dirname(process.execPath),'node_modules','npm','bin','npm-cli.js')).toString('base64')",
      ],
      timeoutMs: Math.min(request.timeoutMs, 30_000),
      maxOutputBytes: 8_192,
    });
    if (!isSuccessful(query)) return query;
    const resolvedPath = decodeNpmCliPath(query.stdout);
    if (!resolvedPath) return invalidRuntimeResult("npm-cli-path-invalid");
    npmCliPath = resolvedPath;
    npmCliPaths.set(key, resolvedPath);
  }
  return runCommand({
    ...request,
    executable: "node",
    arguments: [npmCliPath, ...request.arguments],
  });
}

function decodeNpmCliPath(value: string): string | null {
  const encoded = value.trim();
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded) || encoded.length > 8_192) {
    return null;
  }
  const decoded = Buffer.from(encoded, "base64").toString("utf8");
  const normalized = decoded.replace(/\\/g, "/").toLowerCase();
  if (
    decoded.includes("\0") ||
    !(path.isAbsolute(decoded) || path.win32.isAbsolute(decoded)) ||
    !normalized.endsWith("/node_modules/npm/bin/npm-cli.js")
  ) {
    return null;
  }
  return decoded;
}

function isSuccessful(result: ProcessResult): boolean {
  return (
    result.kind === "exited" &&
    result.exitCode === 0 &&
    !result.stdoutTruncated &&
    !result.stderrTruncated
  );
}

function invalidRuntimeResult(reason: string): ProcessResult {
  return {
    kind: "invalid-request",
    reason,
    stdout: "",
    stderr: "",
    stdoutTruncated: false,
    stderrTruncated: false,
  };
}
