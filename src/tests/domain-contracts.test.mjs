import assert from "node:assert/strict";
import { test } from "node:test";
import { createProjectId, createRunId } from "../dist/domain/identity.js";
import {
  createInitialRunState,
  decideRunTransition,
} from "../dist/domain/run-state.js";

const initial = () =>
  createInitialRunState({
    runId: "run-1",
    projectId: "project-1",
    sourceMajor: 21,
    targetMajor: 22,
  });

test("identity constructors reject empty and non-string values", () => {
  for (const value of ["", "  ", null, 42]) {
    assert.throws(() => createProjectId(value), {
      code: "invalid_project_id",
      category: "invalid-identity",
    });
    assert.throws(() => createRunId(value), {
      code: "invalid_run_id",
      category: "invalid-identity",
    });
  }
});

test("new runs start at the versioned baseline state", () => {
  const state = initial();
  assert.equal(state.schemaVersion, 1);
  assert.equal(state.status, "running");
  assert.equal(state.stage, "baseline");
  assert.equal(state.revision, 0);
  assert.equal(state.sourceMajor, 21);
  assert.equal(state.targetMajor, 22);
  assert.throws(
    () =>
      createInitialRunState({
        runId: "run-1",
        projectId: "project-1",
        sourceMajor: 21,
        targetMajor: 23,
      }),
    { code: "non_sequential_angular_major" },
  );
});

test("table-driven allowed transitions advance exactly one revision", () => {
  const transitions = [
    ["running", "baseline", "running", "resolve", "none"],
    ["running", "resolve", "running", "update-angular", "none"],
    ["running", "update-angular", "running", "update-dependencies", "none"],
    ["running", "update-dependencies", "running", "install", "none"],
    ["running", "install", "running", "validate", "none"],
    ["running", "update-angular", "needs-repair", "update-angular", "none"],
    ["running", "validate", "needs-repair", "validate", "none"],
    ["running", "validate", "verified", "document", "none"],
    ["running", "baseline", "blocked", "baseline", "none"],
    ["running", "baseline", "failed", "baseline", "none"],
    ["blocked", "baseline", "running", "baseline", "human-confirmed-retry"],
    ["needs-repair", "validate", "running", "validate", "repair-verified"],
    ["verified", "document", "completed", "done", "documentation-completed"],
  ];

  for (const [
    fromStatus,
    fromStage,
    toStatus,
    toStage,
    evidence,
  ] of transitions) {
    const state = { ...initial(), status: fromStatus, stage: fromStage };
    const decision = decideRunTransition(
      state,
      { status: toStatus, stage: toStage },
      evidence,
    );
    assert.equal(
      decision.outcome,
      "allowed",
      `${fromStatus}/${fromStage} -> ${toStatus}/${toStage}`,
    );
    assert.equal(decision.value.status, toStatus);
    assert.equal(decision.value.stage, toStage);
    assert.equal(decision.value.revision, 1);
  }
});

