import { randomUUID } from "node:crypto";
import { ProjectFileSystem, type FileIdentity } from "./project-files.js";

const LOCK_PATH = ".angular-migration/discovery.lock";

export type LockReleaseResult =
  | { readonly kind: "released" }
  | { readonly kind: "ownership-lost" }
  | { readonly kind: "recovery-required" };

export type ProjectLockResult =
  | { readonly kind: "contended" }
  | { readonly kind: "recovery-required" }
  | {
      readonly kind: "acquired";
      readonly release: () => Promise<LockReleaseResult>;
    };

interface LockRecord {
  readonly schemaVersion: 1;
  readonly ownerPid: number;
  readonly ownerToken: string;
}

export class ProjectLock {
  constructor(private readonly files = new ProjectFileSystem()) {}

  async acquire(projectRoot: string): Promise<ProjectLockResult> {
    const ownerToken = randomUUID();
    const record: LockRecord = {
      schemaVersion: 1,
      ownerPid: process.pid,
      ownerToken,
    };
    let created:
      | { readonly created: false }
      | { readonly created: true; readonly identity: FileIdentity };
    try {
      created = await this.files.createExclusiveFile(
        projectRoot,
        LOCK_PATH,
        JSON.stringify(record),
      );
    } catch {
      return { kind: "recovery-required" };
    }
    if (!created.created) return { kind: "contended" };

    try {
      const persisted = await this.files.readJson(projectRoot, LOCK_PATH);
      if (
        !isLockRecord(persisted) ||
        persisted.ownerToken !== ownerToken ||
        persisted.ownerPid !== process.pid
      ) {
        return { kind: "recovery-required" };
      }
    } catch {
      return { kind: "recovery-required" };
    }

    let released = false;
    return {
      kind: "acquired",
      release: async () => {
        if (released) return { kind: "released" };
        let persisted: unknown;
        try {
          persisted = await this.files.readJson(projectRoot, LOCK_PATH);
        } catch {
          return { kind: "recovery-required" };
        }
        if (
          !isLockRecord(persisted) ||
          persisted.ownerToken !== ownerToken ||
          persisted.ownerPid !== process.pid
        ) {
          return { kind: "ownership-lost" };
        }

        try {
          released = await this.files.removeIfIdentityMatches(
            projectRoot,
            LOCK_PATH,
            created.identity,
          );
          return released ? { kind: "released" } : { kind: "ownership-lost" };
        } catch {
          return { kind: "recovery-required" };
        }
      },
    };
  }
}

function isLockRecord(value: unknown): value is LockRecord {
  return Boolean(
    value &&
    typeof value === "object" &&
    "schemaVersion" in value &&
    value.schemaVersion === 1 &&
    "ownerPid" in value &&
    typeof value.ownerPid === "number" &&
    Number.isSafeInteger(value.ownerPid) &&
    value.ownerPid > 0 &&
    "ownerToken" in value &&
    typeof value.ownerToken === "string" &&
    /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value.ownerToken),
  );
}
