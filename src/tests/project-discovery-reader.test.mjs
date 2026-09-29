import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  discoverProject,
  readValidatedDiscoveryRecord,
} from "../dist/application/discover-project.js";
import {
  DiscoveryRecordStoreAdapter,
  ProjectValueHasher,
} from "../dist/infrastructure/discovery-persistence.js";
import { ProjectDiscoveryReaderAdapter } from "../dist/infrastructure/project-discovery-reader.js";

async function withProject(callback) {
  const root = await fs.mkdtemp(path.join(tmpdir(), "angular-discovery-"));
  const bin = await fs.mkdtemp(path.join(tmpdir(), "angular-tools-"));
  try {
    for (const executable of ["git.exe", "fnm.exe"])
      await fs.writeFile(path.join(bin, executable), "fixture");
    await writeFixture(root);
    await callback(root, bin);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
    await fs.rm(bin, { recursive: true, force: true });
  }
}

async function writeFixture(root, overrides = {}) {
  const packageJson = {
    name: "sample-angular",
    dependencies: {
      "@angular/core": "^7.2.0",
      "@angular/cli": "~7.3.0",
    },
    devDependencies: { "@angular/compiler-cli": "^7.2.0" },
    scripts: {
      "type-check": "tsc --noEmit",
      lint: "eslint .",
      build: "ng build",
    },
    ...overrides.packageJson,
  };
  const lockfile = {
    name: "sample-angular",
    lockfileVersion: 3,
    packages: {
      "": { name: "sample-angular" },
      "node_modules/@angular/core": { version: "7.2.16" },
      "node_modules/@angular/cli": { version: "7.3.10" },
      "node_modules/@angular/compiler-cli": { version: "7.2.16" },
      ...overrides.lockPackages,
    },
  };
  await fs.writeFile(
    path.join(root, "package.json"),
    JSON.stringify(packageJson),
  );
  await fs.writeFile(
    path.join(root, "package-lock.json"),
    JSON.stringify(lockfile),
  );
  await fs.writeFile(
    path.join(root, "angular.json"),
    JSON.stringify({
      version: 1,
      projects: { app: { projectType: "application" } },
    }),
  );
}

function makeAdapter(bin, overrides = {}) {
  const calls = [];
  const runProcess = async (request) => {
    calls.push(request);
    if (request.executable.endsWith("git.exe")) {
      if (request.arguments[0] === "rev-parse")
        return exited(
          0,
          request.arguments[1] === "--show-prefix" ? "" : "a".repeat(40),
        );
      return exited(0, overrides.gitStatus ?? "");
    }
    if (request.arguments[0] === "list")
      return exited(
        0,
        overrides.installed ?? "* v20.18.0 default\r\n* v16.20.2\r\nsystem\r\n",
      );
    if (request.arguments[0] === "list-remote")
      return exited(0, overrides.remote ?? "v16.20.2\n");
    throw new Error(
      `Unexpected process request: ${request.arguments.join(" ")}`,
    );
  };
  const runRuntime = async (request) => {
    calls.push(request);
    if (request.executable === "node")
      return exited(0, `v${request.nodeVersion}`);
    if (request.executable === "npm" && request.arguments[0] === "--version")
      return exited(
        0,
        overrides.npmVersions?.[request.nodeVersion] ?? "10.8.2",
      );
    if (request.executable === "npm" && request.arguments[0] === "view") {
      const selector = request.arguments[1];
      const name = selector.slice(0, selector.lastIndexOf("@"));
      const version =
        name.endsWith("core") || name.endsWith("compiler-cli")
          ? "8.2.14"
          : "8.3.29";
      return exited(
        0,
        JSON.stringify([
          {
            version,
            engines: { node: ">=10.9.0" },
            peerDependencies:
              overrides.peerDependencies ??
              (name.endsWith("compiler-cli") ? { "@angular/core": "8.x" } : {}),
          },
        ]),
      );
    }
    throw new Error(`Unexpected runtime request: ${request.executable}`);
  };
  const runNpm = async (request) => {
    calls.push({ ...request, executable: "npm" });
    if (request.arguments[0] === "--version")
      return exited(
        0,
        overrides.npmVersions?.[request.nodeVersion] ?? "10.8.2",
      );
    if (request.arguments[0] === "view") {
      const selector = request.arguments[1];
      const name = selector.slice(0, selector.lastIndexOf("@"));
      const version =
        name.endsWith("core") || name.endsWith("compiler-cli")
          ? "8.2.14"
          : "8.3.29";
      return exited(
        0,
        JSON.stringify([
          {
            version,
            engines: { node: ">=10.9.0" },
            peerDependencies:
              overrides.peerDependencies ??
              (name.endsWith("compiler-cli") ? { "@angular/core": "8.x" } : {}),
          },
        ]),
      );
    }
    throw new Error(`Unexpected npm request: ${request.arguments.join(" ")}`);
  };
  return {
    calls,
    adapter: new ProjectDiscoveryReaderAdapter({
      environment: {
        Path: bin,
        PATHEXT: ".EXE",
        MIGRATION_IPS_REGISTRY: overrides.trustedIpsRegistry ?? "",
      },
      runProcess,
      runRuntime,
      runNpm,
    }),
  };
}

function exited(exitCode, stdout = "") {
  return {
    kind: "exited",
    exitCode,
    stdout,
    stderr: "",
    stdoutTruncated: false,
    stderrTruncated: false,
  };
}

