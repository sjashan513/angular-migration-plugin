import { createHash } from "node:crypto";
import * as fs from "node:fs/promises";
import path from "node:path";
import { compare, prerelease } from "semver";
import type {
  DiscoveryIssue,
  DiscoveryPackage,
  ProjectDiscoveryInputs,
  ProjectDiscoveryReader,
} from "../application/ports/project-discovery.js";
import type { ProjectFingerprintReader } from "../application/ports/run-lifecycle.js";
import { createAngularTransition } from "../domain/angular-transition.js";
import {
  planRuntime,
  type RuntimeCandidate,
} from "../domain/runtime-planner.js";
import {
  isValidSemverRange,
  parseExactSemverVersion,
  satisfiesAllSemverRanges,
} from "../domain/semver-constraints.js";
import {
  runWithProjectNpm,
  runWithProjectRuntime,
  type RuntimeCommandRequest,
  type RuntimeNpmRequest,
} from "./fnm-runtime.js";
import { InfrastructureError } from "./infrastructure-error.js";
import type { ProcessRequest, ProcessResult } from "./process-runner.js";
import { runProcess } from "./process-runner.js";
import { ProjectFactsReaderAdapter } from "./project-facts-reader.js";
import { ProjectFileSystem } from "./project-files.js";

const SECTIONS = [
  "dependencies",
  "devDependencies",
  "optionalDependencies",
  "peerDependencies",
] as const;
const FRAMEWORK_PACKAGES = new Set([
  "animations",
  "common",
  "compiler",
  "compiler-cli",
  "core",
  "elements",
  "forms",
  "language-service",
  "localize",
  "platform-browser",
  "platform-browser-dynamic",
  "platform-server",
  "platform-webworker",
  "platform-webworker-dynamic",
  "router",
  "service-worker",
  "upgrade",
]);
const FINGERPRINT_FILES = [
  "package.json",
  "package-lock.json",
  "angular.json",
  ".npmrc",
  ".nvmrc",
  ".node-version",
  ".tool-versions",
  "nx.json",
  "yarn.lock",
  "pnpm-lock.yaml",
];

type CommandRunner = (request: ProcessRequest) => Promise<ProcessResult>;
type RuntimeCommandRunner = (
  request: RuntimeCommandRequest,
) => Promise<ProcessResult>;
type RuntimeNpmRunner = (request: RuntimeNpmRequest) => Promise<ProcessResult>;

export interface ProjectDiscoveryReaderOptions {
  readonly environment: Readonly<Record<string, string>>;
  readonly files?: ProjectFileSystem;
  readonly runProcess?: CommandRunner;
  readonly runRuntime?: RuntimeCommandRunner;
  readonly runNpm?: RuntimeNpmRunner;
}

