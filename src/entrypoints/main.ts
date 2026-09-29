import path from "node:path";
import { fileURLToPath } from "node:url";
import { approveCheckSkip } from "../application/approve-check-skip.js";
import { approveRuntimeInstall } from "../application/approve-runtime-install.js";
import {
  approveBaselineDependencies,
  getBaselineDependencyContext,
} from "../application/baseline-dependencies.js";
import { discoverProject } from "../application/discover-project.js";
import {
  getDocumentationPublishContext,
  publishDocumentation,
} from "../application/documentation-publish.js";
import {
  getDocumentationResearchContext,
  recordDocumentationResearch,
} from "../application/documentation-research.js";
import { inspectProject } from "../application/inspect-project.js";
import { getRepairContext, recordRepair } from "../application/repair-run.js";
import { runProject } from "../application/run-project.js";
import { startRun } from "../application/start-run.js";
import { getRunStatus } from "../application/status-run.js";
import {
  NpmBaselineDependencyInstaller,
  NpmBaselineDependencyProposalReader,
} from "../infrastructure/baseline-dependencies.js";
import {
  DiscoveryRecordStoreAdapter,
  ProjectValueHasher,
} from "../infrastructure/discovery-persistence.js";
import { DocumentationArtifactStoreAdapter } from "../infrastructure/documentation-store.js";
import { HookRuntimeDeployer } from "../infrastructure/hook-runtime.js";
import { ProjectDiscoveryReaderAdapter } from "../infrastructure/project-discovery-reader.js";
import { ProjectFactsReaderAdapter } from "../infrastructure/project-facts-reader.js";
import { ProjectLock } from "../infrastructure/project-lock.js";
import { SafeRepairPatchWriter } from "../infrastructure/repair-files.js";
import { RepairSubmissionStoreAdapter } from "../infrastructure/repair-submission-store.js";
import { CryptoRunIdGenerator } from "../infrastructure/run-id-generator.js";
import { RunOperationExecutorAdapter } from "../infrastructure/run-operation-executor.js";
import { RunRecordStoreAdapter } from "../infrastructure/run-record-store.js";
import {
  FnmExactRuntimeInstaller,
  RuntimeInstallAuditStoreAdapter,
} from "../infrastructure/runtime-install.js";
import { dispatchCli } from "./cli.js";

function currentEnvironment(): Record<string, string> {
  return Object.fromEntries(
    Object.entries(process.env).filter(
      (entry): entry is [string, string] => typeof entry[1] === "string",
    ),
  );
}

