# Step 08 Cutover and Host Integration Evidence

## Decision

This is a preparation report, not authorization to edit host files. No file outside `src/` was changed. The candidate allowlist below requires explicit human approval; the implementation invocation must only begin after the human marks this step `ACTIVE` again.

The host executables are present, and the TypeScript CLI can start under the exact Node 22 runtime. A successful Copilot CLI plugin listing only proves metadata discovery. The controller package is not ready for a clean installation, the current hooks do not understand the TypeScript state contract, and no agent/hook startup or real Angular migration was run. Keep this step `BLOCKED` until the packaging and hook decisions below are accepted and the approved host smoke passes.

## Environment and Observations

- Branch: `migration_to_TS`.
- Windows PowerShell 5.1.26100.9444; PowerShell 7.6.6 at `C:\Program Files\PowerShell\7\pwsh.exe`.
- GitHub Copilot CLI 1.0.88 at `C:\Users\jsingh\AppData\Local\Microsoft\WinGet\Packages\GitHub.Copilot_Microsoft.Winget.Source_8wekyb3d8bbwe\copilot.exe`.
- `fnm` is available and `fnm exec --using 22.19.0 -- node --version` returned `v22.19.0`.
- `scripts/install-host-prerequisites.ps1` without `-Install` returned `status: ready`; it reported `pwsh.exe` and `copilot.exe` available and performed no installation.
- `copilot.exe plugin list --json` showed the installed marketplace plugin `angular-migration@sjashan513-plugins` v5.0.2. `copilot.exe --plugin-dir . plugin list --json` also recognized the local repository as an external `angular-migration` v5.0.2 plugin. Both entries were enabled. This is a name/version collision, not evidence that TypeScript agents or hooks work.
- `fnm exec --using 22.19.0 -- node .\src\dist\entrypoints\main.js inspect --project-root <repo>\src` started the compiled controller and returned one JSON envelope with `status: blocked`, `error.code: project_facts_invalid`, and exit code 2. The package directory is not an Angular project. This proves process startup and output shape only; it is not a successful project inspection or Copilot-host smoke.
- The equivalent read-only request against the repository root returned `project_file_read_failed`, because the repository root is not a supported Angular project.
- No Copilot login, interactive agent invocation, hook permission exercise, marketplace install, or real Angular pilot was performed.

## Launch and Packaging

The current TypeScript launch contract is:

- `src/package.json` is private, targets Node 22, and declares `semver` as a runtime dependency.
- `npm run build` emits `src/dist`; `npm run cli` runs `node dist/entrypoints/main.js`.
- The package `main` points to `dist/index.js`, which is not the CLI entrypoint. `src/index.ts` exports only `controllerNodeMajor`.
- `src/dist` is ignored and `src/node_modules` is local state. A clean clone therefore has neither compiled CLI output nor its runtime dependency. `copilot plugin install` does not run this package's `npm ci` or build scripts.
- The documented build procedure selects Node explicitly and invokes the npm CLI bundled beside that Node. It does not use `fnm use` or rely on the shell's default Node.

Proposed Windows launch after an approved one-time preparation step:

1. Require `fnm` and the exact controller runtime `22.19.0` to be available. Do not install either runtime or dependencies implicitly.
2. From the plugin checkout, run the locked dependency install and build using the `npm-cli.js` belonging to Node 22.19.0, following `src/README.md`.
3. Invoke the controller as `fnm exec --using 22.19.0 -- node <plugin-root>\src\dist\entrypoints\main.js <command> --project-root <absolute-project-root>`. Pass executable and arguments as separate process arguments; preserve the CLI JSON stdout and exit code.
4. Keep project operations routed through the controller's existing `fnm exec --using <selected-version> -- ...` adapters. Do not change the global Node selection.

This is a development-checkout launch route, not yet a distributable package. Before implementation approval, the human must choose whether the host setup is an explicit local build step or a staged release bundle containing `dist` and production dependencies. The repo currently has no generated release bundle or Copilot plugin installation lifecycle that prepares them. A release build must not silently fetch dependencies or a runtime.

## Hook Gap

`hooks.json` currently starts the project's copied `.angular-migration/runtime/copilot-policy.ps1` for `preToolUse` and `subagentStop`. `scripts/hooks/copilot-policy.ps1` validates the v5 state contract. If `active.lock` is not schema version 5, it returns `{}` and allows normal host behavior. Reusing that policy for the new TypeScript contract would therefore fail open.

