import assert from "node:assert/strict";
import { test } from "node:test";
import {
  isValidSemverRange,
  parseExactSemverVersion,
  satisfiesAllSemverRanges,
  selectHighestSatisfyingSemverVersion,
} from "../dist/domain/semver-constraints.js";

test("parses exact versions and rejects ranges as locked versions", () => {
  assert.deepEqual(parseExactSemverVersion("7.2.16"), {
    version: "7.2.16",
    major: 7,
  });
  assert.equal(parseExactSemverVersion("^7.2.0"), null);
});

test("evaluates compound and alternative npm version ranges", () => {
  assert.equal(isValidSemverRange(">=10.13.0 <21.0.0"), true);
  assert.equal(
    satisfiesAllSemverRanges("16.20.2", [">=10.13.0 <21.0.0", ">=7"]),
    true,
  );
  assert.equal(
    satisfiesAllSemverRanges("22.19.0", [">=10.13.0 <21.0.0"]),
    false,
  );
  assert.equal(satisfiesAllSemverRanges("1.9.4", ["1.8.x || 1.9.x"]), true);
});

test("selects the highest exact version satisfying every required range", () => {
  assert.equal(
    selectHighestSatisfyingSemverVersion(
      ["1.0.0", "1.8.0", "1.9.0", "2.0.0", "1.10.0-beta.1"],
      [">=1.0.0", "<2.0.0"],
    ),
    "1.9.0",
  );
});

test("rejects invalid ranges and applies npm prerelease matching rules", () => {
  assert.equal(isValidSemverRange("workspace:*"), false);
  assert.equal(isValidSemverRange(""), false);
  assert.equal(isValidSemverRange("   "), false);
  assert.equal(satisfiesAllSemverRanges("1.9.4", ["workspace:*"]), false);
  assert.equal(satisfiesAllSemverRanges("10.0.0-next.1", [">=10.0.0"]), false);
  assert.equal(
    satisfiesAllSemverRanges("10.0.0-next.1", [">=10.0.0-next.0"]),
    true,
  );
});
