import assert from "node:assert/strict";
import { test } from "node:test";
import { createAngularTransition } from "../dist/domain/angular-transition.js";

test("accepts sequential transitions for arbitrary Angular majors", () => {
  for (const [sourceMajor, targetMajor] of [
    [1, 2],
    [2, 3],
    [7, 8],
    [21, 22],
    [100, 101],
    [Number.MAX_SAFE_INTEGER - 1, Number.MAX_SAFE_INTEGER],
  ]) {
    assert.deepEqual(createAngularTransition(sourceMajor, targetMajor), {
      sourceMajor,
      targetMajor,
    });
  }
});

test("rejects invalid major values", () => {
  for (const value of [
    0,
    -1,
    1.5,
    Number.NaN,
    Number.POSITIVE_INFINITY,
    "7",
    null,
  ]) {
    assert.throws(() => createAngularTransition(value, 8), {
      code: "invalid_angular_major",
      category: "invalid-input",
      name: "DomainError",
    });
    assert.throws(() => createAngularTransition(7, value), {
      code: "invalid_angular_major",
      category: "invalid-input",
      name: "DomainError",
    });
  }
});

test("rejects same-major, skipped-major, and reverse transitions", () => {
  for (const [sourceMajor, targetMajor] of [
    [7, 7],
    [7, 9],
    [8, 7],
  ]) {
    assert.throws(() => createAngularTransition(sourceMajor, targetMajor), {
      code: "non_sequential_angular_major",
      category: "policy-violation",
      name: "DomainError",
    });
  }
});
