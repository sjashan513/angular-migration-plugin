import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { approveCheckSkip } from "../dist/application/approve-check-skip.js";
import {
  approveBaselineDependencies,
  getBaselineDependencyContext,
} from "../dist/application/baseline-dependencies.js";
import { discoverProject } from "../dist/application/discover-project.js";
import {
  getRepairContext,
  recordRepair,
} from "../dist/application/repair-run.js";
import { runProject } from "../dist/application/run-project.js";
import {
  readValidatedRunRecord,
  sealRunRecord,
  startRun,
} from "../dist/application/start-run.js";
import { getRunStatus } from "../dist/application/status-run.js";

const projectRoot = "C:\\fixtures\\angular-app";

function createHarness({
  failAtWrite = 0,
  blockedOperation = null,
  failedOperation = null,
  repairableOperation = null,
  baselineDependencyFailure = false,
} = {}) {
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
    checks: [
      {
        id: "install",
        status: "configured",
        executable: "npm",
        arguments: ["ci"],
        reason: null,
      },
      {
        id: "dependency-tree",
        status: "configured",
        executable: "npm",
        arguments: ["ls", "--all"],
        reason: null,
      },
      {
        id: "typecheck",
        status: "configured",
        executable: "npm",
        arguments: ["run", "type-check"],
        reason: null,
      },
    ],
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
      {
        name: "@angular/cli",
        sourceVersion: "7.3.10",
        targetVersion: "8.3.29",
        registryId: "npmjs",
        nodeRange: null,
        peerDependencies: [],
        reason: "highest-stable-compatible",
      },
    ],
    registryIdentities: [{ scope: "default", registryId: "npmjs" }],
  };
  let discoveryPlan = null;
  let runRecord = null;
  let writeCount = 0;
  let failWrite = failAtWrite;
  let fingerprint = inputs.inputFingerprint;
  let angularMajor = inputs.sourceMajor;
  let repairPasses = false;
  let failBaselineDependencyTree = baselineDependencyFailure;
  const operationsCalled = [];
  const hasher = {
    hash: async (value) =>
      `sha256:${createHash("sha256").update(JSON.stringify(value)).digest("hex")}`,
  };
  const runRecords = {
    read: async () => runRecord,
    write: async (_root, value) => {
      writeCount += 1;
      if (writeCount === failWrite)
        throw new Error("simulated storage interruption");
      runRecord = value;
    },
  };
  const lock = {
    acquire: async () => ({
      kind: "acquired",
      release: async () => ({ kind: "released" }),
    }),
  };
  const ports = {
    reader: { read: async () => inputs },
    discoveries: {
      read: async () => discoveryPlan,
      write: async (_root, value) => {
        discoveryPlan = value;
      },
    },
    runRecords,
    lock,
    ids: { create: () => "00000000-0000-4000-8000-000000000001" },
    hasher,
  };
  const executionPorts = {
    records: runRecords,
    lock,
    hasher,
    facts: {
      readProjectFacts: async () => ({
        projectId: inputs.projectId,
        angularMajor,
      }),
    },
    fingerprints: {
      readFingerprint: async () => fingerprint,
    },
    operations: {
      execute: async (_root, operation) => {
        operationsCalled.push(operation.id);
        if (
          operation.id === "baseline-dependency-tree" &&
          failBaselineDependencyTree
        ) {
          return {
            outcome: "blocked",
            diagnostic: {
              code: "process_nonzero_exit",
              message: "The baseline dependency tree is invalid.",
            },
          };
        }
        if (operation.id === blockedOperation) {
          return {
            outcome: "blocked",
            diagnostic: {
              code: "process_failed",
              message: "A migration operation did not pass its postcondition.",
            },
          };
        }
        if (operation.id === failedOperation) {
          return {
            outcome: "failed",
            diagnostic: {
              code: "process_spawn_failed",
              message: "The planned executable could not be started.",
            },
          };
        }
        if (operation.id === repairableOperation && !repairPasses) {
          return {
            outcome: "blocked",
            diagnostic: {
              code: "process_nonzero_exit",
              message:
                "The configured validation check returned a nonzero exit.",
            },
          };
        }
        if (operation.id === "angular-core-cli-update") angularMajor = 8;
        if (
          [
            "angular-core-cli-update",
            "pin-target-packages",
            "update-lockfile",
          ].includes(operation.id)
        ) {
          fingerprint = `sha256:${createHash("sha256")
            .update(fingerprint + operation.id)
            .digest("hex")}`;
        }
        return { outcome: "passed" };
      },
    },
  };
  return {
    ports,
    executionPorts,
    operationsCalled,
    getRunRecord: () => runRecord,
    getWriteCount: () => writeCount,
    resetWriteFailure: () => {
      writeCount = 0;
      failWrite = 0;
    },
    setFingerprint: (value) => {
      fingerprint = value;
    },
    setRepairPasses: (value) => {
      repairPasses = value;
    },
    setBaselineDependencyFailure: (value) => {
      failBaselineDependencyTree = value;
    },
  };
}

