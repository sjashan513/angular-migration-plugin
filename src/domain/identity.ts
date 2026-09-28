import { DomainError } from "./domain-error.js";

declare const angularMajorBrand: unique symbol;
declare const projectIdBrand: unique symbol;
declare const runIdBrand: unique symbol;

export type AngularMajor = number & { readonly [angularMajorBrand]: true };
export type ProjectId = string & { readonly [projectIdBrand]: true };
export type RunId = string & { readonly [runIdBrand]: true };

export function createAngularMajor(value: unknown): AngularMajor {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    throw new DomainError(
      "invalid_angular_major",
      "invalid-input",
      "Angular major must be a positive safe integer.",
    );
  }

  return value as AngularMajor;
}

export function createProjectId(value: unknown): ProjectId {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new DomainError(
      "invalid_project_id",
      "invalid-identity",
      "Project identity must be a non-empty string.",
    );
  }

  return value as ProjectId;
}

export function createRunId(value: unknown): RunId {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new DomainError(
      "invalid_run_id",
      "invalid-identity",
      "Run identity must be a non-empty string.",
    );
  }

  return value as RunId;
}
