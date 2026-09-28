import { createHash } from "node:crypto";
import type {
  BaselineDependencyInstaller,
  BaselineDependencyProposalPackage,
  BaselineDependencyProposalReader,
} from "../application/ports/approvals.js";
import type { RunRecord } from "../application/ports/run-lifecycle.js";
import {
  isValidSemverRange,
  parseExactSemverVersion,
  satisfiesAllSemverRanges,
  selectHighestSatisfyingSemverVersion,
} from "../domain/semver-constraints.js";
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

const MAX_PROPOSAL_PACKAGES = 50;
const MAX_PEER_RANGES = 20;
const MAX_DEPENDENCY_NODES = 10_000;

export interface BaselineDependencyAdapterOptions {
  readonly environment: Readonly<Record<string, string>>;
  readonly fnmExecutable: string;
  readonly files?: ProjectFileSystem;
  readonly runRuntime?: RuntimeRunner;
  readonly runNpm?: RuntimeNpmRunner;
}

export class NpmBaselineDependencyProposalReader implements BaselineDependencyProposalReader {
  private readonly files: ProjectFileSystem;
  private readonly runRuntime: RuntimeRunner;
  private readonly runNpm: RuntimeNpmRunner;

  constructor(private readonly options: BaselineDependencyAdapterOptions) {
    this.files = options.files ?? new ProjectFileSystem();
    this.runRuntime =
      options.runRuntime ?? ((request) => runWithProjectRuntime(request));
    this.runNpm =
      options.runNpm ??
      ((request) => runWithProjectNpm(request, this.runRuntime));
  }

  async read(projectRoot: string, run: RunRecord): Promise<unknown> {
    const nodeVersion = run.discoveryPlan.runtimePlan.selected?.nodeVersion;
    if (!isExactVersion(nodeVersion)) {
      throw new InfrastructureError(
        "run_record_invalid",
        "The run does not contain an exact selected Node runtime.",
      );
    }
    const canonicalRoot = await this.files.canonicalProjectRoot(projectRoot);
    const result = await this.runNpm(
      this.npmRequest(canonicalRoot, nodeVersion, ["ls", "--all", "--json"]),
    );
    if (
      result.kind !== "exited" ||
      ![0, 1].includes(result.exitCode) ||
      result.stdoutTruncated ||
      result.stderrTruncated
    ) {
      throw new InfrastructureError(
        "registry_metadata_unavailable",
        "npm could not return a complete structured dependency tree.",
      );
    }
    let tree: unknown;
    try {
      tree = JSON.parse(result.stdout) as unknown;
    } catch {
      throw new InfrastructureError(
        "registry_metadata_invalid",
        "npm returned invalid JSON for the dependency tree.",
      );
    }
    if (!isRecord(tree)) {
      throw new InfrastructureError(
        "registry_metadata_invalid",
        "npm returned an invalid dependency tree.",
      );
    }
    const missing = collectMissingPeers(tree);
    if (missing.length > MAX_PROPOSAL_PACKAGES) {
      throw new InfrastructureError(
        "registry_metadata_invalid",
        "The structured missing-peer proposal exceeds its package limit.",
      );
    }
    const proposal: BaselineDependencyProposalPackage[] = [];
    for (const entry of missing) {
      const candidates = new Set<string>();
      for (const range of entry.requiredRanges) {
        const versionResult = await this.runNpm(
          this.npmRequest(canonicalRoot, nodeVersion, [
            "view",
            `${entry.name}@${range}`,
            "version",
            "--json",
          ]),
        );
        if (!isCompleteExit(versionResult, 0)) {
          throw new InfrastructureError(
            "registry_metadata_unavailable",
            "The configured npm registry could not resolve a peer range.",
          );
        }
        const versions = parseVersionList(versionResult.stdout);
        if (versions === null) {
          throw new InfrastructureError(
            "registry_metadata_invalid",
            "The configured npm registry returned invalid version data.",
          );
        }
        for (const version of versions) candidates.add(version);
      }
      const installVersion = selectHighestSatisfyingSemverVersion(
        [...candidates],
        entry.requiredRanges,
      );
      if (!installVersion) {
        throw new InfrastructureError(
          "registry_metadata_unavailable",
          "No exact registry version satisfies every missing peer range.",
        );
      }
      proposal.push({
        name: entry.name,
        installVersion,
        requiredRanges: entry.requiredRanges,
        requiredBy: entry.requiredBy,
      });
    }
    return proposal;
  }

