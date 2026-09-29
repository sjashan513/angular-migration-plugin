import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { approveRuntimeInstall } from "../dist/application/approve-runtime-install.js";
import { discoverProject } from "../dist/application/discover-project.js";

const projectRoot = "C:\\fixtures\\angular-app";

function createPorts() {
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
    nodeRanges: [">=10 <18"],
    npmRange: ">=7",
    runtimeCandidates: [
      { nodeVersion: "16.20.2", npmVersion: null, status: "missing" },
    ],
    metadataRuntimeVersion: null,
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
  };
  let audit = null;
  let installed = false;
  let installCalls = 0;
  let installOutcome = "installed";
  const ports = {
    reader: { read: async () => snapshot },
    records: {
      read: async () => null,
      write: async () => undefined,
    },
    hasher: {
      hash: async (value) =>
        `sha256:${createHash("sha256").update(JSON.stringify(value)).digest("hex")}`,
    },
    runRecords: { read: async () => null },
    lock: {
      acquire: async () => ({
        kind: "acquired",
        release: async () => ({ kind: "released" }),
      }),
    },
    installer: {
      install: async (_root, nodeVersion) => {
        installCalls += 1;
        assert.equal(nodeVersion, "16.20.2");
        if (installOutcome !== "installed") return installOutcome;
        installed = true;
        snapshot.runtimeCandidates = [
          {
            nodeVersion,
            npmVersion: "10.8.2",
            status: "installed",
          },
        ];
        return "installed";
      },
    },
    audit: {
      read: async () => audit,
      write: async (_root, events) => {
        audit = structuredClone(events);
      },
    },
  };
  return {
    ports,
    snapshot,
    get audit() {
      return audit;
    },
    setAudit(value) {
      audit = value;
    },
    setInstallOutcome(value) {
      installOutcome = value;
    },
    get installCalls() {
      return installCalls;
    },
    get installed() {
      return installed;
    },
  };
}

test("requires explicit confirmation before acquiring or installing", async () => {
  const fixture = createPorts();
  await assert.rejects(
    approveRuntimeInstall(
      {
        projectRoot,
        targetMajor: 8,
        proposalHash: `sha256:${"c".repeat(64)}`,
        confirmed: false,
      },
      fixture.ports,
    ),
    { code: "confirmation_required" },
  );
  assert.equal(fixture.installCalls, 0);
  assert.equal(fixture.audit, null);
});

test("rejects a stale proposal digest without installing a runtime", async () => {
  const fixture = createPorts();
  await assert.rejects(
    approveRuntimeInstall(
      {
        projectRoot,
        targetMajor: 8,
        proposalHash: `sha256:${"c".repeat(64)}`,
        confirmed: true,
      },
      fixture.ports,
    ),
    { code: "runtime_proposal_stale" },
  );
  assert.equal(fixture.installCalls, 0);
  assert.equal(fixture.installed, false);
});

test("installs only the approved exact runtime and verifies it by rediscovery", async () => {
  const fixture = createPorts();
  const plan = await discoverProject(
    { projectRoot, targetMajor: 8 },
    fixture.ports,
  );
  const result = await approveRuntimeInstall(
    {
      projectRoot,
      targetMajor: 8,
      proposalHash: plan.planHash,
      confirmed: true,
    },
    fixture.ports,
  );

  assert.equal(result.status, "installed");
  assert.equal(result.nodeVersion, "16.20.2");
  assert.equal(result.discovery.status, "ready");
  assert.equal(result.discovery.runtimePlan.selected.nodeVersion, "16.20.2");
  assert.equal(fixture.installCalls, 1);
  assert.deepEqual(
    fixture.audit.map(({ outcome }) => outcome),
    ["started", "installed"],
  );
});

test("fails closed on corrupted audit history before any runtime mutation", async () => {
  const fixture = createPorts();
  fixture.setAudit([{ sequence: 0, outcome: "started" }]);

  await assert.rejects(
    approveRuntimeInstall(
      {
        projectRoot,
        targetMajor: 8,
        proposalHash: `sha256:${"c".repeat(64)}`,
        confirmed: true,
      },
      fixture.ports,
    ),
    { code: "runtime_install_audit_invalid" },
  );
  assert.equal(fixture.installCalls, 0);
});

test("does not replay a runtime proposal after an unverified install failure", async () => {
  const fixture = createPorts();
  const plan = await discoverProject(
    { projectRoot, targetMajor: 8 },
    fixture.ports,
  );
  fixture.setInstallOutcome("failed");
  const request = {
    projectRoot,
    targetMajor: 8,
    proposalHash: plan.planHash,
    confirmed: true,
  };

  await assert.rejects(approveRuntimeInstall(request, fixture.ports), {
    code: "runtime_install_failed",
  });
  await assert.rejects(approveRuntimeInstall(request, fixture.ports), {
    code: "runtime_install_already_attempted",
  });
  assert.equal(fixture.installCalls, 1);
  assert.deepEqual(
    fixture.audit.map(({ outcome }) => outcome),
    ["started", "failed"],
  );
});
