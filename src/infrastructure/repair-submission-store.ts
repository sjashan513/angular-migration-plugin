import { InfrastructureError } from "./infrastructure-error.js";
import { ProjectFileSystem } from "./project-files.js";

export class RepairSubmissionStoreAdapter {
  constructor(private readonly files = new ProjectFileSystem()) {}

  async read(projectRoot: string, runId: string): Promise<unknown> {
    if (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(runId)) {
      throw new InfrastructureError(
        "repair_submission_invalid",
        "The repair inbox run id is invalid.",
      );
    }
    const path = `.angular-migration/repair-inbox/${runId}.json`;
    const text = await this.files.readOptionalText(projectRoot, path);
    if (text === null) {
      throw new InfrastructureError(
        "repair_submission_missing",
        "No controller-owned repair submission is available.",
      );
    }
    try {
      return JSON.parse(text) as unknown;
    } catch {
      throw new InfrastructureError(
        "repair_submission_invalid",
        "The repair submission contains invalid JSON.",
      );
    }
  }
}
