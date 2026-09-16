#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot '../../scripts/modules'
$fixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot '../fixtures/migrations')).Path
$projectFixture = Join-Path $fixtureRoot 'project'
$toolFixture = Join-Path $fixtureRoot 'tools'
$registryFixture = Join-Path $fixtureRoot 'registry/responses.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('migration-runtime-' + [guid]::NewGuid().ToString('N'))
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

function Assert-Runtime {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name" -ForegroundColor Green
}

function New-RuntimeProject {
    param([string]$Path, [string]$NodeVersion)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $projectFixture -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Path $item.Name) -Recurse -Force
    }
    Set-Content -LiteralPath (Join-Path $Path '.nvmrc') -Value $NodeVersion -Encoding ASCII
    & git -C $Path init --quiet
    & git -C $Path config user.name 'Runtime Fixture'
    & git -C $Path config user.email 'runtime@example.invalid'
    & git -C $Path add .
    & git -C $Path commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Runtime fixture Git setup failed' }
}

function Set-RuntimeFixture {
    param([string]$Installed, [string]$Remote, [string]$Npm)
    $env:PATH = $toolDirectory + [IO.Path]::PathSeparator + $originalPath
    $env:MIGRATION_REGISTRY_FIXTURE = $registryFixture
    $env:FNM_FIXTURE_INSTALLED = $Installed
    $env:FNM_FIXTURE_REMOTE = $Remote
    $env:FNM_FIXTURE_NPM_VERSION = $Npm
    $env:FNM_FIXTURE_STATE_PATH = $statePath
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
}

try {
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $toolFixture 'fnm.cmd') -Destination $toolDirectory -Force
    Copy-Item -LiteralPath (Join-Path $toolFixture 'fnm-fixture.ps1') -Destination $toolDirectory -Force
    Copy-Item -LiteralPath (Join-Path $toolFixture 'npm.cmd') -Destination $toolDirectory -Force

    Set-RuntimeFixture -Installed '16.20.2,20.11.1' -Remote '16.20.2,20.11.1' -Npm '10.2.4'
    $selectedRoot = Join-Path $temporaryRoot 'selected'
    New-RuntimeProject -Path $selectedRoot -NodeVersion '16.20.2'
    $selected = Invoke-MigrationDiscover -ProjectRoot $selectedRoot -TargetMajor 8
    $baselineProfile = @($selected.data.runtimePlan.profiles | Where-Object id -ceq 'baseline:install' | Select-Object -First 1)
    $metadataProfile = @($selected.data.runtimePlan.profiles | Where-Object id -ceq 'metadata' | Select-Object -First 1)
    Assert-Runtime 'installed exact runtime is selected for baseline install' ($selected.ok -and $baselineProfile.Count -eq 1 -and $baselineProfile[0].selectedNodeVersion -ceq '16.20.2' -and $baselineProfile[0].status -eq 'installed')
    Assert-Runtime 'metadata profile has a concrete installed runtime' ($metadataProfile.Count -eq 1 -and $metadataProfile[0].selectedNodeVersion -match '^\d+\.\d+\.\d+$' -and $metadataProfile[0].status -eq 'installed')

    Set-RuntimeFixture -Installed '20.11.1' -Remote '16.20.2,20.11.1' -Npm '10.2.4'
    $installRoot = Join-Path $temporaryRoot 'install'
    New-RuntimeProject -Path $installRoot -NodeVersion '16.20.2'
    $pending = Invoke-MigrationDiscover -ProjectRoot $installRoot -TargetMajor 8
    $proposalHash = [string]$pending.data.installProposal.proposalHash
    Assert-Runtime 'missing exact runtime requires approval' (-not $pending.ok -and $pending.status -eq 'blocked' -and $pending.data.status -eq 'runtime-install-required' -and $pending.error.code -eq 'runtime_install_confirmation_required' -and $proposalHash -match '^[0-9a-f]{64}$')

    $confirmationCode = $null
    try { Invoke-ApproveMigrationRuntimeInstall -ProjectRoot $installRoot -TargetMajor 8 -ProposalHash $proposalHash | Out-Null } catch { $confirmationCode = $_.Exception.Data['code'] }
    Assert-Runtime 'runtime install requires explicit confirmation' ($confirmationCode -eq 'confirmation_required')

    $proposalCode = $null
    try { Invoke-ApproveMigrationRuntimeInstall -ProjectRoot $installRoot -TargetMajor 8 -ProposalHash ('0' * 64) -Confirmed | Out-Null } catch { $proposalCode = $_.Exception.Data['code'] }
    Assert-Runtime 'runtime install rejects a stale proposal hash' ($proposalCode -eq 'runtime_proposal_changed')

    $approved = Invoke-ApproveMigrationRuntimeInstall -ProjectRoot $installRoot -TargetMajor 8 -ProposalHash $proposalHash -Confirmed
    Assert-Runtime 'approved runtime install rediscoveries as ready' ($approved.ok -and $approved.status -eq 'ready' -and $approved.data.status -eq 'ready' -and @($approved.data.toolchain.installedNodeVersions | Where-Object { $_ -ceq '16.20.2' }).Count -eq 1)
    Assert-Runtime 'runtime install writes stdout evidence' (Test-Path -LiteralPath (Join-Path $installRoot '.angular-migration/runtime-install/16.20.2.stdout.log') -PathType Leaf)
    Assert-Runtime 'runtime install persists external fixture state' (([IO.File]::ReadAllLines($statePath) -contains '16.20.2'))
    Write-Host 'Runtime selection contracts OK' -ForegroundColor Green
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