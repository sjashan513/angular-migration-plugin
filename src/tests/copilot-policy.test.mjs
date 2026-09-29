import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { evaluateHook } from "../runtime/copilot-policy.mjs";

test("restricts repair tools and edits to the active run submission", async () => {
  await withProject("needs-repair", async (root, runId) => {
    const submission = `.angular-migration/repair-inbox/${runId}.json`;
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("edit", { path: submission }),
          root,
        )
      ).permissionDecision,
      "allow",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("edit", { path: "src/app.ts" }),
          root,
        )
      ).permissionDecision,
      "deny",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("execute", { command: "npm test" }),
          root,
        )
      ).permissionDecision,
      "deny",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("read", { path: "src/app.ts" }),
          root,
        )
      ).permissionDecision,
      "allow",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("read", { path: "package.json" }),
          root,
        )
      ).permissionDecision,
      "deny",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("read", { path: "src/../.npmrc" }),
          root,
        )
      ).permissionDecision,
      "deny",
    );

    const stopped = await evaluateHook(
      "subagentStop",
      { agentName: "migration-implementer" },
      root,
    );
    assert.equal(stopped.decision, "block");
    await writeSubmission(root, submission, {
      schemaVersion: 1,
      runId,
      fingerprint: `sha256:${"a".repeat(64)}`,
      attempt: 1,
      rootCause: "The active diagnostic identifies the failure.",
      changes: [
        {
          path: "src/app.ts",
          summary: "Repair",
          reason: "Diagnostic evidence",
          content: "updated",
        },
      ],
      evidence: [
        {
          kind: "diagnostic",
          reference: "run-diagnostic",
          claim: "The validation check failed.",
        },
      ],
      unresolvedWarnings: [],
    });
    assert.deepEqual(
      await evaluateHook(
        "subagentStop",
        { agentName: "migration-implementer" },
        root,
      ),
      { decision: "allow" },
    );
  });
});

test("restricts documentation to safe reads, public sources, and run-bound inbox files", async () => {
  await withProject("running", async (root, runId) => {
    const research = `.angular-migration/documentation-inbox/${runId}.research.json`;
    const publish = `.angular-migration/documentation-inbox/${runId}.publish.json`;
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("edit", { path: research }, "migration-documenter"),
          root,
        )
      ).permissionDecision,
      "allow",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("edit", { path: publish }, "migration-documenter"),
          root,
        )
      ).permissionDecision,
      "deny",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload(
            "edit",
            { path: "docs/migration/v8/README.md" },
            "migration-documenter",
          ),
          root,
        )
      ).permissionDecision,
      "deny",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload(
            "web",
            { url: "https://angular.dev/guide" },
            "migration-documenter",
          ),
          root,
        )
      ).permissionDecision,
      "allow",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload(
            "web",
            { url: "https://angular.dev/guide?token=x" },
            "migration-documenter",
          ),
          root,
        )
      ).permissionDecision,
      "deny",
    );
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("execute", { command: "whoami" }, "migration-documenter"),
          root,
        )
      ).permissionDecision,
      "deny",
    );
    await writeSubmission(root, research, researchSubmission(runId));
    assert.deepEqual(
      await evaluateHook(
        "subagentStop",
        { agentName: "migration-documenter" },
        root,
      ),
      { decision: "allow" },
    );
  });
});

test("requires a publish submission after research is recorded", async () => {
  const researchHash = `sha256:${"c".repeat(64)}`;
  const researchEvent = {
    type: "documentation-research-recorded",
    documentation: { researchHash },
  };
  await withProject(
    "verified",
    async (root, runId) => {
      const documenter = "migration-documenter";
      assert.equal(
        (
          await evaluateHook(
            "preToolUse",
            payload(
              "edit",
              { path: "docs/migration/v8/README.md" },
              documenter,
            ),
            root,
          )
        ).permissionDecision,
        "deny",
      );
      assert.equal(
        (
          await evaluateHook(
            "preToolUse",
            payload("edit", { path: "docs/migration/v8/extra.md" }, documenter),
            root,
          )
        ).permissionDecision,
        "deny",
      );
      assert.equal(
        (
          await evaluateHook(
            "preToolUse",
            payload(
              "edit",
              {
                path: `.angular-migration/documentation-inbox/${runId}.research.json`,
              },
              documenter,
            ),
            root,
          )
        ).permissionDecision,
        "deny",
      );
      assert.equal(
        (
          await evaluateHook(
            "preToolUse",
            payload(
              "edit",
              {
                path: `.angular-migration/documentation-inbox/${runId}.publish.json`,
              },
              documenter,
            ),
            root,
          )
        ).permissionDecision,
        "allow",
      );
      await writeSubmission(
        root,
        `.angular-migration/documentation-inbox/${runId}.research.json`,
        researchSubmission(runId),
      );
      assert.equal(
        (
          await evaluateHook(
            "subagentStop",
            { agentName: "migration-documenter" },
            root,
          )
        ).decision,
        "block",
      );

      const publish = publishSubmission(runId, researchHash);
      publish.files[0].path = "docs/migration/v8/../README.md";
      const publishPath = `.angular-migration/documentation-inbox/${runId}.publish.json`;
      await writeSubmission(root, publishPath, publish);
      assert.equal(
        (
          await evaluateHook(
            "subagentStop",
            { agentName: "migration-documenter" },
            root,
          )
        ).decision,
        "block",
      );

      publish.files[0].path = "docs/migration/v8/README.md";
      await writeSubmission(root, publishPath, publish);
      assert.deepEqual(
        await evaluateHook(
          "subagentStop",
          { agentName: "migration-documenter" },
          root,
        ),
        { decision: "allow" },
      );
    },
    "document",
    [researchEvent],
  );
});

