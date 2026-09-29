import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { RunRecordStoreAdapter } from "../dist/infrastructure/run-record-store.js";

test("stores and reads the run record only under plugin-owned state", async () => {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-run-record-"));
  try {
    await fs.writeFile(path.join(root, "package.json"), '{"name":"fixture"}');
    const before = await fs.readFile(path.join(root, "package.json"), "utf8");
    const record = { schemaVersion: 1, state: { runId: "run" } };
    const store = new RunRecordStoreAdapter();

    await store.write(root, record);

    assert.deepEqual(await store.read(root), record);
    assert.equal(
      await fs.readFile(path.join(root, "package.json"), "utf8"),
      before,
    );
    assert.deepEqual(await fs.readdir(path.join(root, ".angular-migration")), [
      "run.json",
    ]);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("rejects malformed persisted run JSON", async () => {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-run-record-"));
  try {
    const directory = path.join(root, ".angular-migration");
    await fs.mkdir(directory);
    await fs.writeFile(path.join(directory, "run.json"), "{");
    await assert.rejects(new RunRecordStoreAdapter().read(root), {
      code: "run_record_invalid",
    });
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
