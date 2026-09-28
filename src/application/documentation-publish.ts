import {
  migrationDocumentationDirectory,
  REQUIRED_MIGRATION_DOCUMENTS,
} from "../domain/documentation-policy.js";
import { ApplicationError } from "./application-error.js";
import { validateStoredResearch } from "./documentation-research.js";
import type {
  DocumentationGitSnapshot,
  DocumentationPublicationRecord,
  DocumentationPublishSubmission,
  DocumentationWorkflowPorts,
} from "./ports/documentation.js";
import type { RunEvent, RunRecord } from "./ports/run-lifecycle.js";
import { readValidatedRunRecord, sealRunRecord } from "./start-run.js";

const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;
const SECRET_TEXT =
  /(?:password|passwd|token|secret|api[_-]?key)\s*[:=]|authorization\s*:\s*bearer|-----BEGIN [A-Z ]*PRIVATE KEY-----/i;
const EXECUTABLE_TEXT =
  /<\s*(?:script|iframe)\b|javascript\s*:|\bon[a-z]+\s*=/i;
const SEMVER =
  /\b(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?\b/g;
const MAX_DOCUMENT_BYTES = 262_144;
const MAX_TOTAL_BYTES = 1_048_576;

interface PreparedPublication {
  readonly run: Awaited<ReturnType<typeof readValidatedRunRecord>>;
  readonly submission: DocumentationPublishSubmission;
  readonly researchHash: string;
  readonly filesHash: string;
  readonly proposalHash: string;
  readonly outputDirectory: string;
  readonly expectedGitSnapshot: DocumentationGitSnapshot;
  readonly expectedFingerprint: string;
  readonly outputFiles:
    | readonly { readonly path: string; readonly sha256: string }[]
    | null;
  readonly pending: boolean;
}

export async function getDocumentationPublishContext(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: DocumentationWorkflowPorts,
): Promise<{
  readonly schemaVersion: 1;
  readonly mode: "publish";
  readonly runId: string;
  readonly technicalStatus: "verified";
  readonly planHash: string;
  readonly researchHash: string;
  readonly outputDirectory: string;
  readonly requiredFiles: readonly string[];
  readonly proposalHash: string;
  readonly submissionPath: string;
  readonly recovery: boolean;
}> {
  validateRequest(request);
  const prepared = await preparePublication(request, ports);
  return {
    schemaVersion: 1,
    mode: "publish",
    runId: prepared.run.state.runId,
    technicalStatus: "verified",
    planHash: prepared.run.discoveryPlan.planHash,
    researchHash: prepared.researchHash,
    outputDirectory: prepared.outputDirectory,
    requiredFiles: REQUIRED_MIGRATION_DOCUMENTS.map(
      (name) => `${prepared.outputDirectory}/${name}`,
    ),
    proposalHash: prepared.proposalHash,
    submissionPath: `.angular-migration/documentation-inbox/${request.runId}.publish.json`,
    recovery: prepared.pending,
  };
}

export async function publishDocumentation(
  request: {
    readonly projectRoot: string;
    readonly runId: string;
    readonly proposalHash: string;
    readonly confirmed: boolean;
  },
  ports: DocumentationWorkflowPorts,
): Promise<{
  readonly schemaVersion: 1;
  readonly runId: string;
  readonly status: "published";
  readonly technicalStatus: "verified";
  readonly outputDirectory: string;
  readonly researchHash: string;
  readonly filesHash: string;
}> {
  validateRequest(request);
  if (
    typeof request.proposalHash !== "string" ||
    !/^sha256:[a-f0-9]{64}$/.test(request.proposalHash) ||
    request.confirmed !== true
  ) {
    throw blocked(
      request?.confirmed === true
        ? "documentation_publish_approval_invalid"
        : "confirmation_required",
      request?.confirmed === true
        ? "A current documentation proposal hash is required."
        : "Publishing documentation requires explicit confirmation.",
    );
  }
  return withProjectLock(request.projectRoot, ports, async () => {
    const prepared = await preparePublication(request, ports);
    if (prepared.proposalHash !== request.proposalHash) {
      throw blocked(
        "documentation_publish_proposal_stale",
        "The documentation proposal changed; request confirmation again.",
      );
    }
    const pendingEvent = prepared.run.events.at(-1);
    if (
      prepared.pending &&
      (!pendingEvent ||
        pendingEvent.type !== "documentation-publish-started" ||
        !pendingEvent.documentation ||
        pendingEvent.documentation.proposalHash !== prepared.proposalHash ||
        pendingEvent.documentation.filesHash !== prepared.filesHash)
    ) {
      throw blocked(
        "documentation_publish_recovery_required",
        "An interrupted publication is bound to a different proposal.",
      );
    }

    let run = prepared.run;
    if (!prepared.pending) {
      const event: RunEvent = {
        sequence: run.events.length,
        type: "documentation-publish-started",
        stage: "document",
        status: "verified",
        revision: run.state.revision,
        documentation: {
          outcome: "publish-started",
          researchHash: prepared.researchHash,
          proposalHash: prepared.proposalHash,
          filesHash: prepared.filesHash,
          outputDirectory: prepared.outputDirectory,
          expectedGitSnapshot: prepared.expectedGitSnapshot,
        },
      };
      const checkpoint = {
        sequence: run.checkpoints.length,
        stage: "document" as const,
        operationId: "documentation-publish",
        phase: "before" as const,
        projectFingerprint: prepared.expectedFingerprint,
        idempotencyKey: `${run.state.runId}:document:documentation-publish:before`,
      };
      run = await saveRun(
        run,
        request.projectRoot,
        {
          events: [...run.events, event],
          checkpoints: [...run.checkpoints, checkpoint],
        },
        ports,
      );
    }

    if (prepared.outputFiles === null) {
      const writtenHash = await ports.artifacts.publishFiles({
        projectRoot: request.projectRoot,
        outputDirectory: prepared.outputDirectory,
        expectedExistingFiles: null,
        expectedGitSnapshot: prepared.expectedGitSnapshot,
        nodeVersion: run.discoveryPlan.runtimePlan.selected!.nodeVersion,
        files: prepared.submission.files,
      });
      if (writtenHash !== prepared.filesHash) {
        throw blocked(
          "documentation_publish_postcondition_failed",
          "The published files do not match their approved digest.",
        );
      }
    }
    const outputFiles = await ports.artifacts.inspectOutput(
      request.projectRoot,
      prepared.outputDirectory,
    );
    if (!sameFileSet(outputFiles, expectedOutputFiles(prepared.submission))) {
      throw blocked(
        "documentation_publish_postcondition_failed",
        "The exact approved documentation files could not be verified.",
      );
    }
    const currentFingerprint = await ports.fingerprints.readFingerprint(
      request.projectRoot,
    );
    if (!isFingerprint(currentFingerprint)) {
      throw blocked(
        "documentation_publish_postcondition_failed",
        "The project fingerprint could not be verified after publication.",
      );
    }
    const publication = {
      schemaVersion: 1 as const,
      runId: run.state.runId,
      planHash: run.discoveryPlan.planHash,
      researchHash: prepared.researchHash,
      proposalHash: prepared.proposalHash,
      filesHash: prepared.filesHash,
      outputDirectory: prepared.outputDirectory,
      files: expectedOutputFiles(prepared.submission),
    };
    const existingPublication = await ports.artifacts.readPublication(
      request.projectRoot,
      request.runId,
    );
    if (existingPublication === null) {
      await ports.artifacts.writePublication(
        request.projectRoot,
        request.runId,
        publication,
      );
    } else if (!samePublication(existingPublication, publication)) {
      throw blocked(
        "documentation_record_invalid",
        "A different publication record already exists for this run.",
      );
    }

    const after = {
      sequence: run.checkpoints.length,
      stage: "document" as const,
      operationId: "documentation-publish",
      phase: "after" as const,
      projectFingerprint: currentFingerprint,
      idempotencyKey: `${run.state.runId}:document:documentation-publish:after`,
    };
    const publishedEvent: RunEvent = {
      sequence: run.events.length,
      type: "documentation-published",
      stage: "document",
      status: "verified",
      revision: run.state.revision,
      documentation: {
        outcome: "published",
        researchHash: prepared.researchHash,
        proposalHash: prepared.proposalHash,
        filesHash: prepared.filesHash,
        outputDirectory: prepared.outputDirectory,
        expectedGitSnapshot: prepared.expectedGitSnapshot,
      },
    };
    await saveRun(
      run,
      request.projectRoot,
      {
        events: [...run.events, publishedEvent],
        checkpoints: [...run.checkpoints, after],
      },
      ports,
    );
    return {
      schemaVersion: 1,
      runId: request.runId,
      status: "published",
      technicalStatus: "verified",
      outputDirectory: prepared.outputDirectory,
      researchHash: prepared.researchHash,
      filesHash: prepared.filesHash,
    };
  });
}

async function preparePublication(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: DocumentationWorkflowPorts,
): Promise<PreparedPublication> {
  const run = await loadRun(request, ports);
  if (run.state.status !== "verified" || run.state.stage !== "document") {
    throw blocked(
      "publish_requires_verified",
      "Documentation publishing requires a technically verified run.",
    );
  }
  const publication = await ports.artifacts.readPublication(
    request.projectRoot,
    request.runId,
  );
  if (
    publication !== null &&
    run.events.at(-1)?.type === "documentation-published"
  ) {
    throw blocked(
      "documentation_already_published",
      "Documentation is already published for this run.",
    );
  }
  const researchRecord = await ports.artifacts.readResearch(
    request.projectRoot,
    request.runId,
  );
  if (!isRecord(researchRecord)) {
    throw blocked(
      "documentation_research_required",
      "Validated research must be recorded before publish.",
    );
  }
  const researchHash = await validateStoredResearch(researchRecord, run, ports);
  if (
    !run.events.some(
      (event) =>
        event.type === "documentation-research-recorded" &&
        event.documentation?.researchHash === researchHash,
    )
  ) {
    throw blocked(
      "documentation_research_required",
      "The run has no audit event for its research record.",
    );
  }
  const submission = await validatePublishSubmission(
    await ports.artifacts.readPublishSubmission(
      request.projectRoot,
      request.runId,
    ),
    run,
    researchHash,
    researchRecord,
    ports,
  );
  const outputDirectory = migrationDocumentationDirectory(
    run.state.targetMajor,
  );
  const expectedOutput = expectedOutputFiles(submission);
  const filesHash = await ports.hasher.hash(expectedOutput);
  requireHash(filesHash, "documentation_hash_invalid");
  const outputFiles = await ports.artifacts.inspectOutput(
    request.projectRoot,
    outputDirectory,
  );
  const pending = run.events.at(-1)?.type === "documentation-publish-started";
  const pendingGitSnapshot = pending
    ? (run.events.at(-1)?.documentation?.expectedGitSnapshot ?? null)
    : null;
  if (pending) {
    if (
      !pendingGitSnapshot ||
      (outputFiles !== null && !sameFileSet(outputFiles, expectedOutput))
    ) {
      throw blocked(
        "documentation_publish_recovery_required",
        "The interrupted output differs from the approved documentation set.",
      );
    }
  } else if (outputFiles !== null || publication !== null) {
    throw blocked(
      "documentation_output_exists",
      "The documentation output already exists and will not be overwritten.",
    );
  }

  const expectedCheckpoint = pending
    ? run.checkpoints.at(-2)
    : run.checkpoints.at(-1);
  const beforeCheckpoint = run.checkpoints.at(-1);
  if (
    !expectedCheckpoint ||
    expectedCheckpoint.stage !== "validate" ||
    expectedCheckpoint.phase !== "after" ||
    (pending &&
      (beforeCheckpoint?.operationId !== "documentation-publish" ||
        beforeCheckpoint.phase !== "before"))
  ) {
    throw blocked(
      "documentation_verification_checkpoint_invalid",
      "The verified run lacks its exact validation checkpoint.",
    );
  }
  const [facts, fingerprint, gitSnapshot] = await Promise.all([
    ports.context.readProjectFacts(request.projectRoot),
    ports.fingerprints.readFingerprint(request.projectRoot),
    ports.artifacts.inspectGitSnapshot(
      request.projectRoot,
      run.discoveryPlan.runtimePlan.selected!.nodeVersion,
    ),
  ]);
  if (
    facts.projectId !== run.state.projectId ||
    facts.angularMajor !== run.state.targetMajor
  ) {
    throw blocked(
      "documentation_project_mismatch",
      "The project identity or Angular major changed.",
    );
  }
  if (
    outputFiles === null &&
    fingerprint !== expectedCheckpoint.projectFingerprint
  ) {
    throw blocked(
      "documentation_project_changed",
      "Project inputs changed after technical verification.",
    );
  }
  const expectedGitSnapshot = pending ? pendingGitSnapshot! : gitSnapshot;
  if (
    pending &&
    (outputFiles === null
      ? !sameGitSnapshot(gitSnapshot, expectedGitSnapshot)
      : !onlyExpectedDocumentationChanges(
          expectedGitSnapshot,
          gitSnapshot,
          expectedOutput.map(({ path }) => path),
        ))
  ) {
    throw blocked(
      "documentation_publish_recovery_required",
      "The interrupted publication has unrelated project changes.",
    );
  }

  if (pending) {
    const started = run.events.at(-1)!;
    if (
      started.type !== "documentation-publish-started" ||
      !started.documentation ||
      started.documentation.researchHash !== researchHash ||
      started.documentation.filesHash !== filesHash ||
      started.documentation.outputDirectory !== outputDirectory
    ) {
      throw blocked(
        "documentation_publish_recovery_required",
        "The pending publish event does not match this submission.",
      );
    }
  }
  const proposalHash = await ports.hasher.hash({
    schemaVersion: 1,
    runId: run.state.runId,
    planHash: run.discoveryPlan.planHash,
    researchHash,
    outputDirectory,
    expectedFingerprint: expectedCheckpoint.projectFingerprint,
    expectedExistingFiles: pending ? null : outputFiles,
    expectedGitSnapshot,
    files: submission.files,
    claims: submission.claims,
    remainingWarnings: submission.remainingWarnings,
  });
  requireHash(proposalHash, "documentation_hash_invalid");
  if (
    pending &&
    run.events.at(-1)?.documentation?.proposalHash !== proposalHash
  ) {
    throw blocked(
      "documentation_publish_recovery_required",
      "The pending publish hash differs from the submission.",
    );
  }
  return {
    run,
    submission,
    researchHash,
    filesHash,
    proposalHash,
    outputDirectory,
    expectedGitSnapshot,
    expectedFingerprint: expectedCheckpoint.projectFingerprint,
    outputFiles,
    pending,
  };
}

function validatePublishSubmission(
  value: unknown,
  run: RunRecord,
  researchHash: string,
  researchValue: unknown,
  ports: DocumentationWorkflowPorts,
): Promise<DocumentationPublishSubmission> {
  return validatePublishSubmissionAsync(
    value,
    run,
    researchHash,
    researchValue,
    ports,
  );
}

async function validatePublishSubmissionAsync(
  value: unknown,
  run: RunRecord,
  researchHash: string,
  researchValue: unknown,
  ports: DocumentationWorkflowPorts,
): Promise<DocumentationPublishSubmission> {
  const outputDirectory = migrationDocumentationDirectory(
    run.state.targetMajor,
  );
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "schemaVersion",
      "runId",
      "planHash",
      "researchHash",
      "outputDirectory",
      "files",
      "claims",
      "remainingWarnings",
    ]) ||
    value.schemaVersion !== 1 ||
    value.runId !== run.state.runId ||
    value.planHash !== run.discoveryPlan.planHash ||
    value.researchHash !== researchHash ||
    value.outputDirectory !== outputDirectory ||
    !Array.isArray(value.files) ||
    value.files.length !== REQUIRED_MIGRATION_DOCUMENTS.length ||
    !Array.isArray(value.claims) ||
    value.claims.length > 200 ||
    !Array.isArray(value.remainingWarnings) ||
    value.remainingWarnings.length > 100
  ) {
    throw blocked(
      "documentation_submission_invalid",
      "Publish input does not match the approved run and research.",
    );
  }
  let totalBytes = 0;
  const knownVersions = knownRunVersions(run);
  const files = [];
  for (let index = 0; index < REQUIRED_MIGRATION_DOCUMENTS.length; index += 1) {
    const file = value.files[index];
    const expectedPath = `${outputDirectory}/${REQUIRED_MIGRATION_DOCUMENTS[index]}`;
    if (
      !isRecord(file) ||
      !hasExactKeys(file, ["path", "content", "sha256"]) ||
      file.path !== expectedPath ||
      typeof file.content !== "string" ||
      file.content.trim().length === 0 ||
      typeof file.sha256 !== "string" ||
      !/^sha256:[a-f0-9]{64}$/.test(file.sha256) ||
      SECRET_TEXT.test(file.content) ||
      EXECUTABLE_TEXT.test(file.content) ||
      !containsOnlyKnownVersions(file.content, knownVersions)
    ) {
      throw blocked(
        "documentation_file_invalid",
        "A documentation file is invalid, sensitive, executable, or claims an unknown version.",
      );
    }
    const bytes = Buffer.byteLength(file.content, "utf8");
    totalBytes += bytes;
    if (bytes > MAX_DOCUMENT_BYTES || totalBytes > MAX_TOTAL_BYTES) {
      throw blocked(
        "documentation_submission_too_large",
        "The documentation exceeds its supported size limit.",
      );
    }
    if ((await ports.contentHasher.hashText(file.content)) !== file.sha256) {
      throw blocked(
        "documentation_file_hash_invalid",
        "A documentation file does not match its declared hash.",
      );
    }
    files.push({ path: file.path, content: file.content, sha256: file.sha256 });
  }
  validateInternalLinks(files);
  const research = isRecord(researchValue) ? researchValue : {};
  const researchSubmission = isRecord(research.submission)
    ? research.submission
    : {};
  const sources = Array.isArray(researchSubmission.sources)
    ? new Set<string>(
        researchSubmission.sources.flatMap((source: unknown) =>
          isRecord(source) && typeof source.id === "string" ? [source.id] : [],
        ),
      )
    : new Set<string>();
  validateClaims(value.claims, run, sources);
  if (
    !value.remainingWarnings.every((warning: unknown) =>
      boundedText(warning, 2000),
    )
  ) {
    throw blocked(
      "documentation_warning_invalid",
      "A remaining warning is invalid or sensitive.",
    );
  }
  return value as unknown as DocumentationPublishSubmission;
}

