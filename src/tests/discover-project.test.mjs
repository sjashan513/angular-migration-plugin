import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import {
  discoverProject,
  readValidatedDiscoveryRecord,
} from "../dist/application/discover-project.js";

const projectRoot = "C:\\fixtures\\angular-app";

function dependencies(overrides = {}) {
  const snapshot = {
    projectId: `sha256:${"a".repeat(64)}`,
    inputFingerprint: `sha256:${"b".repeat(64)}`,
    sourceMajor: 7,
    projectShape: "root-angular-cli",
    packageManager: "npm",
    lockfileVersion: 3,
    gitStatus: "clean",
    registryStatus: "trusted",
    dependencySourcesStatus: "safe",
    nodeRanges: [">=14 <22"],
    npmRange: ">=7",
    runtimeCandidates: [
      { nodeVersion: "20.18.0", npmVersion: "10.8.2", status: "installed" },
    ],
    metadataRuntimeVersion: "20.18.0",
    checks: [
      {
        id: "typecheck",
        status: "configured",
        executable: "npm",
        arguments: ["run", "type-check"],
        reason: null,
      },
      {
        id: "lint",
        status: "not-configured",
        executable: null,
        arguments: [],
        reason: "No matching npm script was found.",
      },
    ],
    packages: [
      {
        name: "@angular/core",
        sourceVersion: "7.2.16",
        targetVersion: "8.2.14",
        registryId: "npmjs",
        nodeRange: ">=10.9.0",
        peerDependencies: [],
        reason: "highest-stable-compatible",
      },
    ],
    registryIdentities: [{ scope: "default", registryId: "npmjs" }],
    ...overrides,
  };
  const recordState = { value: null };
  return {
    reader: { read: async () => snapshot },
    records: {
      read: async () => recordState.value,
      write: async (_root, value) => {
        recordState.value = value;
      },
    },
    hasher: {
      hash: async (value) =>
        `sha256:${createHash("sha256").update(JSON.stringify(value)).digest("hex")}`,
    },
    snapshot,
    recordState,
  };
}

test("produces and persists a deterministic ready N-to-N+1 plan", async () => {
  const ports = dependencies();
  const first = await discoverProject({ projectRoot, targetMajor: 8 }, ports);
  const second = await discoverProject({ projectRoot, targetMajor: 8 }, ports);

  assert.equal(first.status, "ready");
  assert.equal(first.sourceMajor, 7);
  assert.equal(first.targetMajor, 8);
  assert.equal(first.runtimePlan.selected.nodeVersion, "20.18.0");
  assert.equal(first.packages[0].targetVersion, "8.2.14");
  assert.deepEqual(first, second);
  assert.deepEqual(await ports.records.read(), first);
  assert.doesNotMatch(JSON.stringify(first), /C:\\fixtures/);
});

test("blocks unsafe project states and rejects a non-sequential target", async () => {
  const dirty = dependencies({ gitStatus: "dirty" });
  const plan = await discoverProject({ projectRoot, targetMajor: 8 }, dirty);
  assert.equal(plan.status, "blocked");
  assert.ok(plan.blockers.some(({ code }) => code === "git_worktree_dirty"));

  await assert.rejects(
    discoverProject({ projectRoot, targetMajor: 9 }, dependencies()),
    { code: "non_sequential_angular_major" },
  );
});

test("records a missing exact runtime as a proposal without mutation", async () => {
  const ports = dependencies({
    runtimeCandidates: [
      { nodeVersion: "16.20.2", npmVersion: null, status: "missing" },
    ],
  });
  const plan = await discoverProject({ projectRoot, targetMajor: 8 }, ports);

  assert.equal(plan.status, "runtime-install-required");
  assert.equal(plan.runtimePlan.selected.nodeVersion, "16.20.2");
  assert.equal(plan.runtimePlan.selected.status, "missing");
});

test("rejects stale, tampered, and wrong-project discovery records", async () => {
  const ports = dependencies();
  const plan = await discoverProject({ projectRoot, targetMajor: 8 }, ports);
  const expected = {
    projectId: plan.projectId,
    inputFingerprint: plan.inputFingerprint,
    targetMajor: plan.targetMajor,
  };

  assert.deepEqual(
    await readValidatedDiscoveryRecord(plan, expected, ports.hasher),
    plan,
  );
  await assert.rejects(
    readValidatedDiscoveryRecord(
      {
        ...plan,
        checks: [
          { ...plan.checks[0], arguments: [3] },
          ...plan.checks.slice(1),
        ],
      },
      expected,
      ports.hasher,
    ),
    { code: "discovery_invalid" },
  );
  await assert.rejects(
    readValidatedDiscoveryRecord(
      {
        ...plan,
        packages: plan.packages.map((item) => ({
          ...item,
          targetVersion: "8.2.15",
        })),
      },
      expected,
      ports.hasher,
    ),
    { code: "discovery_integrity_failed" },
  );
  await assert.rejects(
    readValidatedDiscoveryRecord(
      plan,
      { ...expected, projectId: "other" },
      ports.hasher,
    ),
    { code: "discovery_context_mismatch" },
  );
  await assert.rejects(
    readValidatedDiscoveryRecord(
      plan,
      { ...expected, inputFingerprint: `sha256:${"c".repeat(64)}` },
      ports.hasher,
    ),
    { code: "discovery_stale" },
  );
});
