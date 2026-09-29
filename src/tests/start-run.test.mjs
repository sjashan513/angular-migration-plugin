import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { discoverProject } from "../dist/application/discover-project.js";
import {
  readValidatedRunRecord,
  startRun,
} from "../dist/application/start-run.js";
import { getRunStatus } from "../dist/application/status-run.js";

const projectRoot = "C:\\fixtures\\angular-app";

function createPorts(overrides = {}) {
  const inputs = {
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
    checks: [],
    packages: [
      {
        name: "@angular/core",
        sourceVersion: "7.2.16",
        targetVersion: "8.2.14",
        registryId: "npmjs",
        nodeRange: null,
        peerDependencies: [],
        reason: "highest-stable-compatible",
      },
    ],
    registryIdentities: [{ scope: "default", registryId: "npmjs" }],
    ...overrides.inputs,
  };
  let discoveryPlan = null;
  const runRecords = { value: null };
  const locks = { released: false };
  const lifecycle = [];
  const ports = {
    reader: { read: async () => inputs },
    discoveries: {
      read: async () => discoveryPlan,
      write: async (_root, value) => {
        discoveryPlan = value;
      },
    },
    runRecords: {
      read: async () => runRecords.value,
      write: async (_root, value) => {
        lifecycle.push("persist");
        runRecords.value = value;
      },
    },
    hookRuntime: overrides.hookRuntime ?? {
      deploy: async () => {
        lifecycle.push("deploy");
      },
    },
    lock: {
      acquire: async () =>
        overrides.lockResult ?? {
          kind: "acquired",
          release: async () => {
            locks.released = true;
            return { kind: "released" };
          },
        },
    },
    ids: { create: () => "00000000-0000-4000-8000-000000000001" },
    hasher: {
      hash: async (value) =>
        `sha256:${createHash("sha256").update(JSON.stringify(value)).digest("hex")}`,
    },
    runRecordsState: runRecords,
    locks,
  };
  return { ports, inputs, runRecords, locks, lifecycle };
}

async function createReadyDiscovery(ports, inputs) {
  return discoverProject(
    { projectRoot, targetMajor: 8 },
    {
      reader: { read: async () => inputs },
      records: ports.discoveries,
      hasher: ports.hasher,
    },
  );
}

test("deploys the hook runtime before persisting a run", async () => {
  const { ports, inputs, runRecords, locks, lifecycle } = createPorts();
  const plan = await createReadyDiscovery(ports, inputs);

  const run = await startRun({ projectRoot, targetMajor: 8 }, ports);

  assert.equal(run.schemaVersion, 1);
  assert.equal(run.state.status, "running");
  assert.equal(run.state.stage, "baseline");
  assert.equal(run.state.sourceMajor, 7);
  assert.equal(run.state.targetMajor, 8);
  assert.equal(run.discoveryPlan.planHash, plan.planHash);
  assert.equal(run.discoveryPlan.runtimePlan.selected.nodeVersion, "20.18.0");
  assert.equal(runRecords.value, run);
  assert.equal(locks.released, true);
  assert.deepEqual(lifecycle, ["deploy", "persist"]);
  assert.doesNotMatch(JSON.stringify(run), /C:\\\\fixtures/);
});

test("does not persist a run when hook runtime deployment fails", async () => {
  const { ports, inputs, runRecords, locks } = createPorts({
    hookRuntime: {
      deploy: async () => {
        throw new Error("runtime asset missing");
      },
    },
  });
  await createReadyDiscovery(ports, inputs);

  await assert.rejects(startRun({ projectRoot, targetMajor: 8 }, ports), {
    message: "runtime asset missing",
  });
  assert.equal(runRecords.value, null);
  assert.equal(locks.released, true);
});

test("rejects a stale discovery plan before writing a run", async () => {
  const { ports, inputs, runRecords } = createPorts();
  await createReadyDiscovery(ports, inputs);
  inputs.inputFingerprint = `sha256:${"c".repeat(64)}`;

  await assert.rejects(startRun({ projectRoot, targetMajor: 8 }, ports), {
    code: "discovery_stale",
  });
  assert.equal(runRecords.value, null);
});

test("status validates and reports the run without writing", async () => {
  const { ports, inputs, runRecords, locks } = createPorts();
  await createReadyDiscovery(ports, inputs);
  const run = await startRun({ projectRoot, targetMajor: 8 }, ports);
  let writes = 0;
  const status = await getRunStatus(
    { projectRoot },
    {
      records: {
        read: async () => runRecords.value,
        write: async () => {
          writes += 1;
        },
      },
      context: {
        readProjectFacts: async () => ({
          projectId: inputs.projectId,
          angularMajor: 7,
        }),
        readFingerprint: async () => inputs.inputFingerprint,
      },
      hasher: ports.hasher,
    },
  );

  assert.deepEqual(status, {
    schemaVersion: 1,
    runId: run.state.runId,
    status: "running",
    stage: "baseline",
    sourceMajor: 7,
    targetMajor: 8,
    revision: 0,
    nextAction: "run",
    diagnostic: null,
  });
  assert.equal(writes, 0);
  assert.equal(locks.released, true);

  const staleStatus = await getRunStatus(
    { projectRoot },
    {
      records: { read: async () => runRecords.value },
      context: {
        readProjectFacts: async () => ({
          projectId: inputs.projectId,
          angularMajor: 7,
        }),
        readFingerprint: async () => `sha256:${"d".repeat(64)}`,
      },
      hasher: ports.hasher,
    },
  );
  assert.equal(staleStatus.nextAction, "human-intervention");
  assert.equal(staleStatus.diagnostic.code, "project_fingerprint_changed");
  assert.equal(writes, 0);
});

test("rejects a re-hashed run record with an incoherent event sequence", async () => {
  const { ports, inputs } = createPorts();
  await createReadyDiscovery(ports, inputs);
  const valid = await startRun({ projectRoot, targetMajor: 8 }, ports);
  const { recordHash: _recordHash, ...content } = valid;
  const altered = {
    ...content,
    events: [
      ...valid.events,
      {
        sequence: 1,
        type: "stage-completed",
        stage: "baseline",
        status: "running",
        revision: 1,
      },
    ],
  };
  const tampered = {
    ...altered,
    recordHash: await ports.hasher.hash(altered),
  };

  await assert.rejects(readValidatedRunRecord(tampered, ports.hasher), {
    code: "run_record_invalid",
  });
});