function validateClaims(
  value: readonly unknown[],
  run: RunRecord,
  sourceIds: ReadonlySet<string>,
): void {
  const ids = new Set<string>();
  const checkIds = new Set([
    ...run.discoveryPlan.checks.map(({ id }) => id),
    ...run.checkpoints.map(({ operationId }) => operationId),
  ]);
  const eventIds = new Set(run.events.map(({ sequence }) => String(sequence)));
  const repairIds = new Set(
    run.events.flatMap((event) =>
      event.repair ? [event.repair.fingerprint] : [],
    ),
  );
  for (const claim of value) {
    if (
      !isRecord(claim) ||
      !hasExactKeys(claim, ["id", "kind", "document", "evidence"]) ||
      typeof claim.id !== "string" ||
      !/^D-[0-9]{1,6}$/.test(claim.id) ||
      ids.has(claim.id) ||
      !isFindingKind(claim.kind) ||
      typeof claim.document !== "string" ||
      !REQUIRED_MIGRATION_DOCUMENTS.includes(
        claim.document as (typeof REQUIRED_MIGRATION_DOCUMENTS)[number],
      ) ||
      !Array.isArray(claim.evidence) ||
      claim.evidence.length === 0 ||
      claim.evidence.length > 20 ||
      new Set(claim.evidence).size !== claim.evidence.length
    ) {
      throw blocked(
        "documentation_claim_invalid",
        "A documentation claim is malformed or unbound.",
      );
    }
    const evidence = claim.evidence as string[];
    const references = evidence.map((item) =>
      parseEvidence(item, run, sourceIds, checkIds, eventIds, repairIds),
    );
    if (references.some((valid) => !valid)) {
      throw blocked(
        "documentation_evidence_mismatch",
        "A documentation claim cites evidence absent from this run.",
      );
    }
    const hasSource = evidence.some((item) => item.startsWith("source:"));
    const hasObserved = evidence.some(
      (item) =>
        /^(?:event|check|repair):/.test(item) || item === "result:verified",
    );
    if (
      (claim.kind === "official-change" && !hasSource) ||
      (claim.kind === "observed-change" && !hasObserved) ||
      (["inference", "not-applicable"].includes(String(claim.kind)) &&
        !hasSource)
    ) {
      throw blocked(
        "documentation_evidence_mismatch",
        "A claim kind requires a matching evidence category.",
      );
    }
    ids.add(claim.id);
  }
}

