import { createHash } from "node:crypto";
import type {
  RunOperation,
  RunOperationExecutor,
  RunOperationResult,
} from "../application/ports/run-lifecycle.js";
import { parseExactSemverVersion } from "../domain/semver-constraints.js";
import {
  runWithProjectNpm,
  runWithProjectRuntime,
  type RuntimeCommandRequest,
  type RuntimeNpmRequest,
} from "./fnm-runtime.js";
import { InfrastructureError } from "./infrastructure-error.js";
import type { ProcessResult } from "./process-runner.js";
import { ProjectFileSystem } from "./project-files.js";

type RuntimeRunner = (request: RuntimeCommandRequest) => Promise<ProcessResult>;
type RuntimeNpmRunner = (request: RuntimeNpmRequest) => Promise<ProcessResult>;

export interface RunOperationExecutorOptions {
  readonly environment: Readonly<Record<string, string>>;
  readonly fnmExecutable: string;
  readonly files?: ProjectFileSystem;
  readonly runRuntime?: RuntimeRunner;
  readonly runNpm?: RuntimeNpmRunner;
}

export class RunOperationExecutorAdapter implements RunOperationExecutor {
  private readonly files: ProjectFileSystem;
  private readonly runRuntime: RuntimeRunner;
  private readonly runNpm: RuntimeNpmRunner;

  constructor(private readonly options: RunOperationExecutorOptions) {
    this.files = options.files ?? new ProjectFileSystem();
    this.runRuntime =
      options.runRuntime ?? ((request) => runWithProjectRuntime(request));
    this.runNpm =
      options.runNpm ??
      ((request) => runWithProjectNpm(request, this.runRuntime));
  }

  async execute(
    projectRoot: string,
    operation: RunOperation,
  ): Promise<RunOperationResult> {
    if (!isValidOperation(operation)) {
      return blocked("operation_invalid", "The planned operation is invalid.");
    }
    if (operation.kind === "verify-plan") {
      return operation.packages.some(({ name }) => name === "@angular/core") &&
        operation.packages.some(({ name }) => name === "@angular/cli")
        ? { outcome: "passed" }
        : blocked(
            "plan_incomplete",
            "The discovery plan lacks exact Angular core or CLI metadata.",
          );
    }
    if (operation.kind === "pin-packages") {
      return this.pinPackages(projectRoot, operation.packages);
    }

    let packageMetadataBefore: string | null = null;
    if (operation.postcondition === "package-metadata-stable") {
      try {
        packageMetadataBefore = await this.packageMetadataHash(projectRoot);
      } catch {
        return blocked(
          "project_metadata_unavailable",
          "Project package metadata could not be read safely.",
        );
      }
    }
    const runtimeRequest = {
      fnmExecutable: this.options.fnmExecutable,
      nodeVersion: operation.nodeVersion,
      executable: operation.executable!,
      arguments: operation.arguments,
      cwd: await this.files.canonicalProjectRoot(projectRoot),
      env: { ...this.options.environment },
      timeoutMs: operation.timeoutMs,
      terminationGraceMs: 5_000,
      maxOutputBytes: 262_144,
    } satisfies RuntimeCommandRequest;
    const result =
      operation.executable === "npm"
        ? await this.runNpm({
            ...runtimeRequest,
            arguments: operation.arguments,
          })
        : await this.runRuntime(runtimeRequest);
    if (!isSuccessful(result)) {
      const outcome =
        result.kind === "spawn-failed" ||
        result.kind === "process-error" ||
        result.kind === "invalid-request"
          ? "failed"
          : "blocked";
      return {
        outcome,
        diagnostic: {
          code: processFailureCode(result),
          message: "The project command did not complete successfully.",
        },
      };
    }

    try {
      switch (operation.postcondition) {
        case "exit-zero":
          return { outcome: "passed" };
        case "dependency-tree":
          return /\b(?:invalid|extraneous|missing)\b/i.test(
            `${result.stdout}\n${result.stderr}`,
          )
            ? blocked(
                "dependency_tree_invalid",
                "npm reported an invalid dependency tree.",
              )
            : { outcome: "passed" };
        case "package-metadata-stable":
          return (await this.packageMetadataHash(projectRoot)) ===
            packageMetadataBefore
            ? { outcome: "passed" }
            : blocked(
                "package_metadata_changed",
                "npm ci changed package metadata.",
              );
        case "target-packages-locked":
          return (await hasLockedPackages(
            this.files,
            projectRoot,
            operation.packages,
          ))
            ? { outcome: "passed" }
            : blocked(
                "target_lock_mismatch",
                "The lockfile does not contain the planned exact package versions.",
              );
        default:
          return blocked(
            "operation_postcondition_invalid",
            "The process operation has an unsupported postcondition.",
          );
      }
    } catch {
      return blocked(
        "postcondition_unavailable",
        "The operation postcondition could not be verified.",
      );
    }
  }