async function start(harness) {
  await discoverProject(
    { projectRoot, targetMajor: 8 },
    {
      reader: harness.ports.reader,
      records: harness.ports.discoveries,
      hasher: harness.ports.hasher,
    },
  );
  return startRun({ projectRoot, targetMajor: 8 }, harness.ports);
}

test("runs the fixed stages in order and stops at verified/document", async () => {
  const harness = createHarness();
  const initial = await start(harness);

  const result = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );

  assert.deepEqual(harness.operationsCalled, [
    "baseline-install",
    "baseline-dependency-tree",
    "baseline-typecheck",
    "verify-discovery-plan",
    "angular-core-cli-update",
    "pin-target-packages",
    "update-lockfile",
    "install-clean",
    "install-dependency-tree",
    "validate-typecheck",
  ]);
  assert.equal(result.state.status, "verified");
  assert.equal(result.state.stage, "document");
  assert.ok(result.checkpoints.length >= 18);
  assert.equal(
    (
      await getRunStatus(
        { projectRoot },
        {
          records: harness.ports.runRecords,
          context: {
            readProjectFacts: async () => ({
              projectId: `sha256:${"a".repeat(64)}`,
              angularMajor: 8,
            }),
            readFingerprint: async () =>
              harness.getRunRecord().checkpoints.at(-1).projectFingerprint,
          },
          hasher: harness.ports.hasher,
        },
      )
    ).nextAction,
    "documentation",
  );
});

test("approves a current baseline proposal once and resumes after its verified gate", async () => {
  const harness = createHarness({ baselineDependencyFailure: true });
  const initial = await start(harness);
  const blocked = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );
  assert.equal(blocked.state.status, "blocked");

  const proposalPackages = [
    {
      name: "peer-lib",
      installVersion: "1.9.0",
      requiredRanges: ["^1.0.0"],
      requiredBy: ["parent-lib@2.0.0"],
    },
  ];
  const approvalPorts = {
    records: harness.ports.runRecords,
    lock: harness.ports.lock,
    fingerprints: harness.executionPorts.fingerprints,
    proposals: { read: async () => proposalPackages },
    installer: {
      install: async (input) => {
        assert.deepEqual(input.packages, proposalPackages);
        harness.setFingerprint(`sha256:${"c".repeat(64)}`);
        return {
          outcome: "installed",
          packageStateHash: `sha256:${"a".repeat(64)}`,
        };
      },
    },
    hasher: harness.ports.hasher,
  };
  const context = await getBaselineDependencyContext(
    { projectRoot, runId: initial.state.runId },
    approvalPorts,
  );
  const approved = await approveBaselineDependencies(
    {
      projectRoot,
      runId: initial.state.runId,
      proposalHash: context.proposalHash,
      confirmed: true,
    },
    approvalPorts,
  );

  assert.equal(approved.status, "running");
  assert.equal(approved.proposalHash, context.proposalHash);
  const validated = await readValidatedRunRecord(
    harness.getRunRecord(),
    harness.ports.hasher,
  );
  assert.equal(validated.events.at(-1).type, "baseline-dependencies-approved");
  assert.equal(validated.checkpoints.at(-1).phase, "after");

  harness.setBaselineDependencyFailure(false);
  const resumed = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );

  assert.equal(resumed.state.status, "verified");
  assert.equal(
    harness.operationsCalled.filter((id) => id === "baseline-dependency-tree")
      .length,
    1,
  );
});

test("resumes from a confirmed checkpoint without repeating completed operations", async () => {
  const harness = createHarness({ failAtWrite: 6 });
  const initial = await start(harness);

  await assert.rejects(
    runProject(
      { projectRoot, runId: initial.state.runId },
      harness.executionPorts,
    ),
    /simulated storage interruption/,
  );
  assert.deepEqual(harness.operationsCalled, [
    "baseline-install",
    "baseline-dependency-tree",
  ]);
  assert.equal(harness.getRunRecord().checkpoints.at(-1).phase, "after");

  harness.resetWriteFailure();
  const result = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );

  assert.equal(result.state.status, "verified");
  assert.deepEqual(harness.operationsCalled.slice(0, 2), [
    "baseline-install",
    "baseline-dependency-tree",
  ]);
  assert.equal(
    harness.operationsCalled.filter((id) => id === "baseline-install").length,
    1,
  );
});

