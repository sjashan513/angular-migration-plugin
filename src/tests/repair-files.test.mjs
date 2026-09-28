import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { SafeRepairPatchWriter } from "../dist/infrastructure/repair-files.js";

test("applies an allowed source patch and restores exact content on rollback", async () => {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-repair-files-"));
  try {
    await fs.mkdir(path.join(root, "src"));
    await fs.writeFile(path.join(root, "src", "app.ts"), "original\n");
    const writer = new SafeRepairPatchWriter();
    const lease = await writer.apply(root, [
      { path: "src/app.ts", content: "repaired\n" },
    ]);
    assert.equal(
      await fs.readFile(path.join(root, "src", "app.ts"), "utf8"),
      "repaired\n",
    );
    await lease.rollback();
    assert.equal(
      await fs.readFile(path.join(root, "src", "app.ts"), "utf8"),
      "original\n",
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("refuses manifest and traversal paths before writing", async () => {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-repair-files-"));
  try {
    await fs.writeFile(path.join(root, "package.json"), "original");
    const writer = new SafeRepairPatchWriter();
    await assert.rejects(
      writer.apply(root, [{ path: "package.json", content: "changed" }]),
      { code: "project_path_invalid" },
    );
    await assert.rejects(
      writer.apply(root, [{ path: "src/../package.json", content: "changed" }]),
      { code: "project_path_invalid" },
    );
    assert.equal(
      await fs.readFile(path.join(root, "package.json"), "utf8"),
      "original",
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
