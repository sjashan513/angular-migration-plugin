Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.Project.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.State.psm1') -DisableNameChecking

$script:MetadataCache = @{}
$script:MetadataQueryEvents = @()
$script:ResolutionContext = $null
$script:ResolverVersion = 1
$script:FrameworkPackageNames = @(
    'animations', 'common', 'compiler', 'core', 'elements', 'forms',
    'language-service', 'localize', 'platform-browser', 'platform-browser-dynamic',
    'platform-server', 'platform-webworker', 'platform-webworker-dynamic', 'router',
    'service-worker', 'upgrade'
)

function Get-DependencyObjectValue {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-DependencyObjectNames {
    param($Object)

    if ($null -eq $Object) { return @() }
    if ($Object -is [Collections.IDictionary]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties | Select-Object -ExpandProperty Name)
}

function ConvertTo-DependencyMap {
    param($Object)

    $result = [ordered]@{}
    foreach ($name in @(Get-DependencyObjectNames -Object $Object | Sort-Object)) {
        $result[$name] = Get-DependencyObjectValue -Object $Object -Name $name
    }
    return $result
}

function Assert-DependencyPackageName {
    param([string]$PackageName)

    if ([string]::IsNullOrWhiteSpace($PackageName) -or $PackageName -notmatch '^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$') {
        Throw-MigrationError -Code 'registry_metadata_invalid' -Message "Invalid npm package name: $PackageName" -Status blocked
    }
}

function Assert-DependencyVersionSelector {
    param([string]$VersionSelector)

    if ([string]::IsNullOrWhiteSpace($VersionSelector) -or $VersionSelector.IndexOf([char]0) -ge 0 -or
        $VersionSelector -match "[`r`n]" -or $VersionSelector.StartsWith('--') -or
        $VersionSelector -notmatch '^[0-9A-Za-z.*xX~^<>=|+() \-]+$') {
        Throw-MigrationError -Code 'registry_metadata_invalid' -Message 'Invalid internally generated npm version selector.' -Status blocked
    }
}

function Get-DependencyQueryLogContext {
    param([string]$PackageName)

    if ($null -eq $script:ResolutionContext) { return $null }
    $script:ResolutionContext.queryIndex++
    $safeName = $PackageName -replace '[^a-zA-Z0-9._-]', '_'
    $prefix = '{0:D3}-{1}' -f $script:ResolutionContext.queryIndex, $safeName
    $directory = $script:ResolutionContext.logDirectory
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    return [PSCustomObject]@{
        stdoutPath = Join-Path $directory ($prefix + '.stdout.log')
        stderrPath = Join-Path $directory ($prefix + '.stderr.log')
        stdoutRelative = 'logs/resolve/' + $prefix + '.stdout.log'
        stderrRelative = 'logs/resolve/' + $prefix + '.stderr.log'
    }
}

function ConvertTo-DependencyMetadataRecord {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$VersionSelector,
        [Parameter(Mandatory = $true)][string]$RetrievedAt
    )

    $version = [string](Get-DependencyObjectValue -Object $Value -Name 'version')
    $candidatesValue = Get-DependencyObjectValue -Object $Value -Name 'candidates'
    $candidates = @()
    if ($null -ne $candidatesValue) {
        foreach ($candidate in @($candidatesValue)) {
            $candidateVersion = [string](Get-DependencyObjectValue -Object $candidate -Name 'version')
            if ($candidateVersion) {
                $candidateNgUpdate = Get-DependencyObjectValue -Object $candidate -Name 'ng-update'
                if ($null -eq $candidateNgUpdate) { $candidateNgUpdate = Get-DependencyObjectValue -Object $candidate -Name 'ngUpdate' }
                $candidates += [ordered]@{
                    version = $candidateVersion
                    deprecated = [bool](Get-DependencyObjectValue -Object $candidate -Name 'deprecated')
                    peerDependencies = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $candidate -Name 'peerDependencies')
                    peerDependenciesMeta = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $candidate -Name 'peerDependenciesMeta')
                    engines = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $candidate -Name 'engines')
                    ngUpdate = $candidateNgUpdate
                }
            }
        }
    }
    if (-not $version -and $candidates.Count -gt 0) { $version = [string]$candidates[0].version }
    if (-not $version) {
        Throw-MigrationError -Code 'registry_metadata_invalid' -Message "Registry metadata for $PackageName has no exact version." -Status blocked
    }
    $deprecatedValue = Get-DependencyObjectValue -Object $Value -Name 'deprecated'
    $deprecated = if ($deprecatedValue -is [bool]) { [bool]$deprecatedValue } else { -not [string]::IsNullOrWhiteSpace([string]$deprecatedValue) }
    $record = [ordered]@{
        version = $version
        source = 'npm-view'
        selector = $VersionSelector
        retrievedAt = $RetrievedAt
        deprecated = $deprecated
        peerDependencies = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $Value -Name 'peerDependencies')
        peerDependenciesMeta = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $Value -Name 'peerDependenciesMeta')
        engines = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $Value -Name 'engines')
        ngUpdate = Get-DependencyObjectValue -Object $Value -Name 'ng-update'
        distTags = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $Value -Name 'dist-tags')
    }
    if ($null -eq $record.ngUpdate) { $record.ngUpdate = Get-DependencyObjectValue -Object $Value -Name 'ngUpdate' }
    if ($candidates.Count -gt 0) { $record.candidates = @($candidates) }
    return [PSCustomObject]$record
}

