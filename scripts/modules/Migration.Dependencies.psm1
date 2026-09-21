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
        stdoutPath     = Join-Path $directory ($prefix + '.stdout.log')
        stderrPath     = Join-Path $directory ($prefix + '.stderr.log')
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

    $rootArray = $Value -is [array]
    $version = if ($rootArray) { $null } else { [string](Get-DependencyObjectValue -Object $Value -Name 'version') }
    $candidatesValue = if ($rootArray) { @($Value) } else { Get-DependencyObjectValue -Object $Value -Name 'candidates' }
    $candidates = @()
    if ($null -ne $candidatesValue) {
        foreach ($candidate in @($candidatesValue)) {
            $candidateVersion = if ($candidate -is [string]) { [string]$candidate } else { [string](Get-DependencyObjectValue -Object $candidate -Name 'version') }
            if ($candidateVersion -and (-not $rootArray -or $candidateVersion -match '^\d+\.\d+\.\d+$')) {
                $candidateNgUpdate = Get-DependencyObjectValue -Object $candidate -Name 'ng-update'
                if ($null -eq $candidateNgUpdate) { $candidateNgUpdate = Get-DependencyObjectValue -Object $candidate -Name 'ngUpdate' }
                $candidateDistTags = Get-DependencyObjectValue -Object $candidate -Name 'dist-tags'
                if ($null -eq $candidateDistTags) { $candidateDistTags = Get-DependencyObjectValue -Object $candidate -Name 'distTags' }
                $candidates += [PSCustomObject][ordered]@{
                    version              = $candidateVersion
                    deprecated           = [bool](Get-DependencyObjectValue -Object $candidate -Name 'deprecated')
                    peerDependencies     = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $candidate -Name 'peerDependencies')
                    peerDependenciesMeta = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $candidate -Name 'peerDependenciesMeta')
                    engines              = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $candidate -Name 'engines')
                    ngUpdate             = $candidateNgUpdate
                    distTags             = ConvertTo-DependencyMap $candidateDistTags
                }
            }
        }
        if ($rootArray) {
            $candidates = @($candidates | Sort-Object { Get-DependencyVersionSortKey -Version $_.version } -Descending)
        }
    }
    if ($rootArray -and $candidates.Count -gt 0) {
        $primary = $candidates[0]
        $version = [string]$primary.version
        $deprecatedValue = $primary.deprecated
        $peerDependencies = $primary.peerDependencies
        $peerDependenciesMeta = $primary.peerDependenciesMeta
        $engines = $primary.engines
        $ngUpdate = $primary.ngUpdate
        $distTags = $primary.distTags
    }
    else {
        $deprecatedValue = Get-DependencyObjectValue -Object $Value -Name 'deprecated'
        $peerDependencies = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $Value -Name 'peerDependencies')
        $peerDependenciesMeta = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $Value -Name 'peerDependenciesMeta')
        $engines = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $Value -Name 'engines')
        $ngUpdate = Get-DependencyObjectValue -Object $Value -Name 'ng-update'
        if ($null -eq $ngUpdate) { $ngUpdate = Get-DependencyObjectValue -Object $Value -Name 'ngUpdate' }
        $distTags = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $Value -Name 'dist-tags')
    }
    if (-not $version -and $candidates.Count -gt 0) { $version = [string]$candidates[0].version }
    if (-not $version) {
        Throw-MigrationError -Code 'registry_metadata_invalid' -Message "Registry metadata for $PackageName has no exact version." -Status blocked
    }
    $deprecated = if ($deprecatedValue -is [bool]) { [bool]$deprecatedValue } else { -not [string]::IsNullOrWhiteSpace([string]$deprecatedValue) }
    $record = [ordered]@{
        version              = $version
        source               = 'npm-view'
        selector             = $VersionSelector
        retrievedAt          = $RetrievedAt
        deprecated           = $deprecated
        peerDependencies     = $peerDependencies
        peerDependenciesMeta = $peerDependenciesMeta
        engines              = $engines
        ngUpdate             = $ngUpdate
        distTags             = $distTags
    }
    if ($candidates.Count -gt 0) { $record.candidates = @($candidates) }
    return [PSCustomObject]$record
}

function Get-DependencyMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$VersionSelector,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$FnmPath = '',
        [string]$NodeVersion = ''
    )

    Assert-DependencyPackageName -PackageName $PackageName
    Assert-DependencyVersionSelector -VersionSelector $VersionSelector
    $key = $PackageName.ToLowerInvariant() + '|' + $VersionSelector
    if ($script:MetadataCache.ContainsKey($key)) { return $script:MetadataCache[$key] }
    $npmPath = if ($FnmPath -and $NodeVersion) { 'npm' } else { Find-MigrationExecutable -Names @('npm.cmd', 'npm.exe', 'npm') }
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
        if ($FnmPath -and $NodeVersion) {
            $process = Invoke-MigrationNodeProcess -FnmPath $FnmPath -NodeVersion $NodeVersion -Executable 'npm' -Arguments $arguments -WorkingDirectory (Resolve-MigrationRoot -Path $ProjectRoot) -TimeoutSeconds 120
        }
        else {
            $process = Invoke-MigrationProcess -FilePath $npmPath -Arguments $arguments -WorkingDirectory (Resolve-MigrationRoot -Path $ProjectRoot) -TimeoutSeconds 120
        }
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
        selector    = $VersionSelector
        exitCode    = $process.exitCode
        timedOut    = [bool]$process.timedOut
        durationMs  = [int64]($finished - $started).TotalMilliseconds
        stdoutLog   = if ($logContext) { $logContext.stdoutRelative } else { $null }
        stderrLog   = if ($logContext) { $logContext.stderrRelative } else { $null }
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
    $evaluation = Test-MigrationVersionRange -Version $Version -Range $Range -Detailed
    if (-not $evaluation.supported) {
        Throw-MigrationError -Code 'semver_range_unsupported' -Message "Unsupported semver range: $Range" -Status blocked -Details ([PSCustomObject]@{ version = $Version; range = $Range })
    }
    return [bool]$evaluation.matches
}

function Get-DependencyRangeDiagnosticEvaluation {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Range
    )

    $evaluation = Test-MigrationVersionRange -Version $Version -Range $Range -Detailed
    return [PSCustomObject]@{
        supported = [bool]$evaluation.supported
        matches   = [bool]$evaluation.matches
        version   = $Version
        range     = $Range
    }
}

