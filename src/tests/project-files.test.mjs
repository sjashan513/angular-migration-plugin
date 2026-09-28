import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { InfrastructureError } from "../dist/infrastructure/infrastructure-error.js";
import { ProjectFileSystem } from "../dist/infrastructure/project-files.js";

async function withProject(callback) {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-controller-"));
  try {
    await callback(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

test("reads JSON as unknown and rejects traversal paths", async () => {
  await withProject(async (root) => {
    await fs.writeFile(
      path.join(root, "package.json"),
      '{"name":"sample"}',
      "utf8",
    );
    const files = new ProjectFileSystem();
    assert.deepEqual(await files.readJson(root, "package.json"), {
      name: "sample",
    });
    assert.equal(
      await files.readText(root, "package.json"),
      '{"name":"sample"}',
    );
    assert.equal(await files.readOptionalText(root, ".nvmrc"), null);
    await assert.rejects(files.readJson(root, "../outside.json"), {
      code: "project_path_invalid",
    });
  });
});

test("atomic writes replace complete content and preserve the old target on interrupted commit", async () => {
  await withProject(async (root) => {
    const target = path.join(root, "state.json");
    await fs.writeFile(target, "old-state", "utf8");
    await new ProjectFileSystem().writeAtomically(
      root,
      "state.json",
      "new-state",
    );
    assert.equal(await fs.readFile(target, "utf8"), "new-state");

    const interruptedFs = Object.create(fs);
    interruptedFs.rename = async () => {
      throw Object.assign(new Error("simulated interruption"), { code: "EIO" });
    };
    await fs.writeFile(target, "stable-state", "utf8");
    await assert.rejects(
      new ProjectFileSystem(interruptedFs).writeAtomically(
        root,
        "state.json",
        "partial-state",
      ),
      { code: "project_write_failed" },
    );
    assert.equal(await fs.readFile(target, "utf8"), "stable-state");
    assert.deepEqual(
      (await fs.readdir(root)).filter((name) => name.endsWith(".tmp")),
      [],
    );
  });
});

test("maps malformed JSON to a safe infrastructure error", async () => {
  await withProject(async (root) => {
    await fs.writeFile(path.join(root, "package.json"), "{not-json", "utf8");
    await assert.rejects(
      new ProjectFileSystem().readJson(root, "package.json"),
      (error) => {
        assert.ok(error instanceof InfrastructureError);
        assert.equal(error.code, "project_json_invalid");
        assert.doesNotMatch(error.message, /not-json|package\.json/);
        return true;
      },
    );
  });
});

test("does not replace a directory when the target is not a regular file", async () => {
  await withProject(async (root) => {
    await fs.mkdir(path.join(root, "state.json"));
    await assert.rejects(
      new ProjectFileSystem().writeAtomically(root, "state.json", "state"),
      {
        code: "project_write_failed",
      },
    );
    assert.equal(
      (await fs.stat(path.join(root, "state.json"))).isDirectory(),
      true,
    );
  });
});

test("does not create directories through a symlink that escapes the project", async (context) => {
  await withProject(async (root) => {
    const outside = await fs.mkdtemp(path.join(tmpdir(), "angular-outside-"));
    try {
      const link = path.join(root, "linked");
      try {
        await fs.symlink(
          outside,
          link,
          process.platform === "win32" ? "junction" : "dir",
        );
      } catch (error) {
        if (["EPERM", "EACCES", "ENOTSUP"].includes(error.code)) {
          context.skip("symlink creation is unavailable in this environment");
          return;
        }
        throw error;
      }

      await assert.rejects(
        new ProjectFileSystem().ensureDirectory(root, "linked/new"),
        {
          code: "project_path_outside_root",
        },
      );
      await assert.rejects(fs.stat(path.join(outside, "new")), {
        code: "ENOENT",
      });
    } finally {
      await fs.rm(outside, { recursive: true, force: true });
    }
  });
});
