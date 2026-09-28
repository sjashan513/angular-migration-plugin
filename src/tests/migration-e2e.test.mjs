import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { discoverProject } from "../dist/application/discover-project.js";
import { runProject } from "../dist/application/run-project.js";
import {
  readValidatedRunRecord,
  startRun,
} from "../dist/application/start-run.js";
import { getRunStatus } from "../dist/application/status-run.js";
import {
  DiscoveryRecordStoreAdapter,
  ProjectValueHasher,
} from "../dist/infrastructure/discovery-persistence.js";
import { runProcess } from "../dist/infrastructure/process-runner.js";
import { ProjectDiscoveryReaderAdapter } from "../dist/infrastructure/project-discovery-reader.js";
import { ProjectFactsReaderAdapter } from "../dist/infrastructure/project-facts-reader.js";
import { ProjectFileSystem } from "../dist/infrastructure/project-files.js";
import { ProjectLock } from "../dist/infrastructure/project-lock.js";
import { RunRecordStoreAdapter } from "../dist/infrastructure/run-record-store.js";

test("discovers, starts, safely resumes, and verifies a file-backed Angular 7 to 8 fixture", async () => {
  const projectRoot = await fs.mkdtemp(
    path.join(tmpdir(), "angular-migration-e2e-"),
  );
  const toolsDirectory = await fs.mkdtemp(
    path.join(tmpdir(), "angular-migration-tools-"),
  );
  const controllerNode = process.execPath;
  const environment = Object.fromEntries(
    Object.entries(process.env).filter((entry) => typeof entry[1] === "string"),
  );
  const pathKey =
    Object.keys(environment).find((key) => key.toLowerCase() === "path") ??
    "Path";
  environment[pathKey] =
    `${toolsDirectory}${path.win32.delimiter}${environment[pathKey] ?? ""}`;
  environment.PATHEXT = ".COM;.EXE;.BAT;.CMD";
  environment.GIT_CONFIG_NOSYSTEM = "1";
  environment.GIT_AUTHOR_NAME = "Migration fixture";
  environment.GIT_AUTHOR_EMAIL = "fixture@example.invalid";
  environment.GIT_COMMITTER_NAME = "Migration fixture";
  environment.GIT_COMMITTER_EMAIL = "fixture@example.invalid";
  await fs.writeFile(path.join(toolsDirectory, "fnm.exe"), "fixture");

  try {
    await writeProjectFixture(projectRoot);
    await git(projectRoot, ["init", "--quiet"], environment);
    await git(
      projectRoot,
      ["add", "package.json", "package-lock.json", "angular.json"],
      environment,
    );
    await git(
      projectRoot,
      ["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"],
      environment,
    );

    const discoveryReader = new ProjectDiscoveryReaderAdapter({
      environment,
      runProcess: async (request) => {
        if (
          path.win32.basename(request.executable).toLowerCase() === "fnm.exe"
        ) {
          return exited(
            0,
            request.arguments[0] === "list"
              ? "* v20.18.0 default\n"
              : "v20.18.0\n",
          );
        }
        return runProcess(request);
      },
      runRuntime: async (request) =>
        exited(
          0,
          request.executable === "node"
            ? `v${request.nodeVersion}`
            : "10.8.2\n",
        ),
      runNpm: async (request) => {
        if (request.arguments[0] === "--version") return exited(0, "10.8.2\n");
        const selector = request.arguments[1];
        const packageName = selector.slice(0, selector.lastIndexOf("@"));
        const version = packageName === "@angular/cli" ? "8.3.29" : "8.2.14";
        return exited(
          0,
          JSON.stringify([
            { version, engines: { node: ">=10.9.0" }, peerDependencies: {} },
          ]),
        );
      },
    });
    const hasher = new ProjectValueHasher();
    const discoveries = new DiscoveryRecordStoreAdapter();
    const fileSystem = new ProjectFileSystem();
    const storedRuns = new RunRecordStoreAdapter(fileSystem);
    const lock = new ProjectLock(fileSystem);
    let runWrites = 0;
    let interrupted = false;
    const runRecords = {
      read: (root) => storedRuns.read(root),
      write: async (root, record) => {
        if (!interrupted && record.state.stage === "resolve") {
          interrupted = true;
          throw new Error(
            "simulated interruption after confirmed baseline checkpoints",
          );
        }
        runWrites += 1;
        await storedRuns.write(root, record);
      },
    };
    const plan = await discoverProject(
      { projectRoot, targetMajor: 8 },
      { reader: discoveryReader, records: discoveries, hasher },
    );
    assert.equal(plan.status, "ready");
    assert.equal(plan.sourceMajor, 7);
    assert.equal(plan.targetMajor, 8);
    assert.equal(plan.runtimePlan.selected.nodeVersion, "20.18.0");

    const initial = await startRun(
      { projectRoot, targetMajor: 8 },
      {
        reader: discoveryReader,
        discoveries,
        runRecords,
        lock,
        ids: { create: () => "00000000-0000-4000-8000-000000000007" },
        hasher,
      },
    );
    const facts = new ProjectFactsReaderAdapter(fileSystem);
    const operationsCalled = [];
    const operations = {
      execute: async (root, operation) => {
        operationsCalled.push(operation.id);
        if (operation.id === "angular-core-cli-update") {
          const manifestPath = path.join(root, "package.json");
          const lockPath = path.join(root, "package-lock.json");
          const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
          const lockfile = JSON.parse(await fs.readFile(lockPath, "utf8"));
          for (const item of operation.packages) {
            manifest.dependencies[item.name] = item.targetVersion;
            lockfile.packages[`node_modules/${item.name}`].version =
              item.targetVersion;
          }
          lockfile.packages[""].dependencies = { ...manifest.dependencies };
          await fs.writeFile(
            manifestPath,
            `${JSON.stringify(manifest, null, 2)}\n`,
          );
          await fs.writeFile(
            lockPath,
            `${JSON.stringify(lockfile, null, 2)}\n`,
          );
        }
        return { outcome: "passed" };
      },
    };
    const runPorts = {
      records: runRecords,
      lock,
      facts,
      fingerprints: discoveryReader,
      operations,
      hasher,
    };
    const runRequest = { projectRoot, runId: initial.state.runId };

    await assert.rejects(
      runProject(runRequest, runPorts),
      /simulated interruption/,
    );
    const beforeResume = await readValidatedRunRecord(
      await runRecords.read(projectRoot),
      hasher,
    );
    assert.equal(beforeResume.state.status, "running");
    assert.equal(beforeResume.state.stage, "baseline");
    assert.equal(beforeResume.checkpoints.at(-1).phase, "after");
    const operationsBeforeResume = [...operationsCalled];
    assert.ok(operationsBeforeResume.includes("baseline-install"));
    assert.ok(operationsBeforeResume.includes("baseline-dependency-tree"));

    const interruptedStatus = await getRunStatus(
      { projectRoot },
      {
        records: runRecords,
        context: {
          readProjectFacts: (root) => facts.readProjectFacts(root),
          readFingerprint: (root) => discoveryReader.readFingerprint(root),
        },
        hasher,
      },
    );
    assert.equal(interruptedStatus.nextAction, "run");

    const completed = await runProject(runRequest, runPorts);
    assert.equal(completed.state.status, "verified");
    assert.equal(completed.state.stage, "document");
    for (const operationId of operationsBeforeResume) {
      assert.equal(
        operationsCalled.filter((called) => called === operationId).length,
        1,
      );
    }
    const finalStatus = await getRunStatus(
      { projectRoot },
      {
        records: runRecords,
        context: {
          readProjectFacts: (root) => facts.readProjectFacts(root),
          readFingerprint: (root) => discoveryReader.readFingerprint(root),
        },
        hasher,
      },
    );
    assert.equal(finalStatus.status, "verified");
    assert.equal(finalStatus.nextAction, "documentation");
    assert.equal(finalStatus.sourceMajor, 7);
    assert.equal(finalStatus.targetMajor, 8);
    assert.equal((await facts.readProjectFacts(projectRoot)).angularMajor, 8);
    assert.equal(process.execPath, controllerNode);
    assert.ok(runWrites > 0);
  } finally {
    await fs.rm(projectRoot, { recursive: true, force: true });
    await fs.rm(toolsDirectory, { recursive: true, force: true });
  }
});

