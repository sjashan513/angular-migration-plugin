import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  FnmExactRuntimeInstaller,
  RuntimeInstallAuditStoreAdapter,
} from "../dist/infrastructure/runtime-install.js";

function exited(exitCode) {
  return {
    kind: "exited",
    exitCode,
    stdout: "",
    stderr: "",
    stdoutTruncated: false,
    stderrTruncated: false,
  };
}

test("invokes fnm install with the exact version as a separated argument", async () => {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-runtime-"));
  try {
    const requests = [];
    const installer = new FnmExactRuntimeInstaller({
      fnmExecutable: "C:\\tools\\fnm.exe",
      environment: { Path: "C:\\tools" },
      run: async (request) => {
        requests.push(request);
        return exited(0);
      },
    });

    assert.equal(await installer.install(root, "16.20.2"), "installed");
    assert.equal(requests.length, 1);
    assert.equal(requests[0].executable, "C:\\tools\\fnm.exe");
    assert.deepEqual(requests[0].arguments, ["install", "16.20.2"]);
    assert.equal(requests[0].cwd, await fs.realpath(root));
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("rejects runtime ranges without invoking fnm", async () => {
  let invoked = false;
  const installer = new FnmExactRuntimeInstaller({
    fnmExecutable: "fnm",
    environment: {},
    run: async () => {
      invoked = true;
      return exited(0);
    },
  });

  assert.equal(await installer.install(".", ">=16"), "failed");
  assert.equal(invoked, false);
});

test("stores audit events under plugin state and rejects malformed history", async () => {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-runtime-audit-"));
  try {
    const store = new RuntimeInstallAuditStoreAdapter();
    const events = [{ sequence: 0, outcome: "started" }];
    await store.write(root, events);
    assert.deepEqual(await store.read(root), events);
    await fs.writeFile(
      path.join(root, ".angular-migration", "runtime-install.json"),
      "{",
    );
    await assert.rejects(store.read(root), {
      code: "runtime_install_audit_invalid",
    });
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
