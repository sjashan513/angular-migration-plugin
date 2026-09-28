import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { REQUIRED_MIGRATION_DOCUMENTS } from "../dist/domain/documentation-policy.js";
import { DocumentationArtifactStoreAdapter } from "../dist/infrastructure/documentation-store.js";

test("rolls back an atomic publish when Git detects an unrelated concurrent change", async () => {
  const projectRoot = await fs.mkdtemp(
    path.join(tmpdir(), "documentation-store-"),
  );
  const head = "e".repeat(40);
  let statusCall = 0;
  const runRuntime = async ({ arguments: arguments_ }) => {
    if (arguments_[0] === "rev-parse") {
      return processResult(`${head}\n`);
    }
    if (arguments_[0] === "status") {
      statusCall += 1;
      if (statusCall === 2) {
        const paths = [
          ...REQUIRED_MIGRATION_DOCUMENTS.map(
            (name) => `docs/migration/v8/${name}`,
          ),
          "src/concurrent-change.ts",
        ];
        return processResult(paths.map((file) => `?? ${file}\0`).join(""));
      }
      return processResult("");
    }
    throw new Error("unexpected Git command");
  };
  const store = new DocumentationArtifactStoreAdapter(undefined, {
    runRuntime,
  });
  const files = REQUIRED_MIGRATION_DOCUMENTS.map((name) => {
    const content = `# ${name}\n`;
    return {
      path: `docs/migration/v8/${name}`,
      content,
      sha256: `sha256:${createHash("sha256").update(content, "utf8").digest("hex")}`,
    };
  });

  try {
    await assert.rejects(
      store.publishFiles({
        projectRoot,
        outputDirectory: "docs/migration/v8",
        expectedExistingFiles: null,
        expectedGitSnapshot: { head, changes: [] },
        nodeVersion: "20.18.0",
        files,
      }),
      { code: "documentation_publish_conflict" },
    );
    assert.equal(
      await store.inspectOutput(projectRoot, "docs/migration/v8"),
      null,
    );
    assert.equal(statusCall, 3);
  } finally {
    await fs.rm(projectRoot, { recursive: true, force: true });
  }
});

function processResult(stdout) {
  return {
    kind: "exited",
    exitCode: 0,
    stdout,
    stderr: "",
    stdoutTruncated: false,
    stderrTruncated: false,
  };
}
