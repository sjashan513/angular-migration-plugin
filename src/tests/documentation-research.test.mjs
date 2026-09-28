import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { discoverProject } from "../dist/application/discover-project.js";
import {
  getDocumentationPublishContext,
  publishDocumentation,
} from "../dist/application/documentation-publish.js";
import {
  getDocumentationResearchContext,
  recordDocumentationResearch,
} from "../dist/application/documentation-research.js";
import { runProject } from "../dist/application/run-project.js";
import {
  readValidatedRunRecord,
  startRun,
} from "../dist/application/start-run.js";

const projectRoot = "C:\\fixtures\\angular-app";

function createHarness() {
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
        id: "build",
        status: "configured",
        executable: "npm",
        arguments: ["run", "build"],
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
  let discovery = null;
  let run = null;
  let researchSubmission = null;
  let researchRecord = null;
  let publishSubmission = null;
  let publicationRecord = null;
  let outputFiles = null;
  let projectFingerprint = inputs.inputFingerprint;
  let angularMajor = inputs.sourceMajor;
  let gitSnapshot = { head: "d".repeat(40), changes: [] };
  let failNextOutputInspection = false;
  let interruptAfterAtomicPublish = false;
  let publishCalls = 0;
  const hasher = {
    hash: async (value) =>
      `sha256:${createHash("sha256").update(JSON.stringify(value)).digest("hex")}`,
  };
  const records = {
    read: async () => run,
    write: async (_root, value) => {
      run = value;
    },
  };
  const lock = {
    acquire: async () => ({
      kind: "acquired",
      release: async () => ({ kind: "released" }),
    }),
  };
  const artifacts = {
    readResearchSubmission: async () => researchSubmission,
    readPublishSubmission: async () => publishSubmission,
    readResearch: async () => researchRecord,
    readPublication: async () => publicationRecord,
    writeResearch: async (_root, _runId, value) => {
      researchRecord = value;
    },
    writePublication: async (_root, _runId, value) => {
      publicationRecord = value;
    },
    inspectOutput: async () => {
      if (failNextOutputInspection) {
        failNextOutputInspection = false;
        throw new Error("simulated interruption after atomic publication");
      }
      return outputFiles;
    },
    inspectGitSnapshot: async () => gitSnapshot,
    publishFiles: async (input) => {
      publishCalls += 1;
      outputFiles = input.files
        .map(({ path: filePath, sha256 }) => ({ path: filePath, sha256 }))
        .sort((left, right) => left.path.localeCompare(right.path));
      gitSnapshot = {
        ...gitSnapshot,
        changes: [
          ...gitSnapshot.changes,
          ...outputFiles.map(({ path: filePath }) => ({
            path: filePath,
            status: "??",
          })),
        ].sort((left, right) => left.path.localeCompare(right.path)),
      };
      if (interruptAfterAtomicPublish) {
        failNextOutputInspection = true;
        interruptAfterAtomicPublish = false;
      }
      return hasher.hash(outputFiles);
    },
  };
  const ports = {
    runs: records,
    lock,
    fingerprints: { readFingerprint: async () => projectFingerprint },
    context: {
      readProjectFacts: async () => ({
        projectId: inputs.projectId,
        angularMajor,
      }),
      readFingerprint: async () => projectFingerprint,
    },
    artifacts,
    hasher,
    contentHasher: {
      hashText: async (content) =>
        `sha256:${createHash("sha256").update(content, "utf8").digest("hex")}`,
    },
  };
  const executionPorts = {
    records,
    lock,
    hasher,
    facts: {
      readProjectFacts: async () => ({
        projectId: inputs.projectId,
        angularMajor,
      }),
    },
    fingerprints: { readFingerprint: async () => projectFingerprint },
    operations: {
      execute: async (_root, operation) => {
        if (operation.id === "angular-core-cli-update") angularMajor = 8;
        if (
          [
            "angular-core-cli-update",
            "pin-target-packages",
            "update-lockfile",
          ].includes(operation.id)
        ) {
          projectFingerprint = `sha256:${createHash("sha256")
            .update(projectFingerprint + operation.id)
            .digest("hex")}`;
        }
        return { outcome: "passed" };
      },
    },
  };
  return {
    inputs,
    ports,
    records,
    artifacts,
    executionPorts,
    hasher,
    setResearchSubmission: (value) => {
      researchSubmission = value;
    },
    setPublishSubmission: (value) => {
      publishSubmission = value;
    },
    getPublishSubmission: () => publishSubmission,
    failAfterAtomicPublish: () => {
      interruptAfterAtomicPublish = true;
    },
    getPublishCalls: () => publishCalls,
    getOutputFiles: () => outputFiles,
    getRun: () => run,
    getResearch: () => researchRecord,
    createRun: harnessCreateRun,
    completeRun: async () => {
      const initial = run ?? (await harnessCreateRun());
      return runProject(
        { projectRoot, runId: initial.state.runId },
        executionPorts,
      );
    },
  };

  async function harnessCreateRun() {
    await discoverProject(
      { projectRoot, targetMajor: 8 },
      {
        reader: { read: async () => inputs },
        records: {
          read: async () => discovery,
          write: async (_root, value) => {
            discovery = value;
          },
        },
        hasher,
      },
    );
    run = await startRun(
      { projectRoot, targetMajor: 8 },
      {
        reader: { read: async () => inputs },
        discoveries: {
          read: async () => discovery,
          write: async (_root, value) => {
            discovery = value;
          },
        },
        runRecords: records,
        lock,
        ids: { create: () => "00000000-0000-4000-8000-000000000001" },
        hasher,
      },
    );
    return run;
  }
}

