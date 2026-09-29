import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { HookRuntimeDeployer } from "../dist/infrastructure/hook-runtime.js";

test("deploys only the TypeScript hook assets under plugin-owned project runtime", async () => {
  const root = await fs.mkdtemp(
    path.join(tmpdir(), "angular-migration-hook-deploy-"),
  );
  const pluginRoot = path.join(root, "plugin");
  const projectRoot = path.join(root, "project");
  try {
    await fs.mkdir(path.join(pluginRoot, "scripts", "hooks"), {
      recursive: true,
    });
    await fs.mkdir(path.join(pluginRoot, "src", "runtime"), {
      recursive: true,
    });
    await fs.mkdir(projectRoot);
    await fs.writeFile(
      path.join(pluginRoot, "scripts", "hooks", "copilot-policy-ts.ps1"),
      "powershell policy",
    );
    await fs.writeFile(
      path.join(pluginRoot, "src", "runtime", "copilot-policy.mjs"),
      "node policy",
    );

    await new HookRuntimeDeployer(pluginRoot).deploy(projectRoot);

    assert.equal(
      await fs.readFile(
        path.join(
          projectRoot,
          ".angular-migration",
          "runtime",
          "copilot-policy-ts.ps1",
        ),
        "utf8",
      ),
      "powershell policy",
    );
    assert.equal(
      await fs.readFile(
        path.join(
          projectRoot,
          ".angular-migration",
          "runtime",
          "copilot-policy.mjs",
        ),
        "utf8",
      ),
      "node policy",
    );
    assert.equal(
      await fs
        .readdir(path.join(projectRoot, ".angular-migration", "runtime"))
        .then((names) => names.length),
      2,
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
