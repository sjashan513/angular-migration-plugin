import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  NpmBaselineDependencyInstaller,
  NpmBaselineDependencyProposalReader,
} from "../dist/infrastructure/baseline-dependencies.js";

const packages = [
  {
    name: "peer-lib",
    installVersion: "1.9.0",
    requiredRanges: ["^1.0.0"],
    requiredBy: ["parent-lib@2.0.0"],
  },
];

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

async function withProject(callback) {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-baseline-"));
  const packageJson = {
    name: "fixture",
    version: "1.0.0",
    dependencies: {},
  };
  const packageLock = {
    name: "fixture",
    version: "1.0.0",
    lockfileVersion: 3,
    packages: { "": { name: "fixture", version: "1.0.0" } },
  };
  await fs.writeFile(
    path.join(root, "package.json"),
    JSON.stringify(packageJson),
  );
  await fs.writeFile(
    path.join(root, "package-lock.json"),
    JSON.stringify(packageLock),
  );
  try {
    await callback(
      root,
      JSON.stringify(packageJson),
      JSON.stringify(packageLock),
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

function installFixture(root, gateExitCode = 0) {
  const requests = [];
  const originalPackage = JSON.stringify({
    name: "fixture",
    version: "1.0.0",
    dependencies: {},
  });
  const originalLock = JSON.stringify({
    name: "fixture",
    version: "1.0.0",
    lockfileVersion: 3,
    packages: { "": { name: "fixture", version: "1.0.0" } },
  });
  const runNpm = async (request) => {
    requests.push(request);
    if (request.arguments[0] === "install") {
      const manifest = JSON.parse(
        await fs.readFile(path.join(root, "package.json"), "utf8"),
      );
      manifest.dependencies["peer-lib"] = "1.9.0";
      await fs.writeFile(
        path.join(root, "package.json"),
        JSON.stringify(manifest),
      );
      const lock = JSON.parse(
        await fs.readFile(path.join(root, "package-lock.json"), "utf8"),
      );
      lock.packages[""].dependencies = { "peer-lib": "1.9.0" };
      lock.packages["node_modules/peer-lib"] = { version: "1.9.0" };
      await fs.writeFile(
        path.join(root, "package-lock.json"),
        JSON.stringify(lock),
      );
      return exited(0);
    }
    if (request.arguments[0] === "ls") return exited(gateExitCode);
    throw new Error("unexpected npm command");
  };
  const runRuntime = async (request) => {
    assert.equal(request.executable, "git");
    assert.equal(request.nodeVersion, "20.18.0");
    const packageChanged =
      (await fs.readFile(path.join(root, "package.json"), "utf8")) !==
      originalPackage;
    const lockChanged =
      (await fs.readFile(path.join(root, "package-lock.json"), "utf8")) !==
      originalLock;
    const stdout = [
      packageChanged ? " M package.json" : "",
      lockChanged ? " M package-lock.json" : "",
    ]
      .filter(Boolean)
      .map((entry) => `${entry}\0`)
      .join("");
    return exited(0, stdout);
  };
  return { requests, runNpm, runRuntime };
}

test("builds a proposal from structured missing-peer fields using the selected runtime", async () => {
  const requests = [];
  const tree = {
    name: "fixture",
    version: "1.0.0",
    problems: ["ignored free-form diagnostic"],
    dependencies: {
      "parent-lib": {
        version: "2.0.0",
        dependencies: {
          "peer-lib": {
            missing: true,
            peer: true,
            required: "^1.0.0",
          },
        },
      },
    },
  };
  const reader = new NpmBaselineDependencyProposalReader({
    fnmExecutable: "fnm",
    environment: {},
    files: { canonicalProjectRoot: async (root) => root },
    runNpm: async (request) => {
      requests.push(request);
      assert.equal(request.nodeVersion, "20.18.0");
      if (request.arguments[0] === "ls") return exited(1, JSON.stringify(tree));
      return exited(0, JSON.stringify(["1.0.0", "1.9.0", "2.0.0"]));
    },
  });
  const proposal = await reader.read("C:\\fixture", {
    discoveryPlan: { runtimePlan: { selected: { nodeVersion: "20.18.0" } } },
  });

  assert.deepEqual(proposal, [packages[0]]);
  assert.deepEqual(requests[0].arguments, ["ls", "--all", "--json"]);
  assert.deepEqual(requests[1].arguments, [
    "view",
    "peer-lib@^1.0.0",
    "version",
    "--json",
  ]);
});

test("installs exact versions only after a clean Git check and verifies npm ls --all", async () => {
  await withProject(async (root) => {
    const fixture = installFixture(root);
    const installer = new NpmBaselineDependencyInstaller({
      fnmExecutable: "fnm",
      environment: {},
      runRuntime: fixture.runRuntime,
      runNpm: fixture.runNpm,
    });

    const result = await installer.install({
      projectRoot: root,
      runId: "run-1",
      nodeVersion: "20.18.0",
      packages,
    });

    assert.equal(result.outcome, "installed");
    assert.match(result.packageStateHash, /^sha256:[a-f0-9]{64}$/);
    assert.deepEqual(fixture.requests[0].arguments, [
      "install",
      "--save-prod",
      "--save-exact",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      "peer-lib@1.9.0",
    ]);
    assert.deepEqual(fixture.requests[1].arguments, ["ls", "--all"]);
  });
});

test("restores package files when the exact dependency-tree gate fails", async () => {
  await withProject(async (root, originalPackage, originalLock) => {
    const fixture = installFixture(root, 1);
    const installer = new NpmBaselineDependencyInstaller({
      fnmExecutable: "fnm",
      environment: {},
      runRuntime: fixture.runRuntime,
      runNpm: fixture.runNpm,
    });

    const result = await installer.install({
      projectRoot: root,
      runId: "run-1",
      nodeVersion: "20.18.0",
      packages,
    });

    assert.deepEqual(result, { outcome: "failed", packageStateHash: null });
    assert.equal(
      await fs.readFile(path.join(root, "package.json"), "utf8"),
      originalPackage,
    );
    assert.equal(
      await fs.readFile(path.join(root, "package-lock.json"), "utf8"),
      originalLock,
    );
  });
});