export class ProjectDiscoveryReaderAdapter
  implements ProjectDiscoveryReader, ProjectFingerprintReader
{
  private readonly files: ProjectFileSystem;
  private readonly runCommand: CommandRunner;
  private readonly runRuntimeCommand: RuntimeCommandRunner;
  private readonly runNpmCommand: RuntimeNpmRunner;

  constructor(private readonly options: ProjectDiscoveryReaderOptions) {
    this.files = options.files ?? new ProjectFileSystem();
    this.runCommand = options.runProcess ?? ((request) => runProcess(request));
    this.runRuntimeCommand =
      options.runRuntime ?? ((request) => runWithProjectRuntime(request));
    this.runNpmCommand =
      options.runNpm ??
      ((request) => runWithProjectNpm(request, this.runRuntimeCommand));
  }

  async read(projectRoot: string, targetMajor: number): Promise<unknown> {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const packageJson = asRecord(
      await this.files.readJson(root, "package.json"),
    );
    const lockfile = asRecord(
      await this.files.readJson(root, "package-lock.json"),
    );
    const angular = asRecord(await this.files.readJson(root, "angular.json"));
    const facts = await new ProjectFactsReaderAdapter(
      this.files,
    ).readProjectFacts(root);
    createAngularTransition(facts.angularMajor, targetMajor);

    const lockfileVersion = Number(lockfile.lockfileVersion);
    const declarations = readDependencies(packageJson, lockfile);
    const issues: DiscoveryIssue[] = [];
    const scripts = asRecordOrEmpty(packageJson.scripts);
    const nxConfig = await this.files.readOptionalText(root, "nx.json");
    const projectShape =
      nxConfig === null && isSupportedRootProject(packageJson, angular)
        ? "root-angular-cli"
        : "unsupported-layout";
    const git = await this.readGitSnapshot(root);
    const npmrc = await this.files.readOptionalText(root, ".npmrc");
    const fingerprint = await fingerprintInputs(
      root,
      this.files,
      this.options.environment.MIGRATION_IPS_REGISTRY ?? "",
      git.fingerprint,
    );
    const registry = validateRegistryTrust(
      npmrc ?? "",
      this.options.environment.MIGRATION_IPS_REGISTRY ?? "",
      declarations.some((item) => item.name.startsWith("@ips/")),
    );
    const registryStatus = registry.trusted ? "trusted" : "untrusted";
    const dependencySourcesStatus = declarations.every((item) => item.safe)
      ? "safe"
      : "unsafe";
    const nodeRanges: string[] = [];
    const npmRanges: string[] = [];
    readDeclaredRanges(packageJson, nodeRanges, npmRanges, issues);
    for (const relative of [".nvmrc", ".node-version"]) {
      const text = await this.files.readOptionalText(root, relative);
      if (text?.trim())
        addRange(text.trim().replace(/^v(?=\d)/, ""), nodeRanges, issues);
    }
    const toolVersions = await this.files.readOptionalText(
      root,
      ".tool-versions",
    );
    const nodeToolVersion = /^\s*nodejs\s+(\S+)/m.exec(toolVersions ?? "")?.[1];
    if (nodeToolVersion)
      addRange(nodeToolVersion.replace(/^v(?=\d)/, ""), nodeRanges, issues);
    const packageManager =
      typeof packageJson.packageManager === "string"
        ? packageJson.packageManager
        : "npm";
    const npmPin = /^npm@(.+)$/.exec(packageManager)?.[1];
    if (npmPin) addRange(npmPin, npmRanges, issues);
    const npmRange = [lockfileVersion === 1 ? ">=5" : ">=7", ...npmRanges].join(
      " ",
    );
    const fnm = await resolveWindowsExecutable("fnm", this.options.environment);
    const runtimeCandidates = fnm
      ? await this.readRuntimeCandidates(fnm, root, nodeRanges, npmRange)
      : [];
    const installedCandidates = runtimeCandidates.filter(
      (candidate) => candidate.status === "installed",
    );
    const metadataRuntime = planRuntime({
      nodeRanges: [],
      npmRange,
      candidates: installedCandidates,
    }).selected;
    let packages: DiscoveryPackage[] = [];
    if (registryStatus === "trusted" && dependencySourcesStatus === "safe") {
      if (metadataRuntime && fnm) {
        packages = await this.readTargetPackageMetadata(
          root,
          fnm,
          metadataRuntime.nodeVersion,
          declarations,
          facts.angularMajor,
          targetMajor,
          issues,
        );
      } else {
        issues.push({
          code: "runtime_metadata_unavailable",
          message:
            "No installed exact Node runtime can run read-only npm metadata queries.",
        });
      }
    }
    const checkRecords = createChecks(scripts, Boolean(lockfileVersion));
    const input: ProjectDiscoveryInputs = {
      projectId: facts.projectId,
      inputFingerprint: fingerprint,
      sourceMajor: facts.angularMajor,
      projectShape,
      packageManager,
      lockfileVersion,
      gitStatus: git.status,
      registryStatus,
      dependencySourcesStatus,
      nodeRanges,
      npmRange,
      runtimeCandidates,
      metadataRuntimeVersion: metadataRuntime?.nodeVersion ?? null,
      checks: checkRecords,
      packages,
      registryIdentities: registry.identities,
      issues: [
        ...issues,
        ...(fnm
          ? []
          : [
              {
                code: "fnm_missing",
                message: "fnm is required for runtime planning.",
              },
            ]),
      ],
    };
    return input;
  }

  async readFingerprint(projectRoot: string): Promise<string> {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const git = await this.readGitSnapshot(root);
    return fingerprintInputs(
      root,
      this.files,
      this.options.environment.MIGRATION_IPS_REGISTRY ?? "",
      git.fingerprint,
    );
  }

  private async readGitSnapshot(root: string): Promise<{
    readonly status: "clean" | "dirty" | "unavailable";
    readonly fingerprint: string;
  }> {
    const git = await resolveWindowsExecutable("git", this.options.environment);
    if (!git) return { status: "unavailable", fingerprint: "git-unavailable" };
    const prefix = await this.runHostCommand(
      git,
      ["rev-parse", "--show-prefix"],
      root,
      10_000,
    );
    if (!successful(prefix) || prefix.stdout.trim() !== "")
      return { status: "unavailable", fingerprint: "git-root-unavailable" };
    const head = await this.runHostCommand(
      git,
      ["rev-parse", "--verify", "HEAD"],
      root,
      10_000,
    );
    if (!successful(head) || !/^[a-f0-9]{40,64}$/i.test(head.stdout.trim()))
      return { status: "unavailable", fingerprint: "git-head-unavailable" };
    const status = await this.runHostCommand(
      git,
      [
        "--no-optional-locks",
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--",
        ".",
        ":!.angular-migration",
      ],
      root,
      30_000,
    );
    if (!successful(status))
      return { status: "unavailable", fingerprint: "git-status-unavailable" };
    return {
      status: status.stdout.trim().length === 0 ? "clean" : "dirty",
      fingerprint: `${head.stdout.trim()}\0${status.stdout}`,
    };
  }

  private async readRuntimeCandidates(
    fnm: string,
    root: string,
    nodeRanges: readonly string[],
    npmRange: string,
  ): Promise<RuntimeCandidate[]> {
    const list = await this.runHostCommand(fnm, ["list"], root, 30_000);
    const versions = successful(list) ? parseFnmVersions(list.stdout) : [];
    const installed: RuntimeCandidate[] = [];
    for (const nodeVersion of versions) {
      const node = await this.runRuntimeCommand({
        fnmExecutable: fnm,
        nodeVersion,
        executable: "node",
        arguments: ["--version"],
        cwd: root,
        env: { ...this.options.environment },
        timeoutMs: 30_000,
        terminationGraceMs: 5_000,
        maxOutputBytes: 8_192,
      });
      const npm = await this.runNpmCommand({
        fnmExecutable: fnm,
        nodeVersion,
        arguments: ["--version"],
        cwd: root,
        env: { ...this.options.environment },
        timeoutMs: 30_000,
        terminationGraceMs: 5_000,
        maxOutputBytes: 8_192,
      });
      const actualNode = parseExactSemverVersion(
        node.stdout.trim().replace(/^v/, ""),
      );
      const actualNpm = parseExactSemverVersion(
        npm.stdout.trim().replace(/^v/, ""),
      );
      if (
        successful(node) &&
        successful(npm) &&
        actualNode?.version === nodeVersion &&
        actualNpm
      ) {
        installed.push({
          nodeVersion,
          npmVersion: actualNpm.version,
          status: "installed",
        });
      }
    }
    const installedPlan = planRuntime({
      nodeRanges,
      npmRange,
      candidates: installed,
    });
    if (installedPlan.status === "ready") return installed;

    const remotePlanRange = nodeRanges.length > 0 ? nodeRanges.join(" ") : "*";
    const fnmRemote = await this.runHostCommand(
      fnm,
      ["list-remote", "--latest", "--filter", remotePlanRange],
      root,
      60_000,
    );
    if (!successful(fnmRemote)) return installed;
    const remoteVersion = parseFnmVersions(fnmRemote.stdout)[0];
    if (
      !remoteVersion ||
      installed.some(({ nodeVersion }) => nodeVersion === remoteVersion)
    )
      return installed;
    return [
      ...installed,
      { nodeVersion: remoteVersion, npmVersion: null, status: "missing" },
    ];
  }

  private async readTargetPackageMetadata(
    root: string,
    fnm: string,
    nodeVersion: string,
    declarations: readonly DependencyDeclaration[],
    sourceMajor: number,
    targetMajor: number,
    issues: DiscoveryIssue[],
  ): Promise<DiscoveryPackage[]> {
    const relevant = declarations.filter(({ name }) =>
      isAngularMigrationPackage(name),
    );
    if (!relevant.some(({ name }) => name === "@angular/core")) return [];
    const resolved: DiscoveryPackage[] = [];
    for (const dependency of relevant) {
      const selector = getTargetSelector(dependency.name, targetMajor);
      const result = await this.runNpmCommand({
        fnmExecutable: fnm,
        nodeVersion,
        arguments: [
          "view",
          `${dependency.name}@${selector}`,
          "version",
          "engines",
          "peerDependencies",
          "deprecated",
          "--json",
        ],
        cwd: root,
        env: { ...this.options.environment },
        timeoutMs: 120_000,
        terminationGraceMs: 5_000,
        maxOutputBytes: 262_144,
      });
      if (!successful(result)) {
        issues.push({
          code: "registry_metadata_unavailable",
          message: `Registry metadata for ${dependency.name} is unavailable.`,
        });
        continue;
      }
      const candidates = parseNpmCandidates(result.stdout, selector);
      if (candidates.length === 0) {
        issues.push({
          code: "registry_metadata_invalid",
          message: `Registry metadata for ${dependency.name} has no stable compatible version.`,
        });
        continue;
      }
      const candidate = candidates[0];
      if (candidate.nodeRange && !isValidSemverRange(candidate.nodeRange)) {
        issues.push({
          code: "registry_metadata_invalid",
          message: `Registry metadata for ${dependency.name} contains an invalid Node engine range.`,
        });
        continue;
      }
      if (
        dependency.name.startsWith("@angular/") &&
        !dependency.name.startsWith("@angular-devkit/") &&
        dependency.name !== "@angular/cli" &&
        candidate.major !== targetMajor
      ) {
        issues.push({
          code: "angular_package_major_mismatch",
          message: `Registry metadata for ${dependency.name} does not match target Angular ${targetMajor}.`,
        });
        continue;
      }
      const toolingPackage =
        dependency.name.startsWith("@angular-devkit/") ||
        dependency.name.startsWith("@ngtools/");
      if (!toolingPackage && dependency.sourceVersionMajor !== sourceMajor) {
        issues.push({
          code: "angular_source_major_mismatch",
          message: `Locked ${dependency.name} does not match the detected Angular source major.`,
        });
        continue;
      }
      resolved.push({
        name: dependency.name,
        sourceVersion: dependency.sourceVersion,
        targetVersion: candidate.version,
        registryId: dependency.name.startsWith("@ips/")
          ? "ips-private"
          : "npmjs",
        nodeRange: candidate.nodeRange,
        peerDependencies: candidate.peerDependencies,
        reason: `highest-stable-version-matching-${selector}`,
      });
    }
    return resolved.sort((left, right) => left.name.localeCompare(right.name));
  }

  private runHostCommand(
    executable: string,
    arguments_: readonly string[],
    cwd: string,
    timeoutMs: number,
  ): Promise<ProcessResult> {
    return this.runCommand({
      executable,
      arguments: arguments_,
      cwd,
      env: { ...this.options.environment },
      timeoutMs,
      terminationGraceMs: 5_000,
      maxOutputBytes: 262_144,
    });
  }
}