function Get-DependencyMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$VersionSelector,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    Assert-DependencyPackageName -PackageName $PackageName
    Assert-DependencyVersionSelector -VersionSelector $VersionSelector
    $key = $PackageName.ToLowerInvariant() + '|' + $VersionSelector
    if ($script:MetadataCache.ContainsKey($key)) { return $script:MetadataCache[$key] }
    $npmPath = Find-MigrationExecutable -Names @('npm.cmd', 'npm.exe', 'npm')
    if (-not $npmPath) {
        Throw-MigrationError -Code 'registry_metadata_unavailable' -Message 'npm is not available for registry metadata.' -Status blocked
    }
    $arguments = @(
        'view',
        "$PackageName@$VersionSelector",
        'version',
        'peerDependencies',
        'peerDependenciesMeta',
        'engines',
        'ng-update',
        'deprecated',
        'dist-tags',
        '--json'
    )
    $logContext = Get-DependencyQueryLogContext -PackageName $PackageName
    $started = Get-Date
    try {
        $process = Invoke-MigrationProcess -FilePath $npmPath -Arguments $arguments -WorkingDirectory (Resolve-MigrationRoot -Path $ProjectRoot) -TimeoutSeconds 120
    }
    catch {
        Throw-MigrationError -Code 'registry_metadata_unavailable' -Message "Could not query metadata for $PackageName." -Status blocked -Details $_.Exception.Message
    }
    $finished = Get-Date
    if ($logContext) {
        try {
            [IO.File]::WriteAllText($logContext.stdoutPath, [string]$process.stdout, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($logContext.stderrPath, [string]$process.stderr, (New-Object Text.UTF8Encoding($false)))
        }
        catch {
            Throw-MigrationError -Code 'resolver_persistence_failed' -Message "Could not persist registry metadata logs for $PackageName." -Status failed
        }
    }
    $queryEvent = [ordered]@{
        packageName = $PackageName
        selector = $VersionSelector
        exitCode = $process.exitCode
        timedOut = [bool]$process.timedOut
        durationMs = [int64]($finished - $started).TotalMilliseconds
        stdoutLog = if ($logContext) { $logContext.stdoutRelative } else { $null }
        stderrLog = if ($logContext) { $logContext.stderrRelative } else { $null }
    }
    $script:MetadataQueryEvents += [PSCustomObject]$queryEvent
    if ($process.timedOut -or $process.exitCode -ne 0) {
        Throw-MigrationError -Code 'registry_metadata_unavailable' -Message "Registry metadata is unavailable for $PackageName@$VersionSelector." -Status blocked -Details ([PSCustomObject]$queryEvent)
    }
    try { $raw = $process.stdout | ConvertFrom-Json }
    catch {
        Throw-MigrationError -Code 'registry_metadata_invalid' -Message "Registry metadata for $PackageName is not valid JSON." -Status blocked
    }
    $metadata = ConvertTo-DependencyMetadataRecord -Value $raw -PackageName $PackageName -VersionSelector $VersionSelector -RetrievedAt (Get-MigrationUtcNow)
    $script:MetadataCache[$key] = $metadata
    return $metadata
}

