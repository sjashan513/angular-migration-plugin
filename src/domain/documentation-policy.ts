export const REQUIRED_MIGRATION_DOCUMENTS = [
  "README.md",
  "changes.md",
  "dependencies.md",
  "errors-and-repairs.md",
  "new-concepts.md",
  "sources.md",
  "validation.md",
  "warnings.md",
] as const;

export function migrationDocumentationDirectory(targetMajor: number): string {
  if (!Number.isSafeInteger(targetMajor) || targetMajor < 1) {
    throw new RangeError("A positive target major is required.");
  }
  return `docs/migration/v${targetMajor}`;
}