function Get-DependencyAngularDiagnosticCompatibility {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][hashtable]$TargetVersions
    )

    $missing = @()
    $incompatible = @()
    $unsupported = @()
    $peers = Get-DependencyObjectValue -Object $Metadata -Name 'peerDependencies'
    foreach ($peerName in @(Get-DependencyObjectNames -Object $peers | Where-Object { $_ -in @('@angular/core', '@angular/common', '@angular/compiler') })) {
        $range = [string](Get-DependencyObjectValue -Object $peers -Name $peerName)
        if (-not $TargetVersions.ContainsKey($peerName)) {
            $missing += [PSCustomObject]@{ peer = $peerName; range = $range }
            continue
        }
        $evaluation = Get-DependencyRangeDiagnosticEvaluation -Version ([string]$TargetVersions[$peerName]) -Range $range
        if (-not $evaluation.supported) {
            $unsupported += [PSCustomObject]@{ peer = $peerName; range = $range; version = [string]$TargetVersions[$peerName] }
        }
        elseif (-not $evaluation.matches) {
            $incompatible += [PSCustomObject]@{ peer = $peerName; range = $range; version = [string]$TargetVersions[$peerName] }
        }
    }
    return [PSCustomObject]@{
        compatible   = $missing.Count -eq 0 -and $incompatible.Count -eq 0 -and $unsupported.Count -eq 0
        missing      = @($missing)
        incompatible = @($incompatible)
        unsupported  = @($unsupported)
    }
}

function Get-DependencyDiagnosticQueryEvents {
    param([AllowNull()][object[]]$Events)

    return @($Events | ForEach-Object {
            [PSCustomObject][ordered]@{
                packageName = [string](Get-DependencyObjectValue -Object $_ -Name 'packageName')
                selector    = [string](Get-DependencyObjectValue -Object $_ -Name 'selector')
                exitCode    = [int](Get-DependencyObjectValue -Object $_ -Name 'exitCode')
                timedOut    = [bool](Get-DependencyObjectValue -Object $_ -Name 'timedOut')
            }
        })
}

function Get-DependencyCandidateList {
    param($Metadata)

    $candidates = Get-DependencyObjectValue -Object $Metadata -Name 'candidates'
    if ($null -ne $candidates) {
        return @($candidates | ForEach-Object {
                $candidateDistTags = Get-DependencyObjectValue -Object $_ -Name 'distTags'
                if ($null -eq $candidateDistTags) { $candidateDistTags = Get-DependencyObjectValue -Object $_ -Name 'dist-tags' }
                if ($null -eq $candidateDistTags) { $candidateDistTags = Get-DependencyObjectValue -Object $Metadata -Name 'distTags' }
                [PSCustomObject]@{
                    version              = [string](Get-DependencyObjectValue -Object $_ -Name 'version')
                    source               = Get-DependencyObjectValue -Object $Metadata -Name 'source'
                    selector             = Get-DependencyObjectValue -Object $Metadata -Name 'selector'
                    retrievedAt          = Get-DependencyObjectValue -Object $Metadata -Name 'retrievedAt'
                    deprecated           = [bool](Get-DependencyObjectValue -Object $_ -Name 'deprecated')
                    peerDependencies     = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $_ -Name 'peerDependencies')
                    peerDependenciesMeta = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $_ -Name 'peerDependenciesMeta')
                    engines              = ConvertTo-DependencyMap (Get-DependencyObjectValue -Object $_ -Name 'engines')
                    ngUpdate             = Get-DependencyObjectValue -Object $_ -Name 'ngUpdate'
                    distTags             = ConvertTo-DependencyMap $candidateDistTags
                }
            })
    }
    return @($Metadata)
}

function Test-DependencyLtsCandidate {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][int]$Major
    )

    $version = [string](Get-DependencyObjectValue -Object $Candidate -Name 'version')
    $distTags = Get-DependencyObjectValue -Object $Candidate -Name 'distTags'
    foreach ($tag in @(Get-DependencyObjectNames -Object $distTags)) {
        if ([string]$tag -ieq "v$Major-lts" -and [string](Get-DependencyObjectValue -Object $distTags -Name ([string]$tag)) -ceq $version) {
            return $true
        }
    }
    return $false
}

function Select-DependencyCandidate {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [int]$Major = -1,
        [string]$RequiredRange,
        [string]$ExactVersion,
        [switch]$AllowLtsDeprecated,
        [switch]$AllowDeprecated,
        [string]$FailureCode = 'registry_metadata_invalid'
    )

    $valid = @()
    foreach ($candidate in @(Get-DependencyCandidateList -Metadata $Metadata)) {
        $tuple = Get-DependencyVersionTuple -Version ([string]$candidate.version)
        $deprecatedAllowed = $AllowDeprecated -or ($AllowLtsDeprecated -and $Major -ge 0 -and (Test-DependencyLtsCandidate -Candidate $candidate -Major $Major))
        if ($null -eq $tuple -or ([bool]$candidate.deprecated -and -not $deprecatedAllowed)) { continue }
        if ($Major -ge 0 -and $tuple[0] -ne $Major) { continue }
        if ($ExactVersion -and $candidate.version -cne $ExactVersion) { continue }
        if ($RequiredRange -and -not (Test-DependencyVersionRange -Version $candidate.version -Range $RequiredRange)) { continue }
        $valid += $candidate
    }
    if ($valid.Count -eq 0) {
        Throw-MigrationError -Code $FailureCode -Message 'No stable, non-deprecated compatible registry candidate exists.' -Status blocked
    }
    $stable = @($valid | Where-Object { -not [bool](Get-DependencyObjectValue -Object $_ -Name 'deprecated') })
    if ($stable.Count -gt 0) { $valid = $stable }
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

function Get-DependencyPeerException {
    param(
        $Policies,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Version
    )

    foreach ($exception in @(Get-DependencyObjectValue -Object $Policies -Name 'peerExceptions')) {
        $package = [string](Get-DependencyObjectValue -Object $exception -Name 'package')
        $exceptionVersion = [string](Get-DependencyObjectValue -Object $exception -Name 'version')
        if ($package -ceq $PackageName -and $exceptionVersion -ceq $Version) { return $exception }
    }
    return $null
}

