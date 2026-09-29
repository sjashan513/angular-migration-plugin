import { ApplicationError } from "./application-error.js";
import type {
  DocumentationResearchSubmission,
  DocumentationWorkflowPorts,
} from "./ports/documentation.js";
import type { RunEvent, RunRecord } from "./ports/run-lifecycle.js";
import { readValidatedRunRecord, sealRunRecord } from "./start-run.js";

const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;
const SECRET_TEXT =
  /(?:password|passwd|token|secret|api[_-]?key)\s*[:=]|authorization\s*:\s*bearer|-----BEGIN [A-Z ]*PRIVATE KEY-----/i;
const SEMVER =
  /\b(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?\b/g;

export async function getDocumentationResearchContext(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: DocumentationWorkflowPorts,
): Promise<{
  readonly schemaVersion: 1;
  readonly mode: "research";
  readonly runId: string;
  readonly sourceMajor: number;
  readonly targetMajor: number;
  readonly planHash: string;
  readonly dependencies: readonly {
    readonly name: string;
    readonly currentVersion: string;
    readonly targetVersion: string;
    readonly reason: string;
  }[];
  readonly evidence: {
    readonly status: string;
    readonly stage: string;
    readonly completedOperations: readonly string[];
    readonly configuredChecks: readonly string[];
    readonly events: readonly {
      readonly sequence: number;
      readonly type: string;
      readonly stage: string;
      readonly status: string;
    }[];
  };
  readonly questions: readonly string[];
  readonly submissionPath: string;
  readonly researchHash: string | null;
}> {
  validateRequest(request);
  const run = await loadRun(request, ports);
  requireResearchEligible(run);
  const stored = await ports.artifacts.readResearch(
    request.projectRoot,
    request.runId,
  );
  const researchHash =
    stored === null ? null : await validateStoredResearch(stored, run, ports);
  return {
    schemaVersion: 1,
    mode: "research",
    runId: run.state.runId,
    sourceMajor: run.state.sourceMajor,
    targetMajor: run.state.targetMajor,
    planHash: run.discoveryPlan.planHash,
    dependencies: run.discoveryPlan.packages.map((item) => ({
      name: item.name,
      currentVersion: item.sourceVersion,
      targetVersion: item.targetVersion,
      reason: item.reason,
    })),
    evidence: {
      status: run.state.status,
      stage: run.state.stage,
      completedOperations: run.checkpoints
        .filter(
          (checkpoint) =>
            checkpoint.phase === "after" || checkpoint.phase === "skipped",
        )
        .map((checkpoint) => checkpoint.operationId),
      configuredChecks: run.discoveryPlan.checks
        .filter((check) => check.status === "configured")
        .map((check) => check.id),
      events: run.events.map(({ sequence, type, stage, status }) => ({
        sequence,
        type,
        stage,
        status,
      })),
    },
    questions: [
      `Which official breaking changes apply from Angular ${run.state.sourceMajor} to ${run.state.targetMajor}?`,
      "Which planned dependency changes require project-specific migration work?",
      "Which material questions remain unresolved after reviewing the authorized evidence?",
    ],
    submissionPath: `.angular-migration/documentation-inbox/${run.state.runId}.research.json`,
    researchHash,
  };
}

export async function recordDocumentationResearch(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: DocumentationWorkflowPorts,
): Promise<{
  readonly schemaVersion: 1;
  readonly runId: string;
  readonly status: "researched";
  readonly researchHash: string;
}> {
  validateRequest(request);
  return withProjectLock(request.projectRoot, ports, async () => {
    const run = await loadRun(request, ports);
    requireResearchEligible(run);
    const submission = validateResearchSubmission(
      await ports.artifacts.readResearchSubmission(
        request.projectRoot,
        request.runId,
      ),
      run,
    );
    const researchHash = await ports.hasher.hash(submission);
    requireHash(researchHash, "documentation_research_hash_invalid");
    const existing = await ports.artifacts.readResearch(
      request.projectRoot,
      request.runId,
    );
    if (existing !== null) {
      const existingHash = await validateStoredResearch(existing, run, ports);
      if (existingHash !== researchHash) {
        throw blocked(
          "documentation_research_already_recorded",
          "Different research is already recorded for this run.",
        );
      }
    } else {
      await ports.artifacts.writeResearch(request.projectRoot, request.runId, {
        schemaVersion: 1,
        runId: run.state.runId,
        planHash: run.discoveryPlan.planHash,
        researchHash,
        submission,
      });
    }
    if (
      !run.events.some(
        (event) =>
          event.type === "documentation-research-recorded" &&
          event.documentation?.researchHash === researchHash,
      )
    ) {
      const event: RunEvent = {
        sequence: run.events.length,
        type: "documentation-research-recorded",
        stage: run.state.stage,
        status: run.state.status,
        revision: run.state.revision,
        documentation: {
          outcome: "research-recorded",
          researchHash,
          proposalHash: null,
          filesHash: null,
          outputDirectory: null,
          expectedGitSnapshot: null,
        },
      };
      await saveRun(
        run,
        request.projectRoot,
        { events: [...run.events, event] },
        ports,
      );
    }
    return {
      schemaVersion: 1,
      runId: run.state.runId,
      status: "researched",
      researchHash,
    };
  });
}

async function loadRun(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: DocumentationWorkflowPorts,
): Promise<Awaited<ReturnType<typeof readValidatedRunRecord>>> {
  const value = await ports.runs.read(request.projectRoot);
  if (value === null)
    throw blocked("run_not_found", "No run exists for this project.");
  const run = await readValidatedRunRecord(value, ports.hasher);
  if (run.state.runId !== request.runId) {
    throw blocked(
      "run_context_mismatch",
      "The run id does not match this project.",
    );
  }
  return run;
}

function requireResearchEligible(run: RunRecord): void {
  if (run.state.status !== "running" && run.state.status !== "verified") {
    throw blocked(
      "documentation_research_unavailable",
      "Research requires a current running or technically verified migration.",
    );
  }
}

function validateResearchSubmission(
  value: unknown,
  run: RunRecord,
): DocumentationResearchSubmission {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "schemaVersion",
      "runId",
      "sourceMajor",
      "targetMajor",
      "planHash",
      "researchedAt",
      "sources",
      "findings",
      "concepts",
      "unresolved",
    ]) ||
    value.schemaVersion !== 1 ||
    value.runId !== run.state.runId ||
    value.sourceMajor !== run.state.sourceMajor ||
    value.targetMajor !== run.state.targetMajor ||
    value.planHash !== run.discoveryPlan.planHash ||
    !isTimestamp(value.researchedAt) ||
    !Array.isArray(value.sources) ||
    value.sources.length === 0 ||
    value.sources.length > 100 ||
    !Array.isArray(value.findings) ||
    value.findings.length > 200 ||
    !Array.isArray(value.concepts) ||
    value.concepts.length > 100 ||
    !Array.isArray(value.unresolved) ||
    value.unresolved.length > 100
  ) {
    throw blocked(
      "documentation_research_invalid",
      "The research submission does not match the active run contract.",
    );
  }
  const sources = value.sources;
  const sourceIds = new Set<string>();
  let hasPrimary = false;
  for (const source of sources) {
    if (
      !isRecord(source) ||
      !hasExactKeys(source, [
        "id",
        "title",
        "url",
        "publisher",
        "primary",
        "accessedAt",
      ]) ||
      typeof source.id !== "string" ||
      !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(source.id) ||
      sourceIds.has(source.id) ||
      !boundedText(source.title, 160) ||
      !boundedText(source.publisher, 160) ||
      !isHttpsUrl(source.url) ||
      typeof source.primary !== "boolean" ||
      !isTimestamp(source.accessedAt)
    ) {
      throw blocked(
        "documentation_source_invalid",
        "A cited research source is invalid.",
      );
    }
    sourceIds.add(source.id);
    hasPrimary ||= source.primary;
  }
  if (!hasPrimary) {
    throw blocked(
      "documentation_primary_source_required",
      "Research requires at least one primary HTTPS source.",
    );
  }

  const packageNames = new Set(
    run.discoveryPlan.packages.map(({ name }) => name),
  );
  const allowedVersions = knownVersions(run);
  const findingIds = new Set<string>();
  for (const finding of value.findings) {
    if (
      !isRecord(finding) ||
      !hasExactKeys(finding, [
        "id",
        "kind",
        "title",
        "area",
        "summary",
        "affectedPackages",
        "sourceIds",
        "applicability",
      ]) ||
      typeof finding.id !== "string" ||
      !/^F-[0-9]{1,6}$/.test(finding.id) ||
      findingIds.has(finding.id) ||
      !isFindingKind(finding.kind) ||
      !boundedText(finding.title, 160) ||
      !boundedText(finding.area, 120) ||
      !boundedText(finding.summary, 2000) ||
      !containsOnlyKnownVersions(
        [finding.title, finding.summary],
        allowedVersions,
      ) ||
      !isUniqueStringArray(finding.affectedPackages, 100) ||
      !finding.affectedPackages.every((name) => packageNames.has(name)) ||
      !validSourceReferences(finding.sourceIds, sourceIds) ||
      !["unknown-until-verified", "applicable", "not-applicable"].includes(
        String(finding.applicability),
      )
    ) {
      throw blocked(
        "documentation_finding_invalid",
        "A research finding is invalid or claims an unplanned package/version.",
      );
    }
    if (
      finding.kind === "official-change" &&
      !finding.sourceIds.some((id: string) =>
        sources.some(
          (source: unknown) =>
            isRecord(source) && source.id === id && source.primary === true,
        ),
      )
    ) {
      throw blocked(
        "documentation_primary_source_required",
        "Official-change findings require a primary source.",
      );
    }
    findingIds.add(finding.id);
  }

  const conceptIds = new Set<string>();
  for (const concept of value.concepts) {
    if (
      !isRecord(concept) ||
      !hasExactKeys(concept, ["id", "name", "whyItMatters", "sourceIds"]) ||
      typeof concept.id !== "string" ||
      !/^C-[0-9]{1,6}$/.test(concept.id) ||
      conceptIds.has(concept.id) ||
      !boundedText(concept.name, 160) ||
      !boundedText(concept.whyItMatters, 2000) ||
      !validSourceReferences(concept.sourceIds, sourceIds)
    ) {
      throw blocked(
        "documentation_concept_invalid",
        "A research concept is invalid.",
      );
    }
    conceptIds.add(concept.id);
  }

  const unresolvedIds = new Set<string>();
  for (const item of value.unresolved) {
    if (
      !isRecord(item) ||
      !hasExactKeys(item, ["id", "question", "critical", "sourceIds"]) ||
      typeof item.id !== "string" ||
      !/^U-[0-9]{1,6}$/.test(item.id) ||
      unresolvedIds.has(item.id) ||
      !boundedText(item.question, 2000) ||
      typeof item.critical !== "boolean" ||
      !Array.isArray(item.sourceIds) ||
      item.sourceIds.some(
        (id: unknown) => typeof id !== "string" || !sourceIds.has(id),
      )
    ) {
      throw blocked(
        "documentation_unresolved_invalid",
        "An unresolved research item is invalid.",
      );
    }
    unresolvedIds.add(item.id);
  }
  return value as unknown as DocumentationResearchSubmission;
}