test("blocks changed project inputs before starting any operation", async () => {
  const harness = createHarness();
  const initial = await start(harness);
  harness.setFingerprint(`sha256:${"c".repeat(64)}`);

  const result = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );

  assert.equal(result.state.status, "blocked");
  assert.equal(result.diagnostic.code, "project_fingerprint_changed");
  assert.deepEqual(harness.operationsCalled, []);
});

test("fails closed on a before-checkpoint without its matching after checkpoint", async () => {
  const harness = createHarness({ failAtWrite: 3 });
  const initial = await start(harness);

  await assert.rejects(
    runProject(
      { projectRoot, runId: initial.state.runId },
      harness.executionPorts,
    ),
    /simulated storage interruption/,
  );
  assert.deepEqual(harness.operationsCalled, ["baseline-install"]);

  harness.resetWriteFailure();
  const result = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );

  assert.equal(result.state.status, "blocked");
  assert.equal(result.diagnostic.code, "operation_outcome_ambiguous");
  assert.deepEqual(harness.operationsCalled, ["baseline-install"]);
});

test("classifies a failed postcondition as blocked and does not continue", async () => {
  const harness = createHarness({
    blockedOperation: "angular-core-cli-update",
  });
  const initial = await start(harness);

  const result = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );

  assert.equal(result.state.status, "blocked");
  assert.equal(result.diagnostic.code, "process_failed");
  assert.deepEqual(harness.operationsCalled, [
    "baseline-install",
    "baseline-dependency-tree",
    "baseline-typecheck",
    "verify-discovery-plan",
    "angular-core-cli-update",
  ]);
});

test("classifies an unexpected process failure as failed", async () => {
  const harness = createHarness({ failedOperation: "baseline-install" });
  const initial = await start(harness);

  const result = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );

  assert.equal(result.state.status, "failed");
  assert.equal(result.diagnostic.code, "process_spawn_failed");
  assert.deepEqual(harness.operationsCalled, ["baseline-install"]);
});

test("an approved optional baseline skip is audited and is not rerun", async () => {
  const harness = createHarness({ blockedOperation: "baseline-typecheck" });
  const initial = await start(harness);
  const blocked = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );
  assert.equal(blocked.state.status, "blocked");

  await approveCheckSkip(
    {
      projectRoot,
      runId: initial.state.runId,
      checkId: "typecheck",
      reason: "The legacy typecheck tool is temporarily unavailable.",
      confirmed: true,
    },
    {
      records: harness.ports.runRecords,
      lock: harness.ports.lock,
      fingerprints: harness.executionPorts.fingerprints,
      hasher: harness.ports.hasher,
    },
  );
  const resumed = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );

  assert.equal(resumed.state.status, "verified");
  assert.equal(
    harness.operationsCalled.filter((id) => id === "baseline-typecheck").length,
    1,
  );
  const skipEvent = resumed.events.find(
    (event) => event.type === "check-skipped",
  );
  const skipCheckpoint = resumed.checkpoints.find(
    (checkpoint) => checkpoint.phase === "skipped",
  );
  assert.equal(
    skipEvent.skip.reason,
    "The legacy typecheck tool is temporarily unavailable.",
  );
  assert.equal(skipCheckpoint.operationId, "baseline-typecheck");
});

test("critical baseline checks cannot be skipped", async () => {
  let acquired = false;
  await assert.rejects(
    approveCheckSkip(
      {
        projectRoot,
        runId: "00000000-0000-4000-8000-000000000001",
        checkId: "build",
        reason: "skip for now",
        confirmed: true,
      },
      {
        records: { read: async () => null, write: async () => undefined },
        lock: {
          acquire: async () => {
            acquired = true;
            return { kind: "contended" };
          },
        },
        fingerprints: { readFingerprint: async () => "" },
        hasher: { hash: async () => "" },
      },
    ),
    { code: "critical_check_cannot_be_skipped" },
  );
  assert.equal(acquired, false);
});

