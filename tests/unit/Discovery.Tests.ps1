#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot '../../scripts/modules'
$fixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot '../fixtures/migrations')).Path
$projectFixture = Join-Path $fixtureRoot 'project'
$toolFixture = Join-Path $fixtureRoot 'tools'
$registryFixture = Join-Path $fixtureRoot 'registry/responses.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('migration-discovery-' + [guid]::NewGuid().ToString('N'))
$toolDirectory = Join-Path $temporaryRoot 'tools'
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
$pipelineModule = Get-Module Migration.Pipeline

function Assert-Discovery {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name" -ForegroundColor Green
}

function New-DiscoveryProject {
    param([string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $projectFixture -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Path $item.Name) -Recurse -Force
    }
    & git -C $Path init --quiet
    & git -C $Path config user.name 'Discovery Fixture'
    & git -C $Path config user.email 'discovery@example.invalid'
    & git -C $Path add .
    & git -C $Path commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Discovery fixture Git setup failed' }
}

function Commit-DiscoveryChanges {
    param([string]$Path, [string]$Message)
    & git -C $Path add .
    & git -C $Path commit --quiet -m $Message
    if ($LASTEXITCODE -ne 0) { throw 'Discovery fixture commit failed' }
}

function Set-DiscoveryRuntime {
    param([string]$Installed, [string]$Remote, [string]$Npm)
    $env:PATH = $toolDirectory + [IO.Path]::PathSeparator + $originalPath
    $env:MIGRATION_REGISTRY_FIXTURE = $registryFixture
    $env:FNM_FIXTURE_INSTALLED = $Installed
    $env:FNM_FIXTURE_REMOTE = $Remote
    $env:FNM_FIXTURE_NPM_VERSION = $Npm
    $env:FNM_FIXTURE_STATE_PATH = Join-Path $temporaryRoot 'fnm-installed.txt'
    Remove-Item -LiteralPath $env:FNM_FIXTURE_STATE_PATH -Force -ErrorAction SilentlyContinue
}

