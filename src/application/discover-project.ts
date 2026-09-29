import { createAngularTransition } from "../domain/angular-transition.js";
import { createAngularMajor, createProjectId } from "../domain/identity.js";
import { planRuntime, type RuntimePlan } from "../domain/runtime-planner.js";
import {
  isValidSemverRange,
  parseExactSemverVersion,
} from "../domain/semver-constraints.js";
import { ApplicationError } from "./application-error.js";
import type {
  DiscoveryCheck,
  DiscoveryPackage,
  DiscoveryRecordStore,
  DiscoveryRegistryIdentity,
  ProjectDiscoveryInputs,
  ProjectDiscoveryReader,
  ValueHasher,
} from "./ports/project-discovery.js";

export interface DiscoveryRecord {
  readonly schemaVersion: 1;
  readonly projectId: string;
  readonly inputFingerprint: string;
  readonly sourceMajor: number;
  readonly targetMajor: number;
  readonly status: "ready" | "runtime-install-required" | "blocked";
  readonly lockfileVersion: number;
  readonly checks: readonly DiscoveryCheck[];
  readonly packages: readonly DiscoveryPackage[];
  readonly registryIdentities: readonly DiscoveryRegistryIdentity[];
  readonly runtimePlan: RuntimePlan & {
    readonly nodeRanges: readonly string[];
    readonly npmRange: string;
    readonly metadataNodeVersion: string | null;
    readonly operations: readonly string[];
  };
  readonly blockers: readonly {
    readonly code: string;
    readonly message: string;
  }[];
  readonly planHash: string;
}

export interface DiscoverProjectPorts {
  readonly reader: ProjectDiscoveryReader;
  readonly records: DiscoveryRecordStore;
  readonly hasher: ValueHasher;
}

export async function discoverProject(
  request: { readonly projectRoot: string; readonly targetMajor: number },
  ports: DiscoverProjectPorts,
): Promise<DiscoveryRecord> {
  if (
    !request ||
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0
  ) {
    throw new ApplicationError(
      "project_root_invalid",
      "A project root is required for discovery.",
    );
  }
  const rawInputs = await ports.reader.read(
    request.projectRoot,
    request.targetMajor,
  );
  const inputs = validateInputs(rawInputs);
  const transition = createAngularTransition(
    inputs.sourceMajor,
    createAngularMajor(request.targetMajor),
  );
  const blockers = collectBlockers(inputs, transition.targetMajor);
  const nodeRanges = [
    ...inputs.nodeRanges,
    ...inputs.packages.flatMap((item) =>
      item.nodeRange ? [item.nodeRange] : [],
    ),
  ];
  const npmRanges = [
    inputs.npmRange,
    inputs.lockfileVersion === 1 ? ">=5" : ">=7",
  ];
  const runtimePlan = planRuntime({
    nodeRanges,
    npmRange: npmRanges.join(" "),
    candidates: inputs.runtimeCandidates,
  });

  if (runtimePlan.status === "blocked") {
    blockers.push({
      code: "runtime_version_unavailable",
      message:
        "No exact fnm runtime satisfies the discovered Node and npm constraints.",
    });
  }
  const status: DiscoveryRecord["status"] =
    blockers.length > 0
      ? "blocked"
      : runtimePlan.status === "runtime-install-required"
        ? "runtime-install-required"
        : "ready";
  const content = {
    schemaVersion: 1 as const,
    projectId: inputs.projectId,
    inputFingerprint: inputs.inputFingerprint,
    sourceMajor: transition.sourceMajor,
    targetMajor: transition.targetMajor,
    status,
    lockfileVersion: inputs.lockfileVersion,
    checks: [...inputs.checks].sort((left, right) =>
      left.id.localeCompare(right.id),
    ),
    packages: [...inputs.packages].sort((left, right) =>
      left.name.localeCompare(right.name),
    ),
    registryIdentities: [...inputs.registryIdentities].sort((left, right) =>
      left.scope.localeCompare(right.scope),
    ),
    runtimePlan: {
      ...runtimePlan,
      nodeRanges: [...new Set(nodeRanges)].sort(),
      npmRange: npmRanges.join(" "),
      metadataNodeVersion: inputs.metadataRuntimeVersion,
      operations: [
        "npm ci",
        "npm ls --all",
        "npm exec -- ng update",
        "npm install --package-lock-only --ignore-scripts",
        ...inputs.checks
          .filter((check) => check.status === "configured")
          .map((check) => `${check.executable} ${check.arguments.join(" ")}`),
      ].sort(),
    },
    blockers: blockers.sort((left, right) =>
      left.code.localeCompare(right.code),
    ),
  };
  const planHash = await ports.hasher.hash(content);
  if (!isSha256(planHash)) {
    throw new ApplicationError(
      "discovery_hash_invalid",
      "The discovery plan could not be integrity-bound.",
    );
  }
  const record: DiscoveryRecord = { ...content, planHash };
  await ports.records.write(request.projectRoot, record);
  return record;
}

