import type {
  RunRecord,
  RunRecordStore,
} from "../application/ports/run-lifecycle.js";
import { InfrastructureError } from "./infrastructure-error.js";
import { ProjectFileSystem } from "./project-files.js";

const RUN_RECORD_PATH = ".angular-migration/run.json";

export class RunRecordStoreAdapter implements RunRecordStore {
  constructor(private readonly files = new ProjectFileSystem()) {}

  async read(projectRoot: string): Promise<unknown> {
    const text = await this.files.readOptionalText(
      projectRoot,
      RUN_RECORD_PATH,
    );
    if (text === null) return null;
    try {
      return JSON.parse(text) as unknown;
    } catch {
      throw new InfrastructureError(
        "run_record_invalid",
        "The persisted run record contains invalid JSON.",
      );
    }
  }

  async write(projectRoot: string, record: RunRecord): Promise<void> {
    let content: string;
    try {
      content = `${JSON.stringify(record)}\n`;
    } catch {
      throw new InfrastructureError(
        "run_record_invalid",
        "The run record cannot be serialized safely.",
      );
    }
    await this.files.writeAtomically(projectRoot, RUN_RECORD_PATH, content);
  }
}