try {
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $toolFixture 'fnm.cmd') -Destination $toolDirectory -Force
    Copy-Item -LiteralPath (Join-Path $toolFixture 'fnm-fixture.ps1') -Destination $toolDirectory -Force
    Copy-Item -LiteralPath (Join-Path $toolFixture 'npm.cmd') -Destination $toolDirectory -Force

    Set-DiscoveryRuntime -Installed '20.11.1' -Remote '16.20.2,20.11.1' -Npm '10.2.4'
    $missingRoot = Join-Path $temporaryRoot 'missing-discovery'
    New-DiscoveryProject -Path $missingRoot
    $missingCode = $null
    try { Invoke-StartMigration -ProjectRoot $missingRoot -TargetMajor 8 | Out-Null } catch { $missingCode = $_.Exception.Data['code'] }
    Assert-Discovery 'start requires a discovery artifact' ($missingCode -eq 'json_not_found')

    $readyRoot = Join-Path $temporaryRoot 'ready'
    New-DiscoveryProject -Path $readyRoot
    $discovery = Invoke-MigrationDiscover -ProjectRoot $readyRoot -TargetMajor 8
    Assert-Discovery 'discovery produces a ready immutable plan' ($discovery.ok -and $discovery.status -eq 'ready' -and $discovery.data.repoSha256 -match '^[0-9a-f]{64}$' -and $discovery.data.runtimePlan.profiles.Count -gt 0)
    $readBack = & $pipelineModule { param($Root) Read-MigrationDiscovery -ProjectRoot $Root } $readyRoot
    Assert-Discovery 'discovery artifact round-trips with its hash' ($readBack.repoSha256 -eq $discovery.data.repoSha256)
    $repoPath = Join-Path $readyRoot '.angular-migration/repo.json'
    $tampered = Read-MigrationJson -Path $repoPath -Required
    $tampered.warnings = @([PSCustomObject]@{ code = 'tampered'; message = 'tampered' })
    Write-MigrationJsonAtomic -Value $tampered -Path $repoPath
    $integrityCode = $null
    try { & $pipelineModule { param($Root) Read-MigrationDiscovery -ProjectRoot $Root | Out-Null } $readyRoot } catch { $integrityCode = $_.Exception.Data['code'] }
    Assert-Discovery 'tampered discovery is rejected' ($integrityCode -eq 'discovery_integrity_failed')
    Invoke-MigrationDiscover -ProjectRoot $readyRoot -TargetMajor 8 | Out-Null
    Set-Content -LiteralPath (Join-Path $readyRoot '.nvmrc') -Value '20.11.1' -Encoding ASCII
    Commit-DiscoveryChanges -Path $readyRoot -Message declaration
    $staleCode = $null
    try { Invoke-StartMigration -ProjectRoot $readyRoot -TargetMajor 8 | Out-Null } catch { $staleCode = $_.Exception.Data['code'] }
    Assert-Discovery 'changed repository inputs invalidate discovery' ($staleCode -eq 'discovery_stale')

    Set-DiscoveryRuntime -Installed '10.24.1' -Remote '10.24.1' -Npm '6.14.18'
    $v3Root = Join-Path $temporaryRoot 'lockfile-v3'
    New-DiscoveryProject -Path $v3Root
    $v3Package = Read-MigrationJson -Path (Join-Path $v3Root 'package.json') -Required
    $v3Package | Add-Member -NotePropertyName engines -NotePropertyValue ([PSCustomObject]@{ node = '10.24.1'; npm = '6.14.18' })
    Write-MigrationJsonAtomic -Value $v3Package -Path (Join-Path $v3Root 'package.json')
    $v3Lock = [ordered]@{
        name = 'pipeline-migration-fixture'; version = '0.0.0'; lockfileVersion = 3; requires = $true
        packages = [ordered]@{
            '' = [ordered]@{ name = 'pipeline-migration-fixture'; version = '0.0.0'; dependencies = [ordered]@{ '@angular/core' = '^7.2.0'; '@angular/common' = '^7.2.0'; '@angular/compiler' = '^7.2.0'; rxjs = '~6.3.3'; 'zone.js' = '~0.8.26' }; devDependencies = [ordered]@{ '@angular/cli' = '~7.3.0'; typescript = '~3.2.2' } }
            'node_modules/@angular/core' = @{ version = '7.2.16' }
            'node_modules/@angular/common' = @{ version = '7.2.16' }
            'node_modules/@angular/compiler' = @{ version = '7.2.16' }
            'node_modules/@angular/cli' = @{ version = '7.3.10' }
            'node_modules/rxjs' = @{ version = '6.3.3' }
            'node_modules/zone.js' = @{ version = '0.8.26' }
            'node_modules/typescript' = @{ version = '3.2.2' }
        }
    }
    Write-MigrationJsonAtomic -Value ([PSCustomObject]$v3Lock) -Path (Join-Path $v3Root 'package-lock.json')
    Set-Content -LiteralPath (Join-Path $v3Root '.nvmrc') -Value '10.24.1' -Encoding ASCII
    Commit-DiscoveryChanges -Path $v3Root -Message lockfile-v3
    $v3Discovery = Invoke-MigrationDiscover -ProjectRoot $v3Root -TargetMajor 8
    $v3Conflict = @($v3Discovery.data.runtimePlan.conflicts | Where-Object code -eq 'lockfile_npm_incompatible')
    Assert-Discovery 'lockfile v3 rejects exact Node 10 npm 6' (-not $v3Discovery.ok -and $v3Discovery.data.status -eq 'blocked' -and $v3Conflict.Count -eq 1 -and $v3Discovery.data.repository.npmRequirements.minimumRange -eq '>=7')

    Set-DiscoveryRuntime -Installed '22.19.0' -Remote '22.19.0' -Npm '10.9.0'
    $webpackRoot = Join-Path $temporaryRoot 'webpack-risk'
    New-DiscoveryProject -Path $webpackRoot
    $webpackPackage = Read-MigrationJson -Path (Join-Path $webpackRoot 'package.json') -Required
    $webpackPackage.devDependencies | Add-Member -NotePropertyName webpack -NotePropertyValue '4.46.0'
    Write-MigrationJsonAtomic -Value $webpackPackage -Path (Join-Path $webpackRoot 'package.json')
    $webpackLock = Read-MigrationJson -Path (Join-Path $webpackRoot 'package-lock.json') -Required
    $webpackLock.dependencies | Add-Member -NotePropertyName webpack -NotePropertyValue ([PSCustomObject]@{ version = '4.46.0' })
    Write-MigrationJsonAtomic -Value $webpackLock -Path (Join-Path $webpackRoot 'package-lock.json')
    Commit-DiscoveryChanges -Path $webpackRoot -Message webpack-risk
    $webpackDiscovery = Invoke-MigrationDiscover -ProjectRoot $webpackRoot -TargetMajor 8
    $webpackRisk = @($webpackDiscovery.data.repository.risks | Where-Object code -eq 'webpack_openssl3_incompatible')
    Assert-Discovery 'Node 22 and Webpack 4 produce an OpenSSL risk conflict' (-not $webpackDiscovery.ok -and $webpackRisk.Count -eq 1 -and $webpackRisk[0].severity -eq 'blocking' -and @($webpackDiscovery.data.runtimePlan.conflicts | Where-Object code -eq 'webpack_openssl3_incompatible').Count -eq 1)

    Set-DiscoveryRuntime -Installed '22.19.0,16.20.2' -Remote '22.19.0,16.20.2' -Npm '10.9.0'
    $mitigatedRoot = Join-Path $temporaryRoot 'webpack-mitigated'
    New-DiscoveryProject -Path $mitigatedRoot
    $mitigatedPackage = Read-MigrationJson -Path (Join-Path $mitigatedRoot 'package.json') -Required
    $mitigatedPackage.devDependencies | Add-Member -NotePropertyName webpack -NotePropertyValue '4.46.0'
    Write-MigrationJsonAtomic -Value $mitigatedPackage -Path (Join-Path $mitigatedRoot 'package.json')
    $mitigatedLock = Read-MigrationJson -Path (Join-Path $mitigatedRoot 'package-lock.json') -Required
    $mitigatedLock.dependencies | Add-Member -NotePropertyName webpack -NotePropertyValue ([PSCustomObject]@{ version = '4.46.0' })
    Write-MigrationJsonAtomic -Value $mitigatedLock -Path (Join-Path $mitigatedRoot 'package-lock.json')
    Commit-DiscoveryChanges -Path $mitigatedRoot -Message webpack-mitigated
    $mitigatedDiscovery = Invoke-MigrationDiscover -ProjectRoot $mitigatedRoot -TargetMajor 8
    $mitigatedRisk = @($mitigatedDiscovery.data.repository.risks | Where-Object code -eq 'webpack_openssl3_incompatible')
    $mitigatedBuild = @($mitigatedDiscovery.data.runtimePlan.profiles | Where-Object id -ceq 'baseline:build' | Select-Object -First 1)
    Assert-Discovery 'an installed Node 16 runtime mitigates the Webpack OpenSSL risk' ($mitigatedDiscovery.ok -and $mitigatedRisk.Count -eq 1 -and $mitigatedRisk[0].severity -eq 'warning' -and $mitigatedRisk[0].mitigated -eq $true -and $mitigatedBuild.Count -eq 1 -and $mitigatedBuild[0].selectedNodeVersion -ceq '16.20.2')
    Write-Host 'Discovery contracts OK' -ForegroundColor Green
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