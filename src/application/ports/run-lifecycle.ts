import type { RunStage, RunState, RunStatus } from "../../domain/run-state.js";
import type { DiscoveryRecord } from "../discover-project.js";

export interface RunEvent {
  readonly sequence: number;
  readonly type:
    | "run-started"
    | "stage-started"
    | "stage-completed"
    | "stage-blocked"
    | "stage-failed"
    | "check-skipped"
    | "stage-needs-repair"
    | "repair-accepted"
    | "repair-rejected"
    | "baseline-dependency-approval-started"
    | "baseline-dependency-approval-failed"
    | "baseline-dependencies-approved"
    | "documentation-research-recorded"
    | "documentation-publish-started"
    | "documentation-published";
  readonly stage: RunStage;
  readonly status: RunStatus;
  readonly revision: number;
  readonly skip?: {
    readonly checkId: string;
    readonly reason: string;
    readonly confirmed: true;
  };
  readonly repair?: {
    readonly attempt: number;
    readonly fingerprint: string;
    readonly submissionHash: string;
    readonly changedPaths: readonly string[];
    readonly outcome: "accepted" | "rejected";
  };
  readonly baselineApproval?: {
    readonly proposalHash: string;
    readonly packages: readonly {
      readonly name: string;
      readonly version: string;
    }[];
    readonly outcome: "started" | "failed" | "installed";
    readonly packageStateHash: string | null;
  };
  readonly documentation?: {
    readonly outcome: "research-recorded" | "publish-started" | "published";
    readonly researchHash: string;
    readonly proposalHash: string | null;
    readonly filesHash: string | null;
    readonly outputDirectory: string | null;
    readonly expectedGitSnapshot: {
      readonly head: string;
      readonly changes: readonly {
        readonly path: string;
        readonly status: string;
      }[];
    } | null;
  };
}

export interface RunCheckpoint {
  readonly sequence: number;
  readonly stage: RunStage;
  readonly operationId: string;
  readonly phase: "before" | "after" | "skipped";
  readonly projectFingerprint: string;
  readonly idempotencyKey: string;
}

export interface RunRecord {
  readonly schemaVersion: 1;
  readonly state: RunState;
  readonly discoveryPlan: DiscoveryRecord;
  readonly events: readonly RunEvent[];
  readonly checkpoints: readonly RunCheckpoint[];
  readonly diagnostic: {
    readonly code: string;
    readonly message: string;
  } | null;
  readonly recordHash: string;
}

export interface RunRecordStore {
  read(projectRoot: string): Promise<unknown>;
  write(projectRoot: string, record: RunRecord): Promise<void>;
}

export interface RunHookRuntimeDeployer {
  deploy(projectRoot: string): Promise<void>;
}

export type RunLockReleaseResult =
  | { readonly kind: "released" }
  | { readonly kind: "ownership-lost" }
  | { readonly kind: "recovery-required" };

export type RunLockResult =
  | { readonly kind: "contended" }
  | { readonly kind: "recovery-required" }
  | {
      readonly kind: "acquired";
      readonly release: () => Promise<RunLockReleaseResult>;
    };

export interface RunLock {
  acquire(projectRoot: string): Promise<RunLockResult>;
}

export interface RunIdGenerator {
  create(): string;
}

export interface RunStatusStore {
  read(projectRoot: string): Promise<unknown>;
}

export interface RunProjectContextReader {
  readProjectFacts(projectRoot: string): Promise<{
    readonly projectId: string;
    readonly angularMajor: number;
  }>;
  readFingerprint(projectRoot: string): Promise<string>;
}

export interface ProjectFingerprintReader {
  readFingerprint(projectRoot: string): Promise<string>;
}

export interface RunOperation {
  readonly id: string;
  readonly kind: "process" | "pin-packages" | "verify-plan";
  readonly stage: RunStage;
  readonly executable: string | null;
  readonly arguments: readonly string[];
  readonly nodeVersion: string;
  readonly timeoutMs: number;
  readonly postcondition:
    | "exit-zero"
    | "dependency-tree"
    | "package-metadata-stable"
    | "target-packages-declared"
    | "target-packages-locked"
    | "verify-plan";
  readonly packages: readonly {
    readonly name: string;
    readonly targetVersion: string;
  }[];
}

export type RunOperationResult =
  | { readonly outcome: "passed" }
  | {
      readonly outcome: "blocked" | "failed";
      readonly diagnostic: { readonly code: string; readonly message: string };
    };

export interface RunOperationExecutor {
  execute(
    projectRoot: string,
    operation: RunOperation,
  ): Promise<RunOperationResult>;
}
