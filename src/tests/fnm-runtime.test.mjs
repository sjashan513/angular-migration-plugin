import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { test } from "node:test";
import {
  runWithProjectNpm,
  runWithProjectRuntime,
} from "../dist/infrastructure/fnm-runtime.js";

const request = (overrides = {}) => ({
  fnmExecutable: "C:\\tools\\fnm.exe",
  nodeVersion: "22.19.0",
  executable: "npm",
  arguments: ["install", "--ignore-scripts"],
  cwd: "C:\\work\\repo",
  env: { PATH: "C:\\tools" },
  timeoutMs: 10_000,
  terminationGraceMs: 20,
  maxOutputBytes: 4_096,
  ...overrides,
});

test("uses fnm exec with the exact selected Node and separated command arguments", async () => {
  const child = Object.assign(new EventEmitter(), {
    stdout: new PassThrough(),
    stderr: new PassThrough(),
  });
  let invocation;
  const resultPromise = runWithProjectRuntime(
    request(),
    (executable, args, options) => {
      invocation = { executable, args, options };
      process.nextTick(() => {
        child.emit("spawn");
        child.stdout.end();
        child.stderr.end();
        child.emit("close", 0, null);
      });
      return child;
    },
  );

  assert.equal((await resultPromise).kind, "exited");
  assert.equal(invocation.executable, "C:\\tools\\fnm.exe");
  assert.deepEqual(invocation.args, [
    "exec",
    "--using",
    "22.19.0",
    "--",
    "npm",
    "install",
    "--ignore-scripts",
  ]);
  assert.equal(invocation.options.shell, false);
  assert.equal(invocation.options.cwd, "C:\\work\\repo");
});

test("rejects runtime ranges and injection strings without spawning", async () => {
  for (const nodeVersion of [
    "22",
    "22.x",
    "^22.19.0",
    "v22.19.0",
    "022.19.0",
    "22.19.0;fnm use 20",
  ]) {
    let spawned = false;
    const result = await runWithProjectRuntime(request({ nodeVersion }), () => {
      spawned = true;
      throw new Error("must not spawn");
    });
    assert.equal(result.kind, "invalid-request");
    assert.equal(result.reason, "node-version-must-be-exact");
    assert.equal(spawned, false);
  }

  for (const malformed of [null, {}, request({ arguments: null })]) {
    const result = await runWithProjectRuntime(malformed, () => {
      throw new Error("must not spawn");
    });
    assert.equal(result.kind, "invalid-request");
  }
});

test("runs npm-cli.js with the exact Node selected by fnm without shell lookup", async () => {
  const calls = [];
  const npmCliPath = "C:\\fnm\\v18.20.8\\node_modules\\npm\\bin\\npm-cli.js";
  const result = await runWithProjectNpm(
    {
      fnmExecutable: "C:\\tools\\fnm.exe",
      nodeVersion: "18.20.8",
      arguments: ["--version"],
      cwd: "C:\\work\\repo",
      env: { PATH: "C:\\tools" },
      timeoutMs: 10_000,
      terminationGraceMs: 20,
      maxOutputBytes: 4_096,
    },
    async (request) => {
      calls.push(request);
      return request.arguments[0] === "-p"
        ? {
            kind: "exited",
            exitCode: 0,
            stdout: Buffer.from(npmCliPath).toString("base64"),
            stderr: "",
            stdoutTruncated: false,
            stderrTruncated: false,
          }
        : {
            kind: "exited",
            exitCode: 0,
            stdout: "10.8.2",
            stderr: "",
            stdoutTruncated: false,
            stderrTruncated: false,
          };
    },
  );

  assert.equal(result.kind, "exited");
  assert.equal(calls.length, 2);
  assert.equal(calls[0].executable, "node");
  assert.deepEqual(calls[1].arguments, [npmCliPath, "--version"]);
  assert.equal(calls[1].nodeVersion, "18.20.8");
  assert.equal(calls[1].executable, "node");
});
