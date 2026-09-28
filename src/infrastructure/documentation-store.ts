import { createHash } from "node:crypto";
import * as fs from "node:fs/promises";
import path from "node:path";
import type {
  DocumentationArtifactStore,
  DocumentationFile,
  DocumentationGitSnapshot,
  DocumentationPublicationRecord,
} from "../application/ports/documentation.js";
import { REQUIRED_MIGRATION_DOCUMENTS } from "../domain/documentation-policy.js";
import {
  runWithProjectRuntime,
  type RuntimeCommandRequest,
} from "./fnm-runtime.js";
import { InfrastructureError } from "./infrastructure-error.js";
import type { ProcessResult } from "./process-runner.js";
import { ProjectFileSystem } from "./project-files.js";

const MAX_DOCUMENT_BYTES = 262_144;

type RuntimeRunner = (request: RuntimeCommandRequest) => Promise<ProcessResult>;

interface DocumentationStoreOptions {
  readonly environment?: Readonly<Record<string, string>>;
  readonly fnmExecutable?: string;
  readonly runRuntime?: RuntimeRunner;
}

export class DocumentationArtifactStoreAdapter implements DocumentationArtifactStore {
  private readonly environment: Readonly<Record<string, string>>;
  private readonly fnmExecutable: string;
  private readonly runRuntime: RuntimeRunner;

  constructor(
    private readonly files = new ProjectFileSystem(),
    options: DocumentationStoreOptions = {},
  ) {
    this.environment =
      options.environment ??
      Object.fromEntries(
        Object.entries(process.env).filter(
          (entry): entry is [string, string] => typeof entry[1] === "string",
        ),
      );
    this.fnmExecutable = options.fnmExecutable ?? "fnm";
    this.runRuntime =
      options.runRuntime ?? ((request) => runWithProjectRuntime(request));
  }

  readResearchSubmission(projectRoot: string, runId: string): Promise<unknown> {
    return this.readInbox(projectRoot, runId, "research");
  }

  readPublishSubmission(projectRoot: string, runId: string): Promise<unknown> {
    return this.readInbox(projectRoot, runId, "publish");
  }

  readResearch(projectRoot: string, runId: string): Promise<unknown> {
    return this.readRecord(projectRoot, runId, "research");
  }

  readPublication(projectRoot: string, runId: string): Promise<unknown> {
    return this.readRecord(projectRoot, runId, "publication");
  }

  async writeResearch(
    projectRoot: string,
    runId: string,
    record: {
      readonly schemaVersion: 1;
      readonly runId: string;
      readonly planHash: string;
      readonly researchHash: string;
      readonly submission: import("../application/ports/documentation.js").DocumentationResearchSubmission;
    },
  ): Promise<void> {
    await this.writeRecord(projectRoot, runId, "research", record);
  }

  async writePublication(
    projectRoot: string,
    runId: string,
    record: DocumentationPublicationRecord,
  ): Promise<void> {
    await this.writeRecord(projectRoot, runId, "publication", record);
  }

  async inspectOutput(
    projectRoot: string,
    outputDirectory: string,
  ): Promise<
    readonly { readonly path: string; readonly sha256: string }[] | null
  > {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const directory = await this.resolveOutputDirectory(root, outputDirectory);
    if (directory === null) return null;
    const entries = await fs.readdir(directory, { withFileTypes: true });
    const result: { path: string; sha256: string }[] = [];
    for (const entry of entries) {
      if (!entry.isFile() || entry.isSymbolicLink()) {
        throw new InfrastructureError(
          "documentation_output_invalid",
          "The documentation output directory contains a non-file entry.",
        );
      }
      const content = await fs.readFile(path.join(directory, entry.name));
      if (content.byteLength > MAX_DOCUMENT_BYTES) {
        throw new InfrastructureError(
          "documentation_output_invalid",
          "A documentation file exceeds the supported size limit.",
        );
      }
      result.push({
        path: `${outputDirectory}/${entry.name}`,
        sha256: sha256(content),
      });
    }
    return result.sort((left, right) => left.path.localeCompare(right.path));
  }

