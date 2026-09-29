import { DomainError } from "./domain-error.js";
import { createAngularMajor, type AngularMajor } from "./identity.js";

export interface AngularTransition {
  readonly sourceMajor: AngularMajor;
  readonly targetMajor: AngularMajor;
}

export function createAngularTransition(
  sourceMajor: unknown,
  targetMajor: unknown,
): AngularTransition {
  const validatedSourceMajor = createAngularMajor(sourceMajor);
  const validatedTargetMajor = createAngularMajor(targetMajor);

  if (validatedTargetMajor !== validatedSourceMajor + 1) {
    throw new DomainError(
      "non_sequential_angular_major",
      "policy-violation",
      "Target major must be exactly one greater than source major.",
    );
  }

  return {
    sourceMajor: validatedSourceMajor,
    targetMajor: validatedTargetMajor,
  };
}
