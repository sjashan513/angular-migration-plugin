import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { ProjectFactsReaderAdapter } from "../dist/infrastructure/project-facts-reader.js";

async function withProject(callback) {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-facts-"));
  try {
    await callback(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

async function writeFixture(
  root,
  { specification = "^22.1.0", resolved = "22.1.4", lockfileVersion = 3 } = {},
) {
  await fs.writeFile(
    path.join(root, "package.json"),
    JSON.stringify({
      name: "sample-project",
      dependencies: { "@angular/core": specification },
    }),
  );
  const lockfile =
    lockfileVersion === 1
      ? {
          lockfileVersion,
          dependencies: { "@angular/core": { version: resolved } },
        }
      : {
          lockfileVersion,
          packages: { "node_modules/@angular/core": { version: resolved } },
        };
  await fs.writeFile(
    path.join(root, "package-lock.json"),
    JSON.stringify(lockfile),
  );
}

test("reads validated project facts without returning the absolute root", async () => {
  await withProject(async (root) => {
    await writeFixture(root);
    const reader = new ProjectFactsReaderAdapter();
    const facts = await reader.readProjectFacts(root);
    assert.equal(facts.angularMajor, 22);
    assert.match(facts.projectId, /^sha256:[a-f0-9]{64}$/);
    assert.doesNotMatch(
      facts.projectId,
      new RegExp(root.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i"),
    );
    assert.deepEqual(await reader.readProjectFacts(root), facts);
  });
});

test("supports npm lockfile v1 and rejects mismatched or malformed external data", async () => {
  await withProject(async (root) => {
    for (const lockfileVersion of [1, 2, 3]) {
      await writeFixture(root, { lockfileVersion });
      assert.equal(
        (await new ProjectFactsReaderAdapter().readProjectFacts(root))
          .angularMajor,
        22,
      );
    }

    await writeFixture(root, { specification: "^21.0.0", resolved: "22.1.4" });
    await assert.rejects(
      new ProjectFactsReaderAdapter().readProjectFacts(root),
      { code: "project_facts_invalid" },
    );

    await writeFixture(root, { lockfileVersion: 4 });
    await assert.rejects(
      new ProjectFactsReaderAdapter().readProjectFacts(root),
      { code: "project_facts_invalid" },
    );

    await fs.writeFile(path.join(root, "package.json"), "[]");
    await assert.rejects(
      new ProjectFactsReaderAdapter().readProjectFacts(root),
      { code: "project_facts_invalid" },
    );
  });
});

test("rejects a locked Angular version outside its declared semver range", async () => {
  await withProject(async (root) => {
    await writeFixture(root, {
      specification: "~7.1.0",
      resolved: "7.2.0",
    });

    await assert.rejects(
      new ProjectFactsReaderAdapter().readProjectFacts(root),
      { code: "project_facts_invalid" },
    );
  });
});
