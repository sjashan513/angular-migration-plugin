import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { ProjectLock } from "../dist/infrastructure/project-lock.js";

async function withProject(callback) {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-lock-"));
  try {
    await callback(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

test("serializes discovery and releases only its own lease", async () => {
  await withProject(async (root) => {
    const locks = new ProjectLock();
    const owner = await locks.acquire(root);
    assert.equal(owner.kind, "acquired");
    assert.equal((await locks.acquire(root)).kind, "contended");
    if (owner.kind !== "acquired") return;

    assert.deepEqual(await owner.release(), { kind: "released" });
    assert.deepEqual(await owner.release(), { kind: "released" });
    const nextOwner = await locks.acquire(root);
    assert.equal(nextOwner.kind, "acquired");
    if (nextOwner.kind === "acquired")
      assert.deepEqual(await nextOwner.release(), { kind: "released" });
  });
});

test("does not infer a stale owner is dead or remove an existing lock", async () => {
  await withProject(async (root) => {
    const lockPath = path.join(root, ".angular-migration", "discovery.lock");
    await fs.mkdir(path.dirname(lockPath), { recursive: true });
    const staleRecord = JSON.stringify({
      schemaVersion: 1,
      ownerPid: 2_000_000_000,
      ownerToken: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    });
    await fs.writeFile(lockPath, staleRecord, "utf8");

    assert.equal((await new ProjectLock().acquire(root)).kind, "contended");
    assert.equal(await fs.readFile(lockPath, "utf8"), staleRecord);
  });
});

test("a lease cannot remove a lock whose owner token changed", async () => {
  await withProject(async (root) => {
    const result = await new ProjectLock().acquire(root);
    assert.equal(result.kind, "acquired");
    if (result.kind !== "acquired") return;

    const lockPath = path.join(root, ".angular-migration", "discovery.lock");
    await fs.writeFile(
      lockPath,
      JSON.stringify({
        schemaVersion: 1,
        ownerPid: process.pid,
        ownerToken: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      }),
    );
    assert.deepEqual(await result.release(), { kind: "ownership-lost" });
    assert.equal(await fs.stat(lockPath).then((stats) => stats.isFile()), true);
  });
});