async function main(): Promise<void> {
  const environment = currentEnvironment();
  const pluginRoot =
    environment.ANGULAR_MIGRATION_PLUGIN_ROOT ??
    path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
  const hookRuntime = new HookRuntimeDeployer(pluginRoot);
  const reader = new ProjectDiscoveryReaderAdapter({ environment });
  const discoveries = new DiscoveryRecordStoreAdapter();
  const runRecords = new RunRecordStoreAdapter();
  const repairSubmissions = new RepairSubmissionStoreAdapter();
  const repairPatches = new SafeRepairPatchWriter();
  const runtimeInstallAudit = new RuntimeInstallAuditStoreAdapter();
  const documentationArtifacts = new DocumentationArtifactStoreAdapter();
  const facts = new ProjectFactsReaderAdapter();
  const lock = new ProjectLock();
  const ids = new CryptoRunIdGenerator();
  const hasher = new ProjectValueHasher();
  const documentationPorts = {
    runs: runRecords,
    lock,
    fingerprints: reader,
    context: {
      readProjectFacts: (root: string) => facts.readProjectFacts(root),
      readFingerprint: (root: string) => reader.readFingerprint(root),
    },
    artifacts: documentationArtifacts,
    hasher,
    contentHasher: hasher,
  };
  const operations = new RunOperationExecutorAdapter({
    environment,
    fnmExecutable: "fnm",
  });
  const runtimeInstaller = new FnmExactRuntimeInstaller({
    environment,
    fnmExecutable: "fnm",
  });
  const baselineProposalReader = new NpmBaselineDependencyProposalReader({
    environment,
    fnmExecutable: "fnm",
  });
  const baselineDependencyInstaller = new NpmBaselineDependencyInstaller({
    environment,
    fnmExecutable: "fnm",
  });
  const result = await dispatchCli(process.argv.slice(2), {
    inspect: (projectRoot) => inspectProject({ projectRoot }, { facts }),
    discover: (projectRoot, targetMajor) =>
      discoverProject(
        { projectRoot, targetMajor },
        {
          reader,
          records: discoveries,
          hasher,
        },
      ),
    approveRuntime: (projectRoot, targetMajor, proposalHash, confirmed) =>
      approveRuntimeInstall(
        { projectRoot, targetMajor, proposalHash, confirmed },
        {
          reader,
          records: discoveries,
          hasher,
          runRecords,
          lock,
          installer: runtimeInstaller,
          audit: runtimeInstallAudit,
        },
      ),
    baselineDependencyContext: (projectRoot, runId) =>
      getBaselineDependencyContext(
        { projectRoot, runId },
        {
          records: runRecords,
          lock,
          fingerprints: reader,
          proposals: baselineProposalReader,
          installer: baselineDependencyInstaller,
          hasher,
        },
      ),
    approveBaselineDependencies: (
      projectRoot,
      runId,
      proposalHash,
      confirmed,
    ) =>
      approveBaselineDependencies(
        { projectRoot, runId, proposalHash, confirmed },
        {
          records: runRecords,
          lock,
          fingerprints: reader,
          proposals: baselineProposalReader,
          installer: baselineDependencyInstaller,
          hasher,
        },
      ),
    skipCheck: (projectRoot, runId, checkId, reason, confirmed) =>
      approveCheckSkip(
        { projectRoot, runId, checkId, reason, confirmed },
        { records: runRecords, lock, fingerprints: reader, hasher },
      ),
    repairContext: (projectRoot, runId) =>
      getRepairContext(
        { projectRoot, runId },
        {
          records: runRecords,
          lock,
          fingerprints: reader,
          operations,
          patches: repairPatches,
          hasher,
        },
      ),
    recordRepair: async (projectRoot, runId) =>
      recordRepair(
        {
          projectRoot,
          runId,
          submission: await repairSubmissions.read(projectRoot, runId),
        },
        {
          records: runRecords,
          lock,
          fingerprints: reader,
          operations,
          patches: repairPatches,
          hasher,
        },
      ),
    documentationResearchContext: (projectRoot, runId) =>
      getDocumentationResearchContext(
        { projectRoot, runId },
        documentationPorts,
      ),
    recordDocumentationResearch: (projectRoot, runId) =>
      recordDocumentationResearch({ projectRoot, runId }, documentationPorts),
    documentationPublishContext: (projectRoot, runId) =>
      getDocumentationPublishContext(
        { projectRoot, runId },
        documentationPorts,
      ),
    publishDocumentation: (projectRoot, runId, proposalHash, confirmed) =>
      publishDocumentation(
        { projectRoot, runId, proposalHash, confirmed },
        documentationPorts,
      ),
    start: (projectRoot, targetMajor) =>
      startRun(
        { projectRoot, targetMajor },
        {
          reader,
          discoveries,
          runRecords,
          lock,
          ids,
          hasher,
          hookRuntime,
        },
      ),
    run: (projectRoot, runId) =>
      runProject(
        { projectRoot, runId },
        {
          records: runRecords,
          lock,
          facts,
          fingerprints: reader,
          operations,
          hasher,
        },
      ),
    status: (projectRoot) =>
      getRunStatus(
        { projectRoot },
        {
          records: runRecords,
          context: {
            readProjectFacts: (root) => facts.readProjectFacts(root),
            readFingerprint: (root) => reader.readFingerprint(root),
          },
          hasher,
        },
      ),
  });
  process.stdout.write(result.stdout);
  process.exitCode = result.exitCode;
}

void main();