  async inspectGitSnapshot(
    projectRoot: string,
    nodeVersion: string,
  ): Promise<DocumentationGitSnapshot> {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const head = await this.runGit(root, nodeVersion, [
      "rev-parse",
      "--verify",
      "HEAD",
    ]);
    if (
      !isCompleteExit(head, 0) ||
      !/^[a-f0-9]{40,64}$/i.test(head.stdout.trim())
    ) {
      throw new InfrastructureError(
        "git_inspection_failed",
        "The documentation operation cannot verify the current Git HEAD.",
      );
    }
    const status = await this.runGit(root, nodeVersion, [
      "status",
      "--porcelain=v1",
      "-z",
      "--untracked-files=all",
      "--",
      ".",
      ":!.angular-migration",
    ]);
    if (!isCompleteExit(status, 0)) {
      throw new InfrastructureError(
        "git_inspection_failed",
        "The documentation operation cannot verify changed project paths.",
      );
    }
    const changes = parseGitStatus(status.stdout);
    if (changes === null) {
      throw new InfrastructureError(
        "git_inspection_failed",
        "The Git status contains an unsupported path change.",
      );
    }
    return { head: head.stdout.trim().toLowerCase(), changes };
  }

  async publishFiles(input: {
    readonly projectRoot: string;
    readonly outputDirectory: string;
    readonly expectedExistingFiles:
      | readonly { readonly path: string; readonly sha256: string }[]
      | null;
    readonly expectedGitSnapshot: DocumentationGitSnapshot;
    readonly nodeVersion: string;
    readonly files: readonly DocumentationFile[];
  }): Promise<string> {
    if (!isPublishFilesRequest(input)) {
      throw new InfrastructureError(
        "documentation_submission_invalid",
        "The documentation file set is invalid.",
      );
    }
    const current = await this.inspectOutput(
      input.projectRoot,
      input.outputDirectory,
    );
    if (!sameFileSet(current, input.expectedExistingFiles)) {
      throw new InfrastructureError(
        "documentation_publish_conflict",
        "The documentation output changed after approval.",
      );
    }
    const gitBefore = await this.inspectGitSnapshot(
      input.projectRoot,
      input.nodeVersion,
    );
    if (!sameGitSnapshot(gitBefore, input.expectedGitSnapshot)) {
      throw new InfrastructureError(
        "documentation_publish_conflict",
        "The project Git state changed after documentation approval.",
      );
    }
    if (current !== null) {
      throw new InfrastructureError(
        "documentation_publish_conflict",
        "The documentation output already exists and will not be overwritten.",
      );
    }

    const root = await this.files.canonicalProjectRoot(input.projectRoot);
    const parent = await this.files.ensureDirectory(root, "docs/migration");
    const target = path.join(root, ...input.outputDirectory.split("/"));
    const staging = await fs.mkdtemp(path.join(parent, ".migration-docs-"));
    let renamed = false;
    try {
      for (const file of input.files) {
        const name = file.path.slice(`${input.outputDirectory}/`.length);
        const destination = path.join(staging, name);
        const handle = await fs.open(destination, "wx", 0o600);
        try {
          await handle.writeFile(file.content, "utf8");
          await handle.sync();
        } finally {
          await handle.close();
        }
        const actualHash = sha256(Buffer.from(file.content, "utf8"));
        if (actualHash !== file.sha256) {
          throw new InfrastructureError(
            "documentation_submission_invalid",
            "A documentation file failed its content hash check.",
          );
        }
      }
      if (
        (await this.inspectOutput(input.projectRoot, input.outputDirectory)) !==
        null
      ) {
        throw new InfrastructureError(
          "documentation_publish_conflict",
          "The documentation output appeared during publication.",
        );
      }
      await fs.rename(staging, target);
      renamed = true;
      const published = await this.inspectOutput(
        input.projectRoot,
        input.outputDirectory,
      );
      if (
        !sameFileSet(
          published,
          input.files
            .map(({ path: filePath, sha256: hash }) => ({
              path: filePath,
              sha256: hash,
            }))
            .sort((left, right) => left.path.localeCompare(right.path)),
        )
      ) {
        throw new InfrastructureError(
          "documentation_rollback_unconfirmed",
          "The published documentation could not be verified after the atomic write.",
        );
      }
      const gitAfter = await this.inspectGitSnapshot(
        input.projectRoot,
        input.nodeVersion,
      );
      if (!onlyExpectedDocumentationChanges(gitBefore, gitAfter, input.files)) {
        throw new InfrastructureError(
          "documentation_publish_conflict",
          "Publication changed paths outside the approved documentation set.",
        );
      }
      return sha256(Buffer.from(JSON.stringify(published), "utf8"));
    } catch (error) {
      if (renamed) {
        try {
          const published = await this.inspectOutput(
            input.projectRoot,
            input.outputDirectory,
          );
          const expected = input.files
            .map(({ path: filePath, sha256: hash }) => ({
              path: filePath,
              sha256: hash,
            }))
            .sort((left, right) => left.path.localeCompare(right.path));
          if (!sameFileSet(published, expected)) throw new Error();
          await fs.rename(target, staging);
          await fs.rm(staging, { recursive: true, force: true });
          renamed = false;
          const restored = await this.inspectGitSnapshot(
            input.projectRoot,
            input.nodeVersion,
          );
          if (!sameGitSnapshot(restored, gitBefore)) throw new Error();
        } catch {
          throw new InfrastructureError(
            "documentation_rollback_unconfirmed",
            "Documentation changed but its rollback could not be verified.",
          );
        }
      } else {
        await fs
          .rm(staging, { recursive: true, force: true })
          .catch(() => undefined);
      }
      if (error instanceof InfrastructureError) throw error;
      throw new InfrastructureError(
        renamed
          ? "documentation_rollback_unconfirmed"
          : "documentation_output_invalid",
        renamed
          ? "Documentation was written but its final state could not be confirmed."
          : "The documentation could not be published safely.",
      );
    }
  }