  private npmRequest(
    projectRoot: string,
    nodeVersion: string,
    arguments_: readonly string[],
  ): RuntimeNpmRequest {
    return {
      fnmExecutable: this.options.fnmExecutable,
      nodeVersion,
      arguments: arguments_,
      cwd: projectRoot,
      env: this.options.environment,
      timeoutMs: 120_000,
      terminationGraceMs: 5_000,
      maxOutputBytes: 1_048_576,
    };
  }
}

export class NpmBaselineDependencyInstaller implements BaselineDependencyInstaller {
  private readonly files: ProjectFileSystem;
  private readonly runRuntime: RuntimeRunner;
  private readonly runNpm: RuntimeNpmRunner;

  constructor(private readonly options: BaselineDependencyAdapterOptions) {
    this.files = options.files ?? new ProjectFileSystem();
    this.runRuntime =
      options.runRuntime ?? ((request) => runWithProjectRuntime(request));
    this.runNpm =
      options.runNpm ??
      ((request) => runWithProjectNpm(request, this.runRuntime));
  }

  async install(input: {
    readonly projectRoot: string;
    readonly runId: string;
    readonly nodeVersion: string;
    readonly packages: readonly BaselineDependencyProposalPackage[];
  }): Promise<{
    readonly outcome: "installed" | "failed";
    readonly packageStateHash: string | null;
  }> {
    if (!isValidInstallRequest(input)) {
      return { outcome: "failed", packageStateHash: null };
    }
    let canonicalRoot: string | undefined;
    let originalPackage: string | undefined;
    let originalLock: string | undefined;
    try {
      canonicalRoot = await this.files.canonicalProjectRoot(input.projectRoot);
      const before = await this.gitStatus(canonicalRoot, input.nodeVersion);
      if (before === null || before.length !== 0) {
        return { outcome: "failed", packageStateHash: null };
      }
      originalPackage = await this.files.readText(
        canonicalRoot,
        "package.json",
      );
      originalLock = await this.files.readText(
        canonicalRoot,
        "package-lock.json",
      );
      const install = await this.runNpm({
        ...this.npmRequest(canonicalRoot, input.nodeVersion),
        arguments: [
          "install",
          "--save-prod",
          "--save-exact",
          "--ignore-scripts",
          "--no-audit",
          "--no-fund",
          ...input.packages.map(
            ({ name, installVersion }) => `${name}@${installVersion}`,
          ),
        ],
      });
      const installPaths = await this.gitStatus(
        canonicalRoot,
        input.nodeVersion,
      );
      if (
        !isCompleteExit(install, 0) ||
        !isAllowedPackageChanges(installPaths) ||
        !(await this.hasExactDeclarations(canonicalRoot, input.packages))
      ) {
        await this.rollback(
          canonicalRoot,
          input.nodeVersion,
          originalPackage,
          originalLock,
        );
        return { outcome: "failed", packageStateHash: null };
      }
      const tree = await this.runNpm({
        ...this.npmRequest(canonicalRoot, input.nodeVersion),
        arguments: ["ls", "--all"],
      });
      const finalPaths = await this.gitStatus(canonicalRoot, input.nodeVersion);
      if (!isCompleteExit(tree, 0) || !isAllowedPackageChanges(finalPaths)) {
        await this.rollback(
          canonicalRoot,
          input.nodeVersion,
          originalPackage,
          originalLock,
        );
        return { outcome: "failed", packageStateHash: null };
      }
      const packageText = await this.files.readText(
        canonicalRoot,
        "package.json",
      );
      const lockText = await this.files.readText(
        canonicalRoot,
        "package-lock.json",
      );
      return {
        outcome: "installed",
        packageStateHash: `sha256:${createHash("sha256")
          .update(packageText)
          .update("\0")
          .update(lockText)
          .digest("hex")}`,
      };
    } catch {
      if (
        canonicalRoot &&
        originalPackage !== undefined &&
        originalLock !== undefined
      ) {
        await this.rollback(
          canonicalRoot,
          input.nodeVersion,
          originalPackage,
          originalLock,
        );
      }
      return { outcome: "failed", packageStateHash: null };
    }
  }

  private npmRequest(
    projectRoot: string,
    nodeVersion: string,
  ): RuntimeNpmRequest {
    return {
      fnmExecutable: this.options.fnmExecutable,
      nodeVersion,
      arguments: [],
      cwd: projectRoot,
      env: this.options.environment,
      timeoutMs: 600_000,
      terminationGraceMs: 10_000,
      maxOutputBytes: 262_144,
    };
  }