function parseEvidence(
  value: string,
  run: RunRecord,
  sourceIds: ReadonlySet<string>,
  checkIds: ReadonlySet<string>,
  eventIds: ReadonlySet<string>,
  repairIds: ReadonlySet<string>,
): boolean {
  const separator = value.indexOf(":");
  if (separator < 1 || value.length > 256 || /\s/.test(value)) return false;
  const kind = value.slice(0, separator);
  const id = value.slice(separator + 1);
  if (!id) return false;
  switch (kind) {
    case "source":
      return sourceIds.has(id);
    case "event":
      return eventIds.has(id);
    case "check":
      return checkIds.has(id);
    case "repair":
      return repairIds.has(id);
    case "result":
      return id === "verified" && run.state.status === "verified";
    default:
      return false;
  }
}

function validateInternalLinks(
  files: readonly DocumentationPublishSubmission["files"][number][],
): void {
  const contents = new Map(
    files.map((file) => [
      file.path.slice(file.path.lastIndexOf("/") + 1),
      file.content,
    ]),
  );
  const anchors = new Map<string, Set<string>>();
  for (const [name, content] of contents) {
    anchors.set(
      name,
      new Set(
        [...content.matchAll(/^#{1,6}\s+(.+?)\s*#*\s*$/gm)].map((match) =>
          slug(match[1]),
        ),
      ),
    );
  }
  for (const [name, content] of contents) {
    for (const match of content.matchAll(
      /!?\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)/g,
    )) {
      const target = match[1];
      if (/^https?:\/\//i.test(target)) {
        if (!isHttpsUrl(target))
          throw blocked(
            "documentation_link_invalid",
            "Only credential-free HTTPS external links are allowed.",
          );
        continue;
      }
      if (target.startsWith("/") || target.includes("\\")) {
        throw blocked(
          "documentation_link_invalid",
          "An internal documentation link escapes the output directory.",
        );
      }
      let decoded: string;
      try {
        decoded = decodeURIComponent(target);
      } catch {
        throw blocked(
          "documentation_link_invalid",
          "An internal documentation link is malformed.",
        );
      }
      const [relative, anchor] = decoded.split("#", 2);
      const destination = relative || name;
      if (
        destination.split("/").includes("..") ||
        destination.includes(":") ||
        !contents.has(destination)
      ) {
        throw blocked(
          "documentation_link_broken",
          "A documentation link points outside or to a missing file.",
        );
      }
      if (anchor && !anchors.get(destination)?.has(anchor.toLowerCase())) {
        throw blocked(
          "documentation_link_broken",
          "A documentation link points to a missing heading.",
        );
      }
    }
  }
}

