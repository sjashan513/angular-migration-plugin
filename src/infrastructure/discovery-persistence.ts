import { createHash } from "node:crypto";
import type {
  DiscoveryRecordStore,
  ValueHasher,
} from "../application/ports/project-discovery.js";
import { InfrastructureError } from "./infrastructure-error.js";
import { ProjectFileSystem } from "./project-files.js";

const DISCOVERY_PATH = ".angular-migration/discovery.json";

export class DiscoveryRecordStoreAdapter implements DiscoveryRecordStore {
  constructor(private readonly files = new ProjectFileSystem()) {}

  async read(projectRoot: string): Promise<unknown> {
    const text = await this.files.readOptionalText(projectRoot, DISCOVERY_PATH);
    if (text === null) return null;
    try {
      return JSON.parse(text) as unknown;
    } catch {
      throw new InfrastructureError(
        "discovery_record_invalid",
        "The persisted discovery record contains invalid JSON.",
      );
    }
  }

  async write(projectRoot: string, record: unknown): Promise<void> {
    await this.files.writeAtomically(
      projectRoot,
      DISCOVERY_PATH,
      `${JSON.stringify(record)}\n`,
    );
  }
}

export class ProjectValueHasher implements ValueHasher {
  async hash(value: unknown): Promise<string> {
    let serialized: string;
    try {
      serialized = JSON.stringify(canonicalize(value));
    } catch {
      throw new InfrastructureError(
        "hash_input_invalid",
        "The discovery value cannot be hashed safely.",
      );
    }
    if (serialized === undefined) {
      throw new InfrastructureError(
        "hash_input_invalid",
        "The discovery value cannot be hashed safely.",
      );
    }
    return `sha256:${createHash("sha256").update(serialized).digest("hex")}`;
  }

  async hashText(value: string): Promise<string> {
    if (typeof value !== "string") {
      throw new InfrastructureError(
        "hash_input_invalid",
        "Text content cannot be hashed safely.",
      );
    }
    return `sha256:${createHash("sha256").update(value, "utf8").digest("hex")}`;
  }
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return Object.fromEntries(
      Object.keys(record)
        .sort()
        .map((key) => [key, canonicalize(record[key])]),
    );
  }
  return value;
}
