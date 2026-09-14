#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot '../../scripts/modules'
Import-Module (Join-Path $modules 'Migration.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.State.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Pipeline.psm1') -Force -DisableNameChecking

$root = Join-Path ([IO.Path]::GetTempPath()) ('baseline-dependency-approval-' + [guid]::NewGuid().ToString('N'))
$fakeNpm = Join-Path $root 'fake-npm.cmd'
$fakeNpmScript = Join-Path $root 'fake-npm.ps1'

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    @'
param([string[]]$Arguments)
$ErrorActionPreference = 'Stop'
$tracePath = Join-Path (Get-Location) 'fake-npm.trace'
$traceLines = if (Test-Path -LiteralPath $tracePath -PathType Leaf) { @(Get-Content -LiteralPath $tracePath) } else { @() }
[IO.File]::AppendAllText($tracePath, (($Arguments -join '|') + [Environment]::NewLine))
if ($Arguments[0] -eq 'view') {
    $viewNumber = @($traceLines | Where-Object { $_ -match '^view(?:\||$)' }).Count + 1
    if ((($viewNumber - 1) % 2) -eq 0) { Write-Output '["3.7.1"]' } else { Write-Output '["1.16.1"]' }
    exit 0
}
if ($Arguments[0] -eq 'install') {
    $packagePath = Join-Path (Get-Location) 'package.json'
    $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
    $package.dependencies | Add-Member -NotePropertyName jquery -NotePropertyValue '3.7.1' -Force
    $package.dependencies | Add-Member -NotePropertyName 'popper.js' -NotePropertyValue '1.16.1' -Force
    [IO.File]::WriteAllText($packagePath, ($package | ConvertTo-Json -Depth 20))
    $lockPath = Join-Path (Get-Location) 'package-lock.json'
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $lock.dependencies | Add-Member -NotePropertyName jquery -NotePropertyValue ([PSCustomObject]@{ version = '3.7.1' }) -Force
    $lock.dependencies | Add-Member -NotePropertyName 'popper.js' -NotePropertyValue ([PSCustomObject]@{ version = '1.16.1' }) -Force
    [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20))
    exit 0
}
if ($Arguments[0] -eq 'ls') {
    Write-Output '{"dependencies":{}}'
    exit 0
}
exit 1
'@ | Set-Content -LiteralPath $fakeNpmScript -Encoding UTF8
    @("@echo off", "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-npm.ps1`" %*", 'exit /b %ERRORLEVEL%') | Set-Content -LiteralPath $fakeNpm -Encoding ASCII

    @'
{
  "name": "baseline-fixture",
  "version": "1.0.0",
  "dependencies": {
    "bootstrap": "4.6.2"
  }
}
'@ | Set-Content -LiteralPath (Join-Path $root 'package.json') -Encoding UTF8
    @'
{
  "name": "baseline-fixture",
  "lockfileVersion": 3,
  "requires": true,
  "dependencies": {
    "bootstrap": { "version": "4.6.2" }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $root 'package-lock.json') -Encoding UTF8
    @('.angular-migration/', 'fake-npm.trace') | Set-Content -LiteralPath (Join-Path $root '.gitignore') -Encoding ASCII

    & git -C $root init --quiet
    & git -C $root config user.name 'Baseline Approval Fixture'
    & git -C $root config user.email 'baseline-approval@example.invalid'
    & git -C $root add .
    & git -C $root commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture Git setup failed' }

    $runId = 'angular-9-to-10-20260914T103643657Z-e2101398'
    $branch = (& git -C $root symbolic-ref --quiet --short HEAD).Trim()
    $initialCommit = (& git -C $root rev-parse HEAD).Trim()
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $runId
    New-Item -ItemType Directory -Path (Join-Path $paths.logs 'baseline') -Force | Out-Null
    New-Item -ItemType File -Path $paths.events -Force | Out-Null
    @'
npm error code ELSPROBLEMS
npm error missing: jquery@1.9.1 - 3, required by bootstrap@4.6.2
npm error missing: popper.js@^1.16.1, required by bootstrap@4.6.2
'@ | Set-Content -LiteralPath (Join-Path $paths.root 'logs/baseline/01.stdout.log') -Encoding UTF8
    '' | Set-Content -LiteralPath (Join-Path $paths.root 'logs/baseline/02.stderr.log') -Encoding UTF8
    $state = New-MigrationRunState -RunId $runId -ProjectRoot $root -SourceMajor 9 -TargetMajor 10 -InitialCommit $initialCommit -InitialBranch $branch
    $state.status = 'blocked'
    $state.lastDiagnostic = [PSCustomObject]@{
        code    = 'baseline_check_failed'
        message = 'Baseline checks did not pass.'
        details = [PSCustomObject]@{
            code      = 'baseline_check_failed'
            checkId   = 'dependency-tree'
            stdoutLog = 'logs/baseline/01.stdout.log'
            stderrLog = 'logs/baseline/02.stderr.log'
        }
    }
    New-ActiveRunLock -ProjectRoot $root -RunId $runId
    Write-MigrationRunState -ProjectRoot $root -RunId $runId -State $state
    Remove-ActiveRunLock -ProjectRoot $root -RunId $runId

    $pipelineModule = Get-Module Migration.Pipeline
    & $pipelineModule {
        param($NpmPath)
        $script:BaselineTestNpmPath = $NpmPath
        function script:Find-MigrationExecutable {
            param([string[]]$Names)
            if ($Names -contains 'npm.cmd' -or $Names -contains 'npm.exe' -or $Names -contains 'npm') { return $script:BaselineTestNpmPath }
            return (Get-Command ($Names | Select-Object -First 1) -ErrorAction Stop).Source
        }
    } $fakeNpm

    $context = Invoke-MigrationBaselineDependencyContext -ProjectRoot $root -RunId $runId
    if ($context.status -ne 'blocked' -or $context.error.code -ne 'baseline_dependency_confirmation_required') { throw 'Missing confirmation context' }
    if (@($context.data.packages).Count -ne 2) { throw 'Expected two missing peer dependencies' }
    $jquery = $context.data.packages | Where-Object name -eq 'jquery'
    $popper = $context.data.packages | Where-Object name -eq 'popper.js'
    Write-Host (Get-Content (Join-Path $root 'fake-npm.trace') -Raw)
    if ($jquery.installVersion -ne '3.7.1' -or $popper.installVersion -ne '1.16.1') { throw 'Proposal versions were not resolved exactly' }
    if ($jquery.requiredBy -notcontains 'bootstrap@4.6.2' -or $jquery.reason -notmatch 'peer dependency') { throw 'Proposal did not explain the dependency reason' }

    $rejected = $false
    try { Invoke-ApproveMigrationBaselineDependencies -ProjectRoot $root -RunId $runId -ProposalHash $context.data.proposalHash | Out-Null }
    catch { $rejected = $_.Exception.Data['code'] -ceq 'confirmation_required' }
    if (-not $rejected) { throw 'Approval without confirmation was accepted' }
    if ((git -C $root status --porcelain) -or (Get-Content (Join-Path $root 'package.json') -Raw) -match 'jquery') { throw 'Rejected approval changed the project' }

    $approved = Invoke-ApproveMigrationBaselineDependencies -ProjectRoot $root -RunId $runId -ProposalHash $context.data.proposalHash -Confirmed
    if (-not $approved.ok -or $approved.status -ne 'ready' -or $approved.data.status -ne 'ready-for-new-run') { throw 'Approved baseline repair did not finish ready' }
    $package = Get-Content (Join-Path $root 'package.json') -Raw | ConvertFrom-Json
    if ($package.dependencies.jquery -ne '3.7.1' -or $package.dependencies.'popper.js' -ne '1.16.1') { throw 'Approved packages were not installed' }
    if (Test-Path -LiteralPath (Join-Path $root '.angular-migration/active.lock')) { throw 'Baseline approval did not release the lock' }
    $subject = (& git -C $root log -1 --format=%s).Trim()
    if ($subject -ne "chore(angular-migration): satisfy baseline peer dependencies [$runId]") { throw 'Baseline approval did not create the controlled commit' }
    Write-Host 'PASS baseline dependency proposal, confirmation, verification and controlled commit'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}