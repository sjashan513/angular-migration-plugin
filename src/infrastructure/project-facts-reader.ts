import { createHash } from "node:crypto";
import type {
  ProjectFacts,
  ProjectFactsReader,
} from "../application/ports/project-facts-reader.js";
import { createAngularMajor, createProjectId } from "../domain/identity.js";
import {
  isValidSemverRange,
  parseExactSemverVersion,
  satisfiesAllSemverRanges,
} from "../domain/semver-constraints.js";
import { InfrastructureError } from "./infrastructure-error.js";
import { ProjectFileSystem } from "./project-files.js";

const DEPENDENCY_SECTIONS = [
  "dependencies",
  "devDependencies",
  "optionalDependencies",
  "peerDependencies",
] as const;

export class ProjectFactsReaderAdapter implements ProjectFactsReader {
  constructor(private readonly files = new ProjectFileSystem()) {}

  async readProjectFacts(projectRoot: string): Promise<ProjectFacts> {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const packageJson = asRecord(
      await this.files.readJson(root, "package.json"),
    );
    const lockfile = asRecord(
      await this.files.readJson(root, "package-lock.json"),
    );
    const declaredRange = readDeclaredAngularSpecification(packageJson);
    const resolvedVersion = parseExactSemverVersion(
      readLockedAngularVersion(lockfile),
    );
    if (
      !isValidSemverRange(declaredRange) ||
      resolvedVersion === null ||
      !satisfiesAllSemverRanges(resolvedVersion.version, [declaredRange])
    ) {
      throw invalidFacts(
        "The declared Angular core range does not include its locked version.",
      );
    }

    const projectId = createHash("sha256").update(root).digest("hex");
    return {
      projectId: createProjectId(`sha256:${projectId}`),
      angularMajor: createAngularMajor(resolvedVersion.major),
    };
  }
}

function readDeclaredAngularSpecification(
  packageJson: Record<string, unknown>,
): string {
  const specifications: string[] = [];
  for (const section of DEPENDENCY_SECTIONS) {
    if (!(section in packageJson)) continue;
    const dependencies = asRecord(packageJson[section]);
    if (!Object.hasOwn(dependencies, "@angular/core")) continue;
    const specification = dependencies["@angular/core"];
    if (typeof specification !== "string")
      throw invalidFacts(
        "Angular core must use a string npm version specification.",
      );
    specifications.push(specification);
  }

  if (specifications.length !== 1)
    throw invalidFacts(
      "Exactly one direct Angular core dependency is required.",
    );
  return specifications[0];
}

function readLockedAngularVersion(lockfile: Record<string, unknown>): string {
  const lockfileVersion = lockfile.lockfileVersion;
  if (lockfileVersion !== 1 && lockfileVersion !== 2 && lockfileVersion !== 3) {
    throw invalidFacts("The npm lockfile version is not supported.");
  }

  const section = lockfileVersion === 1 ? "dependencies" : "packages";
  const entries = asRecord(lockfile[section]);
  const angularEntry =
    lockfileVersion === 1
      ? asRecord(entries["@angular/core"])
      : asRecord(entries["node_modules/@angular/core"]);
  if (typeof angularEntry.version !== "string")
    throw invalidFacts(
      "The npm lockfile has no resolved Angular core version.",
    );

  const version = parseExactSemverVersion(angularEntry.version);
  if (version === null)
    throw invalidFacts("The resolved Angular core version is not exact.");
  return version.version;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw invalidFacts("Project metadata has an invalid object shape.");
  }
  return value as Record<string, unknown>;
}

function invalidFacts(message: string): InfrastructureError {
  return new InfrastructureError("project_facts_invalid", message);
}