function Get-DependencyPeerPromotion {
    param(
        $Policies,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    foreach ($promotion in @(Get-DependencyObjectValue -Object $Policies -Name 'transitivePeerPromotions')) {
        if ([string](Get-DependencyObjectValue -Object $promotion -Name 'package') -eq $PackageName) { return $promotion }
    }
    return $null
}

function Assert-DependencyPolicies {
    param($Policies)

    if ($null -eq $Policies) { return }
    $exceptions = Get-DependencyObjectValue -Object $Policies -Name 'peerExceptions'
    if ($null -ne $exceptions -and $exceptions -isnot [array] -and $exceptions -isnot [Collections.IDictionary] -and $exceptions -isnot [PSCustomObject]) {
        Throw-MigrationError -Code 'policy_invalid' -Message 'peerExceptions must be an array.' -Status blocked
    }
    $exceptionKeys = @()
    foreach ($exception in $(if ($null -eq $exceptions) { @() } else { @($exceptions) })) {
        $package = [string](Get-DependencyObjectValue -Object $exception -Name 'package')
        $version = [string](Get-DependencyObjectValue -Object $exception -Name 'version')
        $ignoredPeers = Get-DependencyObjectValue -Object $exception -Name 'ignoredPeers'
        [array]$normalizedIgnoredPeers = if ($null -eq $ignoredPeers) { @() } else { @($ignoredPeers) }
        $reason = [string](Get-DependencyObjectValue -Object $exception -Name 'reason')
        $scope = [string](Get-DependencyObjectValue -Object $exception -Name 'scope')
        if ($package -notmatch '^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$' -or
            $version -notmatch '^\d+\.\d+\.\d+$' -or $normalizedIgnoredPeers.Count -eq 0 -or
            @($normalizedIgnoredPeers | Where-Object { [string]$_ -notmatch '^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$' }).Count -gt 0 -or
            [string]::IsNullOrWhiteSpace($reason) -or $scope -cne 'run') {
            Throw-MigrationError -Code 'policy_invalid' -Message "Invalid peer exception policy for $package@$version." -Status blocked
        }
        $key = $package + '@' + $version
        if ($key -in $exceptionKeys) { Throw-MigrationError -Code 'policy_invalid' -Message "Duplicate peer exception policy: $key." -Status blocked }
        $exceptionKeys += $key
        if (@($normalizedIgnoredPeers | Sort-Object -Unique).Count -ne $normalizedIgnoredPeers.Count) {
            Throw-MigrationError -Code 'policy_invalid' -Message "Peer exception contains duplicate peers: $key." -Status blocked
        }
    }
    $promotions = Get-DependencyObjectValue -Object $Policies -Name 'transitivePeerPromotions'
    if ($null -ne $promotions -and $promotions -isnot [array] -and $promotions -isnot [Collections.IDictionary] -and $promotions -isnot [PSCustomObject]) {
        Throw-MigrationError -Code 'policy_invalid' -Message 'transitivePeerPromotions must be an array.' -Status blocked
    }
    $promotionNames = @()
    foreach ($promotion in $(if ($null -eq $promotions) { @() } else { @($promotions) })) {
        $package = [string](Get-DependencyObjectValue -Object $promotion -Name 'package')
        $section = [string](Get-DependencyObjectValue -Object $promotion -Name 'section')
        $reason = [string](Get-DependencyObjectValue -Object $promotion -Name 'reason')
        if ($package -notmatch '^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$' -or $section -notin @('dependencies', 'devDependencies') -or [string]::IsNullOrWhiteSpace($reason)) {
            Throw-MigrationError -Code 'policy_invalid' -Message "Invalid transitive peer promotion policy for $package." -Status blocked
        }
        if ($package -in $promotionNames) { Throw-MigrationError -Code 'policy_invalid' -Message "Duplicate transitive peer promotion policy: $package." -Status blocked }
        $promotionNames += $package
    }
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
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$ExcludedProperty = 'manifestSha256'
    )

    $value = [ordered]@{}
    foreach ($name in @(Get-DependencyObjectNames -Object $Manifest | Where-Object { $_ -cne $ExcludedProperty } | Sort-Object)) {
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
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$FnmPath = '',
        [string]$NodeVersion = ''
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
        $lock = Get-ProjectLockfile -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
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
        $policies = Get-DependencyObjectValue -Object $PendingManifest -Name 'policies'
        Assert-DependencyPolicies -Policies $policies
        $promotedEntries = @()
        $promotedNames = @{}
        foreach ($item in $inventory) {
            $name = [string]$item.name
            $currentVersion = [string]$lock.versions[$name]
            $role = Get-DependencyRole -PackageName $name
            $currentMajor = (Get-DependencyVersionTuple $currentVersion)[0]
            $versionPolicy = if ($role -in @('angular-framework', 'angular-tooling')) {
                Get-MigrationAngularToolingVersionPolicy -AngularMajor $targetMajor -PackageName $name
            }
            else {
                [PSCustomObject][ordered]@{ selector = [string]$currentMajor; major = $currentMajor; requiredRange = $null }
            }
            $metadata = Get-DependencyMetadata -PackageName $name -VersionSelector ([string]$versionPolicy.selector) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
            $candidateFailureCode = if ($role -eq 'angular-framework') { 'angular_framework_unresolvable' } else { 'registry_metadata_invalid' }
            $candidate = Select-DependencyCandidate -Metadata $metadata -Major ([int]$versionPolicy.major) -RequiredRange ([string]$versionPolicy.requiredRange) -AllowLtsDeprecated:($role -in @('angular-framework', 'angular-tooling')) -AllowDeprecated:($role -eq 'registry-ordinary') -FailureCode $candidateFailureCode
            $angularPeers = @(Get-DependencyObjectNames (Get-DependencyObjectValue $candidate 'peerDependencies') | Where-Object { $_ -in @('@angular/core', '@angular/common', '@angular/compiler') })
            if ($role -eq 'registry-ordinary' -and $angularPeers.Count -gt 0) {
                $role = 'angular-aware-external'
            }
            $selected[$name] = $candidate
            $targetVersions[$name] = [string]$candidate.version
            if ($role -eq 'registry-ordinary' -and [bool](Get-DependencyObjectValue -Object $candidate -Name 'deprecated')) {
                $warnings += [PSCustomObject]@{ code = 'deprecated_ordinary_dependency'; package = $name; version = [string]$candidate.version; reason = 'An existing ordinary dependency was retained because no non-deprecated compatible candidate was available.' }
            }
        }
        foreach ($alignedName in @('@angular/common', '@angular/compiler')) {
            if ($selected.ContainsKey('@angular/core') -and $selected.ContainsKey($alignedName) -and $selected[$alignedName].version -cne $selected['@angular/core'].version) {
                $alignedMetadata = Get-DependencyMetadata -PackageName $alignedName -VersionSelector ([string]$selected['@angular/core'].version) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
                $selected[$alignedName] = Select-DependencyCandidate -Metadata $alignedMetadata -ExactVersion ([string]$selected['@angular/core'].version) -AllowLtsDeprecated -FailureCode 'angular_framework_unresolvable'
                $targetVersions[$alignedName] = [string]$selected[$alignedName].version
            }
        }
        if ($byName.ContainsKey('@angular/cli') -and -not $byName.ContainsKey('@angular/compiler-cli')) {
            $versionPolicy = Get-MigrationAngularToolingVersionPolicy -AngularMajor $targetMajor -PackageName '@angular/compiler-cli'
            $metadata = Get-DependencyMetadata -PackageName '@angular/compiler-cli' -VersionSelector ([string]$versionPolicy.selector) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
            $selected['@angular/compiler-cli'] = Select-DependencyCandidate -Metadata $metadata -Major ([int]$versionPolicy.major) -RequiredRange ([string]$versionPolicy.requiredRange) -AllowLtsDeprecated -FailureCode 'toolchain_unresolvable'
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
                    $nextMetadata = Get-DependencyMetadata -PackageName $name -VersionSelector ([string]$candidateMajor) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
                    $nextCandidate = Select-DependencyCandidate -Metadata $nextMetadata -Major $candidateMajor -AllowLtsDeprecated:((Get-DependencyRole -PackageName $name) -in @('angular-framework', 'angular-tooling')) -FailureCode 'peer_dependency_conflict'
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
                        $metadata = Get-DependencyMetadata -PackageName $toolName -VersionSelector ([string]$minimumMajor) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
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
        $activeNode = [string]$NodeVersion
        if ([string]::IsNullOrWhiteSpace($activeNode)) {
            $activeNode = [string](Get-DependencyObjectValue -Object (Get-DependencyObjectValue -Object $PendingManifest.project.toolchain -Name 'node') -Name 'version')
        }
        $activeNode = $activeNode -replace '^v', ''
        $requiredRange = if ($nodeRanges.Count -gt 0) { ($nodeRanges | Select-Object -Unique) -join ' && ' } else { '*' }
        $nodeCompatible = $true
        foreach ($range in @($nodeRanges | Select-Object -Unique)) { if (-not (Test-DependencyVersionRange -Version $activeNode -Range $range)) { $nodeCompatible = $false } }
        if (-not $nodeCompatible) {
            Throw-MigrationError -Code 'node_version_incompatible' -Message 'Active Node does not satisfy the selected package engines.' -Status blocked -Details ([PSCustomObject]@{ activeVersion = $activeNode; requiredRange = $requiredRange; packages = $nodePackages })
        }
        $peerScanChanged = $true
        $peerScanIteration = 0
        while ($peerScanChanged) {
            $peerScanIteration++
            if ($peerScanIteration -gt 10) { Throw-MigrationError -Code 'dependency_resolution_did_not_converge' -Message 'Dependency peer promotion did not converge.' -Status blocked }
            $peerScanChanged = $false
            foreach ($name in @($selected.Keys)) {
                $metadata = $selected[$name]
                $version = [string](Get-DependencyObjectValue -Object $metadata -Name 'version')
                $peers = Get-DependencyObjectValue -Object $metadata -Name 'peerDependencies'
                $peerMeta = Get-DependencyObjectValue -Object $metadata -Name 'peerDependenciesMeta'
                $exception = Get-DependencyPeerException -Policies $policies -PackageName $name -Version $version
                $ignoredPeers = if ($exception) { @(Get-DependencyObjectValue -Object $exception -Name 'ignoredPeers') } else { @() }
                foreach ($peerName in @(Get-DependencyObjectNames -Object $peers)) {
                    $range = [string](Get-DependencyObjectValue -Object $peers -Name $peerName)
                    $optionalInfo = Get-DependencyObjectValue -Object $peerMeta -Name $peerName
                    $optional = [bool](Get-DependencyObjectValue -Object $optionalInfo -Name 'optional')
                    if (-not $targetVersions.ContainsKey($peerName)) {
                        if ($peerName -in $ignoredPeers) {
                            if (@($warnings | Where-Object { $_.code -eq 'ignored_peer_dependency' -and $_.package -eq $name -and $_.peer -eq $peerName }).Count -eq 0) {
                                $warnings += [PSCustomObject]@{ code = 'ignored_peer_dependency'; package = $name; peer = $peerName; range = $range; reason = [string](Get-DependencyObjectValue -Object $exception -Name 'reason') }
                            }
                            continue
                        }
                        if ($optional) {
                            if (@($warnings | Where-Object { $_.code -eq 'optional_peer_missing' -and $_.package -eq $name -and $_.peer -eq $peerName }).Count -eq 0) {
                                $warnings += [PSCustomObject]@{ code = 'optional_peer_missing'; package = $name; peer = $peerName; range = $range }
                            }
                            continue
                        }
                        $promotion = Get-DependencyPeerPromotion -Policies $policies -PackageName $peerName
                        if ($promotion) {
                            $promotionSection = [string](Get-DependencyObjectValue -Object $promotion -Name 'section')
                            $lockedVersion = [string]$lock.versions[$peerName]
                            if ($promotionSection -notin @('dependencies', 'devDependencies') -or [string]::IsNullOrWhiteSpace($lockedVersion) -or
                                $null -eq (Get-DependencyVersionTuple -Version $lockedVersion) -or -not (Test-DependencyVersionRange -Version $lockedVersion -Range $range)) {
                                Throw-MigrationError -Code 'peer_dependency_conflict' -Message "Locked transitive peer $peerName does not satisfy $name." -Status blocked -Details ([PSCustomObject]@{ package = $name; peer = $peerName; range = $range; version = $lockedVersion })
                            }
                            if (-not $promotedNames.ContainsKey($peerName)) {
                                $promotedMetadata = Get-DependencyMetadata -PackageName $peerName -VersionSelector $lockedVersion -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
                                $promotedCandidate = Select-DependencyCandidate -Metadata $promotedMetadata -ExactVersion $lockedVersion -FailureCode 'peer_dependency_conflict'
                                $selected[$peerName] = $promotedCandidate
                                $targetVersions[$peerName] = [string]$promotedCandidate.version
                                $promotedNames[$peerName] = $true
                                $promotedEntries += [PSCustomObject][ordered]@{
                                    name = $peerName; section = $promotionSection; role = Get-DependencyRole -PackageName $peerName; kind = 'registry'; declaredSpec = $null; currentVersion = $null
                                    targetVersion = [string]$promotedCandidate.version; writeSpec = [string]$promotedCandidate.version; change = 'added-required-tooling'
                                    reason = [string](Get-DependencyObjectValue -Object $promotion -Name 'reason'); metadata = ConvertTo-PublishedDependencyMetadata -Metadata $promotedCandidate
                                }
                                $peerScanChanged = $true
                            }
                            continue
                        }
                        Throw-MigrationError -Code 'peer_dependency_conflict' -Message "Required peer $peerName is missing for $name." -Status blocked -Details ([PSCustomObject]@{ package = $name; peer = $peerName; range = $range })
                    }
                    if (-not (Test-DependencyVersionRange -Version $targetVersions[$peerName] -Range $range)) {
                        if ($peerName -in $ignoredPeers) {
                            if (@($warnings | Where-Object { $_.code -eq 'ignored_peer_dependency' -and $_.package -eq $name -and $_.peer -eq $peerName }).Count -eq 0) {
                                $warnings += [PSCustomObject]@{ code = 'ignored_peer_dependency'; package = $name; peer = $peerName; range = $range; reason = [string](Get-DependencyObjectValue -Object $exception -Name 'reason') }
                            }
                            continue
                        }
                        Throw-MigrationError -Code 'peer_dependency_conflict' -Message "Peer $peerName is incompatible with $name." -Status blocked -Details ([PSCustomObject]@{ package = $name; peer = $peerName; range = $range; version = $targetVersions[$peerName] })
                    }
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
                name           = $name
                section        = [string]$item.section
                role           = $role
                kind           = 'registry'
                declaredSpec   = [string]$item.spec
                currentVersion = $currentVersion
                targetVersion  = $targetVersion
                writeSpec      = Get-DependencyWriteSpec -DeclaredSpec ([string]$item.spec) -TargetVersion $targetVersion
                change         = Get-DependencyEntryChange -CurrentVersion $currentVersion -TargetVersion $targetVersion -Added $null
                reason         = if ($role -eq 'angular-framework') { "Angular framework packages align to target major $targetMajor" } elseif ($role -eq 'angular-tooling') { 'Angular tooling follows the target framework' } elseif ($role -eq 'angular-aware-external') { 'Angular peer compatibility requires this candidate' } else { 'Latest stable version within the installed major' }
                metadata       = ConvertTo-PublishedDependencyMetadata -Metadata $candidate
            }
        }
        $resolvedEntries += @($promotedEntries)
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
            declaredCoreSpec    = $PendingManifest.angular.declaredCoreSpec
            resolvedCoreVersion = $PendingManifest.angular.resolvedCoreVersion
            current             = $PendingManifest.angular.current
            target              = [ordered]@{ major = $targetMajor; resolved = $true; resolutionStatus = 'resolved'; coreVersion = $targetVersions['@angular/core'] }
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

function Get-MigrationResolveDiagnostics {
    param(
        [Parameter(Mandatory = $true)]$PendingManifest,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$FnmPath = '',
        [string]$NodeVersion = ''
    )

    $script:MetadataCache = @{}
    $script:MetadataQueryEvents = @()
    $script:ResolutionContext = $null
    $conflicts = @()
    $warnings = @()
    $proposals = @()
    $selected = @{}
    $targetVersions = @{}
    $itemsByName = @{}
    $processedNames = @{}
    $roles = @{}
    $angularAwareFailures = @{}
    $promotionProposals = @{}
    try {
        $root = Resolve-MigrationRoot -Path $ProjectRoot
        $sourceMajor = [int](Get-DependencyObjectValue -Object $PendingManifest -Name 'sourceMajor')
        $targetMajor = [int](Get-DependencyObjectValue -Object $PendingManifest -Name 'targetMajor')
        if ((Get-DependencyObjectValue -Object $PendingManifest -Name 'resolutionStatus') -ne 'pending') {
            Throw-MigrationError -Code 'manifest_already_resolved' -Message 'Diagnostics require a pending manifest.' -Status blocked
        }
        if ((Get-DependencyObjectValue -Object $PendingManifest -Name 'manifestType') -and (Get-DependencyObjectValue -Object $PendingManifest -Name 'manifestType') -cne 'migration') {
            Throw-MigrationError -Code 'registry_metadata_invalid' -Message 'Invalid migration manifest.' -Status blocked
        }
        if ($sourceMajor + 1 -ne $targetMajor) {
            Throw-MigrationError -Code 'non_sequential_target' -Message 'Manifest target major must be source major plus one.' -Status blocked
        }
        $policies = Get-DependencyObjectValue -Object $PendingManifest -Name 'policies'
        Assert-DependencyPolicies -Policies $policies
        $lock = Get-ProjectLockfile -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
        $inventory = @((Get-DependencyObjectValue -Object $PendingManifest -Name 'dependencies'))
        foreach ($item in $inventory) {
            $name = [string](Get-DependencyObjectValue -Object $item -Name 'name')
            if ($itemsByName.ContainsKey($name)) {
                $conflicts += [PSCustomObject][ordered]@{
                    package = $name; stage = 'inventory'; code = 'duplicate_dependency_declaration'
                    message = "Dependency is declared more than once: $name."; details = $null
                }
                continue
            }
            $itemsByName[$name] = $item
        }
        foreach ($item in $inventory) {
            $name = [string](Get-DependencyObjectValue -Object $item -Name 'name')
            if ($processedNames.ContainsKey($name)) { continue }
            $processedNames[$name] = $true
            $record = [ordered]@{ package = $name; stage = 'candidate'; code = $null; message = $null; details = $null }
            try {
                if ([string]::IsNullOrWhiteSpace($name)) { Throw-MigrationError -Code 'registry_metadata_invalid' -Message 'Dependency name is required.' -Status blocked }
                if ((Get-DependencyObjectValue -Object $item -Name 'kind') -ne 'registry') {
                    Throw-MigrationError -Code 'unsupported_dependency_spec' -Message "Dependency requires an explicit policy: $name" -Status blocked
                }
                $currentVersion = [string](Get-DependencyObjectValue -Object $lock.versions -Name $name)
                if ([string]::IsNullOrWhiteSpace($currentVersion)) {
                    Throw-MigrationError -Code 'dependency_not_locked' -Message "Dependency is not present in package-lock.json: $name" -Status blocked
                }
                $currentTuple = Get-DependencyVersionTuple -Version $currentVersion
                if ($null -eq $currentTuple) {
                    Throw-MigrationError -Code 'dependency_version_invalid' -Message "Locked dependency version is not exact: $name@$currentVersion" -Status blocked
                }
                $role = Get-DependencyRole -PackageName $name
                $roles[$name] = $role
                $versionPolicy = if ($role -in @('angular-framework', 'angular-tooling')) {
                    Get-MigrationAngularToolingVersionPolicy -AngularMajor $targetMajor -PackageName $name
                }
                else {
                    [PSCustomObject][ordered]@{ selector = [string]$currentTuple[0]; major = $currentTuple[0]; requiredRange = $null }
                }
                $metadata = Get-DependencyMetadata -PackageName $name -VersionSelector ([string]$versionPolicy.selector) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
                $failureCode = if ($role -eq 'angular-framework') { 'angular_framework_unresolvable' } else { 'registry_metadata_invalid' }
                $candidate = Select-DependencyCandidate -Metadata $metadata -Major ([int]$versionPolicy.major) -RequiredRange ([string]$versionPolicy.requiredRange) -AllowLtsDeprecated:($role -in @('angular-framework', 'angular-tooling')) -AllowDeprecated:($role -eq 'registry-ordinary') -FailureCode $failureCode
                $selected[$name] = $candidate
                $targetVersions[$name] = [string](Get-DependencyObjectValue -Object $candidate -Name 'version')
                $angularPeerNames = @(Get-DependencyObjectNames -Object (Get-DependencyObjectValue -Object $candidate -Name 'peerDependencies') | Where-Object { $_ -in @('@angular/core', '@angular/common', '@angular/compiler') })
                if ($role -eq 'registry-ordinary' -and $angularPeerNames.Count -gt 0) { $roles[$name] = 'angular-aware-external' }
                if ($role -eq 'registry-ordinary' -and [bool](Get-DependencyObjectValue -Object $candidate -Name 'deprecated')) {
                    $warnings += [PSCustomObject][ordered]@{ code = 'deprecated_ordinary_dependency'; package = $name; version = [string](Get-DependencyObjectValue -Object $candidate -Name 'version'); reason = 'An existing ordinary dependency was retained because no non-deprecated compatible candidate was available.' }
                }
            }
            catch {
                $record.code = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'resolver_internal_error' }
                $record.message = $_.Exception.Message
                $record.details = $_.Exception.Data['details']
                $conflicts += [PSCustomObject]$record
            }
        }

        if ($selected.ContainsKey('@angular/core')) {
            foreach ($alignedName in @('@angular/common', '@angular/compiler')) {
                if (-not $selected.ContainsKey($alignedName)) { continue }
                if ([string](Get-DependencyObjectValue -Object $selected[$alignedName] -Name 'version') -ceq [string]$targetVersions['@angular/core']) { continue }
                try {
                    $alignedMetadata = Get-DependencyMetadata -PackageName $alignedName -VersionSelector ([string]$targetVersions['@angular/core']) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
                    $alignedCandidate = Select-DependencyCandidate -Metadata $alignedMetadata -ExactVersion ([string]$targetVersions['@angular/core']) -AllowLtsDeprecated -FailureCode 'angular_framework_unresolvable'
                    $selected[$alignedName] = $alignedCandidate
                    $targetVersions[$alignedName] = [string](Get-DependencyObjectValue -Object $alignedCandidate -Name 'version')
                }
                catch {
                    $conflicts += [PSCustomObject][ordered]@{
                        package = $alignedName; stage = 'alignment'; code = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'angular_framework_unresolvable' }
                        message = $_.Exception.Message; details = $_.Exception.Data['details']
                    }
                }
            }
        }

        if ($itemsByName.ContainsKey('@angular/cli') -and -not $itemsByName.ContainsKey('@angular/compiler-cli') -and $selected.ContainsKey('@angular/cli')) {
            try {
                $toolingPolicy = Get-MigrationAngularToolingVersionPolicy -AngularMajor $targetMajor -PackageName '@angular/compiler-cli'
                $toolingMetadata = Get-DependencyMetadata -PackageName '@angular/compiler-cli' -VersionSelector ([string]$toolingPolicy.selector) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
                $toolingCandidate = Select-DependencyCandidate -Metadata $toolingMetadata -Major ([int]$toolingPolicy.major) -RequiredRange ([string]$toolingPolicy.requiredRange) -AllowLtsDeprecated -FailureCode 'toolchain_unresolvable'
                $selected['@angular/compiler-cli'] = $toolingCandidate
                $targetVersions['@angular/compiler-cli'] = [string](Get-DependencyObjectValue -Object $toolingCandidate -Name 'version')
                $roles['@angular/compiler-cli'] = 'angular-tooling'
                $proposals += [PSCustomObject][ordered]@{
                    code = 'add-required-tooling'; package = '@angular/compiler-cli'; section = 'devDependencies'; version = $targetVersions['@angular/compiler-cli']
                    reason = 'Angular application requires compiler-cli for the target framework.'
                }
            }
            catch {
                $conflicts += [PSCustomObject][ordered]@{
                    package = '@angular/compiler-cli'; stage = 'toolchain'; code = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'toolchain_unresolvable' }
                    message = $_.Exception.Message; details = $_.Exception.Data['details']
                }
            }
        }

        foreach ($name in @($selected.Keys | Sort-Object)) {
            if ($roles[$name] -notin @('angular-aware-external', 'registry-ordinary')) { continue }
            $compatibility = Get-DependencyAngularDiagnosticCompatibility -Metadata $selected[$name] -TargetVersions $targetVersions
            foreach ($unsupported in @($compatibility.unsupported)) {
                $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'angular-aware'; code = 'semver_range_unsupported'; message = "Unsupported Angular peer range for $name."; details = $unsupported }
            }
            if ($compatibility.compatible -or $compatibility.unsupported.Count -gt 0) { continue }
            $currentVersion = [string](Get-DependencyObjectValue -Object $lock.versions -Name $name)
            $currentTuple = Get-DependencyVersionTuple -Version $currentVersion
            $found = $false
            if ($compatibility.missing.Count -eq 0 -and $null -ne $currentTuple) {
                for ($candidateMajor = $currentTuple[0] + 1; $candidateMajor -le $currentTuple[0] + 10; $candidateMajor++) {
                    try {
                        $nextMetadata = Get-DependencyMetadata -PackageName $name -VersionSelector ([string]$candidateMajor) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
                        $nextCandidate = Select-DependencyCandidate -Metadata $nextMetadata -Major $candidateMajor -FailureCode 'peer_dependency_conflict'
                        $nextCompatibility = Get-DependencyAngularDiagnosticCompatibility -Metadata $nextCandidate -TargetVersions $targetVersions
                        foreach ($unsupported in @($nextCompatibility.unsupported)) {
                            $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'angular-aware'; code = 'semver_range_unsupported'; message = "Unsupported Angular peer range for $name."; details = $unsupported }
                        }
                        if ($nextCompatibility.compatible) {
                            $selected[$name] = $nextCandidate
                            $targetVersions[$name] = [string](Get-DependencyObjectValue -Object $nextCandidate -Name 'version')
                            $found = $true
                            $warnings += [PSCustomObject][ordered]@{ code = 'package_major_changed_for_angular'; package = $name; fromMajor = $currentTuple[0]; toMajor = (Get-DependencyVersionTuple -Version $targetVersions[$name])[0] }
                            break
                        }
                    }
                    catch { }
                }
            }
            if (-not $found) {
                $angularAwareFailures[$name] = $true
                $conflicts += [PSCustomObject][ordered]@{
                    package = $name; stage = 'angular-aware'; code = 'peer_dependency_conflict'; message = "No Angular-compatible candidate exists for $name."
                    details = [PSCustomObject]@{ missing = @($compatibility.missing); incompatible = @($compatibility.incompatible) }
                }
            }
        }

        $toolchainIteration = 0
        $toolchainChanged = $true
        while ($toolchainChanged -and $toolchainIteration -lt 10) {
            $toolchainIteration++
            $toolchainChanged = $false
            foreach ($toolName in @('typescript', 'rxjs', 'zone.js')) {
                if (-not $selected.ContainsKey($toolName)) { continue }
                foreach ($sourceName in @('@angular/core', '@angular/compiler-cli', '@angular/cli')) {
                    if (-not $selected.ContainsKey($sourceName)) { continue }
                    $range = [string](Get-DependencyObjectValue -Object (Get-DependencyObjectValue -Object $selected[$sourceName] -Name 'peerDependencies') -Name $toolName)
                    if ([string]::IsNullOrWhiteSpace($range)) { continue }
                    $evaluation = Get-DependencyRangeDiagnosticEvaluation -Version ([string]$targetVersions[$toolName] -as [string]) -Range $range
                    if (-not $evaluation.supported) {
                        $conflicts += [PSCustomObject][ordered]@{ package = $sourceName; stage = 'toolchain'; code = 'semver_range_unsupported'; message = "Unsupported toolchain peer range for $sourceName."; details = [PSCustomObject]@{ peer = $toolName; range = $range; version = $targetVersions[$toolName] } }
                        continue
                    }
                    if ($evaluation.matches) { continue }
                    $minimumMajor = Get-DependencyMinimumMajor -Range $range
                    if ($null -eq $minimumMajor) {
                        $conflicts += [PSCustomObject][ordered]@{ package = $sourceName; stage = 'toolchain'; code = 'toolchain_unresolvable'; message = "No compatible $toolName version exists."; details = $evaluation }
                        continue
                    }
                    try {
                        $toolingMetadata = Get-DependencyMetadata -PackageName $toolName -VersionSelector ([string]$minimumMajor) -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
                        $replacement = Select-DependencyCandidate -Metadata $toolingMetadata -Major $minimumMajor -RequiredRange $range -FailureCode 'toolchain_unresolvable'
                        $replacementVersion = [string](Get-DependencyObjectValue -Object $replacement -Name 'version')
                        if ($replacementVersion -cne [string]$targetVersions[$toolName]) {
                            $selected[$toolName] = $replacement
                            $targetVersions[$toolName] = $replacementVersion
                            $toolchainChanged = $true
                        }
                    }
                    catch {
                        $conflicts += [PSCustomObject][ordered]@{ package = $sourceName; stage = 'toolchain'; code = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'toolchain_unresolvable' }; message = $_.Exception.Message; details = $_.Exception.Data['details'] }
                    }
                }
            }
        }
        if ($toolchainChanged) {
            $conflicts += [PSCustomObject][ordered]@{ package = 'toolchain'; stage = 'toolchain'; code = 'dependency_resolution_did_not_converge'; message = 'Toolchain peer diagnostics did not converge.'; details = [PSCustomObject]@{ iterations = $toolchainIteration } }
        }

        $activeNode = [string]$NodeVersion
        if ([string]::IsNullOrWhiteSpace($activeNode)) {
            $nodeDeclaration = Get-DependencyObjectValue -Object (Get-DependencyObjectValue -Object (Get-DependencyObjectValue -Object $PendingManifest -Name 'project') -Name 'toolchain') -Name 'node'
            $activeNode = if ($nodeDeclaration -is [string]) { [string]$nodeDeclaration } else { [string](Get-DependencyObjectValue -Object $nodeDeclaration -Name 'version') }
        }
        $activeNode = $activeNode -replace '^v', ''
        $nodeRanges = @()
        $nodePackages = @()
        foreach ($name in @($selected.Keys | Sort-Object)) {
            if ($name -ne '@angular/cli' -and $name -ne '@angular/compiler-cli' -and $name -notlike '@angular-devkit/*' -and $name -notlike '@ngtools/*') { continue }
            $nodeRange = [string](Get-DependencyObjectValue -Object (Get-DependencyObjectValue -Object $selected[$name] -Name 'engines') -Name 'node')
            if ([string]::IsNullOrWhiteSpace($nodeRange)) { continue }
            $nodeRanges += $nodeRange
            $nodePackages += $name
            if ([string]::IsNullOrWhiteSpace($activeNode)) {
                $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'node'; code = 'node_version_unavailable'; message = 'No active Node version was supplied for engine validation.'; details = [PSCustomObject]@{ requiredRange = $nodeRange } }
                continue
            }
            $nodeEvaluation = Get-DependencyRangeDiagnosticEvaluation -Version $activeNode -Range $nodeRange
            if (-not $nodeEvaluation.supported) {
                $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'node'; code = 'semver_range_unsupported'; message = "Unsupported Node engine range for $name."; details = $nodeEvaluation }
            }
            elseif (-not $nodeEvaluation.matches) {
                $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'node'; code = 'node_version_incompatible'; message = "Node $activeNode does not satisfy $name engine range $nodeRange."; details = $nodeEvaluation }
            }
        }

        $peerQueue = @($selected.Keys | Sort-Object)
        $peerQueueIndex = 0
        while ($peerQueueIndex -lt $peerQueue.Count) {
            $name = [string]$peerQueue[$peerQueueIndex]
            $peerQueueIndex++
            if (-not $selected.ContainsKey($name)) { continue }
            $metadata = $selected[$name]
            $version = [string](Get-DependencyObjectValue -Object $metadata -Name 'version')
            $exception = Get-DependencyPeerException -Policies $policies -PackageName $name -Version $version
            [array]$ignoredPeers = if ($exception) { @(Get-DependencyObjectValue -Object $exception -Name 'ignoredPeers') } else { @() }
            $peers = Get-DependencyObjectValue -Object $metadata -Name 'peerDependencies'
            $peerMeta = Get-DependencyObjectValue -Object $metadata -Name 'peerDependenciesMeta'
            foreach ($peerName in @(Get-DependencyObjectNames -Object $peers | Sort-Object)) {
                if ($name -in $angularAwareFailures.Keys -and $peerName -in @('@angular/core', '@angular/common', '@angular/compiler')) { continue }
                $range = [string](Get-DependencyObjectValue -Object $peers -Name $peerName)
                $optionalInfo = Get-DependencyObjectValue -Object $peerMeta -Name $peerName
                $optional = [bool](Get-DependencyObjectValue -Object $optionalInfo -Name 'optional')
                if (-not $targetVersions.ContainsKey($peerName)) {
                    if ($peerName -in $ignoredPeers) {
                        $warnings += [PSCustomObject][ordered]@{ code = 'ignored_peer_dependency'; package = $name; peer = $peerName; range = $range; reason = [string](Get-DependencyObjectValue -Object $exception -Name 'reason') }
                        continue
                    }
                    if ($optional) {
                        $warnings += [PSCustomObject][ordered]@{ code = 'optional_peer_missing'; package = $name; peer = $peerName; range = $range }
                        continue
                    }
                    $promotion = Get-DependencyPeerPromotion -Policies $policies -PackageName $peerName
                    $lockedVersion = [string](Get-DependencyObjectValue -Object $lock.versions -Name $peerName)
                    if ($promotion -and $lockedVersion) {
                        $promotionEvaluation = Get-DependencyRangeDiagnosticEvaluation -Version $lockedVersion -Range $range
                        if (-not $promotionEvaluation.supported) {
                            $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'promotion'; code = 'semver_range_unsupported'; message = "Unsupported promoted peer range for $name."; details = [PSCustomObject]@{ peer = $peerName; range = $range; version = $lockedVersion } }
                            continue
                        }
                        if ($null -eq (Get-DependencyVersionTuple -Version $lockedVersion) -or -not $promotionEvaluation.matches) {
                            $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'promotion'; code = 'peer_dependency_conflict'; message = "Locked transitive peer $peerName does not satisfy $name."; details = [PSCustomObject]@{ package = $name; peer = $peerName; range = $range; version = $lockedVersion } }
                            continue
                        }
                        if (-not $promotionProposals.ContainsKey($peerName)) {
                            try {
                                $promotedMetadata = Get-DependencyMetadata -PackageName $peerName -VersionSelector $lockedVersion -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
                                $promotedCandidate = Select-DependencyCandidate -Metadata $promotedMetadata -ExactVersion $lockedVersion -FailureCode 'peer_dependency_conflict'
                                $selected[$peerName] = $promotedCandidate
                                $targetVersions[$peerName] = $lockedVersion
                                $peerQueue += $peerName
                                $proposal = [PSCustomObject][ordered]@{
                                    code = 'promote-transitive-peer'; package = $peerName; section = [string](Get-DependencyObjectValue -Object $promotion -Name 'section'); version = $lockedVersion
                                    source = $name; sources = @($name); reason = [string](Get-DependencyObjectValue -Object $promotion -Name 'reason')
                                }
                                $promotionProposals[$peerName] = $proposal
                                $proposals += $proposal
                            }
                            catch {
                                $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'promotion'; code = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'peer_dependency_conflict' }; message = $_.Exception.Message; details = $_.Exception.Data['details'] }
                            }
                        }
                        elseif ($name -notin @($promotionProposals[$peerName].sources)) {
                            $promotionProposals[$peerName].sources = @($promotionProposals[$peerName].sources + $name | Sort-Object -Unique)
                        }
                        continue
                    }
                    $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'peer'; code = 'peer_dependency_conflict'; message = "Required peer $peerName is missing for $name."; details = [PSCustomObject]@{ package = $name; peer = $peerName; range = $range } }
                    continue
                }
                $peerEvaluation = Get-DependencyRangeDiagnosticEvaluation -Version ([string]$targetVersions[$peerName]) -Range $range
                if (-not $peerEvaluation.supported) {
                    $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'peer'; code = 'semver_range_unsupported'; message = "Unsupported peer range for $name."; details = $peerEvaluation }
                }
                elseif (-not $peerEvaluation.matches) {
                    if ($peerName -in $ignoredPeers) {
                        $warnings += [PSCustomObject][ordered]@{ code = 'ignored_peer_dependency'; package = $name; peer = $peerName; range = $range; version = $targetVersions[$peerName]; reason = [string](Get-DependencyObjectValue -Object $exception -Name 'reason') }
                    }
                    else {
                        $conflicts += [PSCustomObject][ordered]@{ package = $name; stage = 'peer'; code = 'peer_dependency_conflict'; message = "Peer $peerName is incompatible with $name."; details = [PSCustomObject]@{ package = $name; peer = $peerName; range = $range; version = $targetVersions[$peerName] } }
                    }
                }
            }
        }

        $queryEvents = @(Get-DependencyDiagnosticQueryEvents -Events @($script:MetadataQueryEvents) | Sort-Object packageName, selector, exitCode, timedOut -Unique)
        $fingerprint = [string](Get-DependencyObjectValue -Object $PendingManifest -Name 'inputFingerprint')
        $diagnostic = [ordered]@{
            schemaVersion    = 1
            diagnosticType   = 'angular-migration-resolve'
            projectRoot      = $root
            sourceMajor      = $sourceMajor
            targetMajor      = $targetMajor
            inputFingerprint = $fingerprint
            selected         = @($selected.Keys | Sort-Object | ForEach-Object { [PSCustomObject][ordered]@{ package = [string]$_; version = [string](Get-DependencyObjectValue -Object $selected[$_] -Name 'version') } })
            node             = [PSCustomObject][ordered]@{
                activeVersion = if ($activeNode) { $activeNode } else { $null }
                requiredRange = if (@($nodeRanges | Select-Object -Unique).Count -gt 0) { (@($nodeRanges | Select-Object -Unique) -join ' && ') } else { '*' }
                compatible    = @($conflicts | Where-Object { $_.stage -eq 'node' -and $_.code -in @('node_version_incompatible', 'node_version_unavailable', 'semver_range_unsupported') }).Count -eq 0
                packages      = @($nodePackages | Sort-Object -Unique)
            }
            conflicts        = @($conflicts | Sort-Object package, stage, code, message -Unique)
            warnings         = @($warnings | Sort-Object code, package, peer, version -Unique)
            proposals        = @($proposals | Sort-Object package, source, code -Unique)
            queryEvents      = $queryEvents
            diagnosticSha256 = $null
        }
        $diagnostic.diagnosticSha256 = Get-ResolvedManifestHash -Manifest ([PSCustomObject]$diagnostic) -ExcludedProperty 'diagnosticSha256'
        return [PSCustomObject]@{
            status      = if (@($diagnostic.conflicts).Count -gt 0) { 'blocked' } else { 'ready' }
            diagnostic  = [PSCustomObject]$diagnostic
            queryEvents = $queryEvents
            error       = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            status      = if ($_.Exception.Data['status'] -eq 'blocked') { 'blocked' } else { 'failed' }
            diagnostic  = $null
            queryEvents = @(Get-DependencyDiagnosticQueryEvents -Events @($script:MetadataQueryEvents))
            error       = [PSCustomObject]@{ code = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'resolver_internal_error' }; message = $_.Exception.Message; details = $_.Exception.Data['details'] }
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
    'Get-ResolvedManifestHash',
    'Test-DependencyVersionRange',
    'Get-MigrationResolveDiagnostics'
)