interface DependencyDeclaration {
  readonly name: string;
  readonly sourceVersion: string;
  readonly sourceVersionMajor: number;
  readonly safe: boolean;
}

interface NpmCandidate {
  readonly version: string;
  readonly major: number;
  readonly nodeRange: string | null;
  readonly peerDependencies: readonly { name: string; range: string }[];
}

function readDependencies(
  packageJson: Record<string, unknown>,
  lockfile: Record<string, unknown>,
): DependencyDeclaration[] {
  const lockfileVersion = lockfile.lockfileVersion;
  const lockEntries = asRecord(
    lockfileVersion === 1 ? lockfile.dependencies : lockfile.packages,
  );
  const declarations: DependencyDeclaration[] = [];
  const seen = new Set<string>();
  for (const sectionName of SECTIONS) {
    const section = packageJson[sectionName];
    if (section === undefined) continue;
    const entries = asRecord(section);
    for (const [name, specification] of Object.entries(entries)) {
      const duplicate = seen.has(name);
      seen.add(name);
      const lockedEntry = asRecordOrEmpty(
        lockfileVersion === 1
          ? lockEntries[name]
          : lockEntries[`node_modules/${name}`],
      );
      const locked =
        typeof lockedEntry.version === "string"
          ? parseExactSemverVersion(lockedEntry.version)
          : null;
      const range = typeof specification === "string" ? specification : null;
      const safe = Boolean(
        !duplicate &&
        range &&
        isValidSemverRange(range) &&
        locked &&
        satisfiesAllSemverRanges(locked.version, [range]),
      );
      if (safe && locked) {
        declarations.push({
          name,
          sourceVersion: locked.version,
          sourceVersionMajor: locked.major,
          safe,
        });
      } else {
        declarations.push({
          name,
          sourceVersion: locked?.version ?? "0.0.0",
          sourceVersionMajor: locked?.major ?? 0,
          safe: false,
        });
      }
    }
  }
  return declarations;
}

