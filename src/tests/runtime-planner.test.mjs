import assert from "node:assert/strict";
import { test } from "node:test";
import { planRuntime } from "../dist/domain/runtime-planner.js";

test("selects the highest installed runtime satisfying Node and npm ranges", () => {
  const plan = planRuntime({
    nodeRanges: [">=14 <22"],
    npmRange: ">=7",
    candidates: [
      { nodeVersion: "20.18.0", npmVersion: "10.8.2", status: "installed" },
      { nodeVersion: "16.20.2", npmVersion: "8.19.4", status: "installed" },
      { nodeVersion: "14.21.3", npmVersion: "6.14.18", status: "installed" },
    ],
  });

  assert.deepEqual(plan, {
    status: "ready",
    selected: {
      nodeVersion: "20.18.0",
      npmVersion: "10.8.2",
      status: "installed",
    },
    reason: null,
  });
});

test("returns an exact proposal without claiming a missing runtime is installed", () => {
  const plan = planRuntime({
    nodeRanges: [">=14 <17"],
    npmRange: ">=7",
    candidates: [
      { nodeVersion: "14.21.3", npmVersion: "6.14.18", status: "installed" },
      { nodeVersion: "16.20.2", npmVersion: null, status: "missing" },
    ],
  });

  assert.deepEqual(plan, {
    status: "runtime-install-required",
    selected: {
      nodeVersion: "16.20.2",
      npmVersion: null,
      status: "missing",
    },
    reason: "exact-runtime-missing",
  });
});

test("fails closed for invalid constraints, candidate versions, or no compatible runtime", () => {
  for (const input of [
    { nodeRanges: ["workspace:*"] },
    {
      nodeRanges: ["*"],
      candidates: [{ nodeVersion: "v18", status: "installed" }],
    },
    {
      nodeRanges: ["<14"],
      candidates: [
        { nodeVersion: "18.20.0", npmVersion: "10.8.2", status: "installed" },
      ],
    },
  ]) {
    assert.equal(
      planRuntime({ npmRange: ">=7", candidates: [], ...input }).status,
      "blocked",
    );
  }
});