  private async pinPackages(
    projectRoot: string,
    packages: RunOperation["packages"],
  ): Promise<RunOperationResult> {
    try {
      const packageText = await this.files.readText(
        projectRoot,
        "package.json",
      );
      const packageJson = asRecord(JSON.parse(packageText) as unknown);
      let changed = false;
      for (const item of packages) {
        const locations: { section: Record<string, unknown>; name: string }[] =
          [];
        for (const sectionName of [
          "dependencies",
          "devDependencies",
          "optionalDependencies",
          "peerDependencies",
        ]) {
          const section = packageJson[sectionName];
          if (
            section &&
            typeof section === "object" &&
            !Array.isArray(section)
          ) {
            const dependencies = section as Record<string, unknown>;
            if (Object.hasOwn(dependencies, item.name)) {
              locations.push({ section: dependencies, name: item.name });
            }
          }
        }
        if (locations.length !== 1) {
          return blocked(
            "dependency_declaration_mismatch",
            "A planned package is not declared exactly once.",
          );
        }
        locations[0].section[item.name] = item.targetVersion;
        changed = true;
      }
      if (!changed)
        return blocked(
          "dependency_plan_empty",
          "No planned packages can be pinned.",
        );
      const indent = /(?:^|\n)([\t ]+)"/.exec(packageText)?.[1] ?? "  ";
      const newline = packageText.includes("\r\n") ? "\r\n" : "\n";
      const trailingNewline = /(?:\r?\n)$/.test(packageText) ? newline : "";
      const output =
        JSON.stringify(packageJson, null, indent).replace(/\n/g, newline) +
        trailingNewline;
      await this.files.writeAtomically(projectRoot, "package.json", output);
      const verified = asRecord(
        await this.files.readJson(projectRoot, "package.json"),
      );
      return packages.every((item) =>
        hasExactDeclaration(verified, item.name, item.targetVersion),
      )
        ? { outcome: "passed" }
        : blocked(
            "dependency_pin_unconfirmed",
            "Exact package declarations failed their postcondition.",
          );
    } catch {
      return blocked(
        "dependency_pin_failed",
        "Exact package declarations could not be written safely.",
      );
    }
  }

  private async packageMetadataHash(projectRoot: string): Promise<string> {
    const packageText = await this.files.readText(projectRoot, "package.json");
    const lockText = await this.files.readText(
      projectRoot,
      "package-lock.json",
    );
    return createHash("sha256")
      .update(packageText)
      .update("\0")
      .update(lockText)
      .digest("hex");
  }
}