export async function readValidatedDiscoveryRecord(
  value: unknown,
  expected: {
    readonly projectId: string;
    readonly inputFingerprint: string;
    readonly targetMajor: number;
  },
  hasher: ValueHasher,
): Promise<DiscoveryRecord> {
  if (!isDiscoveryRecord(value)) {
    throw new ApplicationError(
      "discovery_invalid",
      "The persisted discovery record is invalid.",
    );
  }
  const { planHash, ...content } = value;
  if ((await hasher.hash(content)) !== planHash) {
    throw new ApplicationError(
      "discovery_integrity_failed",
      "The persisted discovery record has been altered.",
    );
  }
  if (
    value.projectId !== expected.projectId ||
    value.targetMajor !== expected.targetMajor
  ) {
    throw new ApplicationError(
      "discovery_context_mismatch",
      "The discovery record does not describe the requested project or target.",
    );
  }
  if (value.inputFingerprint !== expected.inputFingerprint) {
    throw new ApplicationError(
      "discovery_stale",
      "Project inputs changed after discovery.",
    );
  }
  return value;
}

function validateInputs(value: unknown): ProjectDiscoveryInputs {
  if (!isRecord(value)) invalidInputs();
  try {
    const projectId = createProjectId(value.projectId);
    const sourceMajor = createAngularMajor(value.sourceMajor);
    if (
      !isSha256(value.projectId) ||
      !isSha256(value.inputFingerprint) ||
      typeof value.projectShape !== "string" ||
      typeof value.packageManager !== "string" ||
      !Number.isSafeInteger(value.lockfileVersion) ||
      !Array.isArray(value.nodeRanges) ||
      !Array.isArray(value.runtimeCandidates) ||
      (value.metadataRuntimeVersion !== null &&
        parseExactSemverVersion(value.metadataRuntimeVersion) === null) ||
      !Array.isArray(value.checks) ||
      !Array.isArray(value.packages) ||
      !Array.isArray(value.registryIdentities) ||
      (value.issues !== undefined && !Array.isArray(value.issues)) ||
      typeof value.npmRange !== "string"
    ) {
      invalidInputs();
    }
    const gitStatus = value.gitStatus;
    const registryStatus = value.registryStatus;
    const dependencySourcesStatus = value.dependencySourcesStatus;
    if (
      !["clean", "dirty", "unavailable"].includes(String(gitStatus)) ||
      !["trusted", "untrusted"].includes(String(registryStatus)) ||
      !["safe", "unsafe"].includes(String(dependencySourcesStatus)) ||
      value.nodeRanges.some((range: unknown) => !isValidSemverRange(range)) ||
      !isValidSemverRange(value.npmRange) ||
      !value.checks.every(isDiscoveryCheck) ||
      !value.packages.every(isDiscoveryPackage) ||
      !value.registryIdentities.every(isRegistryIdentity) ||
      (value.issues !== undefined && !value.issues.every(isDiscoveryIssue))
    ) {
      invalidInputs();
    }
    return {
      projectId,
      inputFingerprint: value.inputFingerprint,
      sourceMajor,
      projectShape: value.projectShape,
      packageManager: value.packageManager,
      lockfileVersion: value.lockfileVersion,
      gitStatus,
      registryStatus,
      dependencySourcesStatus,
      nodeRanges: value.nodeRanges,
      npmRange: value.npmRange,
      runtimeCandidates: value.runtimeCandidates,
      metadataRuntimeVersion: value.metadataRuntimeVersion,
      checks: value.checks,
      packages: value.packages,
      registryIdentities: value.registryIdentities,
      issues: value.issues,
    } as ProjectDiscoveryInputs;
  } catch (error) {
    if (error instanceof ApplicationError) throw error;
    invalidInputs();
  }
}