  private async gitStatus(
    projectRoot: string,
    nodeVersion: string,
  ): Promise<readonly GitStatusEntry[] | null> {
    try {
      const result = await this.runRuntime({
        fnmExecutable: this.options.fnmExecutable,
        nodeVersion,
        executable: "git",
        arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        cwd: projectRoot,
        env: this.options.environment,
        timeoutMs: 30_000,
        terminationGraceMs: 5_000,
        maxOutputBytes: 1_048_576,
      });
      if (!isCompleteExit(result, 0)) return null;
      return parseGitStatus(result.stdout);
    } catch {
      return null;
    }
  }

  private async hasExactDeclarations(
    projectRoot: string,
    packages: readonly BaselineDependencyProposalPackage[],
  ): Promise<boolean> {
    try {
      const manifest = asRecord(
        await this.files.readJson(projectRoot, "package.json"),
      );
      const lock = asRecord(
        await this.files.readJson(projectRoot, "package-lock.json"),
      );
      const lockedPackages = asRecord(asRecord(lock.packages)[""]);
      const lockedDependencies = asRecord(lock.dependencies);
      return packages.every((item) => {
        const declared = [
          "dependencies",
          "devDependencies",
          "optionalDependencies",
          "peerDependencies",
        ].filter((key) => Object.hasOwn(asRecord(manifest[key]), item.name));
        const lockSections = [
          lockedPackages.dependencies,
          lockedPackages.devDependencies,
          lockedPackages.optionalDependencies,
          lockedPackages.peerDependencies,
        ];
        const rootLockMatches = lockSections.filter(
          (section) => asRecord(section)[item.name] === item.installVersion,
        );
        const lockEntry = asRecord(
          asRecord(lock.packages)[`node_modules/${item.name}`],
        );
        const legacyEntry = asRecord(lockedDependencies[item.name]);
        return (
          declared.length === 1 &&
          asRecord(manifest[declared[0]])[item.name] === item.installVersion &&
          rootLockMatches.length === 1 &&
          (lockEntry.version === item.installVersion ||
            legacyEntry.version === item.installVersion)
        );
      });
    } catch {
      return false;
    }
  }

  private async rollback(
    projectRoot: string,
    nodeVersion: string,
    originalPackage: string,
    originalLock: string,
  ): Promise<boolean> {
    try {
      if ((await this.gitStatus(projectRoot, nodeVersion)) === null)
        return false;
      for (const [file, original] of [
        ["package.json", originalPackage],
        ["package-lock.json", originalLock],
      ] as const) {
        const current = await this.files.readOptionalText(projectRoot, file);
        if (current !== original) {
          await this.files.writeAtomically(projectRoot, file, original);
        }
      }
      const [restoredPackage, restoredLock, after] = await Promise.all([
        this.files.readText(projectRoot, "package.json"),
        this.files.readText(projectRoot, "package-lock.json"),
        this.gitStatus(projectRoot, nodeVersion),
      ]);
      return (
        restoredPackage === originalPackage &&
        restoredLock === originalLock &&
        after !== null &&
        after.length === 0
      );
    } catch {
      return false;
    }
  }
}

interface MissingPeer {
  readonly name: string;
  readonly requiredRanges: readonly string[];
  readonly requiredBy: readonly string[];
}

interface MutableMissingPeer {
  readonly ranges: Set<string>;
  readonly parents: Set<string>;
}

interface GitStatusEntry {
  readonly status: string;
  readonly path: string;
}

