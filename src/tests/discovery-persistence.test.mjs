import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  DiscoveryRecordStoreAdapter,
  ProjectValueHasher,
} from "../dist/infrastructure/discovery-persistence.js";

async function withProject(callback) {
  const root = await fs.mkdtemp(
    path.join(tmpdir(), "angular-discovery-record-"),
  );
  try {
    await fs.writeFile(path.join(root, "package.json"), '{"name":"unchanged"}');
    await callback(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

test("writes only the plugin-owned discovery record atomically", async () => {
  await withProject(async (root) => {
    const packageBefore = await fs.readFile(
      path.join(root, "package.json"),
      "utf8",
    );
    const record = {
      schemaVersion: 1,
      projectId: "sha256:test",
      targetMajor: 8,
    };
    const store = new DiscoveryRecordStoreAdapter();

    await store.write(root, record);

    assert.deepEqual(await store.read(root), record);
    assert.equal(
      await fs.readFile(path.join(root, "package.json"), "utf8"),
      packageBefore,
    );
    assert.deepEqual(await fs.readdir(path.join(root, ".angular-migration")), [
      "discovery.json",
    ]);
  });
});

test("rejects a malformed persisted discovery record", async () => {
  await withProject(async (root) => {
    const directory = path.join(root, ".angular-migration");
    await fs.mkdir(directory);
    await fs.writeFile(path.join(directory, "discovery.json"), "{broken");
    await assert.rejects(new DiscoveryRecordStoreAdapter().read(root), {
      code: "discovery_record_invalid",
    });
  });
});

test("hashes structured objects canonically", async () => {
  const hasher = new ProjectValueHasher();
  assert.equal(
    await hasher.hash({ first: 1, second: { a: true, b: "value" } }),
    await hasher.hash({ second: { b: "value", a: true }, first: 1 }),
  );
});