export function validateStoredResearch(
  value: unknown,
  run: RunRecord,
  ports: DocumentationWorkflowPorts,
): Promise<string> {
  return validateStoredResearchAsync(value, run, ports);
}

async function validateStoredResearchAsync(
  value: unknown,
  run: RunRecord,
  ports: DocumentationWorkflowPorts,
): Promise<string> {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "schemaVersion",
      "runId",
      "planHash",
      "researchHash",
      "submission",
    ]) ||
    value.schemaVersion !== 1 ||
    value.runId !== run.state.runId ||
    value.planHash !== run.discoveryPlan.planHash ||
    typeof value.researchHash !== "string" ||
    !/^sha256:[a-f0-9]{64}$/.test(value.researchHash)
  ) {
    throw blocked(
      "documentation_record_invalid",
      "The stored research record is invalid.",
    );
  }
  const submission = validateResearchSubmission(value.submission, run);
  const actualHash = await ports.hasher.hash(submission);
  if (actualHash !== value.researchHash) {
    throw blocked(
      "documentation_record_integrity_failed",
      "The stored research digest is invalid.",
    );
  }
  return value.researchHash;
}

async function saveRun(
  run: Awaited<ReturnType<typeof readValidatedRunRecord>>,
  projectRoot: string,
  changes: Partial<
    Omit<Awaited<ReturnType<typeof readValidatedRunRecord>>, "recordHash">
  >,
  ports: DocumentationWorkflowPorts,
): Promise<void> {
  const { recordHash: _recordHash, ...unsigned } = run;
  await ports.runs.write(
    projectRoot,
    await sealRunRecord({ ...unsigned, ...changes }, ports.hasher),
  );
}

