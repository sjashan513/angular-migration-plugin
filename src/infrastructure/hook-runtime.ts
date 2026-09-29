import * as fs from "node:fs/promises";
import path from "node:path";
import type { RunHookRuntimeDeployer } from "../application/ports/run-lifecycle.js";
import { InfrastructureError } from "./infrastructure-error.js";
import { ProjectFileSystem } from "./project-files.js";

const RUNTIME_ASSETS = [
  [
    "scripts/hooks/copilot-policy-ts.ps1",
    ".angular-migration/runtime/copilot-policy-ts.ps1",
  ],
  [
    "src/runtime/copilot-policy.mjs",
    ".angular-migration/runtime/copilot-policy.mjs",
  ],
] as const;
const MAX_ASSET_BYTES = 262_144;

export class HookRuntimeDeployer implements RunHookRuntimeDeployer {
  constructor(
    private readonly pluginRoot: string,
    private readonly files = new ProjectFileSystem(),
  ) {}

  async deploy(projectRoot: string): Promise<void> {
    for (const [sourceRelative, projectRelative] of RUNTIME_ASSETS) {
      const source = path.resolve(
        this.pluginRoot,
        ...sourceRelative.split("/"),
      );
      let content: Buffer;
      try {
        const stats = await fs.lstat(source);
        if (
          !stats.isFile() ||
          stats.isSymbolicLink() ||
          stats.size > MAX_ASSET_BYTES
        )
          throw new Error();
        content = await fs.readFile(source);
      } catch {
        throw new InfrastructureError(
          "hook_runtime_unavailable",
          "A required controller hook runtime asset is unavailable.",
        );
      }
      await this.files.writeAtomically(projectRoot, projectRelative, content);
    }
  }
}