The TypeScript CLI currently has no Copilot hook command or hook-policy adapter. A safe cutover must add and test a TypeScript policy against the new versioned state, deploy the exact runtime asset that the project hook invokes, and make unsupported/corrupt state fail closed. The hook and controller switch must be atomic from the user's perspective. Do not update `hooks.json` to call the legacy policy for TypeScript runs.

## Candidate External Allowlist

The following list is the proposed allowlist for a later implementation invocation. It is not approval. Proposed plugin release version is `6.0.0` because v5 persisted runs are not compatible; the human must confirm that version before any metadata edit.

| Operation | Exact path                                  | Purpose and corresponding validation                                                                                                                                                                                      |
| --------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Add       | `scripts/prepare-typescript-controller.ps1` | Explicit, repeatable Node 22.19.0 `npm ci` and build preparation; validate clean-checkout setup and fail without changing runtimes when prerequisites are absent.                                                         |
| Add       | `scripts/angular-migration-ts.ps1`          | Thin PowerShell host shim that starts the built CLI via `fnm exec --using 22.19.0`; verify literal argument forwarding, JSON stdout, stderr separation, and exit codes.                                                   |
| Add       | `scripts/hooks/copilot-policy-ts.ps1`       | Host-compatible shim for the TypeScript hook entrypoint/runtime asset; exercise both hook events through actual Copilot CLI and focused hook tests.                                                                       |
| Update    | `hooks.json`                                | Route both events to the new policy only after the TypeScript hook asset is built and deployed; retain the existing event names and bounded timeout. Validate actual allow and deny decisions in the host.                |
| Update    | `plugin.json`                               | Set the human-approved v6 release version; preserve the existing agent, skill, and hook registrations unless the approved package layout requires a named path change. Validate manifest loading.                         |
| Update    | `marketplace.json`                          | Keep plugin and marketplace metadata versions/descriptions consistent with `plugin.json`; proposed version is `6.0.0`. Validate local marketplace parsing and host listing.                                               |
| Update    | `agents/migration-implementer.agent.md`     | Replace v5 facade/state instructions with the TypeScript CLI contract; validate repair scope and submission through a disposable run.                                                                                     |
| Update    | `agents/migration-documenter.agent.md`      | Replace v5 documentation-context instructions with the TypeScript contract; validate research/publish permissions and stop conditions.                                                                                    |
| Update    | `skills/angular-migration/SKILL.md`         | Replace PowerShell v5 commands, options, and envelope assumptions with the implemented CLI and explicit approvals; validate the read-only and fixture workflows end to end.                                               |
| Update    | `README.md`                                 | Make the TypeScript path canonical and document Node/fnm/build prerequisites, installation, invocation, and v5 data incompatibility. Validate every command against the built package.                                    |
| Update    | `docs/README.md`                            | Reconcile the behavior reference with the TypeScript product while identifying retained v5 implementation/tests as legacy rollback assets. Validate documented commands and contract claims.                              |
| Update    | `docs/flujo-del-pipeline.md`                | Replace v5-only lifecycle and facade claims with the TypeScript lifecycle. Validate each described transition against implementation tests.                                                                               |
| Update    | `docs/host-prerequisites.md`                | Require/check `fnm` and Node 22.19.0 plus the explicit package preparation; do not auto-install runtime or npm dependencies. Validate check-only and missing-prerequisite behavior.                                       |
| Update    | `docs/ANGULAR-MIGRATION-PLUGIN-CHANGES.md`  | Record the approved v6 host and package contract and the no-v5-run-compatibility boundary. Validate all listed release paths.                                                                                             |
| Update    | `scripts/install-host-prerequisites.ps1`    | Extend check-only reporting to `fnm`, exact Node, and prepared package; do not add implicit runtime/dependency installation. Validate ready/blocked JSON on the target host.                                              |
| Update    | `tests/smoke.ps1`                           | Assert the v6 manifest, built launch contract, and new hook registration while retaining legacy assertions only for the rollback path. Run the root smoke suite.                                                          |
| Add       | `tests/host-smoke.ps1`                      | Opt-in, target-host checks for plugin discovery, startup, hook allow/deny, read-only inspect, fixture workflow, envelope/exit behavior, and teardown. Run only against an isolated plugin profile and disposable fixture. |