function isSupportedRootProject(
  packageJson: Record<string, unknown>,
  angular: Record<string, unknown>,
): boolean {
  if (Object.hasOwn(packageJson, "workspaces")) return false;
  const projects = asRecordOrEmpty(angular.projects);
  const applications = Object.values(projects).filter((project) => {
    const record = asRecordOrEmpty(project);
    return (
      record.projectType === "application" &&
      (record.root === undefined || record.root === "" || record.root === ".")
    );
  });
  return applications.length > 0;
}

function readDeclaredRanges(
  packageJson: Record<string, unknown>,
  nodeRanges: string[],
  npmRanges: string[],
  issues: DiscoveryIssue[],
): void {
  const engines = asRecordOrEmpty(packageJson.engines);
  const volta = asRecordOrEmpty(packageJson.volta);
  for (const range of [engines.node, volta.node])
    if (range !== undefined) addRange(range, nodeRanges, issues);
  for (const range of [engines.npm, volta.npm])
    if (range !== undefined) addRange(range, npmRanges, issues);
}

function addRange(
  value: unknown,
  ranges: string[],
  issues: DiscoveryIssue[],
): void {
  if (typeof value !== "string" || !isValidSemverRange(value)) {
    issues.push({
      code: "unsupported_runtime_range",
      message:
        "A declared Node or npm version range is invalid or unsupported.",
    });
    return;
  }
  ranges.push(value);
}

