import { randomBytes } from "node:crypto";
import * as fs from "node:fs/promises";
import path from "node:path";
import { InfrastructureError } from "./infrastructure-error.js";

export interface FileIdentity {
  readonly device: number;
  readonly inode: number;
}

export class ProjectFileSystem {
  constructor(private readonly fileSystem: typeof fs = fs) {}

  async canonicalProjectRoot(projectRoot: string): Promise<string> {
    try {
      if (
        typeof projectRoot !== "string" ||
        projectRoot.trim().length === 0 ||
        projectRoot.includes("\0")
      ) {
        throw new Error();
      }
      const canonical = await this.fileSystem.realpath(
        path.resolve(projectRoot),
      );
      if (!(await this.fileSystem.stat(canonical)).isDirectory())
        throw new Error();
      return canonical;
    } catch {
      throw new InfrastructureError(
        "project_root_invalid",
        "The project root is unavailable or is not a directory.",
      );
    }
  }

  async resolveExistingPath(
    projectRoot: string,
    relativePath: string,
  ): Promise<string> {
    const root = await this.canonicalProjectRoot(projectRoot);
    const candidate = this.resolveRelative(root, relativePath);
    try {
      const canonical = await this.fileSystem.realpath(candidate);
      if (!isWithin(root, canonical)) {
        throw new InfrastructureError(
          "project_path_outside_root",
          "The requested path resolves outside the project root.",
        );
      }
      return canonical;
    } catch (error) {
      if (error instanceof InfrastructureError) throw error;
      throw new InfrastructureError(
        "project_file_read_failed",
        "The requested project file could not be read.",
      );
    }
  }

  async readJson(projectRoot: string, relativePath: string): Promise<unknown> {
    const content = await this.readText(projectRoot, relativePath);
    try {
      return JSON.parse(content) as unknown;
    } catch {
      throw new InfrastructureError(
        "project_json_invalid",
        "The requested project file contains invalid JSON.",
      );
    }
  }

  async readText(projectRoot: string, relativePath: string): Promise<string> {
    const canonicalPath = await this.resolveExistingPath(
      projectRoot,
      relativePath,
    );
    try {
      return await this.fileSystem.readFile(canonicalPath, "utf8");
    } catch {
      throw new InfrastructureError(
        "project_file_read_failed",
        "The requested project file could not be read.",
      );
    }
  }

  async readOptionalText(
    projectRoot: string,
    relativePath: string,
  ): Promise<string | null> {
    const root = await this.canonicalProjectRoot(projectRoot);
    const candidate = this.resolveRelative(root, relativePath);
    let canonicalPath: string;
    try {
      canonicalPath = await this.fileSystem.realpath(candidate);
    } catch (error) {
      if (isErrorCode(error, "ENOENT")) return null;
      throw new InfrastructureError(
        "project_file_read_failed",
        "The requested project file could not be read.",
      );
    }
    if (!isWithin(root, canonicalPath)) {
      throw new InfrastructureError(
        "project_path_outside_root",
        "The requested path resolves outside the project root.",
      );
    }
    try {
      return await this.fileSystem.readFile(canonicalPath, "utf8");
    } catch (error) {
      if (isErrorCode(error, "ENOENT")) return null;
      throw new InfrastructureError(
        "project_file_read_failed",
        "The requested project file could not be read.",
      );
    }
  }

  async ensureDirectory(
    projectRoot: string,
    relativeDirectory: string,
  ): Promise<string> {
    const root = await this.canonicalProjectRoot(projectRoot);
    const target =
      relativeDirectory === "."
        ? root
        : this.resolveRelative(root, relativeDirectory);
    const relative = path.relative(root, target);
    let current = root;
    for (const segment of relative.split(path.sep).filter(Boolean)) {
      current = path.join(current, segment);
      try {
        await this.fileSystem.mkdir(current);
      } catch (error) {
        if (!isErrorCode(error, "EEXIST")) {
          throw new InfrastructureError(
            "project_write_failed",
            "The project directory could not be created safely.",
          );
        }
      }

      try {
        const stats = await this.fileSystem.lstat(current);
        const canonical = await this.fileSystem.realpath(current);
        if (
          stats.isSymbolicLink() ||
          !stats.isDirectory() ||
          !isWithin(root, canonical)
        ) {
          throw new InfrastructureError(
            "project_path_outside_root",
            "The requested directory resolves outside the project root.",
          );
        }
        current = canonical;
      } catch (error) {
        if (error instanceof InfrastructureError) throw error;
        throw new InfrastructureError(
          "project_write_failed",
          "The project directory could not be verified safely.",
        );
      }
    }
    return current;
  }

  async writeAtomically(
    projectRoot: string,
    relativePath: string,
    content: string | Uint8Array,
  ): Promise<void> {
    const root = await this.canonicalProjectRoot(projectRoot);
    const target = this.resolveRelative(root, relativePath);
    const parent = await this.ensureDirectory(
      root,
      path.relative(root, path.dirname(target)) || ".",
    );
    const destination = path.join(parent, path.basename(target));
    await this.assertExistingTargetIsRegularFile(destination, root);

    const temporary = path.join(
      parent,
      `.${path.basename(target)}.${randomBytes(12).toString("hex")}.tmp`,
    );
    let handle: fs.FileHandle | undefined;
    let temporaryCreated = false;
    let committed = false;
    try {
      handle = await this.fileSystem.open(temporary, "wx", 0o600);
      temporaryCreated = true;
      await handle.writeFile(content);
      await handle.sync();
      await handle.close();
      handle = undefined;
      await this.fileSystem.rename(temporary, destination);
      temporaryCreated = false;
      committed = true;

      const canonicalDestination = await this.fileSystem.realpath(destination);
      if (!isWithin(root, canonicalDestination)) {
        throw new InfrastructureError(
          "write_outcome_unconfirmed",
          "The write completed but its destination could not be verified safely.",
        );
      }
      const written = await this.fileSystem.readFile(canonicalDestination);
      if (!Buffer.from(content).equals(written)) {
        throw new InfrastructureError(
          "write_outcome_unconfirmed",
          "The write completed but its contents did not pass verification.",
        );
      }
    } catch (error) {
      if (error instanceof InfrastructureError) throw error;
      throw new InfrastructureError(
        committed ? "write_outcome_unconfirmed" : "project_write_failed",
        committed
          ? "The write may have completed but could not be verified."
          : "The project file could not be written atomically.",
      );
    } finally {
      await handle?.close().catch(() => undefined);
      if (temporaryCreated)
        await this.fileSystem
          .rm(temporary, { force: true })
          .catch(() => undefined);
    }
  }

