#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot '../../scripts/modules'
$fixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot '../fixtures/migrations')).Path
$projectFixture = Join-Path $fixtureRoot 'project'
$toolFixture = Join-Path $fixtureRoot 'tools'
$registryFixture = Join-Path $fixtureRoot 'registry/responses.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('migration-skips-' + [guid]::NewGuid().ToString('N'))
$toolDirectory = Join-Path $temporaryRoot 'tools'
$statePath = Join-Path $temporaryRoot 'fnm-installed.txt'
$originalPath = $env:PATH
$originalRegistry = $env:MIGRATION_REGISTRY_FIXTURE
$originalInstalled = $env:FNM_FIXTURE_INSTALLED
$originalRemote = $env:FNM_FIXTURE_REMOTE
$originalNpm = $env:FNM_FIXTURE_NPM_VERSION
$originalStatePath = $env:FNM_FIXTURE_STATE_PATH

Import-Module (Join-Path $modules 'Migration.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.State.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Project.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Dependencies.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Pipeline.psm1') -Force -DisableNameChecking

foreach ($moduleName in @('Migration.Project', 'Migration.Dependencies', 'Migration.Pipeline')) {
    $module = Get-Module $moduleName
    & $module {
        param([string]$Tools)
        $script:FixtureTools = $Tools
        function script:Find-MigrationExecutable {
            param([Parameter(Mandatory = $true)][string[]]$Names)
            if ($Names -contains 'git.exe' -or $Names -contains 'git') { return (Get-Command git.exe -ErrorAction Stop).Source }
            if ($Names -contains 'node.exe' -or $Names -contains 'node') { return Join-Path $script:FixtureTools 'node.cmd' }
            if ($Names -contains 'npm.cmd' -or $Names -contains 'npm.exe' -or $Names -contains 'npm') { return Join-Path $script:FixtureTools 'npm.cmd' }
            if ($Names -contains 'fnm.exe' -or $Names -contains 'fnm') { return Join-Path $script:FixtureTools 'fnm.cmd' }
            return $null
        }
    } $toolDirectory
}

function Assert-SkipBatch {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name" -ForegroundColor Green
}

function New-SkipProject {
    param([string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $projectFixture -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Path $item.Name) -Recurse -Force
    }
    & git -C $Path init --quiet
    & git -C $Path config user.name 'Skip Fixture'
    & git -C $Path config user.email 'skip@example.invalid'
    & git -C $Path add .
    & git -C $Path commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Skip fixture Git setup failed' }
}

function New-SkipInput {
    param([string]$Path, [string]$RunId, $Skips, [bool]$Confirmed = $true)
    Write-MigrationJsonAtomic -Value ([PSCustomObject][ordered]@{
            schemaVersion = 1
            runId = $RunId
            confirmed = $Confirmed
            skips = @($Skips)
        }) -Path $Path
}

