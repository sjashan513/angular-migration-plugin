import { major, maxSatisfying, satisfies, valid, validRange } from "semver";

export interface ExactSemverVersion {
  readonly version: string;
  readonly major: number;
}

export function parseExactSemverVersion(
  value: unknown,
): ExactSemverVersion | null {
  if (typeof value !== "string") return null;
  const version = valid(value);
  if (version === null) return null;
  return { version, major: major(version) };
}

export function isValidSemverRange(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.trim().length > 0 &&
    validRange(value) !== null
  );
}

export function satisfiesAllSemverRanges(
  version: unknown,
  ranges: readonly unknown[],
): boolean {
  const parsedVersion = parseExactSemverVersion(version);
  if (parsedVersion === null) return false;

  return ranges.every((range) => {
    if (typeof range !== "string") return false;
    const normalizedRange = validRange(range);
    return (
      normalizedRange !== null &&
      satisfies(parsedVersion.version, normalizedRange)
    );
  });
}

export function selectHighestSatisfyingSemverVersion(
  versions: readonly unknown[],
  ranges: readonly unknown[],
): string | null {
  if (
    versions.some((version) => typeof version !== "string") ||
    ranges.length === 0 ||
    ranges.some((range) => !isValidSemverRange(range))
  ) {
    return null;
  }
  const candidates = versions.filter(
    (version): version is string => parseExactSemverVersion(version) !== null,
  );
  const combinedRange = (ranges as readonly string[]).join(" ");
  if (!isValidSemverRange(combinedRange)) return null;
  return maxSatisfying(candidates, combinedRange);
}
