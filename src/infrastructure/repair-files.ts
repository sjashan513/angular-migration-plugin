import type {
  RepairFilePatch,
  RepairPatchLease,
  RepairPatchWriter,
} from "../application/repair-run.js";
import { InfrastructureError } from "./infrastructure-error.js";
import { ProjectFileSystem } from "./project-files.js";

export class SafeRepairPatchWriter implements RepairPatchWriter {
  constructor(private readonly files = new ProjectFileSystem()) {}

  async apply(
    projectRoot: string,
    patches: readonly RepairFilePatch[],
  ): Promise<RepairPatchLease> {
    const originals: { readonly path: string; readonly content: string }[] = [];
    for (const patch of patches) {
      assertRepairPath(patch.path);
      originals.push({
        path: patch.path,
        content: await this.files.readText(projectRoot, patch.path),
      });
    }

    const applied: RepairFilePatch[] = [];
    try {
      for (const patch of patches) {
        await this.files.writeAtomically(
          projectRoot,
          patch.path,
          patch.content,
        );
        applied.push(patch);
      }
    } catch {
      await rollbackFiles(this.files, projectRoot, applied, originals);
      throw new InfrastructureError(
        "repair_patch_failed",
        "Repair patches could not be applied safely.",
      );
    }

    return {
      rollback: () =>
        rollbackFiles(this.files, projectRoot, applied, originals),
    };
  }
}

async function rollbackFiles(
  files: ProjectFileSystem,
  projectRoot: string,
  applied: readonly RepairFilePatch[],
  originals: readonly { readonly path: string; readonly content: string }[],
): Promise<void> {
  for (const patch of [...applied].reverse()) {
    const original = originals.find((item) => item.path === patch.path);
    if (!original) throw rollbackError();
    const current = await files
      .readText(projectRoot, patch.path)
      .catch(() => null);
    if (current !== patch.content) throw rollbackError();
    await files.writeAtomically(projectRoot, patch.path, original.content);
  }
}

function assertRepairPath(relativePath: string): void {
  if (
    typeof relativePath !== "string" ||
    !/^src\/[A-Za-z0-9._/-]+$/.test(relativePath) ||
    relativePath.split("/").includes("..") ||
    relativePath.includes("\\")
  ) {
    throw new InfrastructureError(
      "project_path_invalid",
      "Repair can only target a safe path under src/.",
    );
  }
}

function rollbackError(): InfrastructureError {
  return new InfrastructureError(
    "repair_rollback_unconfirmed",
    "Repair rollback could not be verified safely.",
  );
}
