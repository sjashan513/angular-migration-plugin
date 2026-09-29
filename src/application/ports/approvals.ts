import type { DiscoveryRecord } from "../discover-project.js";
import type { RunRecord } from "./run-lifecycle.js";

export interface RuntimeInstallAuditEvent {
  readonly sequence: number;
  readonly projectId: string;
  readonly inputFingerprint: string;
  readonly proposalHash: string;
  readonly nodeVersion: string;
  readonly outcome: "started" | "installed" | "failed";
  readonly previousHash: string | null;
  readonly eventHash: string;
}

export interface RuntimeInstallAuditStore {
  read(projectRoot: string): Promise<unknown>;
  write(
    projectRoot: string,
    events: readonly RuntimeInstallAuditEvent[],
  ): Promise<void>;
}

export interface ExactRuntimeInstaller {
  install(
    projectRoot: string,
    nodeVersion: string,
  ): Promise<"installed" | "failed">;
}

export interface RuntimeInstallApprovalResult {
  readonly status: "installed";
  readonly proposalHash: string;
  readonly nodeVersion: string;
  readonly discovery: DiscoveryRecord;
}

export interface BaselineDependencyProposalPackage {
  readonly name: string;
  readonly installVersion: string;
  readonly requiredRanges: readonly string[];
  readonly requiredBy: readonly string[];
}

export interface BaselineDependencyProposalReader {
  read(projectRoot: string, run: RunRecord): Promise<unknown>;
}

export interface BaselineDependencyInstaller {
  install(input: {
    readonly projectRoot: string;
    readonly runId: string;
    readonly nodeVersion: string;
    readonly packages: readonly BaselineDependencyProposalPackage[];
  }): Promise<{
    readonly outcome: "installed" | "failed";
    readonly packageStateHash: string | null;
  }>;
}