The TypeScript implementation and focused tests required by this allowlist remain within `src/`; likely touched source surfaces include `src/package.json`, the CLI/hook entrypoint and runtime deployment path, plus their `src/tests/` coverage. No source contract should be inferred from the legacy schemas. The exact source paths must be recorded in the implementation diff and reviewed against this proposal.

### Retain During Cutover

Do not add removals to this allowlist. Keep these v5 rollback assets unchanged through the plugin smoke, the real disposable-project pilot, and human acceptance:

- `scripts/angular-migration.ps1`;
- `scripts/modules/Migration.Core.psm1`, `Migration.Dependencies.psm1`, `Migration.Pipeline.psm1`, `Migration.Project.psm1`, and `Migration.State.psm1`;
- `scripts/hooks/copilot-policy.ps1` and both `scripts/js/` helpers;
- all existing v5 schemas, root Pester/unit/integration fixtures, and the existing `tests/e2e/Invoke-Angular7To8.ps1`.

Retire any of these only in a later invocation with a separate exact remove-path allowlist, after the host smoke and pilot are accepted and the human confirms no v5 run needs the facade. Do not migrate or delete persisted v5 project data. Never run a v5 controller against a project whose `.angular-migration/` has been initialized by the TypeScript controller.

## Validation Plan After Approval

1. In a clean checkout, prove preparation either creates the documented build from the locked package or fails closed with a precise missing-prerequisite report. Confirm no global Node switch and no unapproved runtime/dependency installation.
2. Run TypeScript typecheck, build, all four test tiers, the updated root smoke, and legacy PowerShell tests that protect the rollback path.
3. Use a separate Copilot CLI profile or disposable host account to avoid the currently installed v5 marketplace plugin colliding with the local plugin. Verify the v6 plugin is discovered, enabled, and starts its registered agents and hooks. Record exact executable, CLI version, plugin version/source, commands, exit codes, and redacted output.
4. On a disposable, clean-Git Angular 7 fixture, invoke `inspect` through the host and verify a successful read-only JSON envelope without project changes. Exercise hook allow/deny behavior, including malformed/foreign state and subagent completion without a valid submission.
5. Run one approved Angular 7 -> 8 fixture migration through the host using real supported npm/Angular commands and the chosen project Node via exact `fnm exec`. Record every approval, checkpoint, final status, project diff, and teardown. The existing TypeScript E2E test uses real filesystem/Git persistence but simulated npm/fnm/migration work and is not a substitute.
6. Exercise rollback in the isolated host profile: restore the saved v5 plugin/hook/agent/skill/metadata files, confirm the v5 plugin can again be listed and launched, and leave all fixture `.angular-migration/` data intact. Do not use destructive Git restore commands or alter the user's real project.
7. Human accepts the smoke and rollback evidence. Without that acceptance, keep PowerShell and the v5 entry path intact and leave this roadmap step blocked.

## Rollback

Before switching any host metadata, preserve the exact pre-cutover contents and version of `plugin.json`, `marketplace.json`, `hooks.json`, both migration agents, and `skills/angular-migration/SKILL.md`. Build and test the TypeScript path side by side first. If host discovery, permissions, startup, output, or the pilot fails, restore only those approved host files from the preserved copies, disable/remove the isolated v6 test plugin, and re-enable the existing v5 plugin. Leave newly created source/build artifacts and all project audit/runtime data untouched. Do not invoke the v5 controller on a TypeScript-initialized `.angular-migration/` directory; recover that fixture only by preserving it for diagnosis or deleting the disposable fixture as a whole after evidence is captured and approved.

## Open Blockers

- The installed CLI was not authenticated or used to launch an agent; actual plugin startup, permissions, and hook execution remain unverified.
- Local discovery currently presents two enabled `angular-migration` plugins at v5.0.2. An isolated host profile is required for smoke and rollback.
- A clean-install distribution path for ignored `dist` and runtime `semver` dependencies is not implemented. Human decision is required between explicit local preparation and a staged release bundle.
- The TypeScript hook policy, deployment, and fail-closed behavior do not exist yet; the current v5 hook is fail-open for a non-v5 lock.
- A successful read-only inspection of a valid Angular project and a real Angular 7 -> 8 pilot have not been run.
- The host prerequisites checker currently does not report `fnm`, Node 22.19.0, or whether the TypeScript package has been prepared.

No external files or roadmap files were changed. This evidence does not satisfy the final host gate and does not authorize integration edits.