try {
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $toolFixture 'fnm.cmd') -Destination $toolDirectory -Force
    Copy-Item -LiteralPath (Join-Path $toolFixture 'fnm-fixture.ps1') -Destination $toolDirectory -Force
    Copy-Item -LiteralPath (Join-Path $toolFixture 'npm.cmd') -Destination $toolDirectory -Force
    Set-Content -LiteralPath (Join-Path $toolDirectory 'node.cmd') -Value '@echo off`r`necho v20.11.1' -Encoding ASCII
    $env:PATH = $toolDirectory + [IO.Path]::PathSeparator + $originalPath
    $env:MIGRATION_REGISTRY_FIXTURE = $registryFixture
    $env:FNM_FIXTURE_INSTALLED = '20.11.1'
    $env:FNM_FIXTURE_REMOTE = '20.11.1'
    $env:FNM_FIXTURE_NPM_VERSION = '10.2.4'
    $env:FNM_FIXTURE_STATE_PATH = $statePath

    $projectRoot = Join-Path $temporaryRoot 'project'
    New-SkipProject -Path $projectRoot
    $discovery = Invoke-MigrationDiscover -ProjectRoot $projectRoot -TargetMajor 8
    if (-not $discovery.ok) { throw ('Skip discovery failed: ' + ($discovery | ConvertTo-Json -Depth 20 -Compress)) }
    $start = Invoke-StartMigration -ProjectRoot $projectRoot -TargetMajor 8
    $runId = [string]$start.data.runId
    $runRoot = Join-Path $projectRoot ('.angular-migration/runs/' + $runId)
    $inputPath = Join-Path $runRoot 'inbox/skips.json'
    $inputRelative = '.angular-migration/runs/' + $runId + '/inbox/skips.json'

    $confirmationCode = $null
    try { Invoke-MigrationSkipChecks -ProjectRoot $projectRoot -RunId $runId -InputFile $inputRelative | Out-Null } catch { $confirmationCode = $_.Exception.Data['code'] }
    Assert-SkipBatch 'batch skip requires confirmation' ($confirmationCode -eq 'confirmation_required')

    $pathCode = $null
    try { Invoke-MigrationSkipChecks -ProjectRoot $projectRoot -RunId $runId -InputFile '.angular-migration/other.json' -Confirmed | Out-Null } catch { $pathCode = $_.Exception.Data['code'] }
    Assert-SkipBatch 'batch skip rejects non-controller input paths' ($pathCode -eq 'skip_input_path_invalid')

    Write-MigrationJsonAtomic -Value ([PSCustomObject]@{ schemaVersion = 1; runId = $runId; confirmed = $true; skips = @() }) -Path $inputPath
    $schemaCode = $null
    try { Invoke-MigrationSkipChecks -ProjectRoot $projectRoot -RunId $runId -InputFile $inputRelative -Confirmed | Out-Null } catch { $schemaCode = $_.Exception.Data['code'] }
    Assert-SkipBatch 'batch skip rejects malformed schema input' ($schemaCode -eq 'skip_batch_invalid')

    New-SkipInput -Path $inputPath -RunId 'different-run' -Skips @([PSCustomObject]@{ checkId = 'lint'; reason = 'lint tool is unavailable' })
    $runCode = $null
    try { Invoke-MigrationSkipChecks -ProjectRoot $projectRoot -RunId $runId -InputFile $inputRelative -Confirmed | Out-Null } catch { $runCode = $_.Exception.Data['code'] }
    Assert-SkipBatch 'batch skip rejects a mismatched run id' ($runCode -eq 'skip_batch_invalid')

    New-SkipInput -Path $inputPath -RunId $runId -Skips @([PSCustomObject]@{ checkId = 'build'; reason = 'build is critical' })
    $criticalCode = $null
    try { Invoke-MigrationSkipChecks -ProjectRoot $projectRoot -RunId $runId -InputFile $inputRelative -Confirmed | Out-Null } catch { $criticalCode = $_.Exception.Data['code'] }
    Assert-SkipBatch 'batch skip rejects critical checks' ($criticalCode -eq 'skip_batch_invalid' -or $criticalCode -eq 'check_not_skippable')

    New-SkipInput -Path $inputPath -RunId $runId -Skips @(
        [PSCustomObject]@{ checkId = 'lint'; reason = 'lint is deferred' }
        [PSCustomObject]@{ checkId = 'lint'; reason = 'duplicate approval' }
    )
    $duplicateCode = $null
    try { Invoke-MigrationSkipChecks -ProjectRoot $projectRoot -RunId $runId -InputFile $inputRelative -Confirmed | Out-Null } catch { $duplicateCode = $_.Exception.Data['code'] }
    Assert-SkipBatch 'batch skip rejects duplicate checks' ($duplicateCode -eq 'check_not_skippable')

    New-SkipInput -Path $inputPath -RunId $runId -Skips @(
        [PSCustomObject]@{ checkId = 'lint'; reason = 'lint is deferred' }
        [PSCustomObject]@{ checkId = 'typecheck'; reason = 'typecheck is deferred' }
    )
    $accepted = Invoke-MigrationSkipChecks -ProjectRoot $projectRoot -RunId $runId -InputFile $inputRelative -Confirmed
    $state = Read-MigrationRunState -ProjectRoot $projectRoot -RunId $runId
    $events = @([IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-SkipBatch 'valid batch skip is accepted' ($accepted.ok -and $accepted.status -eq 'running' -and @($accepted.data.checks).Count -eq 2)
    Assert-SkipBatch 'skip input moves atomically to artifacts' ((-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) -and (Test-Path -LiteralPath (Join-Path $runRoot 'artifacts/skips.json') -PathType Leaf))
    Assert-SkipBatch 'state records every approved skip' (@($state.skippedChecks | Where-Object { $_.confirmed -eq $true }).Count -eq 2 -and @($state.skippedChecks.checkId) -contains 'lint' -and @($state.skippedChecks.checkId) -contains 'typecheck')
    Assert-SkipBatch 'batch acceptance is evented' (@($events | Where-Object type -ceq 'skip-batch-accepted').Count -eq 1)
    Write-Host 'Skip batch contracts OK' -ForegroundColor Green
}
finally {
    $env:PATH = $originalPath
    if ($null -eq $originalRegistry) { Remove-Item Env:MIGRATION_REGISTRY_FIXTURE -ErrorAction SilentlyContinue } else { $env:MIGRATION_REGISTRY_FIXTURE = $originalRegistry }
    if ($null -eq $originalInstalled) { Remove-Item Env:FNM_FIXTURE_INSTALLED -ErrorAction SilentlyContinue } else { $env:FNM_FIXTURE_INSTALLED = $originalInstalled }
    if ($null -eq $originalRemote) { Remove-Item Env:FNM_FIXTURE_REMOTE -ErrorAction SilentlyContinue } else { $env:FNM_FIXTURE_REMOTE = $originalRemote }
    if ($null -eq $originalNpm) { Remove-Item Env:FNM_FIXTURE_NPM_VERSION -ErrorAction SilentlyContinue } else { $env:FNM_FIXTURE_NPM_VERSION = $originalNpm }
    if ($null -eq $originalStatePath) { Remove-Item Env:FNM_FIXTURE_STATE_PATH -ErrorAction SilentlyContinue } else { $env:FNM_FIXTURE_STATE_PATH = $originalStatePath }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}