function isValidOperation(value: unknown): value is RunOperation {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const operation = value as RunOperation;
  if (
    typeof operation.id !== "string" ||
    !/^[a-z][a-z0-9-]{0,63}$/.test(operation.id) ||
    !parseExactSemverVersion(operation.nodeVersion) ||
    !Number.isSafeInteger(operation.timeoutMs) ||
    operation.timeoutMs < 1 ||
    operation.timeoutMs > 600_000 ||
    !Array.isArray(operation.arguments) ||
    operation.arguments.some(
      (argument) => typeof argument !== "string" || /[\0\r\n]/.test(argument),
    ) ||
    !Array.isArray(operation.packages) ||
    operation.packages.some(
      (item) =>
        !item ||
        typeof item.name !== "string" ||
        !/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(item.name) ||
        parseExactSemverVersion(item.targetVersion)?.version !==
          item.targetVersion,
    )
  ) {
    return false;
  }
  if (operation.kind === "pin-packages") {
    return (
      operation.stage === "update-dependencies" &&
      operation.executable === null &&
      operation.arguments.length === 0 &&
      operation.postcondition === "target-packages-declared" &&
      operation.packages.length > 0
    );
  }
  if (operation.kind === "verify-plan") {
    return (
      operation.stage === "resolve" &&
      operation.executable === null &&
      operation.arguments.length === 0 &&
      operation.postcondition === "verify-plan"
    );
  }
  if (operation.kind !== "process" || typeof operation.executable !== "string")
    return false;
  if (operation.id === "angular-core-cli-update") {
    return (
      operation.id === "angular-core-cli-update" &&
      operation.stage === "update-angular" &&
      operation.executable === "npm" &&
      operation.arguments.length === 6 &&
      operation.arguments[0] === "exec" &&
      operation.arguments[1] === "--" &&
      operation.arguments[2] === "ng" &&
      operation.arguments[3] === "update" &&
      operation.arguments[4] ===
        `@angular/core@${operation.packages.find(({ name }) => name === "@angular/core")?.targetVersion}` &&
      operation.arguments[5] ===
        `@angular/cli@${operation.packages.find(({ name }) => name === "@angular/cli")?.targetVersion}` &&
      operation.postcondition === "target-packages-locked"
    );
  }
  if (operation.executable !== "npm") return false;
  const allowed = new Map<
    string,
    {
      stage: string;
      args: string[];
      postcondition: RunOperation["postcondition"];
    }
  >([
    [
      "baseline-install",
      {
        stage: "baseline",
        args: ["ci"],
        postcondition: "package-metadata-stable",
      },
    ],
    [
      "install-clean",
      {
        stage: "install",
        args: ["ci"],
        postcondition: "package-metadata-stable",
      },
    ],
    [
      "baseline-dependency-tree",
      {
        stage: "baseline",
        args: ["ls", "--all"],
        postcondition: "dependency-tree",
      },
    ],
    [
      "install-dependency-tree",
      {
        stage: "install",
        args: ["ls", "--all"],
        postcondition: "dependency-tree",
      },
    ],
    [
      "update-lockfile",
      {
        stage: "update-dependencies",
        args: ["install", "--package-lock-only", "--ignore-scripts"],
        postcondition: "target-packages-locked",
      },
    ],
  ]);
  const fixed = allowed.get(operation.id);
  if (fixed) {
    return (
      operation.stage === fixed.stage &&
      JSON.stringify(operation.arguments) === JSON.stringify(fixed.args) &&
      operation.postcondition === fixed.postcondition
    );
  }
  return (
    /^(?:validate|baseline)-[a-z][a-z0-9-]{0,63}$/.test(operation.id) &&
    (operation.stage === "validate" || operation.stage === "baseline") &&
    operation.arguments.length === 2 &&
    operation.arguments[0] === "run" &&
    /^[a-zA-Z0-9:_-]+$/.test(operation.arguments[1]) &&
    operation.postcondition === "exit-zero"
  );
}

function isSuccessful(result: ProcessResult): boolean {
  return (
    result.kind === "exited" &&
    result.exitCode === 0 &&
    !result.stdoutTruncated &&
    !result.stderrTruncated
  );
}

function processFailureCode(result: ProcessResult): string {
  if (result.kind === "timed-out") return "process_timed_out";
  if (result.kind === "spawn-failed") return "process_spawn_failed";
  if (result.kind === "process-error") return "process_error";
  if (result.kind === "invalid-request") return "process_request_invalid";
  if (result.kind === "exited" && result.exitCode !== 0)
    return "process_nonzero_exit";
  if (result.kind === "signaled") return "process_signaled";
  return "process_output_truncated";
}

function blocked(code: string, message: string): RunOperationResult {
  return { outcome: "blocked", diagnostic: { code, message } };
}

async function hasLockedPackages(
  files: ProjectFileSystem,
  projectRoot: string,
  packages: RunOperation["packages"],
): Promise<boolean> {
  const lockfile = asRecord(
    await files.readJson(projectRoot, "package-lock.json"),
  );
  const version = lockfile.lockfileVersion;
  if (version !== 1 && version !== 2 && version !== 3) return false;
  const entries = asRecord(
    lockfile[version === 1 ? "dependencies" : "packages"],
  );
  return packages.every((item) => {
    const entry = asRecord(
      version === 1 ? entries[item.name] : entries[`node_modules/${item.name}`],
    );
    return (
      parseExactSemverVersion(entry.version)?.version === item.targetVersion
    );
  });
}

function hasExactDeclaration(
  packageJson: Record<string, unknown>,
  name: string,
  targetVersion: string,
): boolean {
  const sections = [
    "dependencies",
    "devDependencies",
    "optionalDependencies",
    "peerDependencies",
  ];
  const values = sections.flatMap((section) => {
    const value = packageJson[section];
    if (!value || typeof value !== "object" || Array.isArray(value)) return [];
    const dependencies = value as Record<string, unknown>;
    return Object.hasOwn(dependencies, name) ? [dependencies[name]] : [];
  });
  return values.length === 1 && values[0] === targetVersion;
}

function asRecord(value: unknown): Record<string, any> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new InfrastructureError(
      "project_json_invalid",
      "Project metadata has an invalid object shape.",
    );
  }
  return value as Record<string, any>;
}
