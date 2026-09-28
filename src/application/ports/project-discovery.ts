import type { AngularMajor, ProjectId } from "../../domain/identity.js";
import type { RuntimeCandidate } from "../../domain/runtime-planner.js";

export interface DiscoveryCheck {
  readonly id: string;
  readonly status: "configured" | "not-configured" | "blocked";
  readonly executable: string | null;
  readonly arguments: readonly string[];
  readonly reason: string | null;
}

export interface DiscoveryPackage {
  readonly name: string;
  readonly sourceVersion: string;
  readonly targetVersion: string;
  readonly registryId: string;
  readonly nodeRange: string | null;
  readonly peerDependencies: readonly {
    readonly name: string;
    readonly range: string;
  }[];
  readonly reason: string;
}

export interface DiscoveryIssue {
  readonly code: string;
  readonly message: string;
}

export interface DiscoveryRegistryIdentity {
  readonly scope: string;
  readonly registryId: string;
}

export interface ProjectDiscoveryInputs {
  readonly projectId: ProjectId;
  readonly inputFingerprint: string;
  readonly sourceMajor: AngularMajor;
  readonly projectShape: string;
  readonly packageManager: string;
  readonly lockfileVersion: number;
  readonly gitStatus: "clean" | "dirty" | "unavailable";
  readonly registryStatus: "trusted" | "untrusted";
  readonly dependencySourcesStatus: "safe" | "unsafe";
  readonly nodeRanges: readonly string[];
  readonly npmRange: string;
  readonly runtimeCandidates: readonly RuntimeCandidate[];
  readonly metadataRuntimeVersion: string | null;
  readonly checks: readonly DiscoveryCheck[];
  readonly packages: readonly DiscoveryPackage[];
  readonly registryIdentities: readonly DiscoveryRegistryIdentity[];
  readonly issues?: readonly DiscoveryIssue[];
}

export interface ProjectDiscoveryReader {
  read(projectRoot: string, targetMajor: number): Promise<unknown>;
}

export interface DiscoveryRecordStore {
  read(projectRoot: string): Promise<unknown>;
  write(projectRoot: string, record: unknown): Promise<void>;
}

export interface ValueHasher {
  hash(value: unknown): Promise<string>;
}