function validResearch(run) {
  return {
    schemaVersion: 1,
    runId: run.state.runId,
    sourceMajor: 7,
    targetMajor: 8,
    planHash: run.discoveryPlan.planHash,
    researchedAt: "2026-09-10T10:30:00.000Z",
    sources: [
      {
        id: "S-001",
        title: "Angular Update Guide",
        url: "https://angular.dev/update-guide",
        publisher: "Angular",
        primary: true,
        accessedAt: "2026-09-10T10:20:00.000Z",
      },
    ],
    findings: [
      {
        id: "F-001",
        kind: "official-change",
        title: "Framework migration guidance",
        area: "framework",
        summary:
          "Review the planned @angular/core change from 7.2.16 to 8.2.14.",
        affectedPackages: ["@angular/core"],
        sourceIds: ["S-001"],
        applicability: "applicable",
      },
    ],
    concepts: [
      {
        id: "C-001",
        name: "Migration schematics",
        whyItMatters: "Review generated changes before relying on them.",
        sourceIds: ["S-001"],
      },
    ],
    unresolved: [],
  };
}

async function preparePublishHarness() {
  const harness = createHarness();
  const run = await harness.completeRun();
  harness.setResearchSubmission(validResearch(run));
  await recordDocumentationResearch(
    { projectRoot, runId: run.state.runId },
    harness.ports,
  );
  const outputDirectory = "docs/migration/v8";
  const files = await Promise.all(
    [
      "README.md",
      "changes.md",
      "dependencies.md",
      "errors-and-repairs.md",
      "new-concepts.md",
      "sources.md",
      "validation.md",
      "warnings.md",
    ].map(async (name) => {
      const content =
        name === "README.md"
          ? "# Migration\n\nSee [changes](changes.md#changes).\n"
          : `# ${name.replace(/\.md$/, "")}\n`;
      return {
        path: `${outputDirectory}/${name}`,
        content,
        sha256: await harness.ports.contentHasher.hashText(content),
      };
    }),
  );
  harness.setPublishSubmission({
    schemaVersion: 1,
    runId: run.state.runId,
    planHash: run.discoveryPlan.planHash,
    researchHash: harness.getResearch().researchHash,
    outputDirectory,
    files,
    claims: [
      {
        id: "D-1",
        kind: "official-change",
        document: "changes.md",
        evidence: ["source:S-001"],
      },
    ],
    remainingWarnings: [],
  });
  return { harness, run };
}

test("research context exposes only run-bound plan and authorized evidence", async () => {
  const harness = createHarness();
  const run = await harness.createRun();
  const context = await getDocumentationResearchContext(
    { projectRoot, runId: run.state.runId },
    harness.ports,
  );

  assert.equal(context.mode, "research");
  assert.equal(context.planHash, run.discoveryPlan.planHash);
  assert.deepEqual(context.dependencies, [
    {
      name: "@angular/cli",
      currentVersion: "7.3.10",
      targetVersion: "8.3.29",
      reason: "highest-stable-compatible",
    },
    {
      name: "@angular/core",
      currentVersion: "7.2.16",
      targetVersion: "8.2.14",
      reason: "highest-stable-compatible",
    },
  ]);
  assert.equal(context.evidence.status, "running");
  assert.match(
    context.submissionPath,
    /\.angular-migration\/documentation-inbox/,
  );
});

test("records a validated research artifact and append-only event without changing technical state", async () => {
  const harness = createHarness();
  const run = await harness.createRun();
  harness.setResearchSubmission(validResearch(run));

  const recorded = await recordDocumentationResearch(
    { projectRoot, runId: run.state.runId },
    harness.ports,
  );
  const validated = await readValidatedRunRecord(
    harness.getRun(),
    harness.hasher,
  );

  assert.equal(recorded.status, "researched");
  assert.match(recorded.researchHash, /^sha256:[a-f0-9]{64}$/);
  assert.equal(validated.state.status, "running");
  assert.equal(validated.events.at(-1).type, "documentation-research-recorded");
  assert.equal(harness.getResearch().researchHash, recorded.researchHash);
});