test("inspects a root npm Angular project and resolves exact target metadata under fnm", async () => {
  await withProject(async (root, bin) => {
    const { adapter, calls } = makeAdapter(bin);
    const inputs = await adapter.read(root, 8);

    assert.equal(inputs.sourceMajor, 7);
    assert.equal(inputs.projectShape, "root-angular-cli");
    assert.equal(inputs.gitStatus, "clean");
    assert.equal(inputs.registryStatus, "trusted");
    assert.deepEqual(inputs.registryIdentities, [
      { scope: "default", registryId: "npmjs" },
    ]);
    assert.equal(inputs.lockfileVersion, 3);
    assert.equal(inputs.runtimeCandidates[0].nodeVersion, "20.18.0");
    assert.equal(inputs.runtimeCandidates[0].npmVersion, "10.8.2");
    assert.deepEqual(
      inputs.packages.map(({ name, targetVersion }) => [name, targetVersion]),
      [
        ["@angular/cli", "8.3.29"],
        ["@angular/compiler-cli", "8.2.14"],
        ["@angular/core", "8.2.14"],
      ],
    );
    assert.deepEqual(
      inputs.packages.find(({ name }) => name === "@angular/compiler-cli")
        .peerDependencies,
      [{ name: "@angular/core", range: "8.x" }],
    );
    assert.ok(
      calls.some(
        (call) => call.nodeVersion === "20.18.0" && call.executable === "node",
      ),
    );
  });
});

test("rejects invalid peer constraints returned by npm metadata", async () => {
  await withProject(async (root, bin) => {
    const { adapter } = makeAdapter(bin, {
      peerDependencies: { "@angular/core": "workspace:*" },
    });
    const inputs = await adapter.read(root, 8);

    assert.deepEqual(inputs.packages, []);
    assert.ok(
      inputs.issues.some(({ code }) => code === "registry_metadata_invalid"),
    );
  });
});

test("persists a complete ready plan and validates it after discovery rereads", async () => {
  await withProject(async (root, bin) => {
    const { adapter } = makeAdapter(bin);
    const records = new DiscoveryRecordStoreAdapter();
    const hasher = new ProjectValueHasher();
    const packageBefore = await fs.readFile(
      path.join(root, "package.json"),
      "utf8",
    );
    const plan = await discoverProject(
      { projectRoot: root, targetMajor: 8 },
      { reader: adapter, records, hasher },
    );
    const currentInputs = await adapter.read(root, 8);
    const loaded = await readValidatedDiscoveryRecord(
      await records.read(root),
      {
        projectId: currentInputs.projectId,
        inputFingerprint: currentInputs.inputFingerprint,
        targetMajor: 8,
      },
      hasher,
    );

    assert.equal(plan.status, "ready");
    assert.deepEqual(loaded, plan);
    assert.equal(
      plan.checks.find(({ id }) => id === "typecheck").arguments[1],
      "type-check",
    );
    assert.equal(
      await fs.readFile(path.join(root, "package.json"), "utf8"),
      packageBefore,
    );
  });
});

test("proposes a filtered remote runtime without installing it", async () => {
  await withProject(async (root, bin) => {
    const packageJson = JSON.parse(
      await fs.readFile(path.join(root, "package.json"), "utf8"),
    );
    packageJson.engines = { node: ">=14 <17" };
    await fs.writeFile(
      path.join(root, "package.json"),
      JSON.stringify(packageJson),
    );
    const { adapter, calls } = makeAdapter(bin, {
      installed: "* v20.18.0 default\r\nsystem\r\n",
      remote: "v16.20.2\n",
    });
    const inputs = await adapter.read(root, 8);

    assert.equal(inputs.runtimeCandidates.at(-1).nodeVersion, "16.20.2");
    assert.equal(inputs.runtimeCandidates.at(-1).status, "missing");
    assert.ok(calls.some((call) => call.arguments[0] === "list-remote"));
    assert.ok(!calls.some((call) => call.arguments?.includes("install")));
  });
});

test("fails private @ips registry trust closed and reports dirty Git state", async () => {
  await withProject(async (root, bin) => {
    await fs.writeFile(
      path.join(root, ".npmrc"),
      "@ips:registry=https://evil.example/\n",
    );
    const packageJson = JSON.parse(
      await fs.readFile(path.join(root, "package.json"), "utf8"),
    );
    packageJson.dependencies["@ips/private"] = "^1.0.0";
    await fs.writeFile(
      path.join(root, "package.json"),
      JSON.stringify(packageJson),
    );
    const lockfile = JSON.parse(
      await fs.readFile(path.join(root, "package-lock.json"), "utf8"),
    );
    lockfile.packages["node_modules/@ips/private"] = { version: "1.0.0" };
    await fs.writeFile(
      path.join(root, "package-lock.json"),
      JSON.stringify(lockfile),
    );

    const { adapter } = makeAdapter(bin, {
      gitStatus: " M package.json\n",
      trustedIpsRegistry: "https://registry.ips.example/",
    });
    const inputs = await adapter.read(root, 8);
    assert.equal(inputs.registryStatus, "untrusted");
    assert.equal(inputs.gitStatus, "dirty");
    assert.equal(
      inputs.registryIdentities.find(({ scope }) => scope === "@ips")
        .registryId,
      "untrusted",
    );
    assert.doesNotMatch(
      JSON.stringify(inputs),
      /evil\.example|registry\.ips\.example/,
    );

    await fs.writeFile(
      path.join(root, ".npmrc"),
      "@ips:registry=https://registry.ips.example/\n//registry.ips.example/:_authToken=${NPM_TOKEN}\n",
    );
    const trusted = await makeAdapter(bin, {
      trustedIpsRegistry: "https://registry.ips.example/",
    }).adapter.read(root, 8);
    assert.equal(trusted.registryStatus, "trusted");
    assert.equal(
      trusted.registryIdentities.find(({ scope }) => scope === "@ips")
        .registryId,
      "ips-private",
    );
    assert.doesNotMatch(
      JSON.stringify(trusted),
      /registry\.ips\.example|NPM_TOKEN/,
    );
  });
});