test("fails closed for tampered run records and unavailable agent state", async () => {
  await withProject("needs-repair", async (root) => {
    const recordPath = path.join(root, ".angular-migration", "run.json");
    const record = JSON.parse(await fs.readFile(recordPath, "utf8"));
    record.state.status = "running";
    await fs.writeFile(recordPath, JSON.stringify(record));
    assert.equal(
      (
        await evaluateHook(
          "preToolUse",
          payload("edit", { path: "src/app.ts" }),
          root,
        )
      ).permissionDecision,
      "deny",
    );
    assert.deepEqual(
      await evaluateHook("preToolUse", { agentName: "unrelated-agent" }, root),
      {},
    );
  });
});

test("fails closed for a signed but incoherent status and stage", async () => {
  await withProject(
    "verified",
    async (root) => {
      const result = await evaluateHook(
        "preToolUse",
        payload("read", { path: "docs/README.md" }, "migration-documenter"),
        root,
      );
      assert.equal(result.permissionDecision, "deny");
      assert.match(result.permissionDecisionReason, /invalid/i);
    },
    "baseline",
  );
});

test("standalone hook process reads stdin and emits one deny decision", async () => {
  const root = await fs.mkdtemp(
    path.join(tmpdir(), "angular-migration-hook-cli-"),
  );
  try {
    const script = fileURLToPath(
      new URL("../runtime/copilot-policy.mjs", import.meta.url),
    );
    const result = spawnSync(process.execPath, [script, "preToolUse"], {
      cwd: root,
      input: JSON.stringify(payload("read", { path: "src/app.ts" })),
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      permissionDecision: "deny",
      permissionDecisionReason:
        "No validated TypeScript migration run is active.",
    });
    assert.equal(
      result.stdout.trim(),
      JSON.stringify(JSON.parse(result.stdout)),
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

async function withProject(status, action, stageOverride, events = []) {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-migration-hook-"));
  const runId = "00000000-0000-4000-8000-000000000008";
  try {
    await fs.mkdir(path.join(root, "src"), { recursive: true });
    await fs.mkdir(path.join(root, ".angular-migration"), { recursive: true });
    await fs.writeFile(path.join(root, "src", "app.ts"), "fixture");
    const planHash = `sha256:${"b".repeat(64)}`;
    const content = {
      schemaVersion: 1,
      state: {
        schemaVersion: 1,
        runId,
        projectId: `sha256:${"a".repeat(64)}`,
        sourceMajor: 7,
        targetMajor: 8,
        status,
        stage:
          stageOverride ??
          (status === "needs-repair"
            ? "validate"
            : status === "verified"
              ? "document"
              : "baseline"),
        revision: 1,
      },
      discoveryPlan: { planHash },
      events,
      checkpoints:
        status === "needs-repair"
          ? [
              {
                sequence: 0,
                stage: "validate",
                operationId: "validate-typecheck",
                phase: "before",
                projectFingerprint: `sha256:${"a".repeat(64)}`,
                idempotencyKey: `${runId}:validate:typecheck:before`,
              },
            ]
          : [],
      diagnostic: null,
    };
    const recordHash = `sha256:${createHash("sha256")
      .update(JSON.stringify(canonicalize(content)))
      .digest("hex")}`;
    await fs.writeFile(
      path.join(root, ".angular-migration", "run.json"),
      JSON.stringify({ ...content, recordHash }),
    );
    await action(root, runId);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

function payload(toolName, toolArgs, agentName = "migration-implementer") {
  return { agentName, toolName, toolArgs };
}

async function writeSubmission(root, relativePath, value) {
  const target = path.join(root, ...relativePath.split("/"));
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, JSON.stringify(value));
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  return value;
}

function researchSubmission(runId) {
  return {
    schemaVersion: 1,
    runId,
    sourceMajor: 7,
    targetMajor: 8,
    planHash: `sha256:${"b".repeat(64)}`,
    researchedAt: "2025-01-01T00:00:00.000Z",
    sources: [
      {
        id: "angular",
        title: "Angular update guide",
        url: "https://angular.dev/update-guide",
        publisher: "Angular",
        primary: true,
        accessedAt: "2025-01-01T00:00:00.000Z",
      },
    ],
    findings: [],
    concepts: [],
    unresolved: [],
  };
}

function publishSubmission(runId, researchHash) {
  const names = [
    "README.md",
    "changes.md",
    "dependencies.md",
    "errors-and-repairs.md",
    "new-concepts.md",
    "sources.md",
    "validation.md",
    "warnings.md",
  ];
  return {
    schemaVersion: 1,
    runId,
    planHash: `sha256:${"b".repeat(64)}`,
    researchHash,
    outputDirectory: "docs/migration/v8",
    files: names.map((name) => {
      const content = `# ${name}\n`;
      return { path: `docs/migration/v8/${name}`, content };
    }),
    claims: [],
    remainingWarnings: [],
  };
}