function Get-DependencyVersionTuple {
    param([string]$Version)

    $match = [regex]::Match([string]$Version, '^(\d+)\.(\d+)\.(\d+)$')
    if (-not $match.Success) { return $null }
    return @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Compare-DependencyVersion {
    param([int[]]$Left, [int[]]$Right)

    for ($index = 0; $index -lt 3; $index++) {
        if ($Left[$index] -lt $Right[$index]) { return -1 }
        if ($Left[$index] -gt $Right[$index]) { return 1 }
    }
    return 0
}

function Get-DependencyVersionSortKey {
    param([string]$Version)

    $tuple = Get-DependencyVersionTuple -Version $Version
    if ($null -eq $tuple) { return '' }
    return '{0:D10}.{1:D10}.{2:D10}' -f $tuple[0], $tuple[1], $tuple[2]
}

function Test-DependencyVersionRange {
    param([string]$Version, [string]$Range)

    $versionTuple = Get-DependencyVersionTuple -Version $Version
    if ($null -eq $versionTuple -or [string]::IsNullOrWhiteSpace($Range)) { return $false }
    foreach ($alternative in ($Range -split '\|\|')) {
        $alternativeText = $alternative.Trim()
        if ($alternativeText -in @('', '*', 'x', 'X')) { return $true }
        $tokens = @($alternativeText -split '\s+' | Where-Object { $_ })
        $matches = $true
        foreach ($token in $tokens) {
            $operator = ''
            $value = $token
            if ($token -match '^(\^|~|>=|<=|>|<)(.+)$') { $operator = $Matches[1]; $value = $Matches[2] }
            $parts = $value -split '\.'
            $major = 0; $minor = 0; $patch = 0
            if ($parts.Count -lt 1 -or $parts[0] -notmatch '^\d+$') { $matches = $false; break }
            $major = [int]$parts[0]
            if ($parts.Count -gt 1 -and $parts[1] -notin @('x', 'X', '*')) {
                if ($parts[1] -notmatch '^\d+$') { $matches = $false; break }
                $minor = [int]$parts[1]
            }
            if ($parts.Count -gt 2 -and $parts[2] -notin @('x', 'X', '*')) {
                if ($parts[2] -notmatch '^\d+$') { $matches = $false; break }
                $patch = [int]$parts[2]
            }
            $base = @($major, $minor, $patch)
            $comparison = Compare-DependencyVersion -Left $versionTuple -Right $base
            if ($operator -eq '^') {
                $caretCompatible = if ($major -gt 0) {
                    $versionTuple[0] -eq $major -and $comparison -ge 0
                }
                elseif ($minor -gt 0) {
                    $versionTuple[0] -eq 0 -and $versionTuple[1] -eq $minor -and $comparison -ge 0
                }
                else {
                    $versionTuple[0] -eq 0 -and $versionTuple[1] -eq 0 -and $versionTuple[2] -eq $patch -and $comparison -ge 0
                }
                if (-not $caretCompatible) { $matches = $false; break }
            }
            elseif ($operator -eq '~') {
                if ($versionTuple[0] -ne $major -or $versionTuple[1] -ne $minor -or $comparison -lt 0) { $matches = $false; break }
            }
            elseif ($operator -eq '>=') { if ($comparison -lt 0) { $matches = $false; break } }
            elseif ($operator -eq '>') { if ($comparison -le 0) { $matches = $false; break } }
            elseif ($operator -eq '<=') { if ($comparison -gt 0) { $matches = $false; break } }
            elseif ($operator -eq '<') { if ($comparison -ge 0) { $matches = $false; break } }
            elseif ($parts.Count -eq 1 -or $parts[1] -in @('x', 'X', '*')) {
                if ($versionTuple[0] -ne $major) { $matches = $false; break }
            }
            elseif ($parts.Count -eq 2 -or $parts[2] -in @('x', 'X', '*')) {
                if ($versionTuple[0] -ne $major -or $versionTuple[1] -ne $minor) { $matches = $false; break }
            }
            elseif ($comparison -ne 0) { $matches = $false; break }
        }
        if ($matches) { return $true }
    }
    return $false
}

function Get-DependencyCandidateList {
    param($Metadata)

    $candidates = Get-DependencyObjectValue -Object $Metadata -Name 'candidates'
    if ($null -ne $candidates) {
        return @($candidates | ForEach-Object {
            [PSCustomObject]@{
                version = [string](Get-DependencyObjectValue -Object $_ -Name 'version')
                source = Get-DependencyObjectValue -Object $Metadata -Name 'source'
                selector = Get-DependencyObjectValue -Object $Metadata -Name 'selector'
                retrievedAt = Get-DependencyObjectValue -Object $Metadata -Name 'retrievedAt'
                deprecated = [bool](Get-DependencyObjectValue -Object $_ -Name 'deprecated')
                peerDependencies = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $_ -Name 'peerDependencies')
                peerDependenciesMeta = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $_ -Name 'peerDependenciesMeta')
                engines = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $_ -Name 'engines')
                ngUpdate = Get-DependencyObjectValue -Object $_ -Name 'ngUpdate'
                distTags = Get-DependencyObjectValue -Object $Metadata -Name 'distTags'
            }
        })
    }
    return @($Metadata)
}

function Select-DependencyCandidate {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [int]$Major = -1,
        [string]$RequiredRange,
        [string]$ExactVersion,
        [string]$FailureCode = 'registry_metadata_invalid'
    )

    $valid = @()
    foreach ($candidate in @(Get-DependencyCandidateList -Metadata $Metadata)) {
        $tuple = Get-DependencyVersionTuple -Version ([string]$candidate.version)
        if ($null -eq $tuple -or [bool]$candidate.deprecated) { continue }
        if ($Major -ge 0 -and $tuple[0] -ne $Major) { continue }
        if ($ExactVersion -and $candidate.version -cne $ExactVersion) { continue }
        if ($RequiredRange -and -not (Test-DependencyVersionRange -Version $candidate.version -Range $RequiredRange)) { continue }
        $valid += $candidate
    }
    if ($valid.Count -eq 0) {
        Throw-MigrationError -Code $FailureCode -Message 'No stable, non-deprecated compatible registry candidate exists.' -Status blocked
    }
    return @($valid | Sort-Object { Get-DependencyVersionSortKey -Version $_.version } -Descending | Select-Object -First 1)
}