  private async readInbox(
    projectRoot: string,
    runId: string,
    mode: "research" | "publish",
  ): Promise<unknown> {
    const relative = `.angular-migration/documentation-inbox/${runId}.${mode}.json`;
    const text = await this.files.readOptionalText(projectRoot, relative);
    if (text === null) {
      throw new InfrastructureError(
        "documentation_submission_missing",
        "No controller-readable documentation submission is available.",
      );
    }
    return parseJson(text, "documentation_submission_invalid");
  }

  private async readRecord(
    projectRoot: string,
    runId: string,
    kind: "research" | "publication",
  ): Promise<unknown> {
    const text = await this.files.readOptionalText(
      projectRoot,
      `.angular-migration/documentation/${runId}/${kind}.json`,
    );
    return text === null
      ? null
      : parseJson(text, "documentation_record_invalid");
  }

  private async writeRecord(
    projectRoot: string,
    runId: string,
    kind: "research" | "publication",
    record: unknown,
  ): Promise<void> {
    await this.files.writeAtomically(
      projectRoot,
      `.angular-migration/documentation/${runId}/${kind}.json`,
      `${JSON.stringify(record)}\n`,
    );
  }

  private async resolveOutputDirectory(
    root: string,
    relative: string,
  ): Promise<string | null> {
    if (!/^docs\/migration\/v[1-9]\d*$/.test(relative)) {
      throw new InfrastructureError(
        "project_path_invalid",
        "The documentation output path is not allowed.",
      );
    }
    let current = root;
    for (const segment of relative.split("/")) {
      current = path.join(current, segment);
      let stats: Awaited<ReturnType<typeof fs.lstat>>;
      try {
        stats = await fs.lstat(current);
      } catch (error) {
        if (isErrorCode(error, "ENOENT")) return null;
        throw new InfrastructureError(
          "documentation_output_invalid",
          "The documentation output path could not be inspected safely.",
        );
      }
      if (stats.isSymbolicLink() || !stats.isDirectory()) {
        throw new InfrastructureError(
          "documentation_output_invalid",
          "The documentation output path is not a regular directory.",
        );
      }
      const real = await fs.realpath(current);
      if (!isWithin(root, real)) {
        throw new InfrastructureError(
          "project_path_outside_root",
          "The documentation output resolves outside the project.",
        );
      }
      current = real;
    }
    return current;
  }

  private runGit(
    cwd: string,
    nodeVersion: string,
    arguments_: readonly string[],
  ): Promise<ProcessResult> {
    return this.runRuntime({
      fnmExecutable: this.fnmExecutable,
      nodeVersion,
      executable: "git",
      arguments: arguments_,
      cwd,
      env: this.environment,
      timeoutMs: 30_000,
      terminationGraceMs: 5_000,
      maxOutputBytes: 262_144,
    });
  }
}

function parseJson(
  text: string,
  code: "documentation_submission_invalid" | "documentation_record_invalid",
): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new InfrastructureError(
      code,
      "The documentation artifact contains invalid JSON.",
    );
  }
}