function createChecks(
  scripts: Record<string, unknown>,
  hasLockfile: boolean,
): {
  id: string;
  status: "configured" | "not-configured" | "blocked";
  executable: string | null;
  arguments: string[];
  reason: string | null;
}[] {
  const definitions = [
    ["typecheck", ["typecheck", "type-check", "check:types", "tsc"]],
    ["lint", ["lint"]],
    ["unit-test", ["test:unit", "unit-test", "test"]],
    ["build", ["build"]],
    ["e2e", ["e2e", "test:e2e", "cy:run"]],
  ] as const;
  const checks: {
    id: string;
    status: "configured" | "not-configured" | "blocked";
    executable: string | null;
    arguments: string[];
    reason: string | null;
  }[] = [
    {
      id: "install",
      status: hasLockfile ? ("configured" as const) : ("blocked" as const),
      executable: "npm",
      arguments: ["ci"],
      reason: hasLockfile ? null : "package-lock.json is required.",
    },
    {
      id: "dependency-tree",
      status: hasLockfile ? ("configured" as const) : ("blocked" as const),
      executable: "npm",
      arguments: ["ls", "--all"],
      reason: hasLockfile ? null : "package-lock.json is required.",
    },
  ];
  for (const [id, names] of definitions) {
    const scriptName = names.find((name) => typeof scripts[name] === "string");
    const status = scriptName
      ? "configured"
      : id === "build"
        ? "blocked"
        : "not-configured";
    checks.push({
      id,
      status,
      executable: scriptName ? "npm" : null,
      arguments: scriptName ? ["run", scriptName] : [],
      reason: scriptName
        ? null
        : id === "build"
          ? "An Angular application must define an npm build script."
          : "No matching npm script was found.",
    });
  }
  return checks;
}

