"use strict";

const fs = require("fs");
const path = require("path");

const inputPath = process.argv[2];
if (!inputPath) {
  process.stderr.write("Usage: node inspect-lockfile.js <package-lock.json>\n");
  process.exit(2);
}

try {
  const lockfile = JSON.parse(fs.readFileSync(path.resolve(inputPath), "utf8"));
  const lockfileVersion = lockfile.lockfileVersion;
  if (![1, 2, 3].includes(lockfileVersion)) {
    throw new Error("Unsupported lockfile version");
  }

  const entries =
    lockfileVersion === 1 ? lockfile.dependencies : lockfile.packages;
  if (!entries || typeof entries !== "object" || Array.isArray(entries)) {
    throw new Error("Invalid lockfile layout");
  }

  const versions = {};
  for (const [entryName, entry] of Object.entries(entries)) {
    const match =
      lockfileVersion === 1
        ? null
        : entryName.match(/^node_modules\/(?:@([^/]+)\/)?([^/]+)$/);
    const packageName =
      lockfileVersion === 1
        ? entryName
        : match && (match[1] ? `@${match[1]}/${match[2]}` : match[2]);
    if (packageName && entry && typeof entry.version === "string") {
      versions[packageName] = entry.version;
    }
  }

  process.stdout.write(JSON.stringify({ lockfileVersion, versions }));
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
