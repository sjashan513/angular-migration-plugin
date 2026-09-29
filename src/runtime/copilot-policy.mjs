import { createHash } from "node:crypto";
import * as fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const MAX_INPUT_BYTES = 1_048_576;
const MAX_SUBMISSION_BYTES = 1_048_576;
const IMPLEMENTER = "migration-implementer";
const DOCUMENTER = "migration-documenter";
const DOCUMENTATION_FILES = [
  "README.md",
  "changes.md",
  "dependencies.md",
  "errors-and-repairs.md",
  "new-concepts.md",
  "sources.md",
  "validation.md",
  "warnings.md",
];
const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;
const HASH = /^sha256:[a-f0-9]{64}$/;
const DENIED_SEGMENTS =
  /^(?:\.git|\.angular-migration|\.npmrc|\.env(?:\..*)?|\.ssh|id_rsa.*|id_ed25519.*|.*\.(?:pem|key|pfx|p12))$/i;

export async function evaluateHook(event, payload, projectRoot) {
  const agentName = payload?.agentName;
  if (![IMPLEMENTER, DOCUMENTER].includes(agentName)) return {};
  if (event !== "preToolUse" && event !== "subagentStop") return {};

  try {
    const root = await fs.realpath(projectRoot);
    const record = await readRunRecord(root);
    if (!record)
      return deny(event, "No validated TypeScript migration run is active.");
    if (event === "subagentStop")
      return await decideStop(root, record, agentName);
    return await decideTool(root, record, agentName, payload);
  } catch {
    return deny(
      event,
      "Migration state or hook input is invalid; the operation was denied.",
    );
  }
}

