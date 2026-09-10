#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '../../scripts/modules/Migration.Dependencies.psm1'
Import-Module $modulePath -Force -DisableNameChecking
$fixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot '../fixtures/registry')).Path
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('migration-dependencies-' + [guid]::NewGuid().ToString('N'))
$tracePath = Join-Path $temporaryRoot 'trace.log'
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
$originalPath = $env:PATH
$originalFixture = $env:MIGRATION_REGISTRY_FIXTURE
$originalTrace = $env:MIGRATION_REGISTRY_TRACE
try {
    $env:PATH = $fixtureRoot + [IO.Path]::PathSeparator + $originalPath
    $env:MIGRATION_REGISTRY_FIXTURE = Join-Path $fixtureRoot 'responses.json'
    $env:MIGRATION_REGISTRY_TRACE = $tracePath
    $first = Get-DependencyMetadata -PackageName '@angular/core' -VersionSelector '8' -ProjectRoot $temporaryRoot
    $second = Get-DependencyMetadata -PackageName '@angular/core' -VersionSelector '8' -ProjectRoot $temporaryRoot
    if ($first.version -ne '8.2.14' -or $first.source -ne 'npm-view' -or $first.selector -ne '8' -or $first.deprecated -or $first.ngUpdate.migrations -ne 'migrations.json') { throw 'Metadata normalization failed' }
    if ((Get-Content -LiteralPath $tracePath).Count -ne 1) { throw 'Metadata cache did not avoid the second query' }
    $expectedArguments = 'view @angular/core@8 version peerDependencies peerDependenciesMeta engines ng-update deprecated dist-tags --json'
    if ((Get-Content -LiteralPath $tracePath -Raw).Trim() -ne $expectedArguments) { throw 'npm view arguments are not exact' }
    if ($first.PSObject.Properties.Name -contains 'token' -or $first.PSObject.Properties.Name -contains 'environment') { throw 'Metadata leaked sensitive context' }
    Write-Host 'PASS npm view metadata normalization, cache and argument contract'

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
    $responsePath = Join-Path $temporaryRoot 'responses-complete.json'
    $responses | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $responsePath -Encoding UTF8
    $env:MIGRATION_REGISTRY_FIXTURE = $responsePath
    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    $lock = [ordered]@{ lockfileVersion = 1; dependencies = [ordered]@{
        '@angular/core' = @{ version = '7.2.16' }; '@angular/common' = @{ version = '7.2.16' }; '@angular/compiler' = @{ version = '7.2.16' }; '@angular/cli' = @{ version = '7.3.10' }
        rxjs = @{ version = '6.3.3' }; 'zone.js' = @{ version = '0.8.26' }; typescript = @{ version = '3.2.2' }; ordinary = @{ version = '1.2.0' }; 'angular-aware' = @{ version = '1.0.0' }
    } }
    $lock | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'package-lock.json') -Encoding UTF8
    $pending = [PSCustomObject][ordered]@{
        schemaVersion = 5; manifestType = 'migration'; runId = 'angular-7-to-8-test'; sourceMajor = 7; targetMajor = 8; resolutionStatus = 'pending'
        project = [PSCustomObject][ordered]@{ root = $temporaryRoot; toolchain = [PSCustomObject][ordered]@{ node = [PSCustomObject][ordered]@{ version = '20.11.0' } } }
        angular = [PSCustomObject][ordered]@{ declaredCoreSpec = '^7.2.0'; resolvedCoreVersion = '7.2.16'; current = @{}; target = [PSCustomObject][ordered]@{ major = 8; resolved = $false; resolutionStatus = 'pending' } }
        dependencies = @(
            [PSCustomObject]@{ name = '@angular/core'; section = 'dependencies'; role = 'runtime'; spec = '^7.2.0'; kind = 'registry' }
            [PSCustomObject]@{ name = '@angular/common'; section = 'dependencies'; role = 'runtime'; spec = '^7.2.0'; kind = 'registry' }
            [PSCustomObject]@{ name = '@angular/compiler'; section = 'dependencies'; role = 'runtime'; spec = '^7.2.0'; kind = 'registry' }
            [PSCustomObject]@{ name = '@angular/cli'; section = 'devDependencies'; role = 'dev'; spec = '~7.3.0'; kind = 'registry' }
            [PSCustomObject]@{ name = 'rxjs'; section = 'dependencies'; role = 'runtime'; spec = '~6.3.3'; kind = 'registry' }
            [PSCustomObject]@{ name = 'zone.js'; section = 'dependencies'; role = 'runtime'; spec = '~0.8.26'; kind = 'registry' }
            [PSCustomObject]@{ name = 'typescript'; section = 'devDependencies'; role = 'dev'; spec = '~3.2.2'; kind = 'registry' }
            [PSCustomObject]@{ name = 'ordinary'; section = 'dependencies'; role = 'runtime'; spec = '^1.2.0'; kind = 'registry' }
            [PSCustomObject]@{ name = 'angular-aware'; section = 'dependencies'; role = 'runtime'; spec = '^1.0.0'; kind = 'registry' }
        )
        policies = @{}; checks = @{}; warnings = @{}
    }
    $resolved = Resolve-MigrationManifest -PendingManifest $pending -ProjectRoot $temporaryRoot
    if ($resolved.status -ne 'resolved') { throw "Complete resolution failed: $($resolved.diagnostic | ConvertTo-Json -Depth 10 -Compress)" }
    $resolvedNames = @($resolved.manifest.dependencies | Select-Object -ExpandProperty name)
    if ($resolvedNames -notcontains '@angular/compiler-cli' -or @($resolvedNames | Sort-Object -Unique).Count -ne 10) { throw 'Resolved manifest did not contain direct and required dependencies exactly once' }
    $resolvedCore = $resolved.manifest.dependencies | Where-Object name -eq '@angular/core'
    $resolvedCommon = $resolved.manifest.dependencies | Where-Object name -eq '@angular/common'
    $resolvedOrdinary = $resolved.manifest.dependencies | Where-Object name -eq 'ordinary'
    $resolvedAware = $resolved.manifest.dependencies | Where-Object name -eq 'angular-aware'
    if ($resolvedCore.targetVersion -ne '8.2.14' -or $resolvedCommon.targetVersion -ne '8.2.14' -or $resolvedCore.writeSpec -ne '^8.2.14' -or $resolvedCore.metadata.ngUpdate.migrations -ne 'migrations.json') { throw 'Angular alignment or ng-update preservation failed' }
    if ($resolvedOrdinary.targetVersion -ne '1.4.0' -or $resolvedOrdinary.change -ne 'minor-or-patch' -or $resolvedAware.targetVersion -ne '2.1.0' -or $resolvedAware.change -ne 'major-required') { throw 'Ordinary or Angular-aware resolution policy failed' }
    if ($resolved.manifest.node.compatible -ne $true -or $resolved.manifest.manifestSha256 -notmatch '^[0-9a-f]{64}$' -or -not (Test-ResolvedManifest -Manifest $resolved.manifest)) { throw 'Resolved manifest validation or hash failed' }
    if ((Get-ResolvedManifestHash -Manifest $resolved.manifest) -ne $resolved.manifest.manifestSha256) { throw 'Resolved manifest hash is not self-consistent' }
    $reordered = [PSCustomObject][ordered]@{ targetMajor = 8; sourceMajor = 7; resolutionStatus = 'resolved'; resolverVersion = 1; dependencies = $resolved.manifest.dependencies; node = $resolved.manifest.node; z = 1; a = 2 }
    $reorderedOther = [PSCustomObject][ordered]@{ a = 2; z = 1; node = $resolved.manifest.node; dependencies = $resolved.manifest.dependencies; resolverVersion = 1; resolutionStatus = 'resolved'; sourceMajor = 7; targetMajor = 8 }
    if ((Get-ResolvedManifestHash -Manifest $reordered) -ne (Get-ResolvedManifestHash -Manifest $reorderedOther)) { throw 'Canonical hash depends on input property order' }
    $already = Resolve-MigrationManifest -PendingManifest $resolved.manifest -ProjectRoot $temporaryRoot
    if ($already.status -ne 'blocked' -or $already.diagnostic.code -ne 'manifest_already_resolved') { throw 'Resolved manifest was accepted a second time' }

    function Save-CompleteResponses {
        $responses | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $responsePath -Encoding UTF8
    }

    function Get-PendingCopy {
        param($Value)
        return $Value | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    }

    function Add-DependencyCase {
        param([string]$Name, [string]$Spec, [string]$CurrentVersion, $Metadata)
        $responses[$Name + '@1'] = $Metadata
        $lock.dependencies[$Name] = @{ version = $CurrentVersion }
        $lock | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'package-lock.json') -Encoding UTF8
        $copy = Get-PendingCopy -Value $pending
        $copy.dependencies = @($copy.dependencies + [PSCustomObject]@{ name = $Name; section = 'dependencies'; role = 'runtime'; spec = $Spec; kind = 'registry' })
        return $copy
    }

    $xPending = Get-PendingCopy -Value $pending
    ($xPending.dependencies | Where-Object name -eq 'ordinary').spec = '1.x'
    $xResolved = Resolve-MigrationManifest -PendingManifest $xPending -ProjectRoot $temporaryRoot
    $xOrdinary = $xResolved.manifest.dependencies | Where-Object name -eq 'ordinary'
    if ($xResolved.status -ne 'resolved' -or $xOrdinary.writeSpec -ne '1.x') { throw 'x range style was not preserved against the resolved major' }

    $optionalMetadata = [ordered]@{ version = '1.0.0'; peerDependencies = @{ 'missing-peer' = '^1.0.0' }; peerDependenciesMeta = @{ 'missing-peer' = @{ optional = $true } }; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
    $optionalPending = Add-DependencyCase -Name 'optional-peer' -Spec '^1.0.0' -CurrentVersion '1.0.0' -Metadata $optionalMetadata
    Save-CompleteResponses
    $optionalResolved = Resolve-MigrationManifest -PendingManifest $optionalPending -ProjectRoot $temporaryRoot
    if ($optionalResolved.status -ne 'resolved' -or @($optionalResolved.manifest.warnings | Where-Object code -eq 'optional_peer_missing').Count -ne 1) { throw 'Optional peer warning was not published' }

    $requiredMetadata = [ordered]@{ version = '1.0.0'; peerDependencies = @{ 'required-peer' = '^1.0.0' }; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
    $requiredPending = Add-DependencyCase -Name 'mandatory-package' -Spec '^1.0.0' -CurrentVersion '1.0.0' -Metadata $requiredMetadata
    Save-CompleteResponses
    $requiredResolved = Resolve-MigrationManifest -PendingManifest $requiredPending -ProjectRoot $temporaryRoot
    if ($requiredResolved.status -ne 'blocked' -or $requiredResolved.diagnostic.code -ne 'peer_dependency_conflict') { throw 'Missing mandatory peer did not block' }

    $unsupportedPending = Get-PendingCopy -Value $pending
    $unsupportedPending.dependencies = @($unsupportedPending.dependencies + [PSCustomObject]@{ name = 'git-package'; section = 'dependencies'; role = 'runtime'; spec = 'git+https://example.invalid/repo.git'; kind = 'git' })
    $lock.dependencies['git-package'] = @{ version = '1.0.0' }
    $unsupported = Resolve-MigrationManifest -PendingManifest $unsupportedPending -ProjectRoot $temporaryRoot
    if ($unsupported.status -ne 'blocked' -or $unsupported.diagnostic.code -ne 'unsupported_dependency_spec') { throw 'Unsupported dependency spec was accepted' }

    $duplicatePending = Get-PendingCopy -Value $pending
    $duplicatePending.dependencies = @($duplicatePending.dependencies + [PSCustomObject]@{ name = 'ordinary'; section = 'devDependencies'; role = 'dev'; spec = '^1.2.0'; kind = 'registry' })
    $duplicate = Resolve-MigrationManifest -PendingManifest $duplicatePending -ProjectRoot $temporaryRoot
    if ($duplicate.status -ne 'blocked' -or $duplicate.diagnostic.code -ne 'duplicate_dependency_declaration') { throw 'Duplicate dependency declaration was accepted' }

    $privateMetadata = [ordered]@{ version = 'not-a-version'; peerDependencies = @{}; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
    $privatePending = Add-DependencyCase -Name 'private-package' -Spec '^1.0.0' -CurrentVersion '1.0.0' -Metadata $privateMetadata
    $responses.Remove('private-package@1')
    Save-CompleteResponses
    $private = Resolve-MigrationManifest -PendingManifest $privatePending -ProjectRoot $temporaryRoot
    if ($private.status -ne 'blocked' -or $private.diagnostic.code -ne 'registry_metadata_unavailable') { throw 'Unavailable registry metadata was not blocked' }

    $invalidMetadata = [ordered]@{ version = 'not-a-semver'; peerDependencies = @{}; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
    $invalidPending = Add-DependencyCase -Name 'invalid-metadata' -Spec '^1.0.0' -CurrentVersion '1.0.0' -Metadata $invalidMetadata
    Save-CompleteResponses
    $invalid = Resolve-MigrationManifest -PendingManifest $invalidPending -ProjectRoot $temporaryRoot
    if ($invalid.status -ne 'blocked' -or $invalid.diagnostic.code -ne 'registry_metadata_invalid') { throw 'Invalid registry metadata was not blocked' }

    $responses['angular-aware@2'].peerDependencies = @{ '@angular/core' = '^9.0.0' }
    Save-CompleteResponses
    $awareBlocked = Resolve-MigrationManifest -PendingManifest $pending -ProjectRoot $temporaryRoot
    if ($awareBlocked.status -ne 'blocked' -or $awareBlocked.diagnostic.code -ne 'peer_dependency_conflict') { throw 'Angular-aware package without a compatible candidate was accepted' }
    $responses['angular-aware@2'].peerDependencies = @{ '@angular/core' = '^8.0.0' }
    $responses['@angular/cli@8'].engines = @{ node = '>=99.0.0' }
    Save-CompleteResponses
    $nodeBlocked = Resolve-MigrationManifest -PendingManifest $pending -ProjectRoot $temporaryRoot
    if ($nodeBlocked.status -ne 'blocked' -or $nodeBlocked.diagnostic.code -ne 'node_version_incompatible') { throw 'Incompatible Node version was not blocked' }

    $timeoutMetadata = [ordered]@{ version = '1.0.0'; peerDependencies = @{}; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} }
    $timeoutPending = Add-DependencyCase -Name 'timeout-package' -Spec '^1.0.0' -CurrentVersion '1.0.0' -Metadata $timeoutMetadata
    Save-CompleteResponses
    $dependencyModule = Get-Module Migration.Dependencies
    & $dependencyModule {
        $script:OriginalDependencyProcess = (Get-Command Invoke-MigrationProcess -CommandType Function).ScriptBlock
        function script:Invoke-MigrationProcess {
            param($FilePath, $Arguments, $WorkingDirectory, $TimeoutSeconds)
            return [PSCustomObject]@{ exitCode = 124; stdout = ''; stderr = ''; timedOut = $true }
        }
    }
    try {
        $timeout = Resolve-MigrationManifest -PendingManifest $timeoutPending -ProjectRoot $temporaryRoot
        if ($timeout.status -ne 'blocked' -or $timeout.diagnostic.code -ne 'registry_metadata_unavailable') { throw 'Registry timeout was not classified as blocked' }
    }
    finally {
        & $dependencyModule { Set-Item Function:script:Invoke-MigrationProcess $script:OriginalDependencyProcess }
    }

    try { Get-DependencyMetadata -PackageName 'ordinary' -VersionSelector '--forbidden' -ProjectRoot $temporaryRoot | Out-Null; throw 'Forbidden npm selector was accepted' }
    catch { if ($_.Exception.Data['code'] -ne 'registry_metadata_invalid') { throw } }
    Write-Host 'PASS Angular 7 to 8 resolution, alignment, peers, writeSpec and canonical hash'
} finally {
    $env:PATH = $originalPath
    if ($null -eq $originalFixture) { Remove-Item Env:MIGRATION_REGISTRY_FIXTURE -ErrorAction SilentlyContinue } else { $env:MIGRATION_REGISTRY_FIXTURE = $originalFixture }
    if ($null -eq $originalTrace) { Remove-Item Env:MIGRATION_REGISTRY_TRACE -ErrorAction SilentlyContinue } else { $env:MIGRATION_REGISTRY_TRACE = $originalTrace }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}