async function withProjectLock<T>(
  projectRoot: string,
  ports: DocumentationWorkflowPorts,
  action: () => Promise<T>,
): Promise<T> {
  const lease = await ports.lock.acquire(projectRoot);
  if (lease.kind !== "acquired") {
    throw blocked(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended"
        ? "Another controller operation owns this project."
        : "Project lock ownership requires recovery.",
    );
  }
  let result: T | undefined;
  let failure: unknown;
  try {
    result = await action();
  } catch (error) {
    failure = error;
  }
  if ((await lease.release()).kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed.",
    );
  }
  if (failure !== undefined) throw failure;
  return result!;
}

function validateRequest(request: {
  readonly projectRoot: string;
  readonly runId: string;
}): void {
  if (
    !request ||
    typeof request.projectRoot !== "string" ||
    request.projectRoot.trim().length === 0 ||
    typeof request.runId !== "string" ||
    !UUID.test(request.runId)
  ) {
    throw blocked(
      "documentation_request_invalid",
      "A project root and valid run id are required.",
    );
  }
}

function knownVersions(run: RunRecord): ReadonlySet<string> {
  return new Set(
    [
      ...run.discoveryPlan.packages.flatMap(
        ({ sourceVersion, targetVersion }) => [sourceVersion, targetVersion],
      ),
      run.discoveryPlan.runtimePlan.selected?.nodeVersion,
      run.discoveryPlan.runtimePlan.selected?.npmVersion,
    ].filter((version): version is string => typeof version === "string"),
  );
}