test("rejects non-HTTPS citations and versions absent from the plan", async () => {
  const harness = createHarness();
  const run = await harness.createRun();
  const insecure = validResearch(run);
  insecure.sources[0].url = "http://angular.dev/update-guide";
  harness.setResearchSubmission(insecure);
  await assert.rejects(
    recordDocumentationResearch(
      { projectRoot, runId: run.state.runId },
      harness.ports,
    ),
    { code: "documentation_source_invalid" },
  );

  const unknownVersion = validResearch(run);
  unknownVersion.findings[0].summary =
    "This applies to package version 99.99.99.";
  harness.setResearchSubmission(unknownVersion);
  await assert.rejects(
    recordDocumentationResearch(
      { projectRoot, runId: run.state.runId },
      harness.ports,
    ),
    { code: "documentation_finding_invalid" },
  );
});

test("publishes the exact approved documents without changing verified status", async () => {
  const { harness, run } = await preparePublishHarness();
  const context = await getDocumentationPublishContext(
    { projectRoot, runId: run.state.runId },
    harness.ports,
  );
  const result = await publishDocumentation(
    {
      projectRoot,
      runId: run.state.runId,
      proposalHash: context.proposalHash,
      confirmed: true,
    },
    harness.ports,
  );
  const validated = await readValidatedRunRecord(
    harness.getRun(),
    harness.hasher,
  );

  assert.equal(result.status, "published");
  assert.equal(result.technicalStatus, "verified");
  assert.equal(validated.state.status, "verified");
  assert.equal(validated.events.at(-1).type, "documentation-published");
  assert.equal(
    validated.events.at(-1).documentation.expectedGitSnapshot.changes.length,
    0,
  );
  assert.equal(harness.getPublishCalls(), 1);
  assert.equal(harness.getOutputFiles().length, 8);
});

test("recovers the same proposal after atomic output exists but event finalization is interrupted", async () => {
  const { harness, run } = await preparePublishHarness();
  const context = await getDocumentationPublishContext(
    { projectRoot, runId: run.state.runId },
    harness.ports,
  );
  harness.failAfterAtomicPublish();

  await assert.rejects(
    publishDocumentation(
      {
        projectRoot,
        runId: run.state.runId,
        proposalHash: context.proposalHash,
        confirmed: true,
      },
      harness.ports,
    ),
    /simulated interruption/,
  );
  assert.equal(harness.getRun().state.status, "verified");
  assert.equal(
    harness.getRun().events.at(-1).type,
    "documentation-publish-started",
  );

  const recovery = await getDocumentationPublishContext(
    { projectRoot, runId: run.state.runId },
    harness.ports,
  );
  assert.equal(recovery.recovery, true);
  assert.equal(recovery.proposalHash, context.proposalHash);
  await publishDocumentation(
    {
      projectRoot,
      runId: run.state.runId,
      proposalHash: recovery.proposalHash,
      confirmed: true,
    },
    harness.ports,
  );

  assert.equal(harness.getRun().state.status, "verified");
  assert.equal(harness.getRun().events.at(-1).type, "documentation-published");
  assert.equal(harness.getPublishCalls(), 1);
});

test("blocks publication before technical verification", async () => {
  const harness = createHarness();
  const run = await harness.createRun();
  harness.setResearchSubmission(validResearch(run));
  await recordDocumentationResearch(
    { projectRoot, runId: run.state.runId },
    harness.ports,
  );
  harness.setPublishSubmission({});

  await assert.rejects(
    getDocumentationPublishContext(
      { projectRoot, runId: run.state.runId },
      harness.ports,
    ),
    { code: "publish_requires_verified" },
  );
});

test("rejects a stale publish proposal after its approved content changes", async () => {
  const { harness, run } = await preparePublishHarness();
  const context = await getDocumentationPublishContext(
    { projectRoot, runId: run.state.runId },
    harness.ports,
  );
  const submission = harness.getPublishSubmission();
  submission.files[0].content = "# Revised migration\n";
  submission.files[0].sha256 = await harness.ports.contentHasher.hashText(
    submission.files[0].content,
  );

  await assert.rejects(
    publishDocumentation(
      {
        projectRoot,
        runId: run.state.runId,
        proposalHash: context.proposalHash,
        confirmed: true,
      },
      harness.ports,
    ),
    { code: "documentation_publish_proposal_stale" },
  );
  assert.equal(harness.getRun().state.status, "verified");
  assert.notEqual(
    harness.getRun().events.at(-1).type,
    "documentation-publish-started",
  );
});

test("rejects internal documentation links that escape the output directory", async () => {
  const { harness, run } = await preparePublishHarness();
  const submission = harness.getPublishSubmission();
  submission.files[0].content =
    "# Migration\n\n[package](../../package.json)\n";
  submission.files[0].sha256 = await harness.ports.contentHasher.hashText(
    submission.files[0].content,
  );

  await assert.rejects(
    getDocumentationPublishContext(
      { projectRoot, runId: run.state.runId },
      harness.ports,
    ),
    { code: "documentation_link_broken" },
  );
});