test("illegal transitions and invalid revisions are rejected", () => {
  const rejectedTransitions = [
    [
      { ...initial(), stage: "baseline" },
      { status: "running", stage: "baseline" },
      "none",
    ],
    [
      { ...initial(), stage: "baseline" },
      { status: "running", stage: "update-angular" },
      "none",
    ],
    [
      { ...initial(), stage: "resolve" },
      { status: "running", stage: "baseline" },
      "none",
    ],
    [
      { ...initial(), stage: "baseline" },
      { status: "blocked", stage: "resolve" },
      "none",
    ],
    [
      { ...initial(), stage: "baseline" },
      { status: "needs-repair", stage: "baseline" },
      "none",
    ],
    [
      { ...initial(), status: "needs-repair", stage: "validate" },
      { status: "running", stage: "update-angular" },
      "repair-verified",
    ],
    [
      { ...initial(), status: "blocked", stage: "baseline" },
      { status: "running", stage: "resolve" },
      "human-confirmed-retry",
    ],
    [
      { ...initial(), status: "failed", stage: "validate" },
      { status: "running", stage: "validate" },
      "human-confirmed-retry",
    ],
    [
      { ...initial(), status: "verified", stage: "document" },
      { status: "running", stage: "validate" },
      "none",
    ],
    [
      { ...initial(), status: "completed", stage: "done" },
      { status: "running", stage: "done" },
      "none",
    ],
  ];

  for (const [state, next, evidence] of rejectedTransitions) {
    const decision = decideRunTransition(state, next, evidence);
    assert.equal(
      decision.outcome,
      "rejected",
      `${state.status}/${state.stage} -> ${next.status}/${next.stage}`,
    );
    if (decision.outcome === "rejected") {
      assert.equal(decision.error.code, "invalid_run_transition");
      assert.equal(decision.error.category, "invalid-state");
    }
  }

  const malformedStates = [
    { ...initial(), status: "needs-repair", stage: "baseline" },
    { ...initial(), status: "running", stage: "done" },
    { ...initial(), status: "verified", stage: "validate" },
    { ...initial(), schemaVersion: 2 },
  ];
  for (const state of malformedStates) {
    const decision = decideRunTransition(
      state,
      { status: "running", stage: "resolve" },
      "repair-verified",
    );
    assert.equal(decision.outcome, "rejected");
    if (decision.outcome === "rejected") {
      assert.equal(decision.error.code, "invalid_run_state");
      assert.equal(decision.error.category, "invalid-state");
    }
  }

  for (const revision of [-1, Number.MAX_SAFE_INTEGER, Number.NaN]) {
    const decision = decideRunTransition(
      { ...initial(), revision },
      { status: "running", stage: "resolve" },
    );
    assert.equal(decision.outcome, "rejected");
    if (decision.outcome === "rejected") {
      assert.equal(decision.error.code, "invalid_run_revision");
      assert.equal(decision.error.category, "invalid-state");
    }
  }

  const invalidMajor = decideRunTransition(
    { ...initial(), sourceMajor: 22, targetMajor: 21 },
    { status: "running", stage: "resolve" },
  );
  assert.equal(invalidMajor.outcome, "rejected");
  if (invalidMajor.outcome === "rejected") {
    assert.equal(invalidMajor.error.code, "non_sequential_angular_major");
    assert.equal(invalidMajor.error.category, "policy-violation");
  }
});

test("retry, repair, and documentation transitions require their matching evidence", () => {
  const blocked = { ...initial(), status: "blocked" };
  const retryRequired = decideRunTransition(blocked, {
    status: "running",
    stage: "baseline",
  });
  assert.equal(retryRequired.outcome, "requires-human-action");
  if (retryRequired.outcome === "requires-human-action") {
    assert.equal(retryRequired.error.code, "retry_confirmation_required");
    assert.equal(retryRequired.error.category, "human-action-required");
  }
  assert.equal(
    decideRunTransition(
      blocked,
      { status: "running", stage: "baseline" },
      "human-confirmed-retry",
    ).outcome,
    "allowed",
  );

  const needsRepair = {
    ...initial(),
    status: "needs-repair",
    stage: "validate",
  };
  const repairRequired = decideRunTransition(needsRepair, {
    status: "running",
    stage: "validate",
  });
  assert.equal(repairRequired.outcome, "requires-human-action");
  if (repairRequired.outcome === "requires-human-action") {
    assert.equal(repairRequired.error.code, "repair_verification_required");
  }
  assert.equal(
    decideRunTransition(
      needsRepair,
      { status: "running", stage: "validate" },
      "repair-verified",
    ).outcome,
    "allowed",
  );

  const verified = { ...initial(), status: "verified", stage: "document" };
  const docsRequired = decideRunTransition(verified, {
    status: "completed",
    stage: "done",
  });
  assert.equal(docsRequired.outcome, "requires-human-action");
  if (docsRequired.outcome === "requires-human-action") {
    assert.equal(docsRequired.error.code, "documentation_completion_required");
  }
  assert.equal(
    decideRunTransition(
      verified,
      { status: "completed", stage: "done" },
      "documentation-completed",
    ).outcome,
    "allowed",
  );
});
