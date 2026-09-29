import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { dispatchCli } from "../dist/entrypoints/cli.js";

function dependencies(overrides = {}) {
  const calls = [];
  const useCases = {
    inspect: async (projectRoot) => {
      calls.push(["inspect", projectRoot]);
      return { angularMajor: 7 };
    },
    discover: async (projectRoot, targetMajor) => {
      calls.push(["discover", projectRoot, targetMajor]);
      return { status: "ready", targetMajor };
    },
    approveRuntime: async (
      projectRoot,
      targetMajor,
      proposalHash,
      confirmed,
    ) => {
      calls.push([
        "approve-runtime",
        projectRoot,
        targetMajor,
        proposalHash,
        confirmed,
      ]);
      return { status: "installed", nodeVersion: "16.20.2" };
    },
    baselineDependencyContext: async (projectRoot, runId) => {
      calls.push(["baseline-dependency-context", projectRoot, runId]);
      return { runId, packages: [] };
    },
    approveBaselineDependencies: async (
      projectRoot,
      runId,
      proposalHash,
      confirmed,
    ) => {
      calls.push([
        "approve-baseline-dependencies",
        projectRoot,
        runId,
        proposalHash,
        confirmed,
      ]);
      return { status: "running", runId, stage: "baseline" };
    },
    skipCheck: async (projectRoot, runId, checkId, reason, confirmed) => {
      calls.push([
        "skip-check",
        projectRoot,
        runId,
        checkId,
        reason,
        confirmed,
      ]);
      return { status: "running", runId, stage: "baseline" };
    },
    repairContext: async (projectRoot, runId) => {
      calls.push(["repair-context", projectRoot, runId]);
      return { runId, allowedPaths: ["src/**/*"] };
    },
    recordRepair: async (projectRoot, runId) => {
      calls.push(["record-repair", projectRoot, runId]);
      return { status: "running", runId, stage: "validate" };
    },
    documentationResearchContext: async (projectRoot, runId) => {
      calls.push(["documentation-research-context", projectRoot, runId]);
      return { runId, mode: "research" };
    },
    recordDocumentationResearch: async (projectRoot, runId) => {
      calls.push(["record-documentation-research", projectRoot, runId]);
      return { runId, status: "researched" };
    },
    documentationPublishContext: async (projectRoot, runId) => {
      calls.push(["documentation-publish-context", projectRoot, runId]);
      return { runId, mode: "publish" };
    },
    publishDocumentation: async (
      projectRoot,
      runId,
      proposalHash,
      confirmed,
    ) => {
      calls.push([
        "publish-documentation",
        projectRoot,
        runId,
        proposalHash,
        confirmed,
      ]);
      return { runId, status: "published" };
    },
    start: async (projectRoot, targetMajor) => {
      calls.push(["start", projectRoot, targetMajor]);
      return {
        state: { runId: "run-1", status: "running", stage: "baseline" },
      };
    },
    run: async (projectRoot, runId) => {
      calls.push(["run", projectRoot, runId]);
      return { state: { runId, status: "verified", stage: "document" } };
    },
    status: async (projectRoot) => {
      calls.push(["status", projectRoot]);
      return { runId: "run-1", status: "running" };
    },
    ...overrides,
  };
  return { useCases, calls };
}

test("dispatches supported commands into the versioned JSON envelope", async () => {
  const { useCases, calls } = dependencies();
  const result = await dispatchCli(
    ["start", "--project-root", "C:\\fixture", "--target-major", "8"],
    useCases,
  );

  assert.equal(result.exitCode, 0);
  assert.deepEqual(result.response, {
    schemaVersion: 1,
    ok: true,
    status: "success",
    data: { runId: "run-1", status: "running", stage: "baseline" },
    error: null,
  });
  assert.deepEqual(calls, [["start", "C:\\fixture", 8]]);
  assert.equal(JSON.parse(result.stdout).schemaVersion, 1);
  assert.equal(result.stdout.endsWith("\n"), true);
});