function Get-DependencyWriteSpec {
    param([string]$DeclaredSpec, [string]$TargetVersion)

    if ($DeclaredSpec -match '^\d+\.\d+\.\d+$') { return $TargetVersion }
    if ($DeclaredSpec -match '^\^\d+\.\d+\.\d+$') { return '^' + $TargetVersion }
    if ($DeclaredSpec -match '^~\d+\.\d+\.\d+$') { return '~' + $TargetVersion }
    if ($DeclaredSpec -match '^>=\d+\.\d+\.\d+$') { return '>=' + $TargetVersion }
    if ($DeclaredSpec -match '^\d+\.(x|\*)$') {
        $targetMajor = (Get-DependencyVersionTuple -Version $TargetVersion)[0]
        return $targetMajor.ToString() + '.' + $Matches[1]
    }
    Throw-MigrationError -Code 'unsupported_dependency_spec' -Message "Cannot preserve dependency spec style: $DeclaredSpec" -Status blocked
}

function Get-DependencyRole {
    param([string]$PackageName)

    if ($PackageName -like '@angular/*' -and $script:FrameworkPackageNames -contains ($PackageName -replace '^@angular/', '')) { return 'angular-framework' }
    if ($PackageName -eq '@angular/cli' -or $PackageName -eq '@angular/compiler-cli' -or $PackageName -like '@angular-devkit/*' -or $PackageName -like '@ngtools/*') { return 'angular-tooling' }
    if ($PackageName -in @('typescript', 'rxjs', 'zone.js')) { return 'toolchain-related' }
    return 'registry-ordinary'
}

function Get-DependencyMinimumMajor {
    param([string]$Range)

    $match = [regex]::Match([string]$Range, '(?:\^|~|>=|>|<=|<)?\s*(\d+)')
    if ($match.Success) { return [int]$match.Groups[1].Value }
    return $null
}

function Test-DependencyAngularPeerCompatibility {
    param($Metadata, [hashtable]$TargetVersions)

    $peers = Get-DependencyObjectValue -Object $Metadata -Name 'peerDependencies'
    foreach ($name in @(Get-DependencyObjectNames -Object $peers)) {
        if ($name -notin @('@angular/core', '@angular/common', '@angular/compiler')) { continue }
        $range = [string](Get-DependencyObjectValue -Object $peers -Name $name)
        if (-not $TargetVersions.ContainsKey($name) -or -not (Test-DependencyVersionRange -Version $TargetVersions[$name] -Range $range)) { return $false }
    }
    return $true
}

function ConvertTo-PublishedDependencyMetadata {
    param($Metadata)

    $published = [ordered]@{}
    foreach ($name in @('source', 'selector', 'retrievedAt', 'deprecated', 'peerDependencies', 'peerDependenciesMeta', 'engines', 'ngUpdate', 'distTags')) {
        $published[$name] = Get-DependencyObjectValue -Object $Metadata -Name $name
    }
    return $published
}

function Get-DependencyEntryChange {
    param([string]$CurrentVersion, [string]$TargetVersion, [string]$Added)

    if ($Added) { return 'added-required-tooling' }
    $current = Get-DependencyVersionTuple -Version $CurrentVersion
    $target = Get-DependencyVersionTuple -Version $TargetVersion
    if ($current[0] -ne $target[0]) { return 'major-required' }
    if (($current -join '.') -eq ($target -join '.')) { return 'unchanged' }
    return 'minor-or-patch'
}

function ConvertTo-CanonicalDependencyValue {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($name in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) { $ordered[$name] = ConvertTo-CanonicalDependencyValue $Value[$name] }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-CanonicalDependencyValue $_ })
    }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -gt 0 -and $Value -isnot [ValueType] -and $Value -isnot [string]) {
        $ordered = [ordered]@{}
        foreach ($property in @($properties | Sort-Object Name)) { $ordered[$property.Name] = ConvertTo-CanonicalDependencyValue $property.Value }
        return $ordered
    }
    return $Value
}