function validateRegistryTrust(
  npmrc: string,
  trustedIpsValue: string,
  hasPrivateDependencies: boolean,
): {
  readonly trusted: boolean;
  readonly identities: {
    readonly scope: string;
    readonly registryId: string;
  }[];
} {
  const registryEntries = new Map<string, string>();
  let trusted = true;
  for (const rawLine of npmrc.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) continue;
    const credential = /(?:_authToken|_auth|password)\s*=\s*([^\s#;]+)/i.exec(
      line,
    );
    if (credential && !/^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/.test(credential[1])) {
      trusted = false;
    }
    const match = /^(@[a-z0-9._-]+:)?registry\s*=\s*(\S+)$/i.exec(line);
    if (match) {
      const scope = match[1]
        ? `${match[1].slice(0, -1).toLowerCase()}:registry`
        : "default";
      registryEntries.set(scope, match[2]);
    }
  }

  const identities = new Map<string, string>([["default", "npmjs"]]);
  for (const [scope, value] of registryEntries) {
    const parsed = safeRegistryUrl(value);
    let registryId = "untrusted";
    if (scope === "default") {
      if (parsed?.href !== "https://registry.npmjs.org/") trusted = false;
    } else if (scope === "@ips:registry") {
      if (matchesTrustedIpsRegistry(value, trustedIpsValue)) {
        registryId = "ips-private";
      } else {
        trusted = false;
      }
    } else {
      trusted = false;
    }
    identities.set(
      scope === "default" ? "default" : scope.replace(/:registry$/, ""),
      registryId,
    );
  }
  if (hasPrivateDependencies) {
    const configured = registryEntries.get("@ips:registry");
    if (
      !configured ||
      !matchesTrustedIpsRegistry(configured, trustedIpsValue)
    ) {
      trusted = false;
      identities.set("@ips", "untrusted");
    }
  }
  return {
    trusted,
    identities: [...identities.entries()]
      .map(([scope, registryId]) => ({ scope, registryId }))
      .sort((left, right) => left.scope.localeCompare(right.scope)),
  };
}

function matchesTrustedIpsRegistry(
  configured: string,
  trusted: string,
): boolean {
  const configuredUrl = safeRegistryUrl(configured);
  const trustedUrl = safeRegistryUrl(trusted);
  return Boolean(
    configuredUrl &&
    trustedUrl &&
    configuredUrl.hostname !== "registry.npmjs.org" &&
    configuredUrl.href.replace(/\/+$/, "") ===
      trustedUrl.href.replace(/\/+$/, ""),
  );
}

function safeRegistryUrl(value: string): URL | null {
  try {
    const url = new URL(value);
    if (
      url.protocol !== "https:" ||
      url.username ||
      url.password ||
      url.search ||
      url.hash
    ) {
      return null;
    }
    return url;
  } catch {
    return null;
  }
}

function isAngularMigrationPackage(name: string): boolean {
  if (name.startsWith("@angular-devkit/") || name.startsWith("@ngtools/"))
    return true;
  if (name === "@angular/cli") return true;
  return (
    name.startsWith("@angular/") &&
    FRAMEWORK_PACKAGES.has(name.slice("@angular/".length))
  );
}