  async createExclusiveFile(
    projectRoot: string,
    relativePath: string,
    content: string,
  ): Promise<
    | { readonly created: false }
    | { readonly created: true; readonly identity: FileIdentity }
  > {
    const root = await this.canonicalProjectRoot(projectRoot);
    const target = this.resolveRelative(root, relativePath);
    const parent = await this.ensureDirectory(
      root,
      path.relative(root, path.dirname(target)) || ".",
    );
    const destination = path.join(parent, path.basename(target));
    let handle: fs.FileHandle | undefined;
    let identity: FileIdentity | undefined;
    try {
      handle = await this.fileSystem.open(destination, "wx", 0o600);
      const stats = await handle.stat();
      identity = { device: stats.dev, inode: stats.ino };
      await handle.writeFile(content, "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;

      const canonical = await this.fileSystem.realpath(destination);
      const written = await this.fileSystem.readFile(canonical, "utf8");
      if (!isWithin(root, canonical) || written !== content) {
        throw new InfrastructureError(
          "write_outcome_unconfirmed",
          "The exclusive file was created but could not be verified safely.",
        );
      }
      return { created: true, identity };
    } catch (error) {
      if (isErrorCode(error, "EEXIST")) return { created: false };
      if (identity)
        await this.removeIfIdentityMatches(
          projectRoot,
          relativePath,
          identity,
        ).catch(() => false);
      if (error instanceof InfrastructureError) throw error;
      throw new InfrastructureError(
        "project_write_failed",
        "The exclusive project file could not be created safely.",
      );
    } finally {
      await handle?.close().catch(() => undefined);
    }
  }

  async removeIfIdentityMatches(
    projectRoot: string,
    relativePath: string,
    identity: FileIdentity,
  ): Promise<boolean> {
    const root = await this.canonicalProjectRoot(projectRoot);
    const target = this.resolveRelative(root, relativePath);
    try {
      const stats = await this.fileSystem.lstat(target);
      if (
        stats.isSymbolicLink() ||
        stats.dev !== identity.device ||
        stats.ino !== identity.inode
      )
        return false;
      const canonicalParent = await this.fileSystem.realpath(
        path.dirname(target),
      );
      if (!isWithin(root, canonicalParent)) return false;
      await this.fileSystem.unlink(target);
      return true;
    } catch (error) {
      if (isErrorCode(error, "ENOENT")) return false;
      throw new InfrastructureError(
        "project_write_failed",
        "The owned project file could not be removed safely.",
      );
    }
  }

  private resolveRelative(root: string, relativePath: string): string {
    if (
      typeof relativePath !== "string" ||
      relativePath.trim().length === 0 ||
      relativePath.includes("\0") ||
      path.isAbsolute(relativePath) ||
      path.win32.isAbsolute(relativePath) ||
      /^[a-zA-Z]:/.test(relativePath) ||
      relativePath.split(/[\\/]+/).some((segment) => segment === "..")
    ) {
      throw new InfrastructureError(
        "project_path_invalid",
        "Project paths must be relative and cannot traverse parent directories.",
      );
    }
    const normalized = path.resolve(
      root,
      relativePath.replace(/[\\/]+/g, path.sep),
    );
    if (!isWithin(root, normalized)) {
      throw new InfrastructureError(
        "project_path_outside_root",
        "The requested path resolves outside the project root.",
      );
    }
    return normalized;
  }

  private async assertExistingTargetIsRegularFile(
    destination: string,
    root: string,
  ): Promise<void> {
    try {
      const stats = await this.fileSystem.lstat(destination);
      const parent = await this.fileSystem.realpath(path.dirname(destination));
      if (stats.isSymbolicLink() || !isWithin(root, parent)) {
        throw new InfrastructureError(
          "project_path_outside_root",
          "The requested file target is not a safe project file.",
        );
      }
      if (!stats.isFile())
        throw new InfrastructureError(
          "project_write_failed",
          "The requested target is not a regular project file.",
        );
    } catch (error) {
      if (error instanceof InfrastructureError) throw error;
      if (isErrorCode(error, "ENOENT")) return;
      throw new InfrastructureError(
        "project_file_read_failed",
        "The existing project file could not be verified safely.",
      );
    }
  }
}

function isWithin(root: string, candidate: string): boolean {
  const relative = path.relative(root, candidate);
  return (
    relative === "" ||
    (relative !== ".." &&
      !relative.startsWith(`..${path.sep}`) &&
      !path.isAbsolute(relative))
  );
}

function isErrorCode(error: unknown, code: string): boolean {
  return Boolean(
    error &&
    typeof error === "object" &&
    "code" in error &&
    error.code === code,
  );
}
