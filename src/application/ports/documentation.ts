export interface DocumentationGitSnapshot {
  readonly head: string;
  readonly changes: readonly {
    readonly path: string;
    readonly status: string;
  }[];
}

import type { ValueHasher } from "./project-discovery.js";
import type {
  ProjectFingerprintReader,
  RunLock,
  RunProjectContextReader,
  RunRecord,
} from "./run-lifecycle.js";

export interface DocumentationSource {
  readonly id: string;
  readonly title: string;
  readonly url: string;
  readonly publisher: string;
  readonly primary: boolean;
  readonly accessedAt: string;
}

export interface DocumentationResearchFinding {
  readonly id: string;
  readonly kind:
    | "official-change"
    | "observed-change"
    | "inference"
    | "not-applicable";
  readonly title: string;
  readonly area: string;
  readonly summary: string;
  readonly affectedPackages: readonly string[];
  readonly sourceIds: readonly string[];
  readonly applicability:
    | "unknown-until-verified"
    | "applicable"
    | "not-applicable";
}

export interface DocumentationResearchSubmission {
  readonly schemaVersion: 1;
  readonly runId: string;
  readonly sourceMajor: number;
  readonly targetMajor: number;
  readonly planHash: string;
  readonly researchedAt: string;
  readonly sources: readonly DocumentationSource[];
  readonly findings: readonly DocumentationResearchFinding[];
  readonly concepts: readonly {
    readonly id: string;
    readonly name: string;
    readonly whyItMatters: string;
    readonly sourceIds: readonly string[];
  }[];
  readonly unresolved: readonly {
    readonly id: string;
    readonly question: string;
    readonly critical: boolean;
    readonly sourceIds: readonly string[];
  }[];
}

export interface DocumentationFile {
  readonly path: string;
  readonly content: string;
  readonly sha256: string;
}

export interface DocumentationClaim {
  readonly id: string;
  readonly kind: DocumentationResearchFinding["kind"];
  readonly document: string;
  readonly evidence: readonly string[];
}

export interface DocumentationPublishSubmission {
  readonly schemaVersion: 1;
  readonly runId: string;
  readonly planHash: string;
  readonly researchHash: string;
  readonly outputDirectory: string;
  readonly files: readonly DocumentationFile[];
  readonly claims: readonly DocumentationClaim[];
  readonly remainingWarnings: readonly string[];
}

export interface DocumentationPublicationRecord {
  readonly schemaVersion: 1;
  readonly runId: string;
  readonly planHash: string;
  readonly researchHash: string;
  readonly proposalHash: string;
  readonly filesHash: string;
  readonly outputDirectory: string;
  readonly files: readonly { readonly path: string; readonly sha256: string }[];
}

export interface DocumentationArtifactStore {
  readResearchSubmission(projectRoot: string, runId: string): Promise<unknown>;
  readPublishSubmission(projectRoot: string, runId: string): Promise<unknown>;
  readResearch(projectRoot: string, runId: string): Promise<unknown>;
  readPublication(projectRoot: string, runId: string): Promise<unknown>;
  writeResearch(
    projectRoot: string,
    runId: string,
    record: {
      readonly schemaVersion: 1;
      readonly runId: string;
      readonly planHash: string;
      readonly researchHash: string;
      readonly submission: DocumentationResearchSubmission;
    },
  ): Promise<void>;
  writePublication(
    projectRoot: string,
    runId: string,
    record: DocumentationPublicationRecord,
  ): Promise<void>;
  inspectOutput(
    projectRoot: string,
    outputDirectory: string,
  ): Promise<
    readonly { readonly path: string; readonly sha256: string }[] | null
  >;
  inspectGitSnapshot(
    projectRoot: string,
    nodeVersion: string,
  ): Promise<DocumentationGitSnapshot>;
  publishFiles(input: {
    readonly projectRoot: string;
    readonly outputDirectory: string;
    readonly expectedExistingFiles:
      | readonly { readonly path: string; readonly sha256: string }[]
      | null;
    readonly expectedGitSnapshot: DocumentationGitSnapshot;
    readonly nodeVersion: string;
    readonly files: readonly DocumentationFile[];
  }): Promise<string>;
}

export interface DocumentationRunStore {
  read(projectRoot: string): Promise<unknown>;
  write(projectRoot: string, record: RunRecord): Promise<void>;
}

export interface DocumentationWorkflowPorts {
  readonly runs: DocumentationRunStore;
  readonly lock: RunLock;
  readonly fingerprints: ProjectFingerprintReader;
  readonly context: RunProjectContextReader;
  readonly artifacts: DocumentationArtifactStore;
  readonly hasher: ValueHasher;
  readonly contentHasher: DocumentationContentHasher;
}

export interface DocumentationContentHasher {
  hashText(content: string): Promise<string>;
}
