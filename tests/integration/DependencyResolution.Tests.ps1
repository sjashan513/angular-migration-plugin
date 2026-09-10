#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot '../../scripts/modules'
$fixtureDirectory = (Resolve-Path (Join-Path $PSScriptRoot '../fixtures/registry')).Path
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('migration-resolution-' + [guid]::NewGuid().ToString('N'))
$toolDirectory = Join-Path $temporaryRoot 'tools'
$originalPath = $env:PATH
$originalFixture = $env:MIGRATION_REGISTRY_FIXTURE
$originalTrace = $env:MIGRATION_REGISTRY_TRACE
New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null

function New-RegistryResponses {
    param([string]$Path)

    $responses = [ordered]@{
        '@angular/core@8' = [ordered]@{ version = '8.2.14'; peerDependencies = [ordered]@{ rxjs = '^6.4.0'; 'zone.js' = '~0.9.0' }; peerDependenciesMeta = @{}; engines = @{ node = '>=10.9.0' }; 'ng-update' = @{ migrations = 'migrations.json'; packageGroup = 'angular' }; deprecated = $false; 'dist-tags' = @{ latest = '20.0.0' } }
        '@angular/common@8' = [ordered]@{ version = '8.2.14'; peerDependencies = @{ '@angular/core' = '^8.0.0' }; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
        '@angular/compiler@8' = [ordered]@{ version = '8.2.14'; peerDependencies = @{ '@angular/core' = '^8.0.0' }; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
        '@angular/cli@8' = [ordered]@{ version = '8.3.29'; peerDependencies = @{}; peerDependenciesMeta = @{}; engines = @{ node = '>=10.9.0' }; deprecated = $false; 'dist-tags' = @{} }
        '@angular/compiler-cli@8' = [ordered]@{ version = '8.2.14'; peerDependencies = @{ typescript = '>=3.4.0 <3.6.0' }; peerDependenciesMeta = @{}; engines = @{ node = '>=10.9.0' }; deprecated = $false; 'dist-tags' = @{} }
        'rxjs@6' = [ordered]@{ version = '6.5.5'; peerDependencies = @{}; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
        'zone.js@0' = [ordered]@{ version = '0.9.1'; peerDependencies = @{}; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
        'typescript@3' = [ordered]@{ version = '3.5.3'; peerDependencies = @{}; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
        'ordinary@1' = [ordered]@{ version = '1.5.0-beta.1'; candidates = @(@{ version = '1.5.0-beta.1'; deprecated = $false }, @{ version = '1.4.0'; deprecated = $false }, @{ version = '1.3.0'; deprecated = $true }); peerDependencies = @{}; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
        'angular-aware@1' = [ordered]@{ version = '1.5.0'; peerDependencies = @{ '@angular/core' = '^7.0.0' }; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
        'angular-aware@2' = [ordered]@{ version = '2.1.0'; peerDependencies = @{ '@angular/core' = '^8.0.0' }; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
    }
    $responses | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-IntegrationProject {
    param([string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    @'
{
  "name": "resolution-fixture",
  "dependencies": {
    "@angular/core": "^7.2.0",
    "@angular/common": "^7.2.0",
    "@angular/compiler": "^7.2.0",
    "rxjs": "~6.3.3",
    "zone.js": "~0.8.26",
    "ordinary": "^1.2.0",
    "angular-aware": "^1.0.0"
  },
  "devDependencies": {
    "@angular/cli": "~7.3.0",
    "typescript": "~3.2.2"
  },
  "scripts": {
    "typecheck": "echo typecheck",
    "lint": "echo lint",
    "test:unit": "echo test",
    "build": "echo build",
    "e2e": "echo e2e"
  }
}
'@ | Set-Content -LiteralPath (Join-Path $Path 'package.json') -Encoding UTF8
    @'
{
  "version": 1,
  "projects": {
    "resolution-fixture": {
      "projectType": "application",
      "architect": { "build": { "builder": "@angular-devkit/build-angular:browser" } }
    }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $Path 'angular.json') -Encoding UTF8
    $lock = [ordered]@{ lockfileVersion = 1; requires = $true; dependencies = [ordered]@{
            '@angular/core' = @{ version = '7.2.16' }; '@angular/common' = @{ version = '7.2.16' }; '@angular/compiler' = @{ version = '7.2.16' }; '@angular/cli' = @{ version = '7.3.10' }
            rxjs = @{ version = '6.3.3' }; 'zone.js' = @{ version = '0.8.26' }; typescript = @{ version = '3.2.2' }; ordinary = @{ version = '1.2.0' }; 'angular-aware' = @{ version = '1.0.0' }
        } }
    $lock | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $Path 'package-lock.json') -Encoding UTF8
    ".angular-migration/`n.fixture-trace" | Set-Content -LiteralPath (Join-Path $Path '.gitignore') -Encoding ASCII
    & git -C $Path init --quiet
    & git -C $Path config user.email 'resolution@example.invalid'
    & git -C $Path config user.name 'Resolution Fixture'
    & git -C $Path add .
    & git -C $Path commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Integration Git fixture setup failed' }
}

function Invoke-ResolutionRun {
    param([string]$ProjectRoot)

    $packageHash = (Get-FileHash (Join-Path $ProjectRoot 'package.json')).Hash
    $lockHash = (Get-FileHash (Join-Path $ProjectRoot 'package-lock.json')).Hash
    $started = Invoke-StartMigration -ProjectRoot $ProjectRoot -TargetMajor 8
    $runId = $started.data.runId
    $baseline = Invoke-MigrationBaseline -ProjectRoot $ProjectRoot -RunId $runId
    if ($baseline.status -ne 'passed') { throw "Integration baseline failed: $($baseline | ConvertTo-Json -Depth 20 -Compress)" }
    $resolved = Invoke-MigrationResolution -ProjectRoot $ProjectRoot -RunId $runId
    if ($resolved.status -ne 'resolved') { throw "Integration resolution failed: $($resolved | ConvertTo-Json -Depth 20 -Compress)" }
    if ((Get-FileHash (Join-Path $ProjectRoot 'package.json')).Hash -ne $packageHash -or (Get-FileHash (Join-Path $ProjectRoot 'package-lock.json')).Hash -ne $lockHash) { throw 'Resolution modified dependency files' }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $runId
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $runId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    if ($state.manifestSha256 -ne $manifest.manifestSha256 -or $manifest.manifestSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Published manifest hash was not recorded in state' }
    $events = @(Get-Content -LiteralPath $paths.events | ForEach-Object { $_ | ConvertFrom-Json })
    if (@($events | Where-Object type -eq 'manifest-resolved').Count -ne 1 -or @($events | Where-Object type -eq 'registry-metadata-queried').Count -eq 0) { throw 'Resolution events are incomplete' }
    $second = Invoke-MigrationResolution -ProjectRoot $ProjectRoot -RunId $runId
    if ($second.status -ne 'blocked' -or $second.diagnostic.code -ne 'manifest_already_resolved') { throw 'Resolved manifest was accepted twice by the pipeline' }
    return [PSCustomObject]@{ manifest = $manifest; state = $state; paths = $paths }
}

  function Get-ResolutionDecisionProjection {
    param($Manifest)

    return [ordered]@{
      angular = $Manifest.angular.target
      dependencies = @($Manifest.dependencies | ForEach-Object {
          [ordered]@{
            name = $_.name; section = $_.section; role = $_.role; kind = $_.kind; declaredSpec = $_.declaredSpec
            currentVersion = $_.currentVersion; targetVersion = $_.targetVersion; writeSpec = $_.writeSpec; change = $_.change; reason = $_.reason
            metadata = [ordered]@{
              source = $_.metadata.source; selector = $_.metadata.selector; deprecated = $_.metadata.deprecated
              peerDependencies = $_.metadata.peerDependencies; peerDependenciesMeta = $_.metadata.peerDependenciesMeta
              engines = $_.metadata.engines; ngUpdate = $_.metadata.ngUpdate; distTags = $_.metadata.distTags
            }
          }
        })
      node = $Manifest.node
      warnings = $Manifest.warnings
    }
  }

Import-Module (Join-Path $modules 'Migration.Pipeline.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.State.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Core.psm1') -Force -DisableNameChecking
$responsePath = Join-Path $temporaryRoot 'responses.json'
New-RegistryResponses -Path $responsePath
Copy-Item (Join-Path $fixtureDirectory 'respond.ps1') $toolDirectory
@'
@echo off
if "%~1"=="--version" echo 10.2.4&exit /b 0
if "%~1"=="view" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0respond.ps1" -Key "%~2" -RawArguments "%*"&exit /b %ERRORLEVEL%
if "%~1"=="ci" echo install>>.fixture-trace
if "%~1"=="ls" echo dependency-tree>>.fixture-trace
if "%~1"=="run" if "%~2"=="test:unit" (echo unit-test>>.fixture-trace) else (echo %~2>>.fixture-trace)
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $toolDirectory 'npm.cmd') -Encoding ASCII
@'
@echo off
echo v20.11.1
'@ | Set-Content -LiteralPath (Join-Path $toolDirectory 'node.cmd') -Encoding ASCII
$env:PATH = $toolDirectory + [IO.Path]::PathSeparator + $originalPath
$env:MIGRATION_REGISTRY_FIXTURE = $responsePath

$roots = @(
    (Join-Path $temporaryRoot 'project-one'),
    (Join-Path $temporaryRoot 'project-two')
)
try {
    foreach ($root in $roots) { New-IntegrationProject -Path $root }
    $first = Invoke-ResolutionRun -ProjectRoot $roots[0]
    $second = Invoke-ResolutionRun -ProjectRoot $roots[1]
    $firstProjection = Get-ResolutionDecisionProjection -Manifest $first.manifest
    $secondProjection = Get-ResolutionDecisionProjection -Manifest $second.manifest
    if (($firstProjection | ConvertTo-Json -Depth 50 -Compress) -cne ($secondProjection | ConvertTo-Json -Depth 50 -Compress)) { throw 'Independent resolution runs produced different decisions' }
    $tampered = Read-MigrationJson -Path $first.paths.manifest -Required
    $tampered.node.activeVersion = '0.0.0'
    Write-MigrationJsonAtomic -Value $tampered -Path $first.paths.manifest
    try { Invoke-MigrationStatus -ProjectRoot $roots[0] -RunId $first.state.runId | Out-Null; throw 'Tampered manifest was accepted' }
    catch { if ($_.Exception.Data['code'] -ne 'manifest_integrity_failed') { throw } }
    Write-Host 'PASS independent resolution publication, immutability and integrity'
}
finally {
    $env:PATH = $originalPath
    if ($null -eq $originalFixture) { Remove-Item Env:MIGRATION_REGISTRY_FIXTURE -ErrorAction SilentlyContinue } else { $env:MIGRATION_REGISTRY_FIXTURE = $originalFixture }
    if ($null -eq $originalTrace) { Remove-Item Env:MIGRATION_REGISTRY_TRACE -ErrorAction SilentlyContinue } else { $env:MIGRATION_REGISTRY_TRACE = $originalTrace }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}