test("rejects unknown commands and options with blocked exit semantics", async () => {
  const { useCases, calls } = dependencies();
  const unknownCommand = await dispatchCli(["repair"], useCases);
  const unknownOption = await dispatchCli(
    ["status", "--project-root", "C:\\fixture", "--repair"],
    useCases,
  );

  assert.equal(unknownCommand.exitCode, 2);
  assert.equal(unknownCommand.response.status, "blocked");
  assert.equal(unknownOption.exitCode, 2);
  assert.equal(unknownOption.response.error.code, "cli_option_unknown");
  assert.deepEqual(calls, []);
});

test("runtime approval dispatch requires confirmation and the exact plan hash", async () => {
  const { useCases, calls } = dependencies();
  const hash = `sha256:${"a".repeat(64)}`;
  const approved = await dispatchCli(
    [
      "approve-runtime",
      "--project-root",
      "C:\\fixture",
      "--target-major",
      "8",
      "--plan-hash",
      hash,
      "--confirmed",
      "true",
    ],
    useCases,
  );
  const unconfirmed = await dispatchCli(
    [
      "approve-runtime",
      "--project-root",
      "C:\\fixture",
      "--target-major",
      "8",
      "--plan-hash",
      hash,
      "--confirmed",
      "false",
    ],
    useCases,
  );

  assert.equal(approved.exitCode, 0);
  assert.equal(unconfirmed.exitCode, 2);
  assert.deepEqual(calls, [["approve-runtime", "C:\\fixture", 8, hash, true]]);
});

test("baseline dependency approval is run-bound and requires its proposal hash", async () => {
  const { useCases, calls } = dependencies();
  const hash = `sha256:${"b".repeat(64)}`;
  const context = await dispatchCli(
    [
      "baseline-dependency-context",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
    ],
    useCases,
  );
  const approved = await dispatchCli(
    [
      "approve-baseline-dependencies",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
      "--proposal-hash",
      hash,
      "--confirmed",
      "true",
    ],
    useCases,
  );
  const unconfirmed = await dispatchCli(
    [
      "approve-baseline-dependencies",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
      "--proposal-hash",
      hash,
      "--confirmed",
      "false",
    ],
    useCases,
  );

  assert.equal(context.exitCode, 0);
  assert.equal(approved.exitCode, 0);
  assert.equal(unconfirmed.exitCode, 2);
  assert.deepEqual(calls, [
    ["baseline-dependency-context", "C:\\fixture", "run-1"],
    ["approve-baseline-dependencies", "C:\\fixture", "run-1", hash, true],
  ]);
});

test("skip-check dispatch requires a run-bound reason and explicit confirmation", async () => {
  const { useCases, calls } = dependencies();
  const accepted = await dispatchCli(
    [
      "skip-check",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
      "--check-id",
      "lint",
      "--reason",
      "Tooling is temporarily unavailable.",
      "--confirmed",
      "true",
    ],
    useCases,
  );
  const missingConfirmation = await dispatchCli(
    [
      "skip-check",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
      "--check-id",
      "lint",
      "--reason",
      "Tooling is temporarily unavailable.",
    ],
    useCases,
  );

  assert.equal(accepted.exitCode, 0);
  assert.equal(missingConfirmation.exitCode, 2);
  assert.deepEqual(calls, [
    [
      "skip-check",
      "C:\\fixture",
      "run-1",
      "lint",
      "Tooling is temporarily unavailable.",
      true,
    ],
  ]);
});

test("repair context and record commands accept only the run identity", async () => {
  const { useCases, calls } = dependencies();
  const context = await dispatchCli(
    ["repair-context", "--project-root", "C:\\fixture", "--run-id", "run-1"],
    useCases,
  );
  const record = await dispatchCli(
    ["record-repair", "--project-root", "C:\\fixture", "--run-id", "run-1"],
    useCases,
  );

  assert.equal(context.exitCode, 0);
  assert.equal(record.exitCode, 0);
  assert.deepEqual(calls, [
    ["repair-context", "C:\\fixture", "run-1"],
    ["record-repair", "C:\\fixture", "run-1"],
  ]);
});