function Get-ResolvedManifestHash {
    param([Parameter(Mandatory = $true)]$Manifest)

    $value = [ordered]@{}
    foreach ($name in @(Get-DependencyObjectNames -Object $Manifest | Where-Object { $_ -cne 'manifestSha256' } | Sort-Object)) {
        $value[$name] = ConvertTo-CanonicalDependencyValue (Get-DependencyObjectValue -Object $Manifest -Name $name)
    }
    $json = $value | ConvertTo-Json -Depth 100 -Compress
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ((($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')) }
    finally { $sha.Dispose() }
}

function Test-ResolvedManifest {
    param([Parameter(Mandatory = $true)]$Manifest)

    if ((Get-DependencyObjectValue $Manifest 'resolutionStatus') -ne 'resolved' -or
        (Get-DependencyObjectValue $Manifest 'resolverVersion') -ne $script:ResolverVersion -or
        (Get-DependencyObjectValue $Manifest 'sourceMajor') + 1 -ne (Get-DependencyObjectValue $Manifest 'targetMajor')) { return $false }
    $dependencies = @(Get-DependencyObjectValue $Manifest 'dependencies')
    if ($dependencies.Count -eq 0) { return $false }
    $names = @()
    foreach ($dependency in $dependencies) {
        foreach ($required in @('name', 'section', 'role', 'kind', 'declaredSpec', 'currentVersion', 'targetVersion', 'writeSpec', 'change', 'reason', 'metadata')) {
            if ($required -notin @(Get-DependencyObjectNames -Object $dependency)) { return $false }
        }
        $dependencyKind = Get-DependencyObjectValue -Object $dependency -Name 'kind'
        $targetVersion = Get-DependencyObjectValue -Object $dependency -Name 'targetVersion'
        $currentVersion = Get-DependencyObjectValue -Object $dependency -Name 'currentVersion'
        $change = Get-DependencyObjectValue -Object $dependency -Name 'change'
        $metadata = Get-DependencyObjectValue -Object $dependency -Name 'metadata'
        if ($dependencyKind -ne 'registry' -or $null -eq (Get-DependencyVersionTuple $targetVersion) -or
            (($change -ne 'added-required-tooling') -and $null -eq (Get-DependencyVersionTuple $currentVersion)) -or
            (Get-DependencyObjectValue -Object $metadata -Name 'source') -ne 'npm-view') { return $false }
        $names += Get-DependencyObjectValue -Object $dependency -Name 'name'
    }
    if (@($names | Sort-Object -Unique).Count -ne $names.Count) { return $false }
    $node = Get-DependencyObjectValue $Manifest 'node'
    if ($null -eq $node -or 'activeVersion' -notin @(Get-DependencyObjectNames -Object $node) -or 'requiredRange' -notin @(Get-DependencyObjectNames -Object $node) -or 'compatible' -notin @(Get-DependencyObjectNames -Object $node)) { return $false }
    if ('manifestSha256' -in @(Get-DependencyObjectNames -Object $Manifest)) { return (Get-DependencyObjectValue -Object $Manifest -Name 'manifestSha256') -match '^[0-9a-f]{64}$' }
    return $true
}

function Resolve-MigrationManifest {
    param(
        [Parameter(Mandatory = $true)]$PendingManifest,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $script:MetadataCache = @{}
    $script:MetadataQueryEvents = @()
    $script:ResolutionContext = $null
    try {
        $root = Resolve-MigrationRoot -Path $ProjectRoot
        if ((Get-DependencyObjectValue $PendingManifest 'resolutionStatus') -ne 'pending') { Throw-MigrationError -Code 'manifest_already_resolved' -Message 'Only pending manifests can be resolved.' -Status blocked }
        if ((Get-DependencyObjectValue $PendingManifest 'sourceMajor') + 1 -ne (Get-DependencyObjectValue $PendingManifest 'targetMajor')) { Throw-MigrationError -Code 'non_sequential_target' -Message 'Manifest target major must be source major plus one.' -Status blocked }
        if ($PendingManifest.PSObject.Properties['manifestSha256']) { Throw-MigrationError -Code 'manifest_already_resolved' -Message 'A pending manifest cannot contain a manifest hash.' -Status blocked }
        if ((Get-DependencyObjectValue $PendingManifest 'manifestType') -ne 'migration') { Throw-MigrationError -Code 'registry_metadata_invalid' -Message 'Invalid migration manifest.' -Status blocked }
        $runId = [string](Get-DependencyObjectValue $PendingManifest 'runId')
        Assert-MigrationRunId -RunId $runId
        $runRoot = Join-Path (Join-Path (Join-Path $root '.angular-migration') 'runs') $runId
        $script:ResolutionContext = [PSCustomObject]@{ queryIndex = 0; logDirectory = Join-Path $runRoot 'logs/resolve' }
        $lock = Get-ProjectLockfile -ProjectRoot $root
        $inventory = @($PendingManifest.dependencies)
        $byName = @{}
        foreach ($item in $inventory) {
            if ($byName.ContainsKey($item.name)) { Throw-MigrationError -Code 'duplicate_dependency_declaration' -Message "Dependency is declared more than once: $($item.name)" -Status blocked }
            $byName[$item.name] = $item
            if ($item.kind -ne 'registry') { Throw-MigrationError -Code 'unsupported_dependency_spec' -Message "Dependency requires an explicit policy: $($item.name)" -Status blocked }
            if (-not $lock.versions[$item.name]) { Throw-MigrationError -Code 'dependency_not_locked' -Message "Dependency is not present in package-lock.json: $($item.name)" -Status blocked }
        }
        $targetMajor = [int](Get-DependencyObjectValue $PendingManifest 'targetMajor')
        $targetVersions = @{}
        $resolvedEntries = @()
        $warnings = @()
        $selected = @{}
        foreach ($item in $inventory) {
            $name = [string]$item.name
            $currentVersion = [string]$lock.versions[$name]
            $role = Get-DependencyRole -PackageName $name
            $currentMajor = (Get-DependencyVersionTuple $currentVersion)[0]
            $selectorMajor = if ($role -in @('angular-framework', 'angular-tooling')) { $targetMajor } else { $currentMajor }
            $metadata = Get-DependencyMetadata -PackageName $name -VersionSelector ([string]$selectorMajor) -ProjectRoot $root
            $candidateFailureCode = if ($role -eq 'angular-framework') { 'angular_framework_unresolvable' } else { 'registry_metadata_invalid' }
            $candidate = Select-DependencyCandidate -Metadata $metadata -Major $selectorMajor -FailureCode $candidateFailureCode
            $angularPeers = @(Get-DependencyObjectNames (Get-DependencyObjectValue $candidate 'peerDependencies') | Where-Object { $_ -in @('@angular/core', '@angular/common', '@angular/compiler') })
            if ($role -eq 'registry-ordinary' -and $angularPeers.Count -gt 0) {
                $role = 'angular-aware-external'
            }
            $selected[$name] = $candidate
            $targetVersions[$name] = [string]$candidate.version
        }
        foreach ($alignedName in @('@angular/common', '@angular/compiler')) {
            if ($selected.ContainsKey('@angular/core') -and $selected.ContainsKey($alignedName) -and $selected[$alignedName].version -cne $selected['@angular/core'].version) {
                $alignedMetadata = Get-DependencyMetadata -PackageName $alignedName -VersionSelector ([string]$selected['@angular/core'].version) -ProjectRoot $root
                $selected[$alignedName] = Select-DependencyCandidate -Metadata $alignedMetadata -ExactVersion ([string]$selected['@angular/core'].version) -FailureCode 'angular_framework_unresolvable'
                $targetVersions[$alignedName] = [string]$selected[$alignedName].version
            }
        }
        if ($byName.ContainsKey('@angular/cli') -and -not $byName.ContainsKey('@angular/compiler-cli')) {
            $metadata = Get-DependencyMetadata -PackageName '@angular/compiler-cli' -VersionSelector ([string]$targetMajor) -ProjectRoot $root
            $selected['@angular/compiler-cli'] = Select-DependencyCandidate -Metadata $metadata -Major $targetMajor -FailureCode 'toolchain_unresolvable'
            $targetVersions['@angular/compiler-cli'] = [string]$selected['@angular/compiler-cli'].version
            $byName['@angular/compiler-cli'] = [PSCustomObject]@{ name = '@angular/compiler-cli'; section = 'devDependencies'; role = 'dev'; spec = $null; kind = 'registry'; added = $true }
        }
        foreach ($item in $inventory) {
            $name = [string]$item.name
            $candidate = $selected[$name]
            $angularPeers = @(Get-DependencyObjectNames (Get-DependencyObjectValue $candidate 'peerDependencies') | Where-Object { $_ -in @('@angular/core', '@angular/common', '@angular/compiler') })
            if ($angularPeers.Count -eq 0 -or (Test-DependencyAngularPeerCompatibility -Metadata $candidate -TargetVersions $targetVersions)) { continue }
            $currentMajor = (Get-DependencyVersionTuple ([string]$lock.versions[$name]))[0]
            $found = $false
            for ($candidateMajor = $currentMajor + 1; $candidateMajor -le $currentMajor + 10; $candidateMajor++) {
                try {
                    $nextMetadata = Get-DependencyMetadata -PackageName $name -VersionSelector ([string]$candidateMajor) -ProjectRoot $root
                    $nextCandidate = Select-DependencyCandidate -Metadata $nextMetadata -Major $candidateMajor -FailureCode 'peer_dependency_conflict'
                }
                catch {
                    continue
                }
                if (Test-DependencyAngularPeerCompatibility -Metadata $nextCandidate -TargetVersions $targetVersions) {
                    $candidate = $nextCandidate
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                Throw-MigrationError -Code 'peer_dependency_conflict' -Message "No Angular-compatible candidate exists for $name." -Status blocked
            }
            $selected[$name] = $candidate
            $targetVersions[$name] = [string]$candidate.version
            if ((Get-DependencyVersionTuple ([string]$candidate.version))[0] -ne $currentMajor) {
                $warnings += [PSCustomObject]@{ code = 'package_major_changed_for_angular'; package = $name; fromMajor = $currentMajor; toMajor = (Get-DependencyVersionTuple ([string]$candidate.version))[0] }
            }
        }
        $changed = $true
        $iteration = 0
        while ($changed) {
            $iteration++
            if ($iteration -gt 10) { Throw-MigrationError -Code 'dependency_resolution_did_not_converge' -Message 'Dependency peer resolution did not converge.' -Status blocked }
            $changed = $false
            foreach ($toolName in @('typescript', 'rxjs', 'zone.js')) {
                if (-not $selected.ContainsKey($toolName)) { continue }
                $candidate = $selected[$toolName]
                $peersToCheck = @()
                foreach ($selectedName in @('@angular/core', '@angular/compiler-cli', '@angular/cli')) {
                    if ($selected.ContainsKey($selectedName)) { $peersToCheck += $selected[$selectedName] }
                }
                foreach ($peerSource in $peersToCheck) {
                    $range = Get-DependencyObjectValue -Object (Get-DependencyObjectValue -Object $peerSource -Name 'peerDependencies') -Name $toolName
                    if ($range -and -not (Test-DependencyVersionRange -Version $candidate.version -Range ([string]$range))) {
                        $minimumMajor = Get-DependencyMinimumMajor -Range ([string]$range)
                        if ($null -eq $minimumMajor) { Throw-MigrationError -Code 'toolchain_unresolvable' -Message "No compatible $toolName version exists." -Status blocked }
                        $metadata = Get-DependencyMetadata -PackageName $toolName -VersionSelector ([string]$minimumMajor) -ProjectRoot $root
                        $replacement = Select-DependencyCandidate -Metadata $metadata -Major $minimumMajor -RequiredRange ([string]$range) -FailureCode 'toolchain_unresolvable'
                        if ($replacement.version -cne $candidate.version) {
                            $selected[$toolName] = $replacement
                            $targetVersions[$toolName] = [string]$replacement.version
                            $changed = $true
                        }
                    }
                }
            }
        }
        $nodeRanges = @()
        $nodePackages = @()
        foreach ($name in @($selected.Keys)) {
            if ($name -eq '@angular/cli' -or $name -eq '@angular/compiler-cli' -or $name -like '@angular-devkit/*' -or $name -like '@ngtools/*') {
                $engines = Get-DependencyObjectValue -Object $selected[$name] -Name 'engines'
                $range = [string](Get-DependencyObjectValue -Object $engines -Name 'node')
                if ($range) { $nodeRanges += $range; $nodePackages += $name }
            }
        }
        $activeNode = [string](Get-DependencyObjectValue -Object (Get-DependencyObjectValue -Object $PendingManifest.project.toolchain -Name 'node') -Name 'version')
        $activeNode = $activeNode -replace '^v', ''
        $requiredRange = if ($nodeRanges.Count -gt 0) { ($nodeRanges | Select-Object -Unique) -join ' && ' } else { '*' }
        $nodeCompatible = $true
        foreach ($range in @($nodeRanges | Select-Object -Unique)) { if (-not (Test-DependencyVersionRange -Version $activeNode -Range $range)) { $nodeCompatible = $false } }
        if (-not $nodeCompatible) {
            Throw-MigrationError -Code 'node_version_incompatible' -Message 'Active Node does not satisfy the selected package engines.' -Status blocked -Details ([PSCustomObject]@{ activeVersion = $activeNode; requiredRange = $requiredRange; packages = $nodePackages })
        }
        foreach ($name in @($selected.Keys)) {
            $metadata = $selected[$name]
            $peers = Get-DependencyObjectValue -Object $metadata -Name 'peerDependencies'
            $peerMeta = Get-DependencyObjectValue -Object $metadata -Name 'peerDependenciesMeta'
            foreach ($peerName in @(Get-DependencyObjectNames -Object $peers)) {
                $range = [string](Get-DependencyObjectValue -Object $peers -Name $peerName)
                $optionalInfo = Get-DependencyObjectValue -Object $peerMeta -Name $peerName
                $optional = [bool](Get-DependencyObjectValue -Object $optionalInfo -Name 'optional')
                if (-not $targetVersions.ContainsKey($peerName)) {
                    if ($optional) {
                        $warnings += [PSCustomObject]@{ code = 'optional_peer_missing'; package = $name; peer = $peerName; range = $range }
                        continue
                    }
                    Throw-MigrationError -Code 'peer_dependency_conflict' -Message "Required peer $peerName is missing for $name." -Status blocked -Details ([PSCustomObject]@{ package = $name; peer = $peerName; range = $range })
                }
                if (-not (Test-DependencyVersionRange -Version $targetVersions[$peerName] -Range $range)) {
                    Throw-MigrationError -Code 'peer_dependency_conflict' -Message "Peer $peerName is incompatible with $name." -Status blocked -Details ([PSCustomObject]@{ package = $name; peer = $peerName; range = $range; version = $targetVersions[$peerName] })
                }
            }
        }
        foreach ($item in $inventory) {
            $name = [string]$item.name
            $candidate = $selected[$name]
            $currentVersion = [string]$lock.versions[$name]
            $role = Get-DependencyRole -PackageName $name
            $angularPeers = @(Get-DependencyObjectNames (Get-DependencyObjectValue $candidate 'peerDependencies') | Where-Object { $_ -in @('@angular/core', '@angular/common', '@angular/compiler') })
            if ($role -eq 'registry-ordinary' -and $angularPeers.Count -gt 0) { $role = 'angular-aware-external' }
            $targetVersion = [string]$candidate.version
            $resolvedEntries += [PSCustomObject][ordered]@{
                name = $name
                section = [string]$item.section
                role = $role
                kind = 'registry'
                declaredSpec = [string]$item.spec
                currentVersion = $currentVersion
                targetVersion = $targetVersion
                writeSpec = Get-DependencyWriteSpec -DeclaredSpec ([string]$item.spec) -TargetVersion $targetVersion
                change = Get-DependencyEntryChange -CurrentVersion $currentVersion -TargetVersion $targetVersion -Added $null
                reason = if ($role -eq 'angular-framework') { "Angular framework packages align to target major $targetMajor" } elseif ($role -eq 'angular-tooling') { 'Angular tooling follows the target framework' } elseif ($role -eq 'angular-aware-external') { 'Angular peer compatibility requires this candidate' } else { 'Latest stable version within the installed major' }
                metadata = ConvertTo-PublishedDependencyMetadata -Metadata $candidate
            }
        }
        if ($byName.ContainsKey('@angular/compiler-cli') -and -not @($inventory | Where-Object name -eq '@angular/compiler-cli')) {
            $candidate = $selected['@angular/compiler-cli']
            $resolvedEntries += [PSCustomObject][ordered]@{
                name = '@angular/compiler-cli'; section = 'devDependencies'; role = 'angular-tooling'; kind = 'registry'; declaredSpec = $null; currentVersion = $null
                targetVersion = [string]$candidate.version; writeSpec = [string]$candidate.version; change = 'added-required-tooling'; reason = 'Angular application requires compiler-cli for the target framework'; metadata = ConvertTo-PublishedDependencyMetadata -Metadata $candidate
            }
        }
        $resolved = [ordered]@{}
        foreach ($property in @($PendingManifest.PSObject.Properties)) { $resolved[$property.Name] = $property.Value }
        $resolved.resolutionStatus = 'resolved'
        $resolved.resolverVersion = $script:ResolverVersion
        $resolved.resolvedAt = Get-MigrationUtcNow
        $resolved.node = [ordered]@{ activeVersion = $activeNode; requiredRange = $requiredRange; compatible = $nodeCompatible }
        $resolved.dependencies = @($resolvedEntries)
        $resolved.warnings = @($warnings)
        $resolved.angular = [ordered]@{
            declaredCoreSpec = $PendingManifest.angular.declaredCoreSpec
            resolvedCoreVersion = $PendingManifest.angular.resolvedCoreVersion
            current = $PendingManifest.angular.current
            target = [ordered]@{ major = $targetMajor; resolved = $true; resolutionStatus = 'resolved'; coreVersion = $targetVersions['@angular/core'] }
        }
        if (-not (Test-ResolvedManifest -Manifest ([PSCustomObject]$resolved))) { Throw-MigrationError -Code 'registry_metadata_invalid' -Message 'Resolved manifest failed its contract validation.' -Status blocked }
        $resolved.manifestSha256 = Get-ResolvedManifestHash -Manifest ([PSCustomObject]$resolved)
        $published = [PSCustomObject]$resolved
        return [PSCustomObject]@{ status = 'resolved'; manifest = $published; queryEvents = @($script:MetadataQueryEvents); diagnostic = $null }
    }
    catch {
        $status = if ($_.Exception.Data['status'] -eq 'blocked') { 'blocked' } else { 'failed' }
        $code = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'resolver_internal_error' }
        return [PSCustomObject]@{
            status = $status; manifest = $null; queryEvents = @($script:MetadataQueryEvents)
            diagnostic = [PSCustomObject]@{ code = $code; message = $_.Exception.Message; details = $_.Exception.Data['details'] }
        }
    }
    finally {
        $script:ResolutionContext = $null
    }
}

Export-ModuleMember -Function @(
    'Get-DependencyMetadata',
    'Resolve-MigrationManifest',
    'Test-ResolvedManifest',
    'Get-ResolvedManifestHash'
)