async function loadRun(
  request: { readonly projectRoot: string; readonly runId: string },
  ports: DocumentationWorkflowPorts,
): Promise<Awaited<ReturnType<typeof readValidatedRunRecord>>> {
  const stored = await ports.runs.read(request.projectRoot);
  if (stored === null)
    throw blocked("run_not_found", "No run exists for this project.");
  const run = await readValidatedRunRecord(stored, ports.hasher);
  if (run.state.runId !== request.runId)
    throw blocked(
      "run_context_mismatch",
      "The run id does not match this project.",
    );
  return run;
}

async function saveRun(
  run: Awaited<ReturnType<typeof readValidatedRunRecord>>,
  projectRoot: string,
  changes: Partial<
    Omit<Awaited<ReturnType<typeof readValidatedRunRecord>>, "recordHash">
  >,
  ports: DocumentationWorkflowPorts,
): Promise<Awaited<ReturnType<typeof readValidatedRunRecord>>> {
  const { recordHash: _recordHash, ...unsigned } = run;
  const updated = await sealRunRecord(
    { ...unsigned, ...changes },
    ports.hasher,
  );
  await ports.runs.write(projectRoot, updated);
  return updated;
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

function expectedOutputFiles(
  submission: DocumentationPublishSubmission,
): readonly { readonly path: string; readonly sha256: string }[] {
  return submission.files
    .map(({ path, sha256 }) => ({ path, sha256 }))
    .sort((left, right) => left.path.localeCompare(right.path));
}

function sameFileSet(
  left: readonly { readonly path: string; readonly sha256: string }[] | null,
  right: readonly { readonly path: string; readonly sha256: string }[] | null,
): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function sameGitSnapshot(
  left: DocumentationGitSnapshot,
  right: DocumentationGitSnapshot,
): boolean {
  return (
    left.head === right.head &&
    JSON.stringify(left.changes) === JSON.stringify(right.changes)
  );
}

function onlyExpectedDocumentationChanges(
  before: DocumentationGitSnapshot,
  after: DocumentationGitSnapshot,
  expectedFiles: readonly string[],
): boolean {
  if (before.head !== after.head) return false;
  const previous = new Map(
    before.changes.map((change) => [change.path, change.status]),
  );
  const current = new Map(
    after.changes.map((change) => [change.path, change.status]),
  );
  if ([...previous].some(([file, status]) => current.get(file) !== status))
    return false;
  const added = [...current.keys()]
    .filter((file) => !previous.has(file))
    .sort();
  return (
    JSON.stringify(added) === JSON.stringify([...expectedFiles].sort()) &&
    added.every((file) => current.get(file) === "??")
  );
}

function samePublication(
  left: unknown,
  right: DocumentationPublicationRecord,
): boolean {
  return Boolean(
    isRecord(left) &&
    left.schemaVersion === 1 &&
    left.runId === right.runId &&
    left.planHash === right.planHash &&
    left.researchHash === right.researchHash &&
    left.proposalHash === right.proposalHash &&
    left.filesHash === right.filesHash &&
    left.outputDirectory === right.outputDirectory &&
    JSON.stringify(left.files) === JSON.stringify(right.files),
  );
}

function knownRunVersions(run: RunRecord): ReadonlySet<string> {
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
  text: string,
  known: ReadonlySet<string>,
): boolean {
  for (const match of text.matchAll(SEMVER))
    if (!known.has(match[0])) return false;
  return true;
}

function isFindingKind(
  value: unknown,
): value is DocumentationPublishSubmission["claims"][number]["kind"] {
  return [
    "official-change",
    "observed-change",
    "inference",
    "not-applicable",
  ].includes(String(value));
}

function isHttpsUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}

function slug(value: string): string {
  return value
    .toLowerCase()
    .replace(/[`*_~]/g, "")
    .replace(/[^a-z0-9 -]/g, "")
    .trim()
    .replace(/\s+/g, "-");
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

function isRecord(value: unknown): value is Record<string, any> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function isFingerprint(value: unknown): value is string {
  return typeof value === "string" && /^sha256:[a-f0-9]{64}$/.test(value);
}

function requireHash(value: string, code: string): void {
  if (!isFingerprint(value))
    throw blocked(
      code,
      "The documentation proposal could not be integrity-bound.",
    );
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

function blocked(code: string, message: string): ApplicationError {
  return new ApplicationError(code, message, "blocked");
}