function containsOnlyKnownVersions(
  texts: readonly string[],
  known: ReadonlySet<string>,
): boolean {
  return texts.every((text) => {
    if (SECRET_TEXT.test(text)) return false;
    for (const match of text.matchAll(SEMVER)) {
      if (!known.has(match[0])) return false;
    }
    return true;
  });
}

function validSourceReferences(
  value: unknown,
  sourceIds: ReadonlySet<string>,
): value is string[] {
  return (
    isUniqueStringArray(value, 100) &&
    value.length > 0 &&
    value.every((id) => sourceIds.has(id))
  );
}

function isUniqueStringArray(
  value: unknown,
  maximum: number,
): value is string[] {
  return (
    Array.isArray(value) &&
    value.length <= maximum &&
    value.every(
      (item) =>
        typeof item === "string" && item.length > 0 && item.length <= 200,
    ) &&
    new Set(value).size === value.length
  );
}

function isFindingKind(
  value: unknown,
): value is DocumentationResearchSubmission["findings"][number]["kind"] {
  return [
    "official-change",
    "observed-change",
    "inference",
    "not-applicable",
  ].includes(String(value));
}

function isHttpsUrl(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 2048) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}

function isTimestamp(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length <= 64 &&
    Number.isFinite(Date.parse(value))
  );
}

function boundedText(value: unknown, maximum: number): value is string {
  return (
    typeof value === "string" &&
    value.trim().length > 0 &&
    value.length <= maximum &&
    !SECRET_TEXT.test(value)
  );
}

function hasExactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
): boolean {
  return (
    Object.keys(value).length === expected.length &&
    expected.every((key) => Object.hasOwn(value, key))
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function requireHash(value: string, code: string): void {
  if (!/^sha256:[a-f0-9]{64}$/.test(value)) {
    throw blocked(
      code,
      "The documentation evidence could not be integrity-bound.",
    );
  }
}

function blocked(code: string, message: string): ApplicationError {
  return new ApplicationError(code, message, "blocked");
}
