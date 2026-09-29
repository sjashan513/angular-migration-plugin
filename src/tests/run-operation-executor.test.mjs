import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { RunOperationExecutorAdapter } from "../dist/infrastructure/run-operation-executor.js";

async function withProject(callback) {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-run-operation-"));
  try {
    await fs.writeFile(
      path.join(root, "package.json"),
      JSON.stringify({
        name: "fixture",
        dependencies: { "@angular/core": "^8.2.0" },
        devDependencies: { "@angular/cli": "~8.3.0" },
      }),
    );
    await fs.writeFile(
      path.join(root, "package-lock.json"),
      JSON.stringify({
        lockfileVersion: 3,
        packages: {
          "": { name: "fixture" },
          "node_modules/@angular/core": { version: "8.2.14" },
          "node_modules/@angular/cli": { version: "8.3.29" },
        },
      }),
    );
    await callback(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

const packages = [
  { name: "@angular/core", targetVersion: "8.2.14" },
  { name: "@angular/cli", targetVersion: "8.3.29" },
];

function adapter(
  root,
  runRuntime = async () => exited(0),
  runNpm = async () => exited(0),
) {
  return new RunOperationExecutorAdapter({
    environment: { Path: "C:\\tools", PATHEXT: ".EXE" },
    fnmExecutable: "C:\\tools\\fnm.exe",
    runRuntime,
    runNpm,
  });
}

function exited(exitCode, stdout = "", stderr = "") {
  return {
    kind: "exited",
    exitCode,
    stdout,
    stderr,
    stdoutTruncated: false,
    stderrTruncated: false,
  };
}

test("pins only existing direct package declarations to exact planned versions", async () => {
  await withProject(async (root) => {
    const result = await adapter(root).execute(root, {
      id: "pin-target-packages",
      kind: "pin-packages",
      stage: "update-dependencies",
      executable: null,
      arguments: [],
      nodeVersion: "20.18.0",
      timeoutMs: 30_000,
      postcondition: "target-packages-declared",
      packages,
    });
    const packageJson = JSON.parse(
      await fs.readFile(path.join(root, "package.json"), "utf8"),
    );

    assert.deepEqual(result, { outcome: "passed" });
    assert.equal(packageJson.dependencies["@angular/core"], "8.2.14");
    assert.equal(packageJson.devDependencies["@angular/cli"], "8.3.29");
  });
});

test("uses fnm with exact runtime and validates lockfile target postconditions", async () => {
  await withProject(async (root) => {
    const requests = [];
    const executor = adapter(
      root,
      async () => {
        throw new Error("npm commands must use the npm-cli runtime adapter");
      },
      async (request) => {
        requests.push(request);
        return exited(0);
      },
    );
    const result = await executor.execute(root, {
      id: "update-lockfile",
      kind: "process",
      stage: "update-dependencies",
      executable: "npm",
      arguments: ["install", "--package-lock-only", "--ignore-scripts"],
      nodeVersion: "20.18.0",
      timeoutMs: 60_000,
      postcondition: "target-packages-locked",
      packages,
    });

    assert.deepEqual(result, { outcome: "passed" });
    assert.equal(requests.length, 1);
    assert.equal(requests[0].fnmExecutable, "C:\\tools\\fnm.exe");
    assert.equal(requests[0].nodeVersion, "20.18.0");
    assert.equal(requests[0].executable, "npm");
    assert.deepEqual(requests[0].arguments, [
      "install",
      "--package-lock-only",
      "--ignore-scripts",
    ]);
  });
});

test("rejects commands outside the controller allowlist without spawning", async () => {
  await withProject(async (root) => {
    let spawned = false;
    const result = await adapter(root, async () => {
      spawned = true;
      return exited(0);
    }).execute(root, {
      id: "baseline-install",
      kind: "process",
      stage: "baseline",
      executable: "npm",
      arguments: ["ci", "--ignore-scripts=false"],
      nodeVersion: "20.18.0",
      timeoutMs: 60_000,
      postcondition: "package-metadata-stable",
      packages: [],
    });

    assert.equal(result.outcome, "blocked");
    assert.equal(spawned, false);
  });
});
