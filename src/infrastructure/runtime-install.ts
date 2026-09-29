import type {
  ExactRuntimeInstaller,
  RuntimeInstallAuditEvent,
  RuntimeInstallAuditStore,
} from "../application/ports/approvals.js";
import { parseExactSemverVersion } from "../domain/semver-constraints.js";
import { InfrastructureError } from "./infrastructure-error.js";
import {
  runProcess,
  type ProcessRequest,
  type ProcessResult,
} from "./process-runner.js";
import { ProjectFileSystem } from "./project-files.js";

const AUDIT_PATH = ".angular-migration/runtime-install.json";

type ProcessRunner = (request: ProcessRequest) => Promise<ProcessResult>;

export class RuntimeInstallAuditStoreAdapter implements RuntimeInstallAuditStore {
  constructor(private readonly files = new ProjectFileSystem()) {}

  async read(projectRoot: string): Promise<unknown> {
    const text = await this.files.readOptionalText(projectRoot, AUDIT_PATH);
    if (text === null) return null;
    try {
      return JSON.parse(text) as unknown;
    } catch {
      throw new InfrastructureError(
        "runtime_install_audit_invalid",
        "Runtime installation audit history contains invalid JSON.",
      );
    }
  }

  async write(
    projectRoot: string,
    events: readonly RuntimeInstallAuditEvent[],
  ): Promise<void> {
    await this.files.writeAtomically(
      projectRoot,
      AUDIT_PATH,
      `${JSON.stringify(events)}\n`,
    );
  }
}

export class FnmExactRuntimeInstaller implements ExactRuntimeInstaller {
  constructor(
    private readonly options: {
      readonly fnmExecutable: string;
      readonly environment: Readonly<Record<string, string>>;
      readonly files?: ProjectFileSystem;
      readonly run?: ProcessRunner;
    },
  ) {}

  async install(
    projectRoot: string,
    nodeVersion: string,
  ): Promise<"installed" | "failed"> {
    if (!parseExactSemverVersion(nodeVersion)) return "failed";
    try {
      const files = this.options.files ?? new ProjectFileSystem();
      const result = await (this.options.run ?? runProcess)({
        executable: this.options.fnmExecutable,
        arguments: ["install", nodeVersion],
        cwd: await files.canonicalProjectRoot(projectRoot),
        env: this.options.environment,
        timeoutMs: 600_000,
        terminationGraceMs: 10_000,
        maxOutputBytes: 262_144,
      });
      return result.kind === "exited" && result.exitCode === 0
        ? "installed"
        : "failed";
    } catch {
      return "failed";
    }
  }
}