function collectMissingPeers(
  tree: Record<string, unknown>,
): readonly MissingPeer[] {
  const dependencies = tree.dependencies;
  if (!isRecord(dependencies)) return [];
  const missing = new Map<string, MutableMissingPeer>();
  let visited = 0;
  const walk = (
    children: Record<string, unknown>,
    parents: readonly string[],
    depth: number,
  ): void => {
    if (depth > 100) {
      throw new InfrastructureError(
        "registry_metadata_invalid",
        "The structured dependency tree exceeds its depth limit.",
      );
    }
    for (const [name, raw] of Object.entries(children)) {
      visited += 1;
      if (visited > MAX_DEPENDENCY_NODES) {
        throw new InfrastructureError(
          "registry_metadata_invalid",
          "The structured dependency tree exceeds its node limit.",
        );
      }
      if (!isRecord(raw)) continue;
      if (
        raw.missing === true &&
        raw.peer === true &&
        raw.peerOptional !== true
      ) {
        const range = raw.required;
        if (typeof range !== "string" || range.length > 256) {
          throw new InfrastructureError(
            "registry_metadata_invalid",
            "A missing peer lacks a bounded structured version range.",
          );
        }
        const parent = parents.at(-1) ?? "project root";
        const entry = missing.get(name) ?? {
          ranges: new Set<string>(),
          parents: new Set<string>(),
        };
        entry.ranges.add(range);
        entry.parents.add(parent);
        if (entry.ranges.size > MAX_PEER_RANGES) {
          throw new InfrastructureError(
            "registry_metadata_invalid",
            "A missing peer has too many distinct required ranges.",
          );
        }
        missing.set(name, entry);
      }
      if (isRecord(raw.dependencies)) {
        const version =
          typeof raw.version === "string" ? raw.version : "unknown";
        walk(raw.dependencies, [...parents, `${name}@${version}`], depth + 1);
      }
    }
  };
  walk(dependencies, [], 0);
  return [...missing.entries()]
    .map(([name, value]) => ({
      name,
      requiredRanges: [...value.ranges].sort(),
      requiredBy: [...value.parents].sort(),
    }))
    .sort((left, right) => left.name.localeCompare(right.name));
}

function parseVersionList(text: string): readonly string[] | null {
  try {
    const parsed = JSON.parse(text) as unknown;
    const versions = typeof parsed === "string" ? [parsed] : parsed;
    if (
      !Array.isArray(versions) ||
      versions.length === 0 ||
      versions.some((version) => !isExactVersion(version))
    ) {
      return null;
    }
    return versions;
  } catch {
    return null;
  }
}

function parseGitStatus(text: string): readonly GitStatusEntry[] | null {
  if (text.length === 0) return [];
  if (!text.endsWith("\0")) return null;
  const entries: GitStatusEntry[] = [];
  for (const item of text.split("\0").filter(Boolean)) {
    if (item.length < 4 || item[2] !== " ") return null;
    const status = item.slice(0, 2);
    if (status !== " M") return null;
    entries.push({ status, path: item.slice(3) });
  }
  return entries;
}

function isAllowedPackageChanges(
  entries: readonly GitStatusEntry[] | null,
): boolean {
  return Boolean(
    entries &&
    entries.every(
      ({ path: file }) =>
        file === "package.json" || file === "package-lock.json",
    ),
  );
}

function isValidInstallRequest(value: unknown): value is {
  readonly projectRoot: string;
  readonly runId: string;
  readonly nodeVersion: string;
  readonly packages: readonly BaselineDependencyProposalPackage[];
} {
  const names = new Set<string>();
  return Boolean(
    isRecord(value) &&
    typeof value.projectRoot === "string" &&
    value.projectRoot.trim().length > 0 &&
    typeof value.runId === "string" &&
    isExactVersion(value.nodeVersion) &&
    Array.isArray(value.packages) &&
    value.packages.length > 0 &&
    value.packages.length <= MAX_PROPOSAL_PACKAGES &&
    value.packages.every((item: unknown) => {
      if (
        !isRecord(item) ||
        typeof item.name !== "string" ||
        !/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(item.name) ||
        item.name.startsWith("@angular/") ||
        names.has(item.name) ||
        !isExactVersion(item.installVersion) ||
        parseExactSemverVersion(item.installVersion)?.version !==
          item.installVersion ||
        !Array.isArray(item.requiredRanges) ||
        item.requiredRanges.length === 0 ||
        item.requiredRanges.length > MAX_PEER_RANGES ||
        !item.requiredRanges.every(isValidSemverRange) ||
        !satisfiesAllSemverRanges(item.installVersion, item.requiredRanges) ||
        !Array.isArray(item.requiredBy) ||
        item.requiredBy.length === 0 ||
        item.requiredBy.length > 100 ||
        !item.requiredBy.every(
          (parent: unknown) =>
            typeof parent === "string" &&
            parent.length <= 256 &&
            !/[\0\r\n]/.test(parent),
        )
      ) {
        return false;
      }
      names.add(item.name);
      return true;
    }),
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

function asRecord(value: unknown): Record<string, unknown> {
  return isRecord(value) ? value : {};
}

function isRecord(value: unknown): value is Record<string, any> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