test("documentation commands are run-bound and publish requires an exact confirmed proposal", async () => {
  const { useCases, calls } = dependencies();
  const hash = `sha256:${"c".repeat(64)}`;
  const researchContext = await dispatchCli(
    [
      "documentation-research-context",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
    ],
    useCases,
  );
  const research = await dispatchCli(
    [
      "record-documentation-research",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
    ],
    useCases,
  );
  const publishContext = await dispatchCli(
    [
      "documentation-publish-context",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
    ],
    useCases,
  );
  const published = await dispatchCli(
    [
      "publish-documentation",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
      "--proposal-hash",
      hash,
      "--confirmed",
      "true",
    ],
    useCases,
  );
  const unconfirmed = await dispatchCli(
    [
      "publish-documentation",
      "--project-root",
      "C:\\fixture",
      "--run-id",
      "run-1",
      "--proposal-hash",
      hash,
      "--confirmed",
      "false",
    ],
    useCases,
  );

  assert.equal(researchContext.exitCode, 0);
  assert.equal(research.exitCode, 0);
  assert.equal(publishContext.exitCode, 0);
  assert.equal(published.exitCode, 0);
  assert.equal(unconfirmed.exitCode, 2);
  assert.deepEqual(calls, [
    ["documentation-research-context", "C:\\fixture", "run-1"],
    ["record-documentation-research", "C:\\fixture", "run-1"],
    ["documentation-publish-context", "C:\\fixture", "run-1"],
    ["publish-documentation", "C:\\fixture", "run-1", hash, true],
  ]);
});

test("maps blocked lifecycle state to exit 2 and hides unexpected exception details", async () => {
  const blocked = dependencies({
    run: async () => ({
      state: { runId: "run-1", status: "blocked", stage: "baseline" },
    }),
  });
  const unexpected = dependencies({
    inspect: async () => {
      throw new Error("C:\\private\\token=secret");
    },
  });
  const statusNeedsHuman = dependencies({
    status: async () => ({ nextAction: "human-intervention" }),
  });

  const blockedResult = await dispatchCli(
    ["run", "--project-root", "C:\\fixture", "--run-id", "run-1"],
    blocked.useCases,
  );
  const failedResult = await dispatchCli(
    ["inspect", "--project-root", "C:\\fixture"],
    unexpected.useCases,
  );
  const statusResult = await dispatchCli(
    ["status", "--project-root", "C:\\fixture"],
    statusNeedsHuman.useCases,
  );

  assert.equal(blockedResult.exitCode, 2);
  assert.equal(blockedResult.response.status, "blocked");
  assert.equal(failedResult.exitCode, 1);
  assert.equal(failedResult.response.error.code, "internal_error");
  assert.doesNotMatch(failedResult.stdout, /private|secret/);
  assert.equal(statusResult.exitCode, 2);
  assert.equal(statusResult.response.status, "blocked");
});

test("built inspect entrypoint returns one parseable JSON envelope", async () => {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-cli-smoke-"));
  try {
    await fs.writeFile(
      path.join(root, "package.json"),
      JSON.stringify({
        name: "cli-smoke",
        dependencies: { "@angular/core": "^7.2.0" },
      }),
    );
    await fs.writeFile(
      path.join(root, "package-lock.json"),
      JSON.stringify({
        lockfileVersion: 3,
        packages: { "node_modules/@angular/core": { version: "7.2.16" } },
      }),
    );
    const entrypoint = new URL("../dist/entrypoints/main.js", import.meta.url);
    const child = spawnSync(
      process.execPath,
      [
        entrypoint.pathname.replace(/^\/(\w:)/, "$1"),
        "inspect",
        "--project-root",
        root,
      ],
      { encoding: "utf8", windowsHide: true, shell: false },
    );

    assert.equal(child.status, 0, child.stderr);
    assert.equal(child.stderr, "");
    assert.equal(child.stdout.trim().split(/\r?\n/).length, 1);
    const envelope = JSON.parse(child.stdout);
    assert.equal(envelope.schemaVersion, 1);
    assert.equal(envelope.status, "success");
    assert.equal(envelope.data.angularMajor, 7);
    assert.doesNotMatch(
      child.stdout,
      new RegExp(root.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")),
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("bounds oversized protocol output with a stable failure envelope", async () => {
  const { useCases } = dependencies({
    inspect: async () => ({ value: "x".repeat(1_100_000) }),
  });
  const result = await dispatchCli(
    ["inspect", "--project-root", "C:\\fixture"],
    useCases,
  );

  assert.equal(result.exitCode, 1);
  assert.equal(Buffer.byteLength(result.stdout, "utf8") < 1024, true);
  assert.equal(result.response.error.code, "cli_output_too_large");
});