test("a nonzero configured validation check enters needs-repair, not verified", async () => {
  const harness = createHarness({ repairableOperation: "validate-typecheck" });
  const initial = await start(harness);
  const result = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );

  assert.equal(result.state.status, "needs-repair");
  assert.equal(result.state.stage, "validate");
  assert.equal(result.diagnostic.code, "process_nonzero_exit");
  assert.equal(result.checkpoints.at(-1).operationId, "validate-typecheck");
  assert.equal(result.checkpoints.at(-1).phase, "before");
  const persisted = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );
  assert.equal(persisted.state.status, "needs-repair");

  const context = await getRepairContext(
    { projectRoot, runId: initial.state.runId },
    {
      records: harness.ports.runRecords,
      lock: harness.ports.lock,
      fingerprints: harness.executionPorts.fingerprints,
      operations: harness.executionPorts.operations,
      patches: { apply: async () => ({ rollback: async () => undefined }) },
      hasher: harness.ports.hasher,
    },
  );
  assert.deepEqual(context.allowedPaths, ["src/**/*"]);
  assert.equal(context.attempt, 1);
  const appliedFiles = [];
  harness.setRepairPasses(true);
  const repair = await recordRepair(
    {
      projectRoot,
      runId: initial.state.runId,
      submission: {
        schemaVersion: 1,
        runId: context.runId,
        fingerprint: context.fingerprint,
        attempt: context.attempt,
        rootCause: "The check requires an updated call signature.",
        changes: [
          {
            path: "src/app.ts",
            summary: "Update the call signature.",
            reason: "The compiler diagnostic identifies the argument mismatch.",
            content: "export const result = updatedCall();\n",
          },
        ],
        evidence: [
          {
            reference: "run-diagnostic",
            claim: "The recorded validation failed.",
          },
        ],
        unresolvedWarnings: [],
      },
    },
    {
      records: harness.ports.runRecords,
      lock: harness.ports.lock,
      fingerprints: harness.executionPorts.fingerprints,
      operations: harness.executionPorts.operations,
      patches: {
        apply: async (_root, files) => {
          appliedFiles.push(...files);
          return { rollback: async () => undefined };
        },
      },
      hasher: harness.ports.hasher,
    },
  );
  assert.equal(repair.verification, "passed");
  assert.equal(appliedFiles[0].path, "src/app.ts");
  const resumed = await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );
  assert.equal(resumed.state.status, "verified");
  assert.equal(
    resumed.events.some((event) => event.type === "repair-accepted"),
    true,
  );
});

test("rejects and rolls back a repair when the original validation gate still fails", async () => {
  const harness = createHarness({ repairableOperation: "validate-typecheck" });
  const initial = await start(harness);
  await runProject(
    { projectRoot, runId: initial.state.runId },
    harness.executionPorts,
  );
  const repairPorts = {
    records: harness.ports.runRecords,
    lock: harness.ports.lock,
    fingerprints: harness.executionPorts.fingerprints,
    operations: harness.executionPorts.operations,
    hasher: harness.ports.hasher,
  };
  const context = await getRepairContext(
    { projectRoot, runId: initial.state.runId },
    {
      ...repairPorts,
      patches: { apply: async () => ({ rollback: async () => undefined }) },
    },
  );
  let rollbackCount = 0;
  const resultPorts = {
    ...repairPorts,
    patches: {
      apply: async () => ({
        rollback: async () => {
          rollbackCount += 1;
        },
      }),
    },
  };

  await assert.rejects(
    recordRepair(
      {
        projectRoot,
        runId: initial.state.runId,
        submission: {
          schemaVersion: 1,
          runId: context.runId,
          fingerprint: context.fingerprint,
          attempt: context.attempt,
          rootCause: "The existing check remains unsatisfied.",
          changes: [
            {
              path: "src/app.ts",
              summary: "Adjust the failing call.",
              reason: "The validation diagnostic identifies the mismatch.",
              content: "export const result = updatedCall();\n",
            },
          ],
          evidence: [
            { reference: "run-diagnostic", claim: "The check still fails." },
          ],
          unresolvedWarnings: [],
        },
      },
      resultPorts,
    ),
    { code: "repair_verification_failed" },
  );

  const rejected = await readValidatedRunRecord(
    harness.getRunRecord(),
    harness.ports.hasher,
  );
  assert.equal(rollbackCount, 1);
  assert.equal(rejected.state.status, "needs-repair");
  assert.equal(rejected.events.at(-1).type, "repair-rejected");
  assert.equal(rejected.events.at(-1).repair.outcome, "rejected");

  const { recordHash: _recordHash, ...unsigned } = rejected;
  const corrupted = await sealRunRecord(
    {
      ...unsigned,
      events: rejected.events.map((event, index) =>
        index === rejected.events.length - 1
          ? {
              ...event,
              status: "running",
              repair: { ...event.repair, outcome: "accepted" },
            }
          : event,
      ),
    },
    harness.ports.hasher,
  );
  await assert.rejects(
    readValidatedRunRecord(corrupted, harness.ports.hasher),
    { code: "run_record_invalid" },
  );
});
