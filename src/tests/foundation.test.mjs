import assert from "node:assert/strict";
import { versions } from "node:process";
import { test } from "node:test";
import { controllerNodeMajor } from "../dist/index.js";

test("compiled controller entrypoint targets Node 22", () => {
  assert.equal(controllerNodeMajor, 22);
  assert.equal(Number.parseInt(versions.node, 10), controllerNodeMajor);
});
