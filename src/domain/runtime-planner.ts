import { compare } from "semver";
import {
  isValidSemverRange,
  parseExactSemverVersion,
  satisfiesAllSemverRanges,
} from "./semver-constraints.js";

export interface RuntimeCandidate {
  readonly nodeVersion: string;
  readonly npmVersion: string | null;
  readonly status: "installed" | "missing";
}

export interface RuntimePlanningInput {
  readonly nodeRanges: readonly string[];
  readonly npmRange: string;
  readonly candidates: readonly RuntimeCandidate[];
}

export interface RuntimePlan {
  readonly status: "ready" | "runtime-install-required" | "blocked";
  readonly selected: RuntimeCandidate | null;
  readonly reason:
    | "exact-runtime-missing"
    | "invalid-runtime-constraints"
    | "no-compatible-runtime"
    | null;
}

export function planRuntime(input: RuntimePlanningInput): RuntimePlan {
  if (
    !input ||
    !Array.isArray(input.nodeRanges) ||
    !Array.isArray(input.candidates) ||
    !isValidSemverRange(input.npmRange) ||
    input.nodeRanges.some((range) => !isValidSemverRange(range))
  ) {
    return blocked("invalid-runtime-constraints");
  }

  const candidates = new Map<string, RuntimeCandidate>();
  for (const candidate of input.candidates) {
    if (
      !candidate ||
      (candidate.status !== "installed" && candidate.status !== "missing")
    ) {
      continue;
    }
    const node = parseExactSemverVersion(candidate.nodeVersion);
    const npm =
      candidate.status === "installed" && candidate.npmVersion !== null
        ? parseExactSemverVersion(candidate.npmVersion)
        : null;
    if (
      node === null ||
      (candidate.status === "installed" && npm === null) ||
      (candidate.status === "missing" && candidate.npmVersion !== null)
    ) {
      continue;
    }
    const normalized = {
      nodeVersion: node.version,
      npmVersion: npm?.version ?? null,
      status: candidate.status,
    } satisfies RuntimeCandidate;
    const previous = candidates.get(node.version);
    if (!previous || normalized.status === "installed") {
      candidates.set(node.version, normalized);
    }
  }

  const ordered = [...candidates.values()].sort((left, right) =>
    compare(right.nodeVersion, left.nodeVersion),
  );
  const installed = ordered.find(
    (candidate) =>
      candidate.status === "installed" &&
      satisfiesAllSemverRanges(candidate.nodeVersion, input.nodeRanges) &&
      candidate.npmVersion !== null &&
      satisfiesAllSemverRanges(candidate.npmVersion, [input.npmRange]),
  );
  if (installed) return { status: "ready", selected: installed, reason: null };

  const missing = ordered.find(
    (candidate) =>
      candidate.status === "missing" &&
      satisfiesAllSemverRanges(candidate.nodeVersion, input.nodeRanges),
  );
  if (missing) {
    return {
      status: "runtime-install-required",
      selected: missing,
      reason: "exact-runtime-missing",
    };
  }
  return blocked("no-compatible-runtime");
}

function blocked(reason: RuntimePlan["reason"]): RuntimePlan {
  return { status: "blocked", selected: null, reason };
}
