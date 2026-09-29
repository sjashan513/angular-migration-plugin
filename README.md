# Angular Migration

Version 6.0.0 is the TypeScript controller for sequential Angular major migrations. The controller owns discovery, runtime selection, dependency changes, checks, run state, repair application, and documentation publication. PowerShell remains only as a thin Windows host and Node/fnm integration layer.

## Scope and requirements

- Windows, Git, GitHub Copilot CLI, PowerShell 7+, fnm, and Node 22.19.0 selected through fnm.
- Angular CLI projects using npm at the repository root; one `N -> N+1` migration per run.
- A clean Git working tree before discovery. Runtime and baseline dependency changes require explicit approval.
- Yarn, pnpm, workspaces, Nx, and legacy PowerShell v5 run state are not supported.

Prepare the bundled controller from a clean checkout:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\prepare-typescript-controller.ps1 -Prepare
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-host-prerequisites.ps1
```

The preparer uses the npm CLI adjacent to Node 22.19.0, runs `npm ci --ignore-scripts` in `src/`, and builds `src/dist/entrypoints/main.mjs`. The prerequisite check does not install fnm, Node, or the bundle. Its `-Install` option is limited to `pwsh.exe` and `copilot.exe` via WinGet.

## Migration flow

The Windows wrapper is `scripts/angular-migration-ts.ps1`. Commands emit a JSON schema 1 envelope; exit codes are 0 for success, 1 for failure, and 2 for a block or required human action.

```powershell
$cli = '.\scripts\angular-migration-ts.ps1'
$project = 'C:\src\my-angular-app'

powershell.exe -NoProfile -File $cli inspect --project-root $project
powershell.exe -NoProfile -File $cli discover --project-root $project --target-major 8
powershell.exe -NoProfile -File $cli start --project-root $project --target-major 8
powershell.exe -NoProfile -File $cli run --project-root $project --run-id <run-id>
powershell.exe -NoProfile -File $cli status --project-root $project
```

`discover` must return ready before `start`. Ask for confirmation before starting, installing an approved runtime, approving baseline peers, skipping an optional check, or publishing documentation. Repairs are submitted to the controller and verified before the same run resumes. Documentation publish uses a draft submission, a second hashed proposal, and explicit confirmation; only the controller writes the eight final files.

Supported commands are `inspect`, `discover`, `approve-runtime`, `start`, `run`, `status`, `baseline-dependency-context`, `approve-baseline-dependencies`, `skip-check`, `repair-context`, `record-repair`, `documentation-research-context`, `record-documentation-research`, `documentation-publish-context`, and `publish-documentation`.

## Legacy state

The PowerShell v5 facade, modules, hook, schemas, and root test suite have been removed. Existing `.angular-migration/active.lock` and v5 run artifacts are not migrated. The v6 hook blocks legacy `active.lock` state when there is no TypeScript `run.json`; archive or resolve old runs before using v6. Do not delete project state automatically.

## Retained PowerShell scripts

- `scripts/angular-migration-ts.ps1` launches the bundled controller with Node 22.19.0 through fnm.
- `scripts/hooks/copilot-policy-ts.ps1` bridges Copilot hook events to the TypeScript policy.
- `scripts/prepare-typescript-controller.ps1` prepares dependencies and the standalone bundle.
- `scripts/install-host-prerequisites.ps1` checks or installs the Windows host tools.

## Local validation

Run package tiers under Node 22.19.0 so npm child processes inherit the pinned runtime:

```powershell
Push-Location .\src
$node = (fnm exec --using 22.19.0 -- node -p 'process.execPath' | Select-Object -Last 1).Trim()
$npmCli = Join-Path (Split-Path -Parent $node) 'node_modules/npm/bin/npm-cli.js'
fnm exec --using 22.19.0 -- node $npmCli test
fnm exec --using 22.19.0 -- node $npmCli run test:adapters
fnm exec --using 22.19.0 -- node $npmCli run test:process
fnm exec --using 22.19.0 -- node $npmCli run test:e2e
Pop-Location
```

The real Copilot CLI host smoke and real Angular pilot/rollback are separate acceptance gates; local fixtures and a `ready` prerequisite report do not replace them.

See [technical documentation](docs/typescript-controller-v6.md) and [host prerequisites](docs/host-prerequisites.md).
