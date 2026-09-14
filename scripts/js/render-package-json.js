#!/usr/bin/env node
"use strict";

const fs = require("fs");

const dependencySections = [
  "dependencies",
  "devDependencies",
  "optionalDependencies",
  "peerDependencies",
];

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}

function getIndent(packageText) {
  const lines = packageText.split(/\r?\n/);
  for (const line of lines) {
    const match = line.match(/^(\t+| +)"[^\s"]/);
    if (match) {
      return match[1].includes("\t") ? "\t" : " ".repeat(match[1].length);
    }
  }
  return "  ";
}

function hasOwn(object, name) {
  return Object.prototype.hasOwnProperty.call(object, name);
}

function render(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("Input must be a JSON object.");
  }
  if (input.mode !== "exact" && input.mode !== "declared") {
    throw new Error("mode must be exact or declared.");
  }
  if (typeof input.packageText !== "string") {
    throw new Error("packageText must be a string.");
  }
  if (!Array.isArray(input.dependencies)) {
    throw new Error("dependencies must be an array.");
  }

  let packageJson;
  try {
    packageJson = JSON.parse(input.packageText);
  } catch (error) {
    throw new Error(`packageText is not valid JSON: ${error.message}`);
  }
  if (
    !packageJson ||
    typeof packageJson !== "object" ||
    Array.isArray(packageJson)
  ) {
    throw new Error("packageText must contain a JSON object.");
  }

  const seen = new Set();
  for (const dependency of input.dependencies) {
    if (
      !dependency ||
      typeof dependency !== "object" ||
      Array.isArray(dependency)
    ) {
      throw new Error("Each dependency must be an object.");
    }
    const name = dependency.name;
    const section = dependency.section;
    if (typeof name !== "string" || name.length === 0) {
      throw new Error("Dependency name is required.");
    }
    if (!dependencySections.includes(section)) {
      throw new Error(`Unsupported dependency section: ${section}`);
    }
    if (seen.has(name)) {
      throw new Error(`Duplicate dependency: ${name}`);
    }
    seen.add(name);

    const value =
      input.mode === "exact" ? dependency.targetVersion : dependency.writeSpec;
    if (typeof value !== "string" || value.length === 0) {
      throw new Error(
        `Missing ${input.mode === "exact" ? "targetVersion" : "writeSpec"} for ${name}`,
      );
    }

    const declaredSections = dependencySections.filter((candidate) => {
      const values = packageJson[candidate];
      return (
        values &&
        typeof values === "object" &&
        !Array.isArray(values) &&
        hasOwn(values, name)
      );
    });
    if (declaredSections.length === 0) {
      const canAddRequiredTooling =
        dependency.change === "added-required-tooling" &&
        section === "devDependencies" &&
        hasOwn(packageJson, section) &&
        packageJson[section] &&
        typeof packageJson[section] === "object" &&
        !Array.isArray(packageJson[section]);
      if (!canAddRequiredTooling) {
        throw new Error(`Dependency is missing from package.json: ${name}`);
      }
      packageJson[section][name] = value;
      continue;
    }
    if (declaredSections.length !== 1 || declaredSections[0] !== section) {
      throw new Error(`Dependency is declared in the wrong section: ${name}`);
    }
    packageJson[section][name] = value;
  }

  const newline = input.packageText.includes("\r\n") ? "\r\n" : "\n";
  const hasFinalNewline = /(?:\r\n|\n)$/.test(input.packageText);
  let output = JSON.stringify(packageJson, null, getIndent(input.packageText));
  if (newline !== "\n") {
    output = output.replace(/\n/g, newline);
  }
  if (hasFinalNewline) {
    output += newline;
  }
  return output;
}

let input = "";
try {
  input = fs.readFileSync(0, "utf8");
  process.stdout.write(render(JSON.parse(input)));
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