function isPublishFilesRequest(value: unknown): value is {
  readonly projectRoot: string;
  readonly outputDirectory: string;
  readonly expectedExistingFiles:
    | readonly { readonly path: string; readonly sha256: string }[]
    | null;
  readonly expectedGitSnapshot: DocumentationGitSnapshot;
  readonly nodeVersion: string;
  readonly files: readonly DocumentationFile[];
} {
  return Boolean(
    value &&
    typeof value === "object" &&
    typeof (value as Record<string, unknown>).projectRoot === "string" &&
    typeof (value as Record<string, unknown>).outputDirectory === "string" &&
    isExactVersion((value as Record<string, unknown>).nodeVersion) &&
    isDocumentationGitSnapshot(
      (value as Record<string, unknown>).expectedGitSnapshot,
    ) &&
    /^docs\/migration\/v[1-9]\d*$/.test(
      String((value as Record<string, unknown>).outputDirectory),
    ) &&
    Array.isArray((value as Record<string, unknown>).files) &&
    ((value as Record<string, unknown>).files as unknown[]).length ===
      REQUIRED_MIGRATION_DOCUMENTS.length &&
    ((value as Record<string, unknown>).files as unknown[]).every(
      (file, index) => {
        if (!file || typeof file !== "object") return false;
        const item = file as Record<string, unknown>;
        const expectedPath = `${String((value as Record<string, unknown>).outputDirectory)}/${REQUIRED_MIGRATION_DOCUMENTS[index]}`;
        return (
          item.path === expectedPath &&
          typeof item.content === "string" &&
          Buffer.byteLength(item.content, "utf8") <= MAX_DOCUMENT_BYTES &&
          typeof item.sha256 === "string" &&
          /^sha256:[a-f0-9]{64}$/.test(item.sha256) &&
          sha256(Buffer.from(item.content, "utf8")) === item.sha256
        );
      },
    ),
  );
}

function sameFileSet(
  left: readonly { readonly path: string; readonly sha256: string }[] | null,
  right: readonly { readonly path: string; readonly sha256: string }[] | null,
): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function sha256(value: Uint8Array): string {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
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

function parseGitStatus(
  text: string,
): readonly { readonly path: string; readonly status: string }[] | null {
  if (text.length === 0) return [];
  if (!text.endsWith("\0")) return null;
  const result: { path: string; status: string }[] = [];
  for (const entry of text.split("\0").filter(Boolean)) {
    if (entry.length < 4 || entry[2] !== " ") return null;
    const status = entry.slice(0, 2);
    const file = entry.slice(3);
    if (
      /^[RC]/.test(status) ||
      result.some(({ path: prior }) => prior === file)
    )
      return null;
    result.push({ path: file, status });
  }
  return result.sort((left, right) => left.path.localeCompare(right.path));
}

function sameGitSnapshot(
  left: DocumentationGitSnapshot,
  right: DocumentationGitSnapshot,
): boolean {
  return (
    left.head === right.head &&
    JSON.stringify(left.changes) === JSON.stringify(right.changes)
  );
}

function onlyExpectedDocumentationChanges(
  before: DocumentationGitSnapshot,
  after: DocumentationGitSnapshot,
  files: readonly DocumentationFile[],
): boolean {
  if (before.head !== after.head) return false;
  const prior = new Map(
    before.changes.map((entry) => [entry.path, entry.status]),
  );
  const next = new Map(
    after.changes.map((entry) => [entry.path, entry.status]),
  );
  if ([...prior].some(([file, status]) => next.get(file) !== status))
    return false;
  const added = [...next.keys()].filter((file) => !prior.has(file)).sort();
  const expected = files.map(({ path: file }) => file).sort();
  return (
    JSON.stringify(added) === JSON.stringify(expected) &&
    added.every((file) => next.get(file) === "??")
  );
}

function isDocumentationGitSnapshot(
  value: unknown,
): value is DocumentationGitSnapshot {
  return Boolean(
    value &&
    typeof value === "object" &&
    typeof (value as Record<string, unknown>).head === "string" &&
    /^[a-f0-9]{40,64}$/i.test(
      String((value as Record<string, unknown>).head),
    ) &&
    Array.isArray((value as Record<string, unknown>).changes) &&
    ((value as Record<string, unknown>).changes as unknown[]).every((entry) =>
      Boolean(
        entry &&
        typeof entry === "object" &&
        typeof (entry as Record<string, unknown>).path === "string" &&
        typeof (entry as Record<string, unknown>).status === "string",
      ),
    ),
  );
}

function isCompleteExit(result: ProcessResult, code: number): boolean {
  return (
    result.kind === "exited" &&
    result.exitCode === code &&
    !result.stdoutTruncated &&
    !result.stderrTruncated
  );
}

function isExactVersion(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/.test(value)
  );
}