async function writeProjectFixture(projectRoot) {
  const manifest = {
    name: "angular-7-to-8-fixture",
    version: "1.0.0",
    dependencies: { "@angular/core": "^7.2.0", "@angular/cli": "~7.3.0" },
    scripts: { "type-check": "tsc --noEmit", build: "ng build" },
  };
  const lockfile = {
    name: manifest.name,
    lockfileVersion: 3,
    packages: {
      "": {
        name: manifest.name,
        version: manifest.version,
        dependencies: { ...manifest.dependencies },
      },
      "node_modules/@angular/core": { version: "7.2.16" },
      "node_modules/@angular/cli": { version: "7.3.10" },
    },
  };
  await fs.writeFile(
    path.join(projectRoot, "package.json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );
  await fs.writeFile(
    path.join(projectRoot, "package-lock.json"),
    `${JSON.stringify(lockfile, null, 2)}\n`,
  );
  await fs.writeFile(
    path.join(projectRoot, "angular.json"),
    `${JSON.stringify({ version: 1, projects: { app: { projectType: "application" } } }, null, 2)}\n`,
  );
}

async function git(cwd, arguments_, env) {
  const result = await runProcess({
    executable: "git",
    arguments: arguments_,
    cwd,
    env,
    timeoutMs: 30_000,
    terminationGraceMs: 2_000,
    maxOutputBytes: 16_384,
  });
  assert.equal(result.kind, "exited", result.stderr);
  assert.equal(result.exitCode, 0, result.stderr);
}

function exited(exitCode, stdout = "") {
  return {
    kind: "exited",
    exitCode,
    stdout,
    stderr: "",
    stdoutTruncated: false,
    stderrTruncated: false,
  };
}