function getTargetSelector(name: string, targetMajor: number): string {
  if (name.startsWith("@angular-devkit/") || name.startsWith("@ngtools/")) {
    if (targetMajor === 6) return ">=0.6.0 <0.7.0";
    if (targetMajor === 7) return ">=0.10.0 <0.14.0";
    return `>=0.${targetMajor}00.0 <0.${targetMajor + 1}00.0`;
  }
  return `${targetMajor}.x`;
}

function parseNpmCandidates(value: string, range: string): NpmCandidate[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value) as unknown;
  } catch {
    return [];
  }
  const values = Array.isArray(parsed) ? parsed : [parsed];
  const candidates: NpmCandidate[] = [];
  for (const item of values) {
    const record = asRecordOrEmpty(item);
    const version = parseExactSemverVersion(record.version);
    if (
      !version ||
      prerelease(version.version) !== null ||
      record.deprecated ||
      !satisfiesAllSemverRanges(version.version, [range])
    ) {
      continue;
    }
    const engines = asRecordOrEmpty(record.engines);
    const peerDependencies = Object.entries(
      asRecordOrEmpty(record.peerDependencies),
    ).map(([name, peerRange]) => ({ name, range: peerRange }));
    if (
      peerDependencies.some(
        ({ name, range }) =>
          !/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(name) ||
          !isValidSemverRange(range),
      )
    ) {
      continue;
    }
    candidates.push({
      version: version.version,
      major: version.major,
      nodeRange: typeof engines.node === "string" ? engines.node : null,
      peerDependencies,
    });
  }
  return candidates.sort((left, right) => compare(right.version, left.version));
}

function parseFnmVersions(text: string): string[] {
  const versions = new Set<string>();
  for (const line of text.split(/\r?\n/)) {
    const match =
      /^\s*(?:\*\s*)?v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?:\s|$)/.exec(
        line,
      );
    if (match && parseExactSemverVersion(match[1])) versions.add(match[1]);
  }
  return [...versions].sort((left, right) => compare(right, left));
}

async function resolveWindowsExecutable(
  name: string,
  environment: Readonly<Record<string, string>>,
): Promise<string | null> {
  const searchPath = environment.PATH ?? environment.Path ?? "";
  const extensions = (environment.PATHEXT ?? ".COM;.EXE;.BAT;.CMD")
    .split(";")
    .filter(Boolean);
  for (const directory of searchPath
    .split(path.win32.delimiter)
    .filter(Boolean)) {
    for (const extension of extensions) {
      const candidate = path.win32.join(
        directory,
        `${name}${extension.toLowerCase()}`,
      );
      try {
        if ((await fs.stat(candidate)).isFile()) return candidate;
      } catch {
        continue;
      }
    }
  }
  return null;
}

async function fingerprintInputs(
  root: string,
  files: ProjectFileSystem,
  trustedRegistry: string,
  gitFingerprint: string,
): Promise<string> {
  const hash = createHash("sha256");
  for (const relative of FINGERPRINT_FILES) {
    const content = await files.readOptionalText(root, relative);
    hash
      .update(relative)
      .update("\0")
      .update(content === null ? "missing" : "present");
    hash
      .update("\0")
      .update(content ?? "")
      .update("\0");
  }
  hash.update("trusted-registry\0").update(trustedRegistry).update("\0");
  hash.update("git-snapshot\0").update(gitFingerprint).update("\0");
  return `sha256:${hash.digest("hex")}`;
}

function successful(result: ProcessResult): result is ProcessResult & {
  readonly kind: "exited";
  readonly exitCode: 0;
} {
  return (
    result.kind === "exited" &&
    result.exitCode === 0 &&
    !result.stdoutTruncated &&
    !result.stderrTruncated
  );
}

function asRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new InfrastructureError(
      "project_facts_invalid",
      "Project metadata has an invalid object shape.",
    );
  }
  return value as Record<string, unknown>;
}

function asRecordOrEmpty(value: unknown): Record<string, any> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, any>)
    : {};
}