function collectBlockers(
  inputs: ProjectDiscoveryInputs,
  targetMajor: number,
): { code: string; message: string }[] {
  const blockers: { code: string; message: string }[] = [];
  if (inputs.projectShape !== "root-angular-cli")
    blockers.push(
      blocker(
        "unsupported_project_layout",
        "Only a root Angular CLI project is supported.",
      ),
    );
  for (const issue of inputs.issues ?? []) blockers.push(issue);
  if (inputs.packageManager !== "npm")
    blockers.push(
      blocker("unsupported_package_manager", "Only npm is supported."),
    );
  if (![1, 2, 3].includes(inputs.lockfileVersion))
    blockers.push(
      blocker(
        "unsupported_lockfile",
        "The npm lockfile version is unsupported.",
      ),
    );
  if (inputs.gitStatus !== "clean")
    blockers.push(
      blocker("git_worktree_dirty", "The Git working tree must be clean."),
    );
  if (inputs.registryStatus !== "trusted")
    blockers.push(
      blocker(
        "registry_untrusted",
        "The configured package registry is not trusted.",
      ),
    );
  if (
    !inputs.registryIdentities.some(
      (identity) =>
        identity.scope === "default" && identity.registryId === "npmjs",
    ) ||
    inputs.registryIdentities.some(
      (identity) => identity.registryId === "untrusted",
    )
  ) {
    blockers.push(
      blocker(
        "registry_identity_invalid",
        "The plan contains an untrusted or missing registry identity.",
      ),
    );
  }
  if (inputs.dependencySourcesStatus !== "safe")
    blockers.push(
      blocker(
        "unsafe_dependency_source",
        "Dependencies must use trusted npm registry sources.",
      ),
    );
  if (inputs.checks.some((check) => check.status === "blocked"))
    blockers.push(
      blocker(
        "project_check_blocked",
        "A required project check is not configured.",
      ),
    );

  const names = new Set<string>();
  for (const item of inputs.packages) {
    if (names.has(item.name))
      blockers.push(
        blocker(
          "duplicate_package_metadata",
          `Duplicate metadata for ${item.name}.`,
        ),
      );
    names.add(item.name);
    if (
      !parseExactSemverVersion(item.sourceVersion) ||
      !parseExactSemverVersion(item.targetVersion) ||
      !/^[a-z0-9][a-z0-9._:-]{0,127}$/.test(item.registryId)
    ) {
      blockers.push(
        blocker(
          "package_metadata_invalid",
          `Invalid exact metadata for ${item.name}.`,
        ),
      );
    }
    if (
      item.name.startsWith("@angular/") &&
      !item.name.startsWith("@angular-devkit/")
    ) {
      const sourceVersion = parseExactSemverVersion(item.sourceVersion);
      const targetVersion = parseExactSemverVersion(item.targetVersion);
      if (
        !sourceVersion ||
        sourceVersion.major !== inputs.sourceMajor ||
        !targetVersion ||
        targetVersion.major !== targetMajor
      )
        blockers.push(
          blocker(
            "angular_package_major_mismatch",
            `Registry metadata for ${item.name} does not match the requested N-to-N+1 transition.`,
          ),
        );
    }
  }
  if (!names.has("@angular/core"))
    blockers.push(
      blocker(
        "angular_core_metadata_missing",
        "Target @angular/core metadata is required.",
      ),
    );
  return blockers;
}

function isDiscoveryRecord(value: unknown): value is DiscoveryRecord {
  return Boolean(
    isRecord(value) &&
    value.schemaVersion === 1 &&
    isSha256(value.projectId) &&
    isSha256(value.inputFingerprint) &&
    Number.isSafeInteger(value.sourceMajor) &&
    Number.isSafeInteger(value.targetMajor) &&
    ["ready", "runtime-install-required", "blocked"].includes(
      String(value.status),
    ) &&
    [1, 2, 3].includes(Number(value.lockfileVersion)) &&
    Array.isArray(value.checks) &&
    value.checks.every(isDiscoveryCheck) &&
    Array.isArray(value.packages) &&
    value.packages.every(isDiscoveryPackage) &&
    Array.isArray(value.registryIdentities) &&
    value.registryIdentities.every(isRegistryIdentity) &&
    isRecord(value.runtimePlan) &&
    ["ready", "runtime-install-required", "blocked"].includes(
      String(value.runtimePlan.status),
    ) &&
    Array.isArray(value.runtimePlan.nodeRanges) &&
    value.runtimePlan.nodeRanges.every(isValidSemverRange) &&
    isValidSemverRange(value.runtimePlan.npmRange) &&
    Array.isArray(value.runtimePlan.operations) &&
    value.runtimePlan.operations.every(
      (operation: unknown) => typeof operation === "string",
    ) &&
    (value.runtimePlan.metadataNodeVersion === null ||
      parseExactSemverVersion(value.runtimePlan.metadataNodeVersion) !==
        null) &&
    isRuntimePlan(value.runtimePlan) &&
    Array.isArray(value.blockers) &&
    value.blockers.every(
      (item: unknown) =>
        isRecord(item) &&
        typeof item.code === "string" &&
        /^[a-z][a-z0-9_]{0,63}$/.test(item.code) &&
        typeof item.message === "string",
    ) &&
    isSha256(value.planHash) &&
    value.targetMajor === value.sourceMajor + 1 &&
    (value.status !== "ready" ||
      (value.runtimePlan.status === "ready" &&
        value.runtimePlan.selected?.status === "installed" &&
        value.blockers.length === 0)) &&
    (value.status !== "runtime-install-required" ||
      (value.runtimePlan.status === "runtime-install-required" &&
        value.runtimePlan.selected?.status === "missing" &&
        value.blockers.length === 0)),
  );
}