async function readRunRecord(root) {
  let text;
  try {
    text = await fs.readFile(
      path.join(root, ".angular-migration", "run.json"),
      "utf8",
    );
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  if (Buffer.byteLength(text, "utf8") > MAX_INPUT_BYTES)
    throw new Error("oversized run record");
  const record = JSON.parse(text);
  if (!isRunRecord(record)) throw new Error("invalid run record");
  const { recordHash, ...content } = record;
  const actualHash = `sha256:${createHash("sha256")
    .update(JSON.stringify(canonicalize(content)))
    .digest("hex")}`;
  if (actualHash !== recordHash) throw new Error("run record hash mismatch");
  return record;
}

function isRunRecord(value) {
  return (
    isRecord(value) &&
    value.schemaVersion === 1 &&
    isRecord(value.state) &&
    value.state.schemaVersion === 1 &&
    UUID.test(value.state.runId) &&
    HASH.test(value.state.projectId) &&
    Number.isSafeInteger(value.state.sourceMajor) &&
    value.state.sourceMajor > 0 &&
    Number.isSafeInteger(value.state.targetMajor) &&
    value.state.targetMajor === value.state.sourceMajor + 1 &&
    isValidState(value.state) &&
    Number.isSafeInteger(value.state.revision) &&
    value.state.revision >= 0 &&
    isRecord(value.discoveryPlan) &&
    Array.isArray(value.events) &&
    Array.isArray(value.checkpoints) &&
    (value.diagnostic === null || isRecord(value.diagnostic)) &&
    HASH.test(value.recordHash)
  );
}

async function decideTool(root, record, agentName, payload) {
  const state = record.state;
  const arguments_ = parseToolArguments(payload?.toolArgs);
  const tool = payload?.toolName;
  if (agentName === IMPLEMENTER) {
    if (state.status !== "needs-repair")
      return deny(
        "preToolUse",
        "Repair tools are unavailable outside needs-repair.",
      );
    if (["read", "search", "view", "grep", "rg", "glob"].includes(tool)) {
      return (await safeProjectReads(root, arguments_, true))
        ? allow(
            "preToolUse",
            "Read is limited to source files in the active repair scope.",
          )
        : deny("preToolUse", "Read is outside the active repair scope.");
    }
    if (tool === "edit") {
      const target = onePath(arguments_);
      return target === `.angular-migration/repair-inbox/${state.runId}.json`
        ? allow(
            "preToolUse",
            "Only the run-bound repair submission may be edited.",
          )
        : deny(
            "preToolUse",
            "Only the run-bound repair submission may be edited.",
          );
    }
    return deny(
      "preToolUse",
      "This tool is not permitted for the repair agent.",
    );
  }

  if (!["running", "verified"].includes(state.status)) {
    return deny(
      "preToolUse",
      "Documentation tools are unavailable for this run state.",
    );
  }
  if (["read", "search", "view", "grep", "rg", "glob"].includes(tool)) {
    return (await safeProjectReads(root, arguments_, false))
      ? allow(
          "preToolUse",
          "Documentation reads exclude plugin state and credential files.",
        )
      : deny(
          "preToolUse",
          "Documentation read is outside the safe project scope.",
        );
  }
  if (tool === "web") {
    return safeUrls(arguments_)
      ? allow(
          "preToolUse",
          "Only public HTTPS sources without credentials or query data are allowed.",
        )
      : deny(
          "preToolUse",
          "Only public HTTPS sources without credentials or query data are allowed.",
        );
  }
  if (tool === "edit") {
    const target = onePath(arguments_);
    const research = `.angular-migration/documentation-inbox/${state.runId}.research.json`;
    const publish = `.angular-migration/documentation-inbox/${state.runId}.publish.json`;
    const recorded = hasRecordedResearch(record);
    const allowed =
      target === research
        ? !recorded
        : state.status === "verified" && recorded && target === publish;
    return allowed
      ? allow(
          "preToolUse",
          "Only run-bound documentation submissions may be edited.",
        )
      : deny(
          "preToolUse",
          "Only run-bound documentation submissions may be edited.",
        );
  }
  return deny(
    "preToolUse",
    "This tool is not permitted for the documentation agent.",
  );
}

async function decideStop(root, record, agentName) {
  const { state } = record;
  let relativePath;
  let kind;
  if (
    agentName === IMPLEMENTER &&
    state.status === "needs-repair" &&
    state.stage === "validate"
  ) {
    relativePath = `.angular-migration/repair-inbox/${state.runId}.json`;
    kind = "repair";
  } else if (agentName === DOCUMENTER && state.status === "running") {
    relativePath = `.angular-migration/documentation-inbox/${state.runId}.research.json`;
    kind = "research";
  } else if (
    agentName === DOCUMENTER &&
    state.status === "verified" &&
    state.stage === "document"
  ) {
    const researchRecorded = hasRecordedResearch(record);
    kind = researchRecorded ? "publish" : "research";
    relativePath = `.angular-migration/documentation-inbox/${state.runId}.${kind === "publish" ? "publish" : "research"}.json`;
  } else {
    return deny("subagentStop", "No submission is allowed for this run state.");
  }
  return (await hasValidSubmission(root, relativePath, kind, record))
    ? { decision: "allow" }
    : deny("subagentStop", "The run-bound submission is missing or invalid.");
}

function hasRecordedResearch(record) {
  return record.events.some(
    (event) =>
      event.type === "documentation-research-recorded" &&
      HASH.test(event.documentation?.researchHash ?? ""),
  );
}

async function hasValidSubmission(root, relativePath, kind, record) {
  const target = await resolveSafePath(root, relativePath, false);
  if (!target) return false;
  try {
    const stats = await fs.stat(target);
    if (!stats.isFile() || stats.size > MAX_SUBMISSION_BYTES) return false;
    const value = JSON.parse(await fs.readFile(target, "utf8"));
    if (!isRecord(value) || value.runId !== record.state.runId) return false;
    switch (kind) {
      case "repair":
        return isRepairSubmission(value, record);
      case "research":
        return isResearchSubmission(value, record);
      case "publish":
        return isPublishSubmission(value, record);
      default:
        return false;
    }
  } catch {
    return false;
  }
}

function isRepairSubmission(value, record) {
  const fingerprint = record.checkpoints.at(-1)?.projectFingerprint;
  const attempt =
    record.events.filter((event) => event.repair?.fingerprint === fingerprint)
      .length + 1;
  return (
    hasExactKeys(value, [
      "schemaVersion",
      "runId",
      "fingerprint",
      "attempt",
      "rootCause",
      "changes",
      "evidence",
      "unresolvedWarnings",
    ]) &&
    value.schemaVersion === 1 &&
    value.fingerprint === fingerprint &&
    value.attempt === attempt &&
    boundedText(value.rootCause, 4000) &&
    Array.isArray(value.changes) &&
    value.changes.length > 0 &&
    value.changes.length <= 20 &&
    value.changes.every(
      (change) =>
        isRecord(change) &&
        hasExactKeys(change, ["path", "summary", "reason", "content"]) &&
        typeof change.path === "string" &&
        /^src\/[A-Za-z0-9._/-]+$/.test(change.path) &&
        !change.path.split("/").includes("..") &&
        boundedText(change.summary, 1000) &&
        boundedText(change.reason, 1000) &&
        typeof change.content === "string",
    ) &&
    Array.isArray(value.evidence) &&
    value.evidence.length > 0 &&
    value.evidence.every(
      (item) =>
        isRecord(item) &&
        hasExactKeys(item, ["kind", "reference", "claim"]) &&
        item.kind === "diagnostic" &&
        item.reference === "run-diagnostic" &&
        boundedText(item.claim, 2000),
    ) &&
    Array.isArray(value.unresolvedWarnings) &&
    value.unresolvedWarnings.every((item) => boundedText(item, 1000))
  );
}

function isResearchSubmission(value, record) {
  return (
    hasExactKeys(value, [
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
    ]) &&
    value.schemaVersion === 1 &&
    value.sourceMajor === record.state.sourceMajor &&
    value.targetMajor === record.state.targetMajor &&
    value.planHash === record.discoveryPlan.planHash &&
    isTimestamp(value.researchedAt) &&
    Array.isArray(value.sources) &&
    value.sources.length > 0 &&
    value.sources.length <= 100 &&
    value.sources.every(
      (source) =>
        isRecord(source) &&
        hasExactKeys(source, [
          "id",
          "title",
          "url",
          "publisher",
          "primary",
          "accessedAt",
        ]) &&
        boundedText(source.id, 64) &&
        boundedText(source.title, 160) &&
        boundedText(source.publisher, 160) &&
        safeUrls({ url: source.url }) &&
        typeof source.primary === "boolean" &&
        isTimestamp(source.accessedAt),
    ) &&
    value.sources.some((source) => source.primary) &&
    Array.isArray(value.findings) &&
    value.findings.length <= 200 &&
    Array.isArray(value.concepts) &&
    value.concepts.length <= 100 &&
    Array.isArray(value.unresolved) &&
    value.unresolved.length <= 100
  );
}

function isPublishSubmission(value, record) {
  const expectedFiles = DOCUMENTATION_FILES;
  const outputDirectory = `docs/migration/v${record.state.targetMajor}`;
  const researchHash = record.events.findLast(
    (event) => event.type === "documentation-research-recorded",
  )?.documentation?.researchHash;
  if (!HASH.test(researchHash ?? "")) return false;
  let totalBytes = 0;
  return (
    hasExactKeys(value, [
      "schemaVersion",
      "runId",
      "planHash",
      "researchHash",
      "outputDirectory",
      "files",
      "claims",
      "remainingWarnings",
    ]) &&
    value.schemaVersion === 1 &&
    value.planHash === record.discoveryPlan.planHash &&
    value.researchHash === researchHash &&
    value.outputDirectory === outputDirectory &&
    Array.isArray(value.files) &&
    value.files.length === expectedFiles.length &&
    value.files.every((file, index) => {
      if (
        !isRecord(file) ||
        !hasExactKeys(file, ["path", "content"]) ||
        file.path !== `${outputDirectory}/${expectedFiles[index]}` ||
        typeof file.content !== "string" ||
        file.content.trim().length === 0
      )
        return false;
      const content = Buffer.from(file.content, "utf8");
      totalBytes += content.byteLength;
      return (
        content.byteLength <= 262_144 && totalBytes <= MAX_SUBMISSION_BYTES
      );
    }) &&
    Array.isArray(value.claims) &&
    value.claims.length <= 200 &&
    Array.isArray(value.remainingWarnings) &&
    value.remainingWarnings.length <= 100 &&
    value.remainingWarnings.every((warning) => boundedText(warning, 2000))
  );
}

async function safeProjectReads(root, arguments_, sourceOnly) {
  const paths = extractPaths(arguments_);
  if (paths.length === 0 || paths.length > 20) return false;
  for (const value of paths) {
    if (typeof value !== "string") return false;
    const normalized = normalizeRelativePath(value);
    if (
      !normalized ||
      normalized.split("/").some((segment) => DENIED_SEGMENTS.test(segment))
    )
      return false;
    if (sourceOnly && !normalized.startsWith("src/")) return false;
    const resolved = await resolveSafePath(root, normalized, true);
    if (!resolved) return false;
    const stats = await fs.lstat(resolved);
    if (
      stats.isDirectory() &&
      !(await directoryIsSafe(root, resolved, sourceOnly))
    )
      return false;
  }
  return true;
}

async function directoryIsSafe(root, directory, sourceOnly) {
  const pending = [directory];
  let entriesSeen = 0;
  while (pending.length > 0) {
    const current = pending.pop();
    for (const entry of await fs.readdir(current, { withFileTypes: true })) {
      entriesSeen += 1;
      if (
        entriesSeen > 5000 ||
        entry.isSymbolicLink() ||
        DENIED_SEGMENTS.test(entry.name)
      )
        return false;
      const target = path.join(current, entry.name);
      const relative = path.relative(root, target).replaceAll("\\", "/");
      if (
        !isWithin(root, target) ||
        (sourceOnly && !relative.startsWith("src/"))
      )
        return false;
      if (entry.isDirectory()) pending.push(target);
      else if (!entry.isFile()) return false;
    }
  }
  return true;
}

async function resolveSafePath(root, relativePath, mustExist) {
  const normalized = normalizeRelativePath(relativePath);
  if (!normalized) return null;
  const target = path.resolve(root, ...normalized.split("/"));
  if (!isWithin(root, target)) return null;
  let current = root;
  const segments = normalized.split("/");
  for (let index = 0; index < segments.length; index += 1) {
    current = path.join(current, segments[index]);
    try {
      const stats = await fs.lstat(current);
      if (stats.isSymbolicLink()) return null;
      const real = await fs.realpath(current);
      if (!isWithin(root, real)) return null;
      current = real;
    } catch (error) {
      if (error?.code !== "ENOENT" || mustExist) return null;
      return current;
    }
  }
  return current;
}

function parseToolArguments(value) {
  if (typeof value === "string") {
    try {
      value = JSON.parse(value);
    } catch {
      return null;
    }
  }
  return isRecord(value) ? value : null;
}

function onePath(arguments_) {
  const paths = extractPaths(arguments_);
  if (paths.length !== 1 || typeof paths[0] !== "string") return null;
  return normalizeRelativePath(paths[0]);
}

function extractPaths(arguments_) {
  if (!isRecord(arguments_)) return [];
  const result = [];
  for (const key of ["path", "paths", "filePath"]) {
    if (Object.hasOwn(arguments_, key))
      result.push(
        ...(Array.isArray(arguments_[key])
          ? arguments_[key]
          : [arguments_[key]]),
      );
  }
  return result;
}

function normalizeRelativePath(value) {
  if (typeof value !== "string" || value.length === 0 || value.includes("\0"))
    return null;
  const normalized = value.replaceAll("\\", "/");
  if (
    normalized.startsWith("/") ||
    /^[a-z]:/i.test(normalized) ||
    normalized.endsWith("/") ||
    normalized.includes("//")
  )
    return null;
  const segments = normalized.split("/");
  if (
    segments.some(
      (segment) =>
        !segment ||
        segment === "." ||
        segment === ".." ||
        /[:*?<>|\x00-\x1f]/.test(segment) ||
        /[. ]$/.test(segment),
    )
  )
    return null;
  return segments.join("/");
}

function safeUrls(arguments_) {
  if (!isRecord(arguments_)) return false;
  const urls = [];
  for (const key of ["url", "urls"])
    if (Object.hasOwn(arguments_, key))
      urls.push(
        ...(Array.isArray(arguments_[key])
          ? arguments_[key]
          : [arguments_[key]]),
      );
  if (urls.length === 0 || urls.length > 10) return false;
  return urls.every((value) => {
    if (typeof value !== "string") return false;
    try {
      const url = new URL(value);
      return (
        url.protocol === "https:" &&
        !url.username &&
        !url.password &&
        !url.search &&
        !url.hash &&
        !url.hostname.endsWith(".localhost") &&
        url.hostname !== "localhost" &&
        !/^127\./.test(url.hostname) &&
        url.hostname !== "::1"
      );
    } catch {
      return false;
    }
  });
}

function deny(event, reason) {
  return event === "subagentStop"
    ? { decision: "block", reason }
    : { permissionDecision: "deny", permissionDecisionReason: reason };
}

function allow(event, reason) {
  return event === "subagentStop"
    ? { decision: "allow" }
    : { permissionDecision: "allow", permissionDecisionReason: reason };
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(value, keys) {
  return (
    isRecord(value) &&
    Object.keys(value).length === keys.length &&
    keys.every((key) => Object.hasOwn(value, key))
  );
}

function boundedText(value, maximum) {
  return (
    typeof value === "string" &&
    value.trim().length > 0 &&
    value.length <= maximum
  );
}

function isTimestamp(value) {
  return (
    typeof value === "string" &&
    value.length <= 64 &&
    Number.isFinite(Date.parse(value))
  );
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative === "" ||
    (!relative.startsWith(`..${path.sep}`) &&
      relative !== ".." &&
      !path.isAbsolute(relative))
  );
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const event = process.argv[2];
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
    if (Buffer.byteLength(input, "utf8") > MAX_INPUT_BYTES) break;
  }
  try {
    const result = await evaluateHook(event, JSON.parse(input), process.cwd());
    process.stdout.write(JSON.stringify(result));
  } catch {
    process.stdout.write(
      JSON.stringify(
        deny(
          event,
          "Migration hook input is invalid; the operation was denied.",
        ),
      ),
    );
  }
}

function isValidState(state) {
  switch (state.status) {
    case "running":
      return [
        "baseline",
        "resolve",
        "update-angular",
        "update-dependencies",
        "install",
        "validate",
      ].includes(state.stage);
    case "needs-repair":
      return ["update-angular", "validate"].includes(state.stage);
    case "verified":
      return state.stage === "document";
    case "completed":
      return state.stage === "done";
    case "blocked":
    case "failed":
      return (
        state.stage !== "done" &&
        [
          "baseline",
          "resolve",
          "update-angular",
          "update-dependencies",
          "install",
          "validate",
          "document",
        ].includes(state.stage)
      );
    default:
      return false;
  }
}
