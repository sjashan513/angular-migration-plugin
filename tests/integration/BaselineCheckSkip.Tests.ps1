#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot '../../scripts/modules'
Import-Module (Join-Path $modules 'Migration.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.State.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Project.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Pipeline.psm1') -Force -DisableNameChecking

$root = Join-Path ([IO.Path]::GetTempPath()) ('baseline-check-skip-' + [guid]::NewGuid().ToString('N'))
$toolDirectory = Join-Path ([IO.Path]::GetTempPath()) ('baseline-check-skip-tools-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$runId = 'angular-7-to-8-20260914T103643657Z-a1b2c3d4'

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    @'
param([string[]]$Arguments)
$ErrorActionPreference = 'Stop'
$trace = Join-Path (Get-Location) '.fixture-trace'
[IO.File]::AppendAllText($trace, (($Arguments -join '|') + [Environment]::NewLine))
if ($Arguments[0] -eq 'run' -and $Arguments[1] -eq 'lint') {
    [Console]::Error.WriteLine('src/tsconfig.app.json:1 fixture lint failure')
    exit 1
}
if ($Arguments[0] -in @('ci', 'ls')) { exit 0 }
if ($Arguments[0] -eq 'run') { exit 0 }
exit 1
'@ | Set-Content -LiteralPath (Join-Path $toolDirectory 'npm-fixture.ps1') -Encoding UTF8
    @('@echo off', 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0npm-fixture.ps1" %*', 'exit /b %ERRORLEVEL%') | Set-Content -LiteralPath (Join-Path $toolDirectory 'npm.cmd') -Encoding ASCII
    $env:PATH = $toolDirectory + [IO.Path]::PathSeparator + $oldPath

    @'
{
  "name": "baseline-skip-fixture",
  "version": "1.0.0",
  "scripts": {
        "test:unit": "unit-test",
    "lint": "lint",
    "build": "build"
  }
}
'@ | Set-Content -LiteralPath (Join-Path $root 'package.json') -Encoding UTF8
    @'
{
  "name": "baseline-skip-fixture",
  "lockfileVersion": 1,
  "requires": true,
  "dependencies": {}
}
'@ | Set-Content -LiteralPath (Join-Path $root 'package-lock.json') -Encoding UTF8
    @('.angular-migration/', '.fixture-trace') | Set-Content -LiteralPath (Join-Path $root '.gitignore') -Encoding ASCII
    $pipeline = Get-Module Migration.Pipeline
    & $pipeline {
        param($TracePath)
        $script:BaselineSkipTestTracePath = $TracePath
        function script:Invoke-ProjectCheck {
            param($Check, [string]$LogDirectory)
            [IO.File]::AppendAllText($script:BaselineSkipTestTracePath, ([string]$Check.id + [Environment]::NewLine))
            $status = if ($Check.status -eq 'not-configured') { 'not-configured' } elseif ($Check.id -eq 'lint') { 'failed' } else { 'passed' }
            return [PSCustomObject]@{
                id = $Check.id; status = $status; exitCode = if ($status -eq 'failed') { 1 } else { 0 }; timedOut = $false
                startedAt = $null; finishedAt = $null; durationMs = 0; stdoutLog = $null; stderrLog = $null
                diagnosticSummary = if ($status -eq 'failed') { 'fixture lint failure' } else { $Check.reason }
                executable = 'fixture'
            }
        }
    } (Join-Path $root '.fixture-trace')
    $coreModule = Get-Module Migration.Core
    & $coreModule {
        param($NpmPath)
        $script:BaselineSkipTestNpmPath = $NpmPath
        function script:Find-MigrationExecutable {
            param([string[]]$Names)
            if ($Names -contains 'npm.cmd' -or $Names -contains 'npm.exe' -or $Names -contains 'npm') { return $script:BaselineSkipTestNpmPath }
            return (Get-Command ($Names | Select-Object -First 1) -ErrorAction Stop).Source
        }
    } (Join-Path $toolDirectory 'npm.cmd')

    & git -C $root init --quiet
    & git -C $root config user.name 'Baseline Skip Fixture'
    & git -C $root config user.email 'baseline-skip@example.invalid'
    & git -C $root add .
    & git -C $root commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture Git setup failed' }

    $initialCommit = (& git -C $root rev-parse HEAD).Trim()
    $branch = (& git -C $root symbolic-ref --quiet --short HEAD).Trim()
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $runId
    $package = Get-ProjectPackage -ProjectRoot $root
    $checks = @(Get-ProjectChecks -Package $package -ProjectRoot $root -HasLockfile $true)
    $manifest = [PSCustomObject]@{
        schemaVersion = 5
        manifestType  = 'migration'
        runId         = $runId
        sourceMajor   = 7
        targetMajor   = 8
        project       = [PSCustomObject]@{
            root = $root
            git  = [PSCustomObject]@{ initialCommit = $initialCommit }
        }
        checks        = $checks
    }
    $state = New-MigrationRunState -RunId $runId -ProjectRoot $root -SourceMajor 7 -TargetMajor 8 -InitialCommit $initialCommit -InitialBranch $branch
    New-ActiveRunLock -ProjectRoot $root -RunId $runId
    try {
        Write-MigrationRunState -ProjectRoot $root -RunId $runId -State $state
        Write-MigrationRunManifest -ProjectRoot $root -RunId $runId -Manifest $manifest
        $preflight = Invoke-MigrationSkipCheck -ProjectRoot $root -RunId $runId -CheckId 'unit-test' -Reason 'Unit tests are not part of this repository baseline.' -Confirmed
        if (-not $preflight.ok -or $preflight.data.source -cne 'preflight' -or $preflight.data.nextAction -cne 'run') { throw 'Preflight skip approval was not accepted' }
        if (-not (Test-Path -LiteralPath (Join-Path $root '.angular-migration/active.lock') -PathType Leaf)) { throw 'Preflight approval did not retain ownership' }
    }
    finally { Remove-ActiveRunLock -ProjectRoot $root -RunId $runId }

    New-ActiveRunLock -ProjectRoot $root -RunId $runId
    $first = Invoke-MigrationRun -ProjectRoot $root -RunId $runId
    if ($first.status -ne 'blocked' -or $first.error.code -ne 'baseline_check_failed' -or $first.error.details.checkId -ne 'lint') { throw 'Lint baseline did not produce the expected blocked envelope' }
    if (Test-Path -LiteralPath (Join-Path $root '.angular-migration/active.lock')) { throw 'Blocked baseline retained the active lock' }
    $blockedState = Read-MigrationRunState -ProjectRoot $root -RunId $runId
    if ($blockedState.status -ne 'blocked' -or $blockedState.stage -ne 'baseline' -or @($blockedState.skippedChecks).Count -ne 1 -or $blockedState.skippedChecks[0].checkId -cne 'unit-test' -or $blockedState.skippedChecks[0].diagnostic.code -cne 'preflight_skip_approved') { throw 'Preflight skip was not persisted before the baseline failure' }

    $unchangedState = (Get-Content -LiteralPath $paths.state -Raw)
    $rejected = $false
    try { Invoke-MigrationSkipCheck -ProjectRoot $root -RunId $runId -CheckId 'lint' -Reason 'Missing generated lint configuration.' | Out-Null }
    catch { $rejected = $_.Exception.Data['code'] -ceq 'confirmation_required' }
    if (-not $rejected -or (Get-Content -LiteralPath $paths.state -Raw) -cne $unchangedState -or (Test-Path -LiteralPath (Join-Path $root '.angular-migration/active.lock'))) { throw 'Skip without confirmation changed the run' }
    Write-Host 'PASS skip requires explicit confirmation without mutating state'

    foreach ($critical in @('install', 'dependency-tree', 'build')) {
        $criticalRejected = $false
        try { Invoke-MigrationSkipCheck -ProjectRoot $root -RunId $runId -CheckId $critical -Reason 'Temporary bypass.' -Confirmed | Out-Null }
        catch { $criticalRejected = $_.Exception.Data['code'] -ceq 'critical_check_cannot_be_skipped' }
        if (-not $criticalRejected) { throw "Critical check was accepted for skip: $critical" }
    }
    Write-Host 'PASS install, dependency-tree and build cannot be skipped'

    $accepted = Invoke-MigrationSkipCheck -ProjectRoot $root -RunId $runId -CheckId 'lint' -Reason 'The project has no checked-in lint tsconfig yet.' -Confirmed
    if (-not $accepted.ok -or $accepted.status -ne 'running' -or $accepted.data.runId -cne $runId -or $accepted.data.nextAction -cne 'run') { throw 'Skip approval did not resume the same run' }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.angular-migration/active.lock') -PathType Leaf)) { throw 'Skip approval did not hand ownership to the resumed run' }
    $approvedState = Read-MigrationRunState -ProjectRoot $root -RunId $runId
    $skip = @($approvedState.skippedChecks | Where-Object checkId -ceq 'lint')[0]
    if ($approvedState.status -ne 'running' -or $approvedState.stage -ne 'baseline' -or
        $skip.reason -cne 'The project has no checked-in lint tsconfig yet.' -or
        $skip.confirmed -ne $true -or $skip.diagnostic.details.checkId -ne 'lint') { throw 'Skip approval was not audited in state' }
    Write-Host 'PASS approved skip records reason, confirmation and original diagnostic'

    & $pipeline {
        function script:Invoke-PipelineResolveStage {
            param([string]$ProjectRoot, [string]$RunId)
            Throw-PipelineError -Code 'test_stop_after_baseline' -Message 'Fixture stops after baseline.' -Status blocked
        }
    }
    $resumed = Invoke-MigrationRun -ProjectRoot $root -RunId $runId
    if ($resumed.error.code -ceq 'run_not_owner' -or $resumed.error.code -cne 'test_stop_after_baseline') { throw 'Approved skip could not resume through the run facade' }

    $resumedState = Read-MigrationRunState -ProjectRoot $root -RunId $runId
    $trace = @(Get-Content -LiteralPath (Join-Path $root '.fixture-trace'))
    $lintRuns = @($trace | Where-Object { $_ -ceq 'lint' }).Count
    $buildRuns = @($trace | Where-Object { $_ -ceq 'build' }).Count
    $events = @(Get-Content -LiteralPath $paths.events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    if ($resumedState.status -ne 'blocked' -or $resumedState.stage -ne 'resolve' -or
        'baseline' -notin @($resumedState.completedOperations) -or $lintRuns -ne 1 -or $buildRuns -ne 1 -or
        @($events | Where-Object type -ceq 'skip-accepted').Count -ne 1 -or
        @($events | Where-Object type -ceq 'skip-preapproved').Count -ne 1 -or
        @($events | Where-Object type -ceq 'check-skipped').Count -ne 2) { throw 'Approved skip did not resume baseline deterministically' }
    Write-Host 'PASS same run skips lint, executes the next check and records audit events'
}
finally {
    $env:PATH = $oldPath
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $toolDirectory -Recurse -Force -ErrorAction SilentlyContinue
}