function isDiscoveryCheck(value: unknown): value is DiscoveryCheck {
  if (!isRecord(value)) return false;
  const executableValid =
    value.executable === null ||
    (typeof value.executable === "string" &&
      value.executable.trim().length > 0 &&
      !/[\0\r\n]/.test(value.executable));
  const reasonValid =
    value.reason === null ||
    (typeof value.reason === "string" &&
      value.reason.trim().length > 0 &&
      !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(value.reason));
  return (
    typeof value.id === "string" &&
    /^[a-z][a-z0-9-]{0,63}$/.test(value.id) &&
    ["configured", "not-configured", "blocked"].includes(
      String(value.status),
    ) &&
    executableValid &&
    Array.isArray(value.arguments) &&
    value.arguments.every(
      (argument: unknown) =>
        typeof argument === "string" && !/[\0\r\n]/.test(argument),
    ) &&
    reasonValid &&
    (value.status !== "configured" ||
      (typeof value.executable === "string" && value.reason === null)) &&
    (value.status !== "not-configured" ||
      (value.executable === null &&
        value.arguments.length === 0 &&
        typeof value.reason === "string")) &&
    (value.status !== "blocked" || typeof value.reason === "string")
  );
}

function isDiscoveryPackage(value: unknown): value is DiscoveryPackage {
  return Boolean(
    isRecord(value) &&
    typeof value.name === "string" &&
    /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(value.name) &&
    typeof value.sourceVersion === "string" &&
    typeof value.targetVersion === "string" &&
    parseExactSemverVersion(value.sourceVersion) !== null &&
    parseExactSemverVersion(value.targetVersion) !== null &&
    typeof value.registryId === "string" &&
    /^[a-z0-9][a-z0-9._:-]{0,127}$/.test(value.registryId) &&
    (value.nodeRange === null || isValidSemverRange(value.nodeRange)) &&
    Array.isArray(value.peerDependencies) &&
    value.peerDependencies.every(
      (peer: unknown) =>
        isRecord(peer) &&
        typeof peer.name === "string" &&
        /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(peer.name) &&
        isValidSemverRange(peer.range),
    ) &&
    typeof value.reason === "string" &&
    value.reason.length > 0 &&
    !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(value.reason),
  );
}

function isRegistryIdentity(
  value: unknown,
): value is DiscoveryRegistryIdentity {
  return Boolean(
    isRecord(value) &&
    typeof value.scope === "string" &&
    /^(?:default|@[a-z0-9._-]+)$/.test(value.scope) &&
    typeof value.registryId === "string" &&
    /^[a-z0-9][a-z0-9._:-]{0,127}$/.test(value.registryId),
  );
}

function isRuntimePlan(value: Record<string, any>): boolean {
  const selected = value.selected;
  if (value.status === "ready")
    return (
      isRuntimeCandidate(selected) &&
      selected.status === "installed" &&
      value.reason === null
    );
  if (value.status === "runtime-install-required")
    return (
      isRuntimeCandidate(selected) &&
      selected.status === "missing" &&
      value.reason === "exact-runtime-missing"
    );
  return (
    value.status === "blocked" &&
    selected === null &&
    ["invalid-runtime-constraints", "no-compatible-runtime"].includes(
      String(value.reason),
    )
  );
}

function isRuntimeCandidate(value: unknown): value is {
  readonly nodeVersion: string;
  readonly npmVersion: string | null;
  readonly status: "installed" | "missing";
} {
  return Boolean(
    isRecord(value) &&
    parseExactSemverVersion(value.nodeVersion) !== null &&
    (value.status === "installed" || value.status === "missing") &&
    (value.status === "installed"
      ? parseExactSemverVersion(value.npmVersion) !== null
      : value.npmVersion === null),
  );
}

function isDiscoveryIssue(value: unknown): boolean {
  return Boolean(
    isRecord(value) &&
    typeof value.code === "string" &&
    /^[a-z][a-z0-9_]{0,63}$/.test(value.code) &&
    typeof value.message === "string" &&
    !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(value.message),
  );
}

function isRecord(value: unknown): value is Record<string, any> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function isSha256(value: unknown): value is string {
  return typeof value === "string" && /^sha256:[a-f0-9]{64}$/.test(value);
}

function blocker(code: string, message: string) {
  return { code, message };
}

function invalidInputs(): never {
  throw new ApplicationError(
    "discovery_inputs_invalid",
    "Project discovery returned malformed or unsupported input.",
  );
}
