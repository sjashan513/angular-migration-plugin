import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { test } from "node:test";
import { runProcess } from "../dist/infrastructure/process-runner.js";

const cwd = process.cwd();
const request = (overrides = {}) => ({
  executable: "tool",
  arguments: [],
  cwd,
  env: { PATH: process.env.PATH ?? "" },
  timeoutMs: 1_000,
  terminationGraceMs: 20,
  maxOutputBytes: 1_024,
  ...overrides,
});

class FakeChild extends EventEmitter {
  stdout = new PassThrough();
  stderr = new PassThrough();
  killSignals = [];
  killHandler = () => true;

  kill(signal) {
    this.killSignals.push(signal);
    return this.killHandler(signal);
  }
}

function settleChild(child, { exitCode = 0, stdout = "", stderr = "" } = {}) {
  process.nextTick(() => {
    child.emit("spawn");
    child.stdout.end(stdout);
    child.stderr.end(stderr);
    child.emit("close", exitCode, null);
  });
}

test("uses executable, arguments, cwd, and environment separately with shell disabled", async () => {
  const child = new FakeChild();
  let invocation;
  const resultPromise = runProcess(
    request({
      executable: "fixed-tool",
      arguments: ["literal; $(not-shell)"],
      cwd: "C:\\work\\project",
    }),
    (executable, args, options) => {
      invocation = { executable, args, options };
      settleChild(child, {
        stdout: "C:\\work\\project\\output token=secret-value",
      });
      return child;
    },
  );
  const result = await resultPromise;

  assert.equal(invocation.executable, "fixed-tool");
  assert.deepEqual(invocation.args, ["literal; $(not-shell)"]);
  assert.equal(invocation.options.shell, false);
  assert.equal(invocation.options.cwd, "C:\\work\\project");
  assert.deepEqual(invocation.options.env, request().env);
  assert.equal(result.kind, "exited");
  assert.equal(result.stdout, "<project-root>\\output token=[REDACTED]");
});

test("maps spawn failure and nonzero exit without exposing raw error text", async () => {
  const spawnError = new Error("secret path C:\\Users\\private\\tool missing");
  spawnError.code = "ENOENT";
  const failed = new FakeChild();
  const spawnFailure = runProcess(request(), () => {
    process.nextTick(() => failed.emit("error", spawnError));
    return failed;
  });
  assert.deepEqual(await spawnFailure, {
    kind: "spawn-failed",
    errorCode: "ENOENT",
    stdout: "",
    stderr: "",
    stdoutTruncated: false,
    stderrTruncated: false,
  });

  const nonzero = new FakeChild();
  const result = await runProcess(request(), () => {
    settleChild(nonzero, { exitCode: 17, stderr: "failure" });
    return nonzero;
  });
  assert.equal(result.kind, "exited");
  assert.equal(result.exitCode, 17);
  assert.equal(result.stderr, "failure");

  const signaled = new FakeChild();
  const signalResult = await runProcess(request(), () => {
    process.nextTick(() => {
      signaled.emit("spawn");
      signaled.emit("close", null, "SIGTERM");
    });
    return signaled;
  });
  assert.equal(signalResult.kind, "signaled");
  assert.equal(signalResult.signal, "SIGTERM");
});

test("bounds captured output and escalates timeout termination", async () => {
  const oversized = new FakeChild();
  const bounded = await runProcess(request({ maxOutputBytes: 4 }), () => {
    settleChild(oversized, { stdout: "abcdefgh" });
    return oversized;
  });
  assert.equal(bounded.stdout, "abcd");
  assert.equal(bounded.stdoutTruncated, true);

  const timedOut = new FakeChild();
  timedOut.killHandler = (signal) => {
    if (signal === "SIGKILL")
      process.nextTick(() => timedOut.emit("close", null, "SIGKILL"));
    return true;
  };
  const result = await runProcess(
    request({ timeoutMs: 5, terminationGraceMs: 5 }),
    () => {
      process.nextTick(() => timedOut.emit("spawn"));
      return timedOut;
    },
  );
  assert.equal(result.kind, "timed-out");
  assert.equal(result.terminated, true);
  assert.deepEqual(timedOut.killSignals, ["SIGTERM", "SIGKILL"]);

  const unconfirmed = new FakeChild();
  unconfirmed.killHandler = () => false;
  const unconfirmedResult = await runProcess(
    request({ timeoutMs: 2, terminationGraceMs: 2 }),
    () => {
      process.nextTick(() => unconfirmed.emit("spawn"));
      return unconfirmed;
    },
  );
  assert.equal(unconfirmedResult.kind, "timed-out");
  assert.equal(unconfirmedResult.terminated, false);
});

test("redacts credentials and absolute paths from captured output", async () => {
  const child = new FakeChild();
  const resultPromise = runProcess(request(), () => {
    settleChild(child, {
      stdout:
        "Authorization: Bearer bearer-secret _authToken=registry-secret https://user:pass@example.test /home/private/project/file",
    });
    return child;
  });
  const result = await resultPromise;
  assert.equal(result.kind, "exited");
  for (const secret of [
    "bearer-secret",
    "registry-secret",
    "user:pass",
    "/home/private/project/file",
  ]) {
    assert.equal(result.stdout.includes(secret), false);
  }
});

test("real child receives shell metacharacters literally", async () => {
  const literal = "value;$(echo should-not-run)&";
  const result = await runProcess(
    request({
      executable: process.execPath,
      arguments: ["-e", "process.stdout.write(process.argv[1])", literal],
    }),
  );
  assert.equal(result.kind, "exited");
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout, literal);
});

test("real child is terminated when its deadline expires", async () => {
  const result = await runProcess(
    request({
      executable: process.execPath,
      arguments: ["-e", "setInterval(() => {}, 1000)"],
      timeoutMs: 100,
      terminationGraceMs: 100,
    }),
  );
  assert.equal(result.kind, "timed-out");
  assert.equal(result.terminated, true);
});

test("rejects unbounded or malformed requests before spawning", async () => {
  let spawned = false;
  const result = await runProcess(
    request({ timeoutMs: Number.POSITIVE_INFINITY }),
    () => {
      spawned = true;
      return new FakeChild();
    },
  );
  assert.equal(result.kind, "invalid-request");
  assert.equal(result.reason, "timeout-invalid");
  assert.equal(spawned, false);

  const tooMuchEnvironment = await runProcess(
    request({ env: { TOKEN: "x".repeat(65_536) } }),
    () => {
      spawned = true;
      return new FakeChild();
    },
  );
  assert.equal(tooMuchEnvironment.kind, "invalid-request");
  assert.equal(tooMuchEnvironment.reason, "environment-invalid");
  assert.equal(spawned, false);

  for (const args of [
    ["--token", "secret-value"],
    ["_authToken=secret-value"],
    ["https://user:pass@example.test"],
    ["Authorization: Bearer secret-value"],
    ["Bearer secret-value"],
  ]) {
    const credentials = await runProcess(request({ arguments: args }), () => {
      spawned = true;
      return new FakeChild();
    });
    assert.equal(credentials.kind, "invalid-request");
    assert.equal(
      credentials.reason,
      "credentials-must-not-be-passed-as-arguments",
    );
    assert.equal(spawned, false);
  }
});
