Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.Project.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.Dependencies.psm1') -DisableNameChecking
. (Join-Path $PSScriptRoot '../hooks/copilot-policy.ps1')

function New-StartManifest {
    param(
        [Parameter(Mandatory = $true)]$Inspection,
        [Parameter(Mandatory = $true)]$Discovery,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$Target
    )

    return [ordered]@{
        schemaVersion        = Get-MigrationSchemaVersion
        manifestType         = 'migration'
        runId                = $RunId
        createdAt            = Get-MigrationUtcNow
        project              = [ordered]@{
            name             = $Inspection.projectName
            root             = $Inspection.projectRoot
            packageManager   = $Inspection.packageManager
            files            = $Inspection.files
            lockfileVersion  = $Inspection.lockfileVersion
            scripts          = $Inspection.scripts
            builders         = $Inspection.builders
            toolchain        = $Inspection.node
            runtimeToolchain = [ordered]@{
                fnm = $Discovery.toolchain.fnm
            }
            git              = [ordered]@{
                branch        = $Inspection.git.branch
                initialCommit = $Inspection.git.head
            }
        }
        sourceMajor          = $Inspection.angular.currentMajor
        targetMajor          = $Target
        discoverySha256      = $Discovery.repoSha256
        inputFingerprint     = $Discovery.inputFingerprint
        runtimePlan          = $Discovery.runtimePlan
        resolutionStatus     = 'pending'
        resolverVersion      = 1
        angular              = [ordered]@{
            declaredCoreSpec    = $Inspection.angular.declaredCoreSpec
            resolvedCoreVersion = $Inspection.angular.resolvedCoreVersion
            current             = $Inspection.angular.packages
            target              = [ordered]@{
                major            = $Target
                resolved         = $false
                resolutionStatus = 'pending'
            }
        }
        dependencies         = $Inspection.dependencies
        policies             = $Inspection.policies
        authorizedOperations = @(
            'resolve-manifest',
            'update-angular',
            'update-dependencies',
            'install',
            'dependency-tree',
            'typecheck',
            'lint',
            'unit-test',
            'build',
            'e2e',
            'skip-check',
            'skip-checks'
        )
        policy               = [ordered]@{
            sequentialMajor       = $true
            exactManifestVersions = $true
            allowForce            = $false
            allowDirty            = $false
            allowLegacyPeerDeps   = $false
        }
        checks               = $Inspection.checks
        warnings             = @()
    }

}

function Get-DiscoveryValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) {
        $value = $Object[$Name]
        if ($value -is [array]) { return , $value }
        return $value
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        if ($property.Value -is [array]) { return , $property.Value }
        return $property.Value
    }
    return $null
}

function Get-MigrationJsonSchemaPropertyNames {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    return @($Value.PSObject.Properties | Select-Object -ExpandProperty Name)
}

function Resolve-MigrationJsonSchemaReference {
    param(
        [Parameter(Mandatory = $true)]$RootSchema,
        [Parameter(Mandatory = $true)][string]$Reference,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Reference -notmatch '^#/') { throw "Schema validation failed at ${Path}: unsupported schema reference." }
    $resolved = $RootSchema
    foreach ($segment in @($Reference.Substring(2).Split('/'))) {
        $name = [uri]::UnescapeDataString($segment).Replace('~1', '/').Replace('~0', '~')
        $property = $resolved.PSObject.Properties[$name]
        if (-not $property) { throw "Schema validation failed at ${Path}: unresolved schema reference $Reference." }
        $resolved = $property.Value
    }
    return $resolved
}

function Assert-MigrationJsonSchemaValue {
    param(
        $Value,
        [Parameter(Mandatory = $true)]$Schema,
        [Parameter(Mandatory = $true)]$RootSchema,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $reference = Get-DiscoveryValue -Object $Schema -Name '$ref'
    if ($reference) {
        $resolvedSchema = Resolve-MigrationJsonSchemaReference -RootSchema $RootSchema -Reference ([string]$reference) -Path $Path
        Assert-MigrationJsonSchemaValue -Value $Value -Schema $resolvedSchema -RootSchema $RootSchema -Path $Path
        return
    }

    foreach ($keyword in @('anyOf', 'oneOf')) {
        $alternatives = Get-DiscoveryValue -Object $Schema -Name $keyword
        if ($null -eq $alternatives) { continue }
        $matches = 0
        foreach ($alternative in @($alternatives)) {
            try {
                Assert-MigrationJsonSchemaValue -Value $Value -Schema $alternative -RootSchema $RootSchema -Path $Path
                $matches++
            }
            catch { }
        }
        $valid = if ($keyword -eq 'oneOf') { $matches -eq 1 } else { $matches -ge 1 }
        if (-not $valid) { throw "Schema validation failed at $Path." }
    }

    $types = Get-DiscoveryValue -Object $Schema -Name 'type'
    if ($null -ne $types) {
        $typeMatches = $false
        foreach ($type in @($types)) {
            $typeMatches = switch ([string]$type) {
                'null' { $null -eq $Value; break }
                'object' { ($null -ne $Value -and $Value -isnot [array] -and ($Value -is [Collections.IDictionary] -or $Value -is [PSCustomObject])); break }
                'array' { $Value -is [array]; break }
                'string' { $Value -is [string]; break }
                'boolean' { $Value -is [bool]; break }
                'integer' { $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or (($Value -is [double] -or $Value -is [decimal]) -and [math]::Floor([double]$Value) -eq [double]$Value); break }
                'number' { $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]; break }
                default { $false; break }
            }
            if ($typeMatches) { break }
        }
        if (-not $typeMatches) { throw "Schema validation failed at $Path." }
    }

    $const = Get-DiscoveryValue -Object $Schema -Name 'const'
    if ($null -ne $const -and ((ConvertTo-Json -InputObject $Value -Depth 20 -Compress) -cne (ConvertTo-Json -InputObject $const -Depth 20 -Compress))) {
        throw "Schema validation failed at $Path."
    }
    $enum = Get-DiscoveryValue -Object $Schema -Name 'enum'
    if ($null -ne $enum) {
        $enumMatch = $false
        foreach ($allowed in @($enum)) {
            if ((ConvertTo-Json -InputObject $Value -Depth 20 -Compress) -ceq (ConvertTo-Json -InputObject $allowed -Depth 20 -Compress)) { $enumMatch = $true; break }
        }
        if (-not $enumMatch) { throw "Schema validation failed at $Path." }
    }
    if ($null -eq $Value) { return }

    if ($Value -is [string]) {
        $minLength = Get-DiscoveryValue -Object $Schema -Name 'minLength'
        if ($null -ne $minLength -and $Value.Length -lt [int]$minLength) { throw "Schema validation failed at $Path." }
        $maxLength = Get-DiscoveryValue -Object $Schema -Name 'maxLength'
        if ($null -ne $maxLength -and $Value.Length -gt [int]$maxLength) { throw "Schema validation failed at $Path." }
        $pattern = Get-DiscoveryValue -Object $Schema -Name 'pattern'
        if ($pattern -and $Value -cnotmatch ([string]$pattern)) { throw "Schema validation failed at $Path." }
        if ((Get-DiscoveryValue -Object $Schema -Name 'format') -eq 'date-time') {
            try { [DateTimeOffset]::Parse($Value) | Out-Null } catch { throw "Schema validation failed at $Path." }
        }
    }
    $minimum = Get-DiscoveryValue -Object $Schema -Name 'minimum'
    if ($null -ne $minimum -and $null -ne $Value -and [double]$Value -lt [double]$minimum) { throw "Schema validation failed at $Path." }

    if ($Value -is [array]) {
        $minItems = Get-DiscoveryValue -Object $Schema -Name 'minItems'
        $maxItems = Get-DiscoveryValue -Object $Schema -Name 'maxItems'
        if ($null -ne $minItems -and $Value.Count -lt [int]$minItems) { throw "Schema validation failed at $Path." }
        if ($null -ne $maxItems -and $Value.Count -gt [int]$maxItems) { throw "Schema validation failed at $Path." }
        $items = Get-DiscoveryValue -Object $Schema -Name 'items'
        if ($items) {
            for ($index = 0; $index -lt $Value.Count; $index++) {
                Assert-MigrationJsonSchemaValue -Value $Value[$index] -Schema $items -RootSchema $RootSchema -Path ($Path + '[' + $index + ']')
            }
        }
        if ((Get-DiscoveryValue -Object $Schema -Name 'uniqueItems') -eq $true) {
            $serialized = @($Value | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 30 -Compress })
            if (@($serialized | Sort-Object -Unique).Count -ne $serialized.Count) { throw "Schema validation failed at $Path." }
        }
    }

    $properties = Get-DiscoveryValue -Object $Schema -Name 'properties'
    $required = Get-DiscoveryValue -Object $Schema -Name 'required'
    $additional = Get-DiscoveryValue -Object $Schema -Name 'additionalProperties'
    if ($null -ne $properties -or $null -ne $required -or $null -ne $additional) {
        if ($null -eq $Value -or $Value -is [array] -or ($Value -isnot [Collections.IDictionary] -and $Value -isnot [PSCustomObject])) { throw "Schema validation failed at $Path." }
        $names = @(Get-MigrationJsonSchemaPropertyNames -Value $Value)
        if ($null -ne $required) {
            foreach ($name in @($required)) {
                if ($name -notin $names) { throw "Schema validation failed at $Path.$name." }
            }
        }
        if ($additional -eq $false) {
            foreach ($name in $names) {
                $property = $properties.PSObject.Properties[[string]$name]
                if (-not $property) { throw "Schema validation failed at $Path.$name." }
            }
        }
        foreach ($name in $names) {
            $property = if ($null -ne $properties) { $properties.PSObject.Properties[[string]$name] } else { $null }
            if ($property) {
                Assert-MigrationJsonSchemaValue -Value (Get-DiscoveryValue -Object $Value -Name ([string]$name)) -Schema $property.Value -RootSchema $RootSchema -Path ($Path + '.' + $name)
            }
            elseif ($additional -is [PSCustomObject]) {
                Assert-MigrationJsonSchemaValue -Value (Get-DiscoveryValue -Object $Value -Name ([string]$name)) -Schema $additional -RootSchema $RootSchema -Path ($Path + '.' + $name)
            }
        }
    }
}

function Assert-MigrationDiscoveryContract {
    param([Parameter(Mandatory = $true)]$Discovery)

    $schemaPath = Join-Path $PSScriptRoot '../../schemas/repo-discovery.schema.json'
    try {
        $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-MigrationJsonSchemaValue -Value $Discovery -Schema $schema -RootSchema $schema -Path '$'
    }
    catch {
        Throw-PipelineError -Code 'discovery_invalid' -Message 'repo.json does not match schemas/repo-discovery.schema.json.' -Status blocked -Details $_.Exception.Message
    }
}

function Test-DiscoveryRangeSupported {
    param([AllowEmptyString()][string]$Range)

    if ([string]::IsNullOrWhiteSpace($Range)) { return $false }
    if ($Range -notmatch '^[0-9A-Za-z.*xX~^<>=|+() \-]+$') { return $false }
    $Range = $Range -replace '(?<!\S)(>=|<=|>|<|\||\^|~)\s+(?=\d)', '$1'
    foreach ($alternative in @($Range -split '\|\|')) {
        $text = $alternative.Trim()
        if ($text -in @('', '*', 'x', 'X')) { continue }
        if ($text -match '^([0-9]+)\.([0-9]+)\.([0-9]+)\s+-\s+([0-9]+)\.([0-9]+)\.([0-9]+)$') { continue }
        foreach ($token in @($text -split '\s+' | Where-Object { $_ })) {
            $value = $token -replace '^(\^|~|>=|<=|>|<)', ''
            $value = $value -replace '^v(?=\d)', ''
            if ($value -notmatch '^\d+(?:\.(?:\d+|x|X|\*))?(?:\.(?:\d+|x|X|\*))?$') { return $false }
        }
    }
    return $true
}

function Get-DiscoveryNormalizedIdentity {
    param([Parameter(Mandatory = $true)]$Identity)

    $nodeVersion = [string](Get-DiscoveryValue -Object $Identity -Name 'nodeVersion')
    $npmVersion = [string](Get-DiscoveryValue -Object $Identity -Name 'npmVersion')
    $status = [string](Get-DiscoveryValue -Object $Identity -Name 'status')
    return [PSCustomObject][ordered]@{
        nodeVersion = $nodeVersion
        npmVersion  = if ($npmVersion -match '^\d+\.\d+\.\d+$') { $npmVersion } else { $null }
        status      = if ($status -eq 'usable') { 'usable' } else { 'unusable' }
        reason      = if ($status -eq 'usable') { $null } else { [string](Get-DiscoveryValue -Object $Identity -Name 'reason') }
    }
}

function Select-DiscoveryRuntimeCandidate {
    param(
        [Parameter(Mandatory = $true)]$Candidates,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$NodeRanges,
        [Parameter(Mandatory = $true)][string]$NpmRange,
        [Parameter(Mandatory = $true)]$Selected
    )

    $ordered = @()
    foreach ($candidate in @($Selected | Where-Object { $_.status -eq 'installed' })) {
        if ($candidate -and $candidate.nodeVersion -notin @($ordered | ForEach-Object { $_.nodeVersion })) { $ordered += $candidate }
    }
    foreach ($candidate in @($Candidates | Where-Object { $_.status -eq 'installed' } | Sort-Object { [version]$_.nodeVersion } -Descending)) {
        if ($candidate.nodeVersion -notin @($ordered | ForEach-Object { $_.nodeVersion })) { $ordered += $candidate }
    }
    foreach ($candidate in @($Selected | Where-Object { $_.status -ne 'installed' })) {
        if ($candidate -and $candidate.nodeVersion -notin @($ordered | ForEach-Object { $_.nodeVersion })) { $ordered += $candidate }
    }
    foreach ($candidate in @($Candidates | Where-Object { $_.status -ne 'installed' } | Sort-Object { [version]$_.nodeVersion } -Descending)) {
        if ($candidate.nodeVersion -notin @($ordered | ForEach-Object { $_.nodeVersion })) { $ordered += $candidate }
    }
    foreach ($candidate in $ordered) {
        if ($candidate.status -eq 'unusable') { continue }
        $nodeMatches = $true
        foreach ($range in @($NodeRanges | Where-Object { $_ -and $_ -ne '*' })) {
            if (-not (Test-MigrationVersionRange -Version $candidate.nodeVersion -Range $range)) { $nodeMatches = $false; break }
        }
        if (-not $nodeMatches) { continue }
        if ($candidate.status -eq 'installed' -and $NpmRange -and $NpmRange -ne '*' -and
            (-not $candidate.npmVersion -or -not (Test-MigrationVersionRange -Version $candidate.npmVersion -Range $NpmRange))) { continue }
        return $candidate
    }
    return $null
}

function New-DiscoveryProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string[]]$Operations,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$NodeRanges,
        [Parameter(Mandatory = $true)][string]$NpmRange,
        [Parameter(Mandatory = $true)]$Constraints,
        [Parameter(Mandatory = $true)]$Candidates,
        [Parameter(Mandatory = $true)]$Selected
    )

    $candidate = Select-DiscoveryRuntimeCandidate -Candidates $Candidates -NodeRanges $NodeRanges -NpmRange $NpmRange -Selected $Selected
    return [PSCustomObject][ordered]@{
        id                  = $Id
        operations          = @($Operations)
        requiredNodeRanges  = @($NodeRanges | Where-Object { $_ } | Select-Object -Unique)
        requiredNpmRange    = $NpmRange
        constraints         = @($Constraints)
        selectedNodeVersion = if ($candidate) { [string]$candidate.nodeVersion } else { $null }
        detectedNpmVersion  = if ($candidate -and $candidate.status -eq 'installed') { [string]$candidate.npmVersion } else { $null }
        status              = if (-not $candidate) { 'blocked' } elseif ($candidate.status -eq 'installed') { 'installed' } else { 'missing' }
    }
}

function Get-DiscoveryRuntimeMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$FnmPath,
        [Parameter(Mandatory = $true)][string]$NodeVersion,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Packages,
        [Parameter(Mandatory = $true)][hashtable]$Selectors
    )

    $records = @()
    foreach ($name in @($Packages | Sort-Object -Unique)) {
        try {
            $metadata = Get-DependencyMetadata -PackageName $name -VersionSelector ([string]$Selectors[$name]) -ProjectRoot $ProjectRoot -FnmPath $FnmPath -NodeVersion $NodeVersion
            $engines = Get-DiscoveryValue -Object $metadata -Name 'engines'
            $nodeRange = [string](Get-DiscoveryValue -Object $engines -Name 'node')
            $version = [string](Get-DiscoveryValue -Object $metadata -Name 'version')
            if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Metadata for $name did not contain an exact stable version." }
            $records += [PSCustomObject][ordered]@{ name = $name; version = $version; nodeRange = if ($nodeRange) { $nodeRange } else { $null } }
        }
        catch {
            $records += [PSCustomObject][ordered]@{ name = $name; version = [string]$Selectors[$name]; nodeRange = $null; error = $_.Exception.Message }
        }
    }
    return @($records)
}

function New-MigrationDiscoveryDocument {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$TargetMajor,
        [Parameter(Mandatory = $true)]$Inspection
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $declarations = Get-ProjectNodeDeclarations -ProjectRoot $root
    $inventory = Get-ProjectFnmInventory -ProjectRoot $root -IncludeRemote
    $normalizedIdentities = @($inventory.identities | ForEach-Object { Get-DiscoveryNormalizedIdentity -Identity $_ })
    $usableInstalled = @($normalizedIdentities | Where-Object { $_.status -eq 'usable' } | ForEach-Object {
            [PSCustomObject][ordered]@{ nodeVersion = $_.nodeVersion; npmVersion = $_.npmVersion; status = 'installed'; source = 'installed' }
        })
    $remoteCandidates = @($inventory.remoteVersions | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ } -Descending -Unique | ForEach-Object {
            [PSCustomObject][ordered]@{ nodeVersion = [string]$_; npmVersion = $null; status = 'missing'; source = 'remote' }
        })
    $candidates = @($usableInstalled) + @($remoteCandidates)
    $conflicts = @()
    $warnings = @()

    if (-not $inventory.available) {
        $conflicts += [PSCustomObject][ordered]@{ code = 'fnm_missing'; profileId = 'toolchain'; message = 'fnm is required for runtime discovery.' }
    }
    elseif (@($inventory.errors).Count -gt 0 -and @($inventory.installedVersions).Count -eq 0) {
        $conflicts += [PSCustomObject][ordered]@{ code = 'fnm_inventory_unavailable'; profileId = 'toolchain'; message = (@($inventory.errors) -join '; ') }
    }
    foreach ($conflict in @($declarations.conflicts)) {
        $conflicts += [PSCustomObject][ordered]@{ code = [string]$conflict.code; profileId = 'declarations'; message = "$($conflict.source)=$($conflict.value) conflicts with $($conflict.conflictsWith)=$($conflict.conflictingValue)." }
    }
    foreach ($range in @($declarations.nodeRanges | ForEach-Object { $_.value }) + @($declarations.npmRanges | ForEach-Object { $_.value })) {
        if ($range -and -not (Test-DiscoveryRangeSupported -Range ([string]$range))) {
            $conflicts += [PSCustomObject][ordered]@{ code = 'unsupported_node_range'; profileId = 'declarations'; message = "The declared runtime range is not supported by the shared evaluator: $range" }
        }
    }

    $lockfileVersion = if ($null -ne $Inspection.lockfileVersion) { [int]$Inspection.lockfileVersion } else { $null }
    $minimumNpmRange = if ($lockfileVersion) { Get-ProjectLockfileNpmMinimumRange -LockfileVersion $lockfileVersion } else { '*' }
    $npmRanges = @($minimumNpmRange) + @($declarations.npmRanges | ForEach-Object { $_.value } | Where-Object { $_ })
    $requiredNpmRange = (@($npmRanges | Where-Object { $_ -and $_ -ne '*' }) -join ' ')
    if ([string]::IsNullOrWhiteSpace($requiredNpmRange)) { $requiredNpmRange = '*' }
    $localNodeRanges = @($declarations.nodeRanges | ForEach-Object { $_.value } | Where-Object { $_ })
    $inputFingerprint = Get-ProjectInputFingerprint -ProjectRoot $root -Inspection $Inspection
    $exactDeclaredNodeVersions = @($declarations.nodeRanges | Where-Object { $_.value -match '^v?\d+\.\d+\.\d+$' } | ForEach-Object { ([string]$_.value) -replace '^v', '' })
    foreach ($identity in @($normalizedIdentities | Where-Object { $_.status -eq 'usable' -and $_.nodeVersion -in $exactDeclaredNodeVersions })) {
        if ($minimumNpmRange -ne '*' -and (-not $identity.npmVersion -or -not (Test-MigrationVersionRange -Version ([string]$identity.npmVersion) -Range $minimumNpmRange))) {
            $conflicts += [PSCustomObject][ordered]@{ code = 'lockfile_npm_incompatible'; profileId = 'metadata'; message = "Node $($identity.nodeVersion) exposes npm $($identity.npmVersion), which does not satisfy the lockfile requirement $minimumNpmRange." }
        }
    }

    $metadataCandidate = Select-DiscoveryRuntimeCandidate -Candidates $usableInstalled -NodeRanges @() -NpmRange $minimumNpmRange -Selected @()
    $metadataInstallCandidate = Select-DiscoveryRuntimeCandidate -Candidates $candidates -NodeRanges @() -NpmRange $minimumNpmRange -Selected @()
    $sourceRuntime = @()
    $targetRuntime = @()
    $lockedTooling = @()
    try { $lockedTooling = @(Get-ProjectLockedTooling -Lock (Get-ProjectLockfile -ProjectRoot $root -DisallowAmbientNode) -Package (Get-ProjectPackage -ProjectRoot $root)) } catch { }
    if ($metadataCandidate -and $inventory.executable) {
        $sourcePackages = @($lockedTooling | Where-Object { $_.name -eq '@angular/cli' -or $_.name -eq '@angular/compiler-cli' -or $_.name -like '@angular-devkit/*' -or $_.name -like '@ngtools/*' } | Select-Object -ExpandProperty name)
        $sourceSelectors = @{}
        foreach ($tool in @($lockedTooling | Where-Object { $_.name -in $sourcePackages })) {
            if ($tool.lockedVersion -match '^\d+\.\d+\.\d+$') { $sourceSelectors[$tool.name] = [string]$tool.lockedVersion }
        }
        $sourceRuntime = @(Get-DiscoveryRuntimeMetadata -ProjectRoot $root -FnmPath $inventory.executable -NodeVersion $metadataCandidate.nodeVersion -Packages @($sourceSelectors.Keys) -Selectors $sourceSelectors)
        $targetNames = @('@angular/cli', '@angular/compiler-cli') + @($sourcePackages | Where-Object { $_ -like '@angular-devkit/*' -or $_ -like '@ngtools/*' })
        $targetSelectors = @{}
        foreach ($name in @($targetNames | Sort-Object -Unique)) {
            $targetSelectors[$name] = [string](Get-MigrationAngularToolingVersionPolicy -AngularMajor $TargetMajor -PackageName $name).selector
        }
        $targetRuntime = @(Get-DiscoveryRuntimeMetadata -ProjectRoot $root -FnmPath $inventory.executable -NodeVersion $metadataCandidate.nodeVersion -Packages $targetNames -Selectors $targetSelectors)
        foreach ($record in @($sourceRuntime + $targetRuntime)) {
            if ($record.PSObject.Properties['error']) {
                $conflicts += [PSCustomObject][ordered]@{ code = 'runtime_metadata_unavailable'; profileId = 'metadata'; message = [string]$record.error }
            }
            elseif ($record.nodeRange -and -not (Test-DiscoveryRangeSupported -Range $record.nodeRange)) {
                $conflicts += [PSCustomObject][ordered]@{ code = 'unsupported_node_range'; profileId = 'metadata'; message = "$($record.name) published an unsupported Node range: $($record.nodeRange)" }
            }
        }
    }
    elseif ($inventory.available -and $metadataInstallCandidate) {
        $warnings += [PSCustomObject][ordered]@{ code = 'runtime_metadata_install_required'; message = 'An installed fnm runtime satisfying the metadata npm requirement is unavailable; the selected exact runtime must be installed before rediscovery.' }
    }
    elseif ($inventory.available) {
        $conflicts += [PSCustomObject][ordered]@{ code = 'runtime_metadata_unavailable'; profileId = 'metadata'; message = 'No installed fnm runtime can execute npm metadata queries with the lockfile npm requirement.' }
    }

    $sourceRanges = @($sourceRuntime | Where-Object { $_.nodeRange } | Select-Object -ExpandProperty nodeRange)
    $targetRanges = @($targetRuntime | Where-Object { $_.nodeRange } | Select-Object -ExpandProperty nodeRange)
    $webpack = @($lockedTooling | Where-Object { $_.name -eq 'webpack' } | Select-Object -First 1)
    $webpackOpenSslRisk = $false
    if ($webpack -and $webpack.lockedVersion -match '^(\d+)\.\d+\.\d+$' -and [int]$Matches[1] -le 4) { $webpackOpenSslRisk = $true }
    $scriptValues = if ($Inspection.scripts -is [Collections.IDictionary]) { @($Inspection.scripts.Values) } else { @($Inspection.scripts.PSObject.Properties | ForEach-Object { $_.Value }) }
    $opensslMitigated = @($scriptValues | Where-Object { [string]$_ -match '--openssl-legacy-provider' }).Count -gt 0

    $runtimeProfiles = @()
    $profileDefinitions = @(
        [PSCustomObject]@{ id = 'metadata'; operations = @('npm view'); ranges = @(); npm = $requiredNpmRange; constraints = @() },
        [PSCustomObject]@{ id = 'baseline-install'; operations = @('npm ci'); ranges = @($localNodeRanges + $sourceRanges); npm = $requiredNpmRange; constraints = @() },
        [PSCustomObject]@{ id = 'update-angular'; operations = @('ng update'); ranges = @($targetRanges); npm = $requiredNpmRange; constraints = @() },
        [PSCustomObject]@{ id = 'update-dependencies'; operations = @('renderer', 'npm install --package-lock-only'); ranges = @($targetRanges); npm = $requiredNpmRange; constraints = @() },
        [PSCustomObject]@{ id = 'install'; operations = @('npm ci', 'npm ls --all'); ranges = @($targetRanges); npm = $requiredNpmRange; constraints = @() }
    )
    foreach ($check in @($Inspection.checks | Where-Object { $_.status -eq 'configured' })) {
        $ranges = if ($check.id -in @('install', 'dependency-tree')) { @($localNodeRanges + $sourceRanges) } else { @($targetRanges) }
        $runtimeProfiles += [PSCustomObject]@{ id = 'baseline:' + $check.id; operations = @($check.id); ranges = @($ranges); npm = if ($check.id -in @('install', 'dependency-tree')) { $requiredNpmRange } else { $requiredNpmRange }; constraints = @() }
        $runtimeProfiles += [PSCustomObject]@{ id = 'validate:' + $check.id; operations = @($check.id); ranges = @($targetRanges); npm = $requiredNpmRange; constraints = @() }
    }
    $profileDefinitions += $runtimeProfiles

    $selected = @()
    foreach ($definition in $profileDefinitions) {
        $constraints = @()
        if ($lockfileVersion) { $constraints += [PSCustomObject][ordered]@{ source = 'package-lock.json#lockfileVersion'; value = [string]$lockfileVersion; reason = "npm must read lockfileVersion $lockfileVersion" } }
        foreach ($range in @($definition.ranges | Where-Object { $_ })) { $constraints += [PSCustomObject][ordered]@{ source = 'runtime metadata'; value = [string]$range; reason = 'The selected Node runtime must satisfy published or declared engines.' } }
        if ($webpackOpenSslRisk) {
            $constraints += [PSCustomObject][ordered]@{ source = 'package-lock.json#webpack'; value = [string]$webpack.lockedVersion; reason = 'Webpack 4 is incompatible with OpenSSL 3 by default.' }
            if (-not $opensslMitigated -and $definition.id -in @('baseline:build', 'validate:build')) { $definition.ranges = @($definition.ranges + '<17') }
        }
        $profile = New-DiscoveryProfile -Id $definition.id -Operations $definition.operations -NodeRanges @($definition.ranges) -NpmRange ([string]$definition.npm) -Constraints $constraints -Candidates $candidates -Selected $selected
        $runtimeProfiles += @() # Keep the profile object materialized before selecting its next reusable candidate.
        if ($profile.selectedNodeVersion) {
            $chosen = @($candidates | Where-Object nodeVersion -ceq $profile.selectedNodeVersion | Select-Object -First 1)
            if ($chosen.Count -eq 1) { $selected += $chosen[0] }
        }
        $runtimeProfiles = @($runtimeProfiles | Where-Object { $_.id -ne $profile.id }) + @($profile)
    }
    $runtimeProfiles = @($runtimeProfiles | Sort-Object id)
    foreach ($profile in $runtimeProfiles | Where-Object { $_.status -eq 'blocked' }) {
        $conflicts += [PSCustomObject][ordered]@{ code = 'runtime_version_unavailable'; profileId = $profile.id; message = "No exact fnm runtime satisfies the constraints for profile $($profile.id)." }
    }
    $missingVersions = @($runtimeProfiles | Where-Object { $_.status -eq 'missing' } | Select-Object -ExpandProperty selectedNodeVersion -Unique)
    $proposalVersions = @()
    foreach ($version in @($missingVersions | Sort-Object { [version]$_ })) {
        $profiles = @($runtimeProfiles | Where-Object selectedNodeVersion -ceq $version | Select-Object -ExpandProperty id)
        $reasons = @($runtimeProfiles | Where-Object selectedNodeVersion -ceq $version | ForEach-Object { $_.constraints | Select-Object -ExpandProperty reason } | Sort-Object -Unique)
        $proposalVersions += [PSCustomObject][ordered]@{ version = $version; profiles = @($profiles); reasons = @($reasons) }
    }
    $proposal = $null
    if ($proposalVersions.Count -gt 0) {
        $proposal = [ordered]@{
            schemaVersion    = 1
            projectRoot      = $root
            targetMajor      = $TargetMajor
            inputFingerprint = $inputFingerprint
            versions         = @($proposalVersions)
            proposalHash     = $null
        }
        $proposal.proposalHash = Get-PipelineObjectHash -Value ([PSCustomObject]$proposal) -ExcludedProperty 'proposalHash'
    }
    $riskRecords = @()
    if ($webpackOpenSslRisk) {
        $buildProfiles = @($runtimeProfiles | Where-Object id -in @('baseline:build', 'validate:build'))
        $buildVersions = @($buildProfiles | Where-Object selectedNodeVersion | Select-Object -ExpandProperty selectedNodeVersion)
        $mitigated = $opensslMitigated -or (@($buildVersions | Where-Object { $_ -match '^\d+\.\d+\.\d+$' -and [int]($_ -split '\.')[0] -lt 17 }).Count -eq $buildVersions.Count -and $buildVersions.Count -gt 0)
        $riskRecords += [PSCustomObject][ordered]@{ code = 'webpack_openssl3_incompatible'; severity = if ($mitigated) { 'warning' } else { 'blocking' }; mitigated = $mitigated; reason = if ($opensslMitigated) { 'Webpack 4 has an explicit --openssl-legacy-provider mitigation in an npm script.' } else { 'Webpack major 4 requires Node major below 17 unless OpenSSL legacy provider is enabled.' } }
        if (-not $mitigated) { $conflicts += [PSCustomObject][ordered]@{ code = 'webpack_openssl3_incompatible'; profileId = 'validate:build'; message = 'Webpack 4 has no compatible Node runtime below major 17 and no explicit OpenSSL legacy-provider mitigation.' } }
    }
    foreach ($risk in @($riskRecords | Where-Object { -not $_.mitigated })) { $warnings += [PSCustomObject][ordered]@{ code = $risk.code; message = $risk.reason } }

    $files = @(
        [PSCustomObject][ordered]@{ path = 'package.json'; present = [bool]$Inspection.files.packageJson; kind = 'required' },
        [PSCustomObject][ordered]@{ path = 'package-lock.json'; present = [bool]$Inspection.files.packageLock; kind = 'lockfile' },
        [PSCustomObject][ordered]@{ path = 'angular.json'; present = [bool]$Inspection.files.angularJson; kind = 'required' }
    )
    foreach ($relative in @('.nvmrc', '.node-version', '.tool-versions')) {
        $files += [PSCustomObject][ordered]@{ path = $relative; present = Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf; kind = 'declaration' }
    }
    foreach ($relative in @($Inspection.files.configurations)) {
        $files += [PSCustomObject][ordered]@{
            path    = [string]$relative
            present = Test-Path -LiteralPath (Join-Path $root ([string]$relative -replace '/', [IO.Path]::DirectorySeparatorChar)) -PathType Leaf
            kind    = 'configuration'
        }
    }
    $repositoryDependencies = @($Inspection.dependencies | ForEach-Object {
            [PSCustomObject][ordered]@{
                name          = $_.name
                section       = $_.section
                declaredSpec  = $_.spec
                lockedVersion = if ($Inspection.lockfileVersion) { [string]((Get-ProjectLockfile -ProjectRoot $root -DisallowAmbientNode).versions[$_.name]) } else { $null }
                kind          = $_.role
            }
        })
    $repositoryDependencies = @($repositoryDependencies | ForEach-Object {
            if ($_.kind -notin @('runtime', 'dev', 'optional', 'peer')) { $_.kind = 'dev' }
            $_
        })
    $repository = [ordered]@{
        angular          = [ordered]@{
            declaredCoreSpec    = $Inspection.angular.declaredCoreSpec
            resolvedCoreVersion = $Inspection.angular.resolvedCoreVersion
            projects            = @($Inspection.angular.projects)
        }
        packageManager   = 'npm'
        lockfileVersion  = $lockfileVersion
        scripts          = $Inspection.scripts
        checks           = @($Inspection.checks | ForEach-Object {
                [PSCustomObject][ordered]@{ id = $_.id; status = $_.status; blocking = $true; canSkip = [bool]$_.canSkip; executable = $_.executable; arguments = @($_.arguments); displayCommand = $_.displayCommand; cwd = $_.cwd; timeoutSeconds = [int]$_.timeoutSeconds; reason = $_.reason; runtimeProfile = $_.runtimeProfile }
            })
        files            = @($files)
        dependencies     = @($repositoryDependencies)
        nodeDeclarations = @($declarations.declarations)
        angularRuntime   = [ordered]@{
            source = @($sourceRuntime | Where-Object { $_.version -match '^\d+\.\d+\.\d+$' -and -not $_.PSObject.Properties['error'] } | ForEach-Object { [PSCustomObject][ordered]@{ name = $_.name; version = $_.version; nodeRange = $_.nodeRange } })
            target = @($targetRuntime | Where-Object { $_.version -match '^\d+\.\d+\.\d+$' -and -not $_.PSObject.Properties['error'] } | ForEach-Object { [PSCustomObject][ordered]@{ name = $_.name; version = $_.version; nodeRange = $_.nodeRange } })
        }
        npmRequirements  = [ordered]@{ minimumRange = $minimumNpmRange; source = if ($lockfileVersion) { 'package-lock.json#lockfileVersion' } else { 'policy' } }
        tooling          = @($lockedTooling | ForEach-Object { [PSCustomObject][ordered]@{ name = $_.name; version = $_.lockedVersion } })
        risks            = @($riskRecords)
    }
    $toolchain = [ordered]@{
        fnm                   = [ordered]@{ available = [bool]$inventory.available; executable = $inventory.executable; version = $inventory.version }
        installedNodeVersions = @($inventory.installedVersions | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ } -Unique)
        identities            = @($normalizedIdentities)
    }
    $document = [ordered]@{
        schemaVersion    = 1
        discoveryType    = 'angular-migration-repository'
        projectRoot      = $root
        projectName      = $Inspection.projectName
        sourceMajor      = [int]$Inspection.angular.currentMajor
        targetMajor      = $TargetMajor
        status           = if ($conflicts.Count -gt 0) { 'blocked' } elseif ($missingVersions.Count -gt 0) { 'runtime-install-required' } else { 'ready' }
        discoveredAt     = Get-MigrationUtcNow
        inputFingerprint = $inputFingerprint
        toolchain        = $toolchain
        repository       = $repository
        runtimePlan      = [ordered]@{ profiles = @($runtimeProfiles); conflicts = @($conflicts | Sort-Object code, profileId, message -Unique); missingVersions = @($missingVersions) }
        installProposal  = $proposal
        warnings         = @($warnings)
        repoSha256       = $null
    }
    $document.repoSha256 = Get-PipelineObjectHash -Value ([PSCustomObject]$document) -ExcludedProperty 'repoSha256'
    Assert-MigrationDiscoveryContract -Discovery ([PSCustomObject]$document)
    return [PSCustomObject]$document
}

function Read-MigrationDiscovery {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $path = Get-MigrationDiscoveryPath -ProjectRoot $root
    $discovery = Read-MigrationJson -Path $path -Required
    try {
        Assert-MigrationDiscoveryContract -Discovery $discovery
    }
    catch {
        Throw-PipelineError -Code 'discovery_invalid' -Message 'The repository discovery artifact is invalid.' -Status blocked -Details $_.Exception.Message
    }
    if ($discovery.repoSha256 -cne (Get-PipelineObjectHash -Value $discovery -ExcludedProperty 'repoSha256')) {
        Throw-PipelineError -Code 'discovery_integrity_failed' -Message 'The repository discovery artifact has been altered.' -Status blocked
    }
    return $discovery
}

function Assert-MigrationStartDiscovery {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$TargetMajor
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $inspection = Get-ProjectInspection -ProjectRoot $root -SkipNodeToolchain
    if (-not $inspection.ready) {
        Throw-MigrationError -Code 'project_not_ready' -Message 'Project inspection found blocking preconditions.' -Status blocked -Details $inspection.blockers
    }
    $discovery = Read-MigrationDiscovery -ProjectRoot $root
    if ($discovery.status -cne 'ready') {
        Throw-MigrationError -Code 'discovery_not_ready' -Message 'Discovery must be ready before start.' -Status blocked -Details $discovery.runtimePlan.conflicts
    }
    if ([string]$discovery.projectRoot -cne $root -or [int]$discovery.targetMajor -ne $TargetMajor -or
        [int]$discovery.sourceMajor -ne [int]$inspection.angular.currentMajor) {
        Throw-MigrationError -Code 'discovery_context_mismatch' -Message 'Discovery does not describe the requested project or Angular transition.' -Status blocked
    }
    $fingerprint = Get-ProjectInputFingerprint -ProjectRoot $root -Inspection $inspection
    if ([string]$discovery.inputFingerprint -cne $fingerprint) {
        Throw-MigrationError -Code 'discovery_stale' -Message 'Repository inputs changed after discovery; run discover again.' -Status blocked
    }
    if (-not $discovery.toolchain.fnm.available -or [string]::IsNullOrWhiteSpace([string]$discovery.toolchain.fnm.executable)) {
        Throw-MigrationError -Code 'fnm_missing' -Message 'fnm is required by the discovered runtime plan.' -Status blocked
    }
    return [PSCustomObject]@{ inspection = $inspection; discovery = $discovery }
}

function Invoke-MigrationDiscover {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$TargetMajor
    )

    if ($TargetMajor -lt 1) { Throw-MigrationError -Code 'target_major_required' -Message '-TargetMajor must be a positive Angular major.' -Status blocked }
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $inspection = Get-ProjectInspection -ProjectRoot $root -SkipNodeToolchain
    if (-not $inspection.ready) {
        Throw-MigrationError -Code 'project_not_ready' -Message 'Project inspection found blocking preconditions.' -Status blocked -Details $inspection.blockers
    }
    $expectedTarget = [int]$inspection.angular.currentMajor + 1
    if ($TargetMajor -ne $expectedTarget) {
        Throw-MigrationError -Code 'non_sequential_target' -Message "Only the next Angular major is allowed. Expected $expectedTarget, received $TargetMajor." -Status blocked
    }
    $document = New-MigrationDiscoveryDocument -ProjectRoot $root -TargetMajor $TargetMajor -Inspection $inspection
    Write-MigrationJsonAtomic -Value $document -Path (Get-MigrationDiscoveryPath -ProjectRoot $root)
    if ($document.status -eq 'ready') {
        return [PSCustomObject]@{ ok = $true; status = 'ready'; data = $document; error = $null }
    }
    if ($document.status -eq 'runtime-install-required') {
        return [PSCustomObject]@{ ok = $false; status = 'blocked'; data = $document; error = [PSCustomObject]@{ code = 'runtime_install_confirmation_required'; message = 'Exact Node runtimes are missing and require explicit approval.'; details = $document.installProposal } }
    }
    return [PSCustomObject]@{ ok = $false; status = 'blocked'; data = $document; error = [PSCustomObject]@{ code = 'discovery_blocked'; message = 'Discovery found an incompatible or unsupported runtime plan.'; details = $document.runtimePlan.conflicts } }
}

function Add-MigrationRuntimeInstallEvent {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$Data
    )

    $path = Join-Path (Get-MigrationDirectory -ProjectRoot $ProjectRoot) 'runtime-install.jsonl'
    $line = ([ordered]@{ schemaVersion = 1; timestamp = Get-MigrationUtcNow; data = $Data } | ConvertTo-Json -Depth 30 -Compress) + [Environment]::NewLine
    $stream = $null
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Write-MigrationRuntimeInstallLog {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][ValidateSet('stdout', 'stderr')][string]$Stream,
        [AllowEmptyString()][string]$Text
    )

    $relative = '.angular-migration/runtime-install/' + $Version + '.' + $Stream + '.log'
    $path = Join-Path (Get-MigrationDirectory -ProjectRoot $ProjectRoot) ('runtime-install/' + $Version + '.' + $Stream + '.log')
    Write-MigrationTextAtomic -Text (Protect-RepairText -Text ([string]$Text) -Root $ProjectRoot) -Path $path
    return $relative
}

function Invoke-ApproveMigrationRuntimeInstall {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$TargetMajor,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProposalHash,
        [switch]$Confirmed
    )

    if (-not $Confirmed) { Throw-MigrationError -Code 'confirmation_required' -Message 'Runtime installation requires explicit confirmation.' -Status blocked }
    if ($ProposalHash -notmatch '^[0-9a-f]{64}$') { Throw-MigrationError -Code 'proposal_hash_required' -Message 'A lowercase 64-hex runtime proposal hash is required.' -Status blocked }
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $discovery = Read-MigrationDiscovery -ProjectRoot $root
    if ($discovery.status -cne 'runtime-install-required' -or [int]$discovery.targetMajor -ne $TargetMajor -or $null -eq $discovery.installProposal) {
        Throw-MigrationError -Code 'runtime_install_not_required' -Message 'The current discovery has no approved runtime installation proposal.' -Status blocked
    }
    if ($discovery.installProposal.proposalHash -cne $ProposalHash) {
        Throw-MigrationError -Code 'runtime_proposal_changed' -Message 'The runtime installation proposal changed; run discover again.' -Status blocked -Details $discovery.installProposal
    }
    $inspection = Get-ProjectInspection -ProjectRoot $root -SkipNodeToolchain
    $fingerprint = Get-ProjectInputFingerprint -ProjectRoot $root -Inspection $inspection
    if ($fingerprint -cne $discovery.inputFingerprint) {
        Throw-MigrationError -Code 'discovery_stale' -Message 'Repository inputs changed after discovery; run discover again.' -Status blocked
    }
    if (Read-ActiveRunLock -ProjectRoot $root) {
        Throw-MigrationError -Code 'active_run' -Message 'Runtime installation cannot run while a migration run is active.' -Status blocked
    }
    $recalculated = New-MigrationDiscoveryDocument -ProjectRoot $root -TargetMajor $TargetMajor -Inspection $inspection
    if ($recalculated.installProposal.proposalHash -cne $ProposalHash) {
        Throw-MigrationError -Code 'runtime_proposal_changed' -Message 'The recalculated runtime proposal differs from the approved proposal.' -Status blocked -Details $recalculated.installProposal
    }
    $lockCreated = $false
    try {
        New-MigrationDiscoveryLock -ProjectRoot $root
        $lockCreated = $true
        $fnm = [string]$discovery.toolchain.fnm.executable
        if ([string]::IsNullOrWhiteSpace($fnm)) { Throw-MigrationError -Code 'fnm_missing' -Message 'fnm is required for runtime installation.' -Status blocked }
        foreach ($item in @($discovery.installProposal.versions)) {
            $version = Assert-MigrationExactNodeVersion -Version ([string]$item.version)
            $install = Invoke-MigrationProcess -FilePath $fnm -Arguments @('install', $version) -WorkingDirectory $root -TimeoutSeconds 1800
            $stdoutLog = Write-MigrationRuntimeInstallLog -ProjectRoot $root -Version $version -Stream 'stdout' -Text ([string]$install.stdout)
            $stderrLog = Write-MigrationRuntimeInstallLog -ProjectRoot $root -Version $version -Stream 'stderr' -Text ([string]$install.stderr)
            Add-MigrationRuntimeInstallEvent -ProjectRoot $root -Data ([PSCustomObject]@{
                    proposalHash = $ProposalHash
                    version      = $version
                    status       = if ($install.exitCode -eq 0 -and -not $install.timedOut) { 'installed' } else { 'failed' }
                    exitCode     = $install.exitCode
                    timedOut     = [bool]$install.timedOut
                    stdoutLog    = $stdoutLog
                    stderrLog    = $stderrLog
                })
            if ($install.timedOut -or $install.exitCode -ne 0) {
                Throw-MigrationError -Code 'runtime_install_failed' -Message "fnm could not install Node $version." -Status blocked -Details ([PSCustomObject]@{ version = $version; exitCode = $install.exitCode; timedOut = $install.timedOut })
            }
            $identity = Get-MigrationNodeIdentity -FnmPath $fnm -NodeVersion $version -WorkingDirectory $root -TimeoutSeconds 60
            if ($identity.status -ne 'usable') {
                Throw-MigrationError -Code 'runtime_identity_mismatch' -Message "Installed Node $version did not expose a matching node/npm identity." -Status blocked -Details $identity
            }
        }
        return Invoke-MigrationDiscover -ProjectRoot $root -TargetMajor $TargetMajor
    }
    finally {
        if ($lockCreated) { Remove-MigrationDiscoveryLock -ProjectRoot $root }
    }
}

function Invoke-InspectMigration {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $inspection = Get-ProjectInspection -ProjectRoot $ProjectRoot
    return [PSCustomObject]@{
        ok     = [bool]$inspection.ready
        status = $inspection.status
        data   = $inspection
        error  = if ($inspection.ready) { $null } else {
            [PSCustomObject]@{
                code    = 'project_not_ready'
                message = 'Project inspection found blocking preconditions.'
                details = $inspection.blockers
            }
        }
    }
}

function Invoke-MigrationPreflight {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Invoke-InspectMigration -ProjectRoot $ProjectRoot
}

function Invoke-MigrationResolveDiagnostics {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [int]$TargetMajor = 0
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $inspection = Get-ProjectInspection -ProjectRoot $root -SkipNodeToolchain
    if (-not $inspection.ready) {
        return [PSCustomObject]@{
            ok = $false; status = 'blocked'; data = $null
            error = [PSCustomObject]@{ code = 'project_not_ready'; message = 'Project inspection found blocking preconditions.'; details = $inspection.blockers }
        }
    }
    $expectedTarget = [int]$inspection.angular.currentMajor + 1
    if ($TargetMajor -eq 0) { $TargetMajor = $expectedTarget }
    if ($TargetMajor -ne $expectedTarget) {
        return [PSCustomObject]@{
            ok = $false; status = 'blocked'; data = $null
            error = [PSCustomObject]@{ code = 'non_sequential_target'; message = "Only the next Angular major is allowed. Expected $expectedTarget, received $TargetMajor."; details = [PSCustomObject]@{ sourceMajor = $inspection.angular.currentMajor; expectedTargetMajor = $expectedTarget; requestedTargetMajor = $TargetMajor } }
        }
    }

    $discovery = New-MigrationDiscoveryDocument -ProjectRoot $root -TargetMajor $TargetMajor -Inspection $inspection
    if ($discovery.status -ne 'ready') {
        return [PSCustomObject]@{
            ok = $false; status = 'blocked'; data = [PSCustomObject]@{ discovery = $discovery }
            error = [PSCustomObject]@{ code = 'discovery_blocked'; message = 'Runtime discovery did not produce a ready diagnostic context.'; details = $discovery.runtimePlan.conflicts }
        }
    }
    $metadataProfile = @($discovery.runtimePlan.profiles | Where-Object id -ceq 'metadata' | Select-Object -First 1)
    if ($metadataProfile.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$metadataProfile[0].selectedNodeVersion) -or
        [string]::IsNullOrWhiteSpace([string]$discovery.toolchain.fnm.executable)) {
        return [PSCustomObject]@{
            ok = $false; status = 'blocked'; data = [PSCustomObject]@{ discovery = $discovery }
            error = [PSCustomObject]@{ code = 'metadata_runtime_unavailable'; message = 'A selected Node runtime is required for resolver diagnostics.'; details = $discovery.runtimePlan }
        }
    }

    $runId = New-MigrationRunId -SourceMajor $inspection.angular.currentMajor -TargetMajor $TargetMajor
    $pending = New-StartManifest -Inspection $inspection -Discovery $discovery -RunId $runId -Target $TargetMajor
    $diagnostic = Get-MigrationResolveDiagnostics -PendingManifest ([PSCustomObject]$pending) -ProjectRoot $root -FnmPath ([string]$discovery.toolchain.fnm.executable) -NodeVersion ([string]$metadataProfile[0].selectedNodeVersion)
    if ($diagnostic.diagnostic) {
        $diagnostic.diagnostic | Add-Member -NotePropertyName discoverySha256 -NotePropertyValue $discovery.repoSha256
        $diagnostic.diagnostic.inputFingerprint = $discovery.inputFingerprint
        $diagnostic.diagnostic.diagnosticSha256 = Get-PipelineObjectHash -Value $diagnostic.diagnostic -ExcludedProperty 'diagnosticSha256'
    }
    return [PSCustomObject]@{
        ok     = $diagnostic.status -eq 'ready'
        status = $diagnostic.status
        data   = [PSCustomObject]@{
            diagnostic       = $diagnostic.diagnostic
            discoverySha256  = $discovery.repoSha256
            inputFingerprint = $discovery.inputFingerprint
            queryEvents      = @($diagnostic.queryEvents)
        }
        error  = $diagnostic.error
    }
}

function Invoke-StartMigration {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$TargetMajor
    )

    if ($TargetMajor -lt 1) {
        Throw-MigrationError -Code 'target_major_required' -Message '-TargetMajor must be a positive Angular major.' -Status blocked
    }

    $startContext = Assert-MigrationStartDiscovery -ProjectRoot $ProjectRoot -TargetMajor $TargetMajor
    $inspection = $startContext.inspection
    $discovery = $startContext.discovery
    $expectedTarget = [int]$inspection.angular.currentMajor + 1
    if ($TargetMajor -ne $expectedTarget) {
        Throw-MigrationError -Code 'non_sequential_target' -Message "Only the next Angular major is allowed. Expected $expectedTarget, received $TargetMajor." -Status blocked -Details ([PSCustomObject]@{
                sourceMajor          = $inspection.angular.currentMajor
                expectedTargetMajor  = $expectedTarget
                requestedTargetMajor = $TargetMajor
            })
    }

    $runId = New-MigrationRunId -SourceMajor $inspection.angular.currentMajor -TargetMajor $TargetMajor
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $runId
    $createdRunDirectory = $false
    $lockCreated = $false
    try {
        New-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $runId
        $lockCreated = $true

        New-Item -ItemType Directory -Path $paths.logs | Out-Null
        $createdRunDirectory = $true

        $manifest = New-StartManifest -Inspection $inspection -Discovery $discovery -RunId $runId -Target $TargetMajor
        $state = New-MigrationRunState -RunId $runId -ProjectRoot $ProjectRoot -SourceMajor $inspection.angular.currentMajor -TargetMajor $TargetMajor -InitialCommit $inspection.git.head -InitialBranch $inspection.git.branch -DiscoverySha256 $discovery.repoSha256 -InputFingerprint $discovery.inputFingerprint -RuntimePlan $discovery.runtimePlan -RuntimeFnmPath $discovery.toolchain.fnm.executable
        $runtime = Resolve-RepairPath $ProjectRoot '.angular-migration/runtime/copilot-policy.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $runtime) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../hooks/copilot-policy.ps1') -Destination $runtime -Force
        $state.runtimeSha256 = (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $runId -State $state
        Write-MigrationRunManifest -ProjectRoot $ProjectRoot -RunId $runId -Manifest $manifest
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $runId -Type 'run-started' -Stage 'baseline' -Data ([PSCustomObject]@{
                sourceMajor   = $inspection.angular.currentMajor
                targetMajor   = $TargetMajor
                initialCommit = $inspection.git.head
            })

        return [PSCustomObject]@{
            ok     = $true
            status = 'running'
            data   = [PSCustomObject]@{
                runId       = $runId
                sourceMajor = $inspection.angular.currentMajor
                targetMajor = $TargetMajor
                stage       = 'baseline'
                manifest    = '.angular-migration/runs/' + $runId + '/manifest.json'
                state       = '.angular-migration/runs/' + $runId + '/state.json'
            }
            error  = $null
        }
    }
    catch {
        if ($createdRunDirectory -and (Test-Path -LiteralPath $paths.root -PathType Container)) {
            Remove-Item -LiteralPath $paths.root -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($lockCreated) {
            Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $runId
        }
        throw
    }
}

function Invoke-MigrationBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $results = @()
    $checks = @()
    try {
        $root = Resolve-MigrationRoot -Path $ProjectRoot
        Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
        $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        $manifest = Read-MigrationJson -Path $paths.manifest -Required
        if ($manifest.schemaVersion -ne (Get-MigrationSchemaVersion) -or $manifest.runId -cne $RunId -or
            $manifest.manifestType -cne 'migration' -or $manifest.project.root -cne (Resolve-MigrationRoot -Path $ProjectRoot) -or $state.projectRoot -cne $root -or
            $manifest.sourceMajor -ne $state.sourceMajor -or $manifest.targetMajor -ne $state.targetMajor -or
            $manifest.project.git.initialCommit -cne $state.initialCommit) {
            Throw-MigrationError -Code 'invalid_run_manifest' -Message 'Manifest and state must describe the same run and project.' -Status failed
        }
        if ($state.status -cne 'running' -or $state.stage -cne 'baseline') {
            Throw-MigrationError -Code 'invalid_baseline_stage' -Message 'Baseline requires running/baseline.' -Status blocked
        }
        $git = Get-ProjectGit -ProjectRoot $root
        if ($git.errorCode) { Throw-MigrationError -Code $git.errorCode -Message $git.error -Status blocked }
        if ($git.head -cne $state.initialCommit) {
            Throw-MigrationError -Code 'baseline_head_changed' -Message 'Git HEAD differs from the initial commit.' -Status blocked
        }
        $checks = @($manifest.checks)
        Update-PipelineOperationProgress -ProjectRoot $root -RunId $RunId -OperationId 'baseline' -Step 'baseline-checks' -OperationIndex 0 -OperationCount $checks.Count -CurrentFile $null -Health 'healthy'
        $discovered = @(Get-ProjectChecks -Package (Get-ProjectPackage -ProjectRoot $root) -ProjectRoot $root -HasLockfile (Test-Path -LiteralPath (Join-Path $root 'package-lock.json') -PathType Leaf))
        if ((ConvertTo-Json -InputObject $checks -Depth 10 -Compress) -cne (ConvertTo-Json -InputObject $discovered -Depth 10 -Compress)) {
            Throw-MigrationError -Code 'invalid_check_contract' -Message 'Manifest checks differ from current discovery.' -Status blocked
        }
        $checkIndex = 0
        foreach ($check in $checks) {
            $checkIndex++
            Update-PipelineOperationProgress -ProjectRoot $root -RunId $RunId -OperationId 'baseline' -Step ('baseline-check:' + $check.id) -OperationIndex $checkIndex -OperationCount $checks.Count -CurrentFile $null -Health 'healthy'
            $skip = if ($check.status -eq 'configured') { Get-BaselineSkipRecord -State $state -CheckId $check.id } else { $null }
            if ($skip) {
                $skipDetails = if ($skip.diagnostic.PSObject.Properties['details']) { $skip.diagnostic.details } else { $null }
                $skippedResult = [PSCustomObject]@{
                    id = $check.id; status = 'skipped'; exitCode = $null; timedOut = $false
                    startedAt = $null; finishedAt = $skip.approvedAt; durationMs = 0
                    stdoutLog = if ($skipDetails -and $skipDetails.PSObject.Properties['stdoutLog']) { $skipDetails.stdoutLog } else { $null }
                    stderrLog = if ($skipDetails -and $skipDetails.PSObject.Properties['stderrLog']) { $skipDetails.stderrLog } else { $null }
                    diagnosticSummary = "Explicitly skipped after user confirmation: $($skip.reason)"
                    executable = $null
                }
                $results += $skippedResult
                Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'check-skipped' -Stage 'baseline' -Data ([PSCustomObject]@{ checkId = $check.id; reason = $skip.reason; diagnostic = $skip.diagnostic; confirmed = $skip.confirmed })
                continue
            }
            if ($check.status -eq 'configured') {
                Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'check-started' -Stage 'baseline' -Data ([PSCustomObject]@{ checkId = $check.id })
            }
            $runtime = if ($check.status -eq 'configured') { Get-PipelineRuntimeProfile -ProjectRoot $root -RunId $RunId -ProfileId ([string]$check.runtimeProfile) } else { $null }
            $result = if ($runtime) {
                Invoke-ProjectCheck -Check $check -LogDirectory (Join-Path $paths.logs 'baseline') -FnmPath $runtime.fnmPath -NodeVersion $runtime.nodeVersion
            }
            else {
                Invoke-ProjectCheck -Check $check -LogDirectory (Join-Path $paths.logs 'baseline')
            }
            $results += $result
            if ($check.status -eq 'configured') {
                Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'check-finished' -Stage 'baseline' -Data $result
            }
            if ($result.status -notin @('passed', 'not-configured', 'skipped')) {
                return [PSCustomObject]@{
                    status = 'blocked'; checks = @($results); notStarted = @($checks | Select-Object -Skip @($results).Count)
                    diagnostic = [PSCustomObject]@{
                        code = 'baseline_check_failed'; checkId = $result.id; exitCode = $result.exitCode; timedOut = $result.timedOut
                        stdoutLog = $result.stdoutLog; stderrLog = $result.stderrLog
                        message = "The project does not pass its existing $($result.id) before migration."
                    }
                }
            }
        }
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'baseline-completed' -Stage 'baseline' -Data ([PSCustomObject]@{ checks = $results })
        $state.baselineStatus = 'passed'
        Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $state
        return [PSCustomObject]@{ status = 'passed'; checks = $results; notStarted = @(); diagnostic = $null }
    }
    catch {
        $status = if ($_.Exception.Data['status'] -eq 'blocked') { 'blocked' } else { 'failed' }
        $code = if ($_.Exception.Data['code']) { $_.Exception.Data['code'] } else { 'baseline_internal_error' }
        return [PSCustomObject]@{
            status = $status; checks = @($results); notStarted = @($checks | Select-Object -Skip @($results).Count)
            diagnostic = [PSCustomObject]@{ code = $code; message = 'Baseline could not be completed.' }
        }
    }
}

function Get-BaselineDependencyProposal {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$State
    )

    if ($State.status -cne 'blocked' -or $State.stage -cne 'baseline' -or
        -not $State.lastDiagnostic -or $State.lastDiagnostic.code -cne 'baseline_check_failed' -or
        -not $State.lastDiagnostic.details -or $State.lastDiagnostic.details.checkId -cne 'dependency-tree') {
        Throw-PipelineError -Code 'baseline_dependency_context_unavailable' -Message 'A blocked dependency-tree baseline is required before proposing dependency changes.' -Status blocked
    }

    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $diagnostic = $State.lastDiagnostic.details
    $output = ''
    foreach ($log in @($diagnostic.stdoutLog, $diagnostic.stderrLog)) {
        if ([string]::IsNullOrWhiteSpace([string]$log)) { continue }
        if ($log -notmatch '^logs/baseline/[a-zA-Z0-9._-]+\.(?:stdout|stderr)\.log$') {
            Throw-PipelineError -Code 'baseline_dependency_log_invalid' -Message 'The baseline dependency log path is invalid.' -Status failed
        }
        $fullLog = Join-Path $paths.root $log.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $fullLog -PathType Leaf)) {
            Throw-PipelineError -Code 'baseline_dependency_log_missing' -Message 'The baseline dependency log is missing.' -Status failed
        }
        $output += "`n" + [IO.File]::ReadAllText($fullLog)
    }

    $pattern = '(?im)^\s*(?:npm\s+error\s+)?missing:\s+(?<name>@[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*|[a-z0-9][a-z0-9._-]*)@(?<range>.+?),\s+required\s+by\s+(?<parent>.+?)\s*$'
    $groups = @{}
    foreach ($match in [regex]::Matches($output, $pattern)) {
        $name = [string]$match.Groups['name'].Value
        $range = [string]$match.Groups['range'].Value.Trim()
        $parent = [string]$match.Groups['parent'].Value.Trim()
        if ($range -notmatch '^[0-9A-Za-z.*xX~^<>=|+() \-]+$' -or $parent -notmatch '^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*(?:@[^\s]+)?$') {
            Throw-PipelineError -Code 'baseline_dependency_proposal_unsafe' -Message "The baseline dependency proposal contains an unsupported npm spec: $name." -Status blocked
        }
        if (-not $groups.ContainsKey($name)) {
            $groups[$name] = [ordered]@{ ranges = @(); requiredBy = @() }
        }
        $groups[$name].ranges += $range
        $groups[$name].requiredBy += $parent
    }
    if ($groups.Count -eq 0) {
        Throw-PipelineError -Code 'baseline_dependency_proposal_unavailable' -Message 'The dependency-tree log does not contain a supported missing peer dependency.' -Status blocked
    }

    $metadataRuntime = Get-PipelineRuntimeProfile -ProjectRoot $ProjectRoot -RunId $RunId -ProfileId 'metadata'
    $packages = @()
    $queryIndex = 0
    foreach ($name in @($groups.Keys | Sort-Object)) {
        $ranges = @($groups[$name].ranges | Sort-Object -Unique)
        if ($ranges.Count -ne 1) {
            Throw-PipelineError -Code 'baseline_dependency_proposal_ambiguous' -Message "Multiple peer ranges were reported for $name." -Status blocked -Details ([PSCustomObject]@{ package = $name; ranges = $ranges })
        }
        $range = [string]$ranges[0]
        $queryIndex++
        $query = Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'baseline-dependency-context' -Prefix ('{0:D2}-npm-view-' -f $queryIndex) -FilePath 'npm' -Arguments @('view', "$name@$range", 'version', '--json') -WorkingDirectory $ProjectRoot -TimeoutSeconds 120 -NodeVersion $metadataRuntime.nodeVersion -FnmPath $metadataRuntime.fnmPath
        if ($query.timedOut -or $query.exitCode -ne 0) {
            Throw-PipelineError -Code 'baseline_dependency_proposal_unavailable' -Message "Registry metadata is unavailable for $name@$range." -Status blocked -Details ([PSCustomObject]@{ package = $name; requiredRange = $range; stdoutLog = $query.stdoutLog; stderrLog = $query.stderrLog })
        }
        try { $rawVersions = $query.stdout | ConvertFrom-Json } catch { Throw-PipelineError -Code 'baseline_dependency_proposal_unavailable' -Message "Registry metadata for $name is not valid JSON." -Status blocked }
        $versions = if ($rawVersions -is [array]) { @($rawVersions) } else { @($rawVersions) }
        $candidates = @($versions | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\d+\.\d+\.\d+$' })
        if ($candidates.Count -eq 0) {
            Throw-PipelineError -Code 'baseline_dependency_proposal_unavailable' -Message "Registry metadata for $name has no stable exact version." -Status blocked
        }
        $selectedVersion = [string](@($candidates | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)[0])
        $requiredBy = @($groups[$name].requiredBy | Sort-Object -Unique)
        $packages += [PSCustomObject][ordered]@{
            name           = $name
            installVersion = $selectedVersion
            requiredRange  = $range
            requiredBy     = $requiredBy
            section        = 'dependencies'
            reason         = "The project declares a package that requires $name as a peer dependency, but npm reports it missing. Installing it as a direct runtime dependency makes that requirement explicit and allows the dependency tree to pass before migration."
        }
    }

    $proposal = [PSCustomObject][ordered]@{
        schemaVersion = 1
        runId         = $RunId
        stage         = 'baseline'
        failedCheck   = 'dependency-tree'
        status        = 'confirmation-required'
        packages      = @($packages)
        rationale     = 'These exact stable versions satisfy the peer ranges reported by npm. No Angular package or migration dependency is changed by this proposal.'
        verification  = 'The controller will run npm ls --all after installation and will roll back the proposal if the dependency tree remains invalid.'
    }
    $proposalHash = Get-PipelineObjectHash -Value $proposal
    $proposal | Add-Member -NotePropertyName proposalHash -NotePropertyValue $proposalHash
    return $proposal
}

function Invoke-MigrationBaselineDependencyContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RunId
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-MigrationError -Code 'run_id_required' -Message '-RunId is required for baseline dependency context.' -Status blocked }
    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    $proposal = Get-BaselineDependencyProposal -ProjectRoot $root -RunId $RunId -State $state
    return [PSCustomObject]@{
        ok     = $false
        status = 'blocked'
        data   = $proposal
        error  = [PSCustomObject]@{ code = 'baseline_dependency_confirmation_required'; message = 'Explicit confirmation is required before installing the proposed baseline dependencies.'; details = $proposal }
    }
}

function Invoke-ApproveMigrationBaselineDependencies {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RunId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProposalHash,
        [switch]$Confirmed
    )

    if (-not $Confirmed) { Throw-MigrationError -Code 'confirmation_required' -Message 'Baseline dependency installation requires explicit confirmation.' -Status blocked }
    if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-MigrationError -Code 'run_id_required' -Message '-RunId is required for baseline dependency approval.' -Status blocked }
    if ($ProposalHash -notmatch '^[0-9a-f]{64}$') { Throw-MigrationError -Code 'proposal_hash_required' -Message 'A valid baseline dependency proposal hash is required.' -Status blocked }
    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    $proposal = Get-BaselineDependencyProposal -ProjectRoot $root -RunId $RunId -State $state
    if ($proposal.proposalHash -cne $ProposalHash) {
        Throw-MigrationError -Code 'baseline_dependency_proposal_changed' -Message 'The baseline dependency proposal changed; request confirmation again.' -Status blocked -Details $proposal
    }
    Assert-PipelineRunGitContext -ProjectRoot $root -State $state
    $before = @(Get-PipelineGitStatus -ProjectRoot $root)
    $baselineRuntime = Get-PipelineRuntimeProfile -ProjectRoot $root -RunId $RunId -ProfileId 'baseline:dependency-tree'
    $lockCreated = $false
    $committed = $false
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
    try {
        New-ActiveRunLock -ProjectRoot $root -RunId $RunId
        $lockCreated = $true
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'baseline-dependencies-approval-started' -Stage 'baseline' -Data ([PSCustomObject]@{ proposalHash = $proposal.proposalHash; packages = @($proposal.packages | ForEach-Object { [PSCustomObject]@{ name = $_.name; version = $_.installVersion; reason = $_.reason } }) })
        $specs = @($proposal.packages | ForEach-Object { "$($_.name)@$($_.installVersion)" })
        $install = Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'baseline-dependency-repair' -Prefix '01-npm-install' -FilePath 'npm' -Arguments (@('install', '--save-exact') + $specs) -WorkingDirectory $root -TimeoutSeconds 900 -NodeVersion $baselineRuntime.nodeVersion -FnmPath $baselineRuntime.fnmPath
        if ($install.timedOut -or $install.exitCode -ne 0) {
            Throw-PipelineError -Code 'baseline_dependency_install_failed' -Message 'The approved baseline dependency installation failed.' -Status blocked -Details ([PSCustomObject]@{ stdoutLog = $install.stdoutLog; stderrLog = $install.stderrLog; exitCode = $install.exitCode; timedOut = $install.timedOut })
        }
        $changed = @(Get-PipelineGitStatus -ProjectRoot $root)
        $unexpected = @($changed | Where-Object { $_.path -notin @('package.json', 'package-lock.json') })
        if ($unexpected.Count -gt 0) {
            Throw-PipelineError -Code 'baseline_dependency_scope_violation' -Message 'The approved dependency installation changed a path outside package metadata.' -Status blocked -Details ([PSCustomObject]@{ paths = @($unexpected.path) })
        }
        $tree = Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'baseline-dependency-repair' -Prefix '02-npm-ls-all' -FilePath 'npm' -Arguments @('ls', '--all') -WorkingDirectory $root -TimeoutSeconds 300 -NodeVersion $baselineRuntime.nodeVersion -FnmPath $baselineRuntime.fnmPath
        if ($tree.timedOut -or $tree.exitCode -ne 0 -or ([string]$tree.stdout + "`n" + [string]$tree.stderr) -match '(?i)\b(invalid|extraneous|missing)\b') {
            Throw-PipelineError -Code 'baseline_dependency_tree_failed' -Message 'The approved dependencies did not produce a valid npm dependency tree.' -Status blocked -Details ([PSCustomObject]@{ stdoutLog = $tree.stdoutLog; stderrLog = $tree.stderrLog; exitCode = $tree.exitCode; timedOut = $tree.timedOut })
        }
        $changed = @(Get-PipelineGitStatus -ProjectRoot $root)
        $unexpected = @($changed | Where-Object { $_.path -notin @('package.json', 'package-lock.json') })
        if ($unexpected.Count -gt 0 -or $changed.Count -eq 0) {
            Throw-PipelineError -Code 'baseline_dependency_scope_violation' -Message 'The approved dependency installation did not produce only the expected package metadata changes.' -Status blocked -Details ([PSCustomObject]@{ paths = @($changed.path) })
        }
        $commit = New-PipelineCheckpoint -ProjectRoot $root -RunId $RunId -Message "chore(angular-migration): satisfy baseline peer dependencies [$RunId]"
        $committed = $true
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'baseline-dependencies-approved' -Stage 'baseline' -Data ([PSCustomObject]@{ proposalHash = $proposal.proposalHash; packages = @($proposal.packages | ForEach-Object { [PSCustomObject]@{ name = $_.name; version = $_.installVersion } }); verification = 'npm ls --all'; commit = $commit })
        return [PSCustomObject]@{
            ok     = $true
            status = 'ready'
            data   = [PSCustomObject]@{ runId = $RunId; status = 'ready-for-new-run'; commit = $commit; packages = @($proposal.packages); proposalHash = $proposal.proposalHash; nextAction = 'inspect-and-start-new-run' }
            error  = $null
        }
    }
    catch {
        if (-not $committed) {
            try { Invoke-PipelineRollback -ProjectRoot $root -CheckpointCommit $state.checkpointCommit -BeforeItems $before } catch { throw }
        }
        throw
    }
    finally {
        if ($lockCreated) { Remove-ActiveRunLock -ProjectRoot $root -RunId $RunId }
    }
}

function Get-BaselineSkipRecord {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$CheckId
    )

    foreach ($skip in @($State.skippedChecks)) {
        if ($skip.stage -ceq 'baseline' -and $skip.checkId -ceq $CheckId -and $skip.confirmed -eq $true) {
            return $skip
        }
    }
    return $null
}

function Invoke-MigrationSkipCheck {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RunId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CheckId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Reason,
        [switch]$Confirmed
    )

    $policy = Get-MigrationCheckSkipPolicy
    if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-PipelineError -Code 'run_id_required' -Message '-RunId is required for skip-check.' -Status blocked }
    if ([string]::IsNullOrWhiteSpace($CheckId)) { Throw-PipelineError -Code 'check_id_required' -Message '-CheckId is required for skip-check.' -Status blocked }
    if ($CheckId -in $policy.critical) { Throw-PipelineError -Code 'critical_check_cannot_be_skipped' -Message "Critical check cannot be skipped: $CheckId" -Status blocked -Details ([PSCustomObject]@{ checkId = $CheckId; criticalChecks = @($policy.critical) }) }
    if ($CheckId -notin $policy.skippable) { Throw-PipelineError -Code 'check_not_skippable' -Message "Check is not eligible for skip: $CheckId" -Status blocked -Details ([PSCustomObject]@{ checkId = $CheckId; skippableChecks = @($policy.skippable) }) }
    if ([string]::IsNullOrWhiteSpace($Reason)) { Throw-PipelineError -Code 'skip_reason_required' -Message 'A non-empty reason is required for skip-check.' -Status blocked }
    if ($Reason.Length -gt 2000) { Throw-PipelineError -Code 'skip_reason_too_long' -Message 'The skip reason must be 2000 characters or fewer.' -Status blocked }
    if (-not $Confirmed) { Throw-PipelineError -Code 'confirmation_required' -Message 'Skipping a baseline check requires explicit confirmation.' -Status blocked }
    Assert-MigrationRunId -RunId $RunId

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    $expectedRevision = [int]$state.stageRevision
    $isPreflight = $state.status -ceq 'running' -and $state.stage -ceq 'baseline'
    $isRecovery = $state.status -ceq 'blocked' -and $state.stage -ceq 'baseline' -and
    $state.lastDiagnostic -and $state.lastDiagnostic.code -ceq 'baseline_check_failed'
    if (-not $isPreflight -and -not $isRecovery) {
        Throw-PipelineError -Code 'skip_context_unavailable' -Message 'skip-check requires a running baseline preflight or a blocked baseline check.' -Status blocked
    }
    if ($isPreflight -and ($state.baselineStatus -ne 'pending' -or 'baseline' -in @($state.completedOperations))) {
        Throw-PipelineError -Code 'skip_context_unavailable' -Message 'Baseline checks can only be skipped before baseline completes.' -Status blocked
    }
    if ($isPreflight) { Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId }
    if ($isRecovery) {
        $details = if ($state.lastDiagnostic.PSObject.Properties['details']) { $state.lastDiagnostic.details } else { $null }
        $failedCheckId = if ($details -and $details.PSObject.Properties['checkId']) { [string]$details.checkId } else { $null }
        if ($failedCheckId -cne $CheckId) {
            Throw-PipelineError -Code 'skip_check_mismatch' -Message 'The requested skip does not match the currently failed baseline check.' -Status blocked -Details ([PSCustomObject]@{ requestedCheckId = $CheckId; failedCheckId = $failedCheckId })
        }
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    if ($manifest.schemaVersion -ne (Get-MigrationSchemaVersion) -or $manifest.manifestType -cne 'migration' -or
        $manifest.runId -cne $RunId -or $manifest.project.root -cne $root -or
        $manifest.sourceMajor -ne $state.sourceMajor -or $manifest.targetMajor -ne $state.targetMajor -or
        $manifest.project.git.initialCommit -cne $state.initialCommit) {
        Throw-PipelineError -Code 'invalid_run_manifest' -Message 'Manifest and state must describe the same run and project before skip-check.' -Status failed
    }
    $manifestCheck = @($manifest.checks | Where-Object { $_.id -ceq $CheckId })
    if ($manifestCheck.Count -ne 1 -or $manifestCheck[0].phase -cne 'baseline' -or $manifestCheck[0].status -cne 'configured') {
        Throw-PipelineError -Code 'skip_check_mismatch' -Message 'The failed check is not a configured baseline check in the immutable manifest.' -Status blocked
    }
    Assert-PipelineRunGitContext -ProjectRoot $root -State $state

    $lockCreated = $false
    $handoffLock = $false
    $operationLockCreated = $false
    try {
        New-MigrationOperationLock -ProjectRoot $root -RunId $RunId -OperationId ('skip-check:' + $CheckId)
        $operationLockCreated = $true
        if ($isPreflight) {
            Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
        }
        else {
            New-ActiveRunLock -ProjectRoot $root -RunId $RunId
            $lockCreated = $true
        }
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        $currentPreflight = $state.status -ceq 'running' -and $state.stage -ceq 'baseline' -and -not $state.activeOperation
        $currentRecovery = $state.status -ceq 'blocked' -and $state.stage -ceq 'baseline' -and
        $state.lastDiagnostic -and $state.lastDiagnostic.code -ceq 'baseline_check_failed'
        if (($isPreflight -and -not $currentPreflight) -or ($isRecovery -and -not $currentRecovery) -or [int]$state.stageRevision -ne $expectedRevision) {
            Throw-PipelineError -Code 'state_revision_conflict' -Message 'Migration state changed before skip-check was accepted.' -Status blocked
        }
        if ($isRecovery) {
            $details = if ($state.lastDiagnostic.PSObject.Properties['details']) { $state.lastDiagnostic.details } else { $null }
            $failedCheckId = if ($details -and $details.PSObject.Properties['checkId']) { [string]$details.checkId } else { $null }
            if ($failedCheckId -cne $CheckId) {
                Throw-PipelineError -Code 'skip_check_mismatch' -Message 'The requested skip no longer matches the failed baseline check.' -Status blocked
            }
        }
        $existing = Get-BaselineSkipRecord -State $state -CheckId $CheckId
        if ($existing -and $existing.reason -cne $Reason.Trim()) {
            Throw-PipelineError -Code 'skip_already_recorded' -Message 'A different skip approval is already recorded for this check.' -Status blocked
        }
        if (-not $existing) {
            $skip = [PSCustomObject][ordered]@{
                stage      = 'baseline'
                checkId    = $CheckId
                reason     = $Reason.Trim()
                diagnostic = $state.lastDiagnostic
                approvedAt = Get-MigrationUtcNow
                confirmed  = $true
            }
            if ($isPreflight) {
                $skip.diagnostic = [PSCustomObject]@{
                    code    = 'preflight_skip_approved'
                    message = "Baseline check was explicitly skipped during preflight: $CheckId"
                    details = [PSCustomObject]@{ checkId = $CheckId; source = 'preflight'; status = $manifestCheck[0].status }
                }
            }
            $state.skippedChecks = @($state.skippedChecks) + @($skip)
            Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $state
        }
        if ($isRecovery) {
            $state = Move-MigrationState -ProjectRoot $root -RunId $RunId -ExpectedStatus 'blocked' -ExpectedStage 'baseline' -ExpectedRevision $state.stageRevision -NewStatus 'running' -NewStage 'baseline'
        }
        $accepted = Get-BaselineSkipRecord -State $state -CheckId $CheckId
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type $(if ($isPreflight) { 'skip-preapproved' } else { 'skip-accepted' }) -Stage 'baseline' -Data ([PSCustomObject]@{ checkId = $CheckId; reason = $accepted.reason; diagnostic = $accepted.diagnostic; confirmed = $accepted.confirmed; source = if ($isPreflight) { 'preflight' } else { 'baseline-failure' } })
        $handoffLock = $isRecovery
        return [PSCustomObject]@{
            ok     = $true
            status = 'running'
            data   = [PSCustomObject]@{ runId = $RunId; stage = 'baseline'; checkId = $CheckId; reason = $accepted.reason; source = if ($isPreflight) { 'preflight' } else { 'baseline-failure' }; criticalChecks = @($policy.critical); nextAction = 'run' }
            error  = $null
        }
    }
    finally {
        if ($lockCreated -and -not $handoffLock) { Remove-ActiveRunLock -ProjectRoot $root -RunId $RunId }
        if ($operationLockCreated) { Remove-MigrationOperationLock -ProjectRoot $root -RunId $RunId }
    }
}


function Invoke-MigrationSkipChecks {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RunId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$InputFile,
        [switch]$Confirmed
    )

    $policy = Get-MigrationCheckSkipPolicy
    if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-PipelineError -Code 'run_id_required' -Message '-RunId is required for skip-checks.' -Status blocked }
    if ([string]::IsNullOrWhiteSpace($InputFile)) { Throw-PipelineError -Code 'skip_input_required' -Message '-InputFile is required for skip-checks.' -Status blocked }
    if (-not $Confirmed) { Throw-PipelineError -Code 'confirmation_required' -Message 'Skipping baseline checks requires explicit confirmation.' -Status blocked }
    Assert-MigrationRunId -RunId $RunId

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
    try {
        $expectedInput = Resolve-RepairPath -Root $root -Path ('.angular-migration/runs/' + $RunId + '/inbox/skips.json')
        $actualInput = Resolve-RepairPath -Root $root -Path $InputFile
    }
    catch {
        Throw-PipelineError -Code 'skip_input_path_invalid' -Message 'skip-checks input must be the controller-owned skips.json path.' -Status blocked
    }
    if ($actualInput -cne $expectedInput) {
        Throw-PipelineError -Code 'skip_input_path_invalid' -Message 'skip-checks input must be the controller-owned skips.json path.' -Status blocked
    }
    if (-not (Test-Path -LiteralPath $actualInput -PathType Leaf)) {
        Throw-PipelineError -Code 'skip_input_missing' -Message 'The controller-owned skips.json input is missing.' -Status blocked
    }
    if (Test-Path -LiteralPath $paths.skipsArtifact -PathType Leaf) {
        Throw-PipelineError -Code 'skip_batch_already_recorded' -Message 'The skip batch has already been recorded for this run.' -Status blocked
    }

    try {
        $input = Read-MigrationJson -Path $actualInput -Required
        $schema = Read-MigrationJson -Path (Join-Path $PSScriptRoot '../../schemas/skip-batch.schema.json') -Required
        Assert-MigrationJsonSchemaValue -Value $input -Schema $schema -RootSchema $schema -Path '$'
    }
    catch {
        Throw-PipelineError -Code 'skip_batch_invalid' -Message 'The skips.json input does not satisfy its schema.' -Status blocked -Details $_.Exception.Message
    }
    if ([string](Get-DiscoveryValue -Object $input -Name 'runId') -cne $RunId) {
        Throw-PipelineError -Code 'skip_batch_invalid' -Message 'The skips.json runId does not match the requested run.' -Status blocked
    }

    $entries = @()
    $seen = @{}
    foreach ($entry in @($input.skips)) {
        $checkId = [string](Get-DiscoveryValue -Object $entry -Name 'checkId')
        $reason = [string](Get-DiscoveryValue -Object $entry -Name 'reason')
        if ($checkId -notin $policy.skippable -or $seen.ContainsKey($checkId)) {
            Throw-PipelineError -Code 'check_not_skippable' -Message "Check is not eligible for batch skip: $checkId" -Status blocked -Details ([PSCustomObject]@{ checkId = $checkId; criticalChecks = @($policy.critical); skippableChecks = @($policy.skippable) })
        }
        $seen[$checkId] = $true
        $entries += [PSCustomObject][ordered]@{ checkId = $checkId; reason = $reason.Trim() }
    }

    $leasePath = Join-Path $paths.root 'skip-checks.lock'
    $operationLockCreated = $false
    $lease = $null
    try {
        New-MigrationOperationLock -ProjectRoot $root -RunId $RunId -OperationId 'skip-checks'
        $operationLockCreated = $true
        try { $lease = [IO.File]::Open($leasePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { Throw-PipelineError -Code 'skip_process_not_owner' -Message 'Another process owns skip-checks for this run.' -Status blocked }
    }
    catch {
        if ($operationLockCreated) { Remove-MigrationOperationLock -ProjectRoot $root -RunId $RunId }
        throw
    }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$PID)
        $lease.Write($bytes, 0, $bytes.Length)
        $lease.Flush($true)
        Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        if ($state.status -cne 'running' -or $state.stage -cne 'baseline' -or $state.activeOperation) {
            Throw-PipelineError -Code 'skip_context_unavailable' -Message 'skip-checks requires a running baseline with no active operation.' -Status blocked
        }
        if ($state.baselineStatus -ne 'pending' -or 'baseline' -in @($state.completedOperations)) {
            Throw-PipelineError -Code 'skip_context_unavailable' -Message 'Baseline checks can only be skipped before baseline completes.' -Status blocked
        }
        $expectedRevision = [int]$state.stageRevision
        $manifest = Read-MigrationJson -Path $paths.manifest -Required
        if ($manifest.schemaVersion -ne (Get-MigrationSchemaVersion) -or $manifest.manifestType -cne 'migration' -or
            $manifest.runId -cne $RunId -or $manifest.project.root -ne $root -or
            $manifest.sourceMajor -ne $state.sourceMajor -or $manifest.targetMajor -ne $state.targetMajor -or
            $manifest.resolutionStatus -ne 'pending') {
            Throw-PipelineError -Code 'invalid_run_manifest' -Message 'Manifest and state must describe a pending baseline run before skip-checks.' -Status failed
        }

        $newSkips = @()
        foreach ($entry in $entries) {
            $manifestCheck = @($manifest.checks | Where-Object { $_.id -ceq $entry.checkId })
            if ($manifestCheck.Count -ne 1 -or $manifestCheck[0].phase -cne 'baseline' -or
                $manifestCheck[0].status -ne 'configured' -or -not $manifestCheck[0].canSkip) {
                Throw-PipelineError -Code 'check_not_skippable' -Message "Configured check is not eligible for batch skip: $($entry.checkId)" -Status blocked
            }
            $existing = Get-BaselineSkipRecord -State $state -CheckId $entry.checkId
            if ($existing) {
                Throw-PipelineError -Code 'skip_already_recorded' -Message "A skip is already recorded for this check: $($entry.checkId)" -Status blocked
            }
            $newSkips += [PSCustomObject][ordered]@{
                stage      = 'baseline'
                checkId    = $entry.checkId
                reason     = $entry.reason
                diagnostic = [PSCustomObject][ordered]@{
                    code    = 'batch_skip_approved'
                    message = "Baseline check was explicitly skipped in a batch: $($entry.checkId)"
                    details = [PSCustomObject][ordered]@{ checkId = $entry.checkId; source = 'skip-checks'; status = $manifestCheck[0].status }
                }
                approvedAt = Get-MigrationUtcNow
                confirmed  = $true
            }
        }

        $current = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        if ($current.status -cne 'running' -or $current.stage -cne 'baseline' -or $current.activeOperation -or [int]$current.stageRevision -ne $expectedRevision) {
            Throw-PipelineError -Code 'state_revision_conflict' -Message 'Migration state changed before the skip batch was accepted.' -Status blocked
        }
        New-Item -ItemType Directory -Path $paths.artifacts -Force | Out-Null
        Move-Item -LiteralPath $actualInput -Destination $paths.skipsArtifact -Force:$false
        $current.skippedChecks = @($current.skippedChecks) + @($newSkips)
        try { Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $current }
        catch {
            Move-Item -LiteralPath $paths.skipsArtifact -Destination $actualInput -Force:$false -ErrorAction SilentlyContinue
            throw
        }
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'skip-batch-accepted' -Stage 'baseline' -Data ([PSCustomObject][ordered]@{
                confirmed = $true
                checks    = @($newSkips | ForEach-Object { [PSCustomObject][ordered]@{ checkId = $_.checkId; reason = $_.reason; diagnostic = $_.diagnostic; approvedAt = $_.approvedAt } })
                input     = '.angular-migration/runs/' + $RunId + '/inbox/skips.json'
            })
        return [PSCustomObject]@{
            ok     = $true
            status = 'running'
            data   = [PSCustomObject]@{
                runId      = $RunId
                stage      = 'baseline'
                checks     = @($newSkips | ForEach-Object { [PSCustomObject]@{ checkId = $_.checkId; reason = $_.reason } })
                artifact   = '.angular-migration/runs/' + $RunId + '/artifacts/skips.json'
                nextAction = 'run'
            }
            error  = $null
        }
    }
    finally {
        if ($lease) { $lease.Dispose(); Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue }
        if ($operationLockCreated) { Remove-MigrationOperationLock -ProjectRoot $root -RunId $RunId }
    }
}

function Invoke-MigrationResolution {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$FnmPath,
        [Parameter(Mandatory = $true)][string]$NodeVersion
    )

    $queryEvents = @()
    try {
        $root = Resolve-MigrationRoot -Path $ProjectRoot
        Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
        $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        $manifest = Read-MigrationJson -Path $paths.manifest -Required
        if ($state.manifestSha256) {
            $actualHash = Get-ResolvedManifestHash -Manifest $manifest
            if ($actualHash -ne $state.manifestSha256 -or $manifest.manifestSha256 -ne $state.manifestSha256) {
                Throw-MigrationError -Code 'manifest_integrity_failed' -Message 'The resolved migration manifest has been altered.' -Status failed
            }
            Throw-MigrationError -Code 'manifest_already_resolved' -Message 'The migration manifest is already resolved.' -Status blocked
        }
        if ($state.status -cne 'running' -or $state.stage -notin @('baseline', 'resolve') -or $state.baselineStatus -cne 'passed') {
            Throw-MigrationError -Code 'invalid_resolution_stage' -Message 'Resolution requires a running run after a passed baseline.' -Status blocked
        }
        if ($manifest.schemaVersion -ne (Get-MigrationSchemaVersion) -or $manifest.manifestType -cne 'migration' -or
            $manifest.runId -cne $RunId -or $manifest.project.root -cne $root -or $manifest.resolutionStatus -cne 'pending') {
            Throw-MigrationError -Code 'invalid_run_manifest' -Message 'Manifest is not a pending manifest for the active run.' -Status failed
        }
        $resolution = Resolve-MigrationManifest -PendingManifest $manifest -ProjectRoot $root -FnmPath $FnmPath -NodeVersion $NodeVersion
        $queryEvents = @($resolution.queryEvents)
        foreach ($queryEvent in $queryEvents) {
            Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'registry-metadata-queried' -Stage 'resolve' -Data $queryEvent
        }
        if ($resolution.status -ne 'resolved') { return $resolution }
        $resolvedManifest = $resolution.manifest
        if (-not (Test-ResolvedManifest -Manifest $resolvedManifest)) {
            Throw-MigrationError -Code 'registry_metadata_invalid' -Message 'Resolved manifest failed its contract validation.' -Status blocked
        }
        $expectedHash = Get-ResolvedManifestHash -Manifest $resolvedManifest
        if ($resolvedManifest.manifestSha256 -ne $expectedHash) {
            Throw-MigrationError -Code 'manifest_integrity_failed' -Message 'Resolved manifest hash is not self-consistent.' -Status failed
        }
        Write-MigrationRunManifest -ProjectRoot $root -RunId $RunId -Manifest $resolvedManifest
        $published = Read-MigrationJson -Path $paths.manifest -Required
        if ($published.manifestSha256 -ne (Get-ResolvedManifestHash -Manifest $published)) {
            Throw-MigrationError -Code 'manifest_integrity_failed' -Message 'Published manifest failed its integrity check.' -Status failed
        }
        $state.manifestSha256 = [string]$published.manifestSha256
        $state.resolutionStatus = 'resolved'
        $state.stage = 'resolve'
        $state.lastDiagnostic = $null
        Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $state
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'manifest-resolved' -Stage 'resolve' -Data ([PSCustomObject]@{
                manifestSha256  = $published.manifestSha256
                dependencyCount = @($published.dependencies).Count
                resolvedAt      = $published.resolvedAt
            })
        return [PSCustomObject]@{ status = 'resolved'; manifest = $published; queryEvents = $queryEvents; diagnostic = $null }
    }
    catch {
        $status = if ($_.Exception.Data['status'] -eq 'blocked') { 'blocked' } else { 'failed' }
        $code = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'resolver_internal_error' }
        return [PSCustomObject]@{
            status = $status; manifest = $null; queryEvents = $queryEvents
            diagnostic = [PSCustomObject]@{ code = $code; message = $_.Exception.Message; details = $_.Exception.Data['details'] }
        }
    }
}

function Invoke-MigrationStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        Throw-MigrationError -Code 'run_id_required' -Message '-RunId is required for status.' -Status blocked
    }
    Assert-MigrationRunId -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    if (-not (Test-Path -LiteralPath $paths.state -PathType Leaf)) {
        Throw-MigrationError -Code 'run_not_found' -Message "Migration run not found: $RunId" -Status blocked
    }

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.manifestSha256) {
        $manifest = Read-MigrationJson -Path $paths.manifest -Required
        if ($manifest.manifestSha256 -ne $state.manifestSha256 -or (Get-ResolvedManifestHash -Manifest $manifest) -ne $state.manifestSha256) {
            Throw-MigrationError -Code 'manifest_integrity_failed' -Message 'The resolved migration manifest has been altered.' -Status failed
        }
    }
    $successful = @('running', 'verified', 'completed') -contains $state.status
    return [PSCustomObject]@{
        ok     = $successful
        status = $state.status
        data   = [PSCustomObject]@{
            runId               = $state.runId
            status              = $state.status
            stage               = $state.stage
            attempt             = $state.attempt
            migrationStatus     = $state.migrationStatus
            resolutionStatus    = $state.resolutionStatus
            manifestSha256      = $state.manifestSha256
            documentationStatus = $state.documentationStatus
            documentation       = $state.documentation
            skippedChecks       = @($state.skippedChecks)
            activeOperation     = $state.activeOperation
            lastDiagnostic      = $state.lastDiagnostic
            manifest            = '.angular-migration/runs/' + $RunId + '/manifest.json'
            state               = '.angular-migration/runs/' + $RunId + '/state.json'
        }
        error  = $null
    }
}

function Get-PipelineRunLogReferences {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)]$State
    )

    $references = @()
    $diagnostics = @($State.lastDiagnostic)
    if ($State.repair -and $State.repair.context -and $State.repair.context.diagnostic) {
        $diagnostics += $State.repair.context.diagnostic
    }
    foreach ($diagnostic in $diagnostics) {
        if ($null -eq $diagnostic -or -not $diagnostic.PSObject.Properties['logFiles']) { continue }
        foreach ($log in @($diagnostic.logFiles)) {
            if ($log -isnot [string] -or [string]::IsNullOrWhiteSpace($log)) { continue }
            $relative = [string]$log
            $prefix = '.angular-migration/runs/' + $RunId + '/'
            if ($relative.StartsWith($prefix, [StringComparison]::Ordinal)) {
                $relative = $relative.Substring($prefix.Length)
            }
            if ($relative -notmatch '(^|/)\.\.(?:/|$)' -and $relative -notmatch '^[A-Za-z]:[\\/]') {
                $references += '.angular-migration/runs/' + $RunId + '/' + $relative.TrimStart([char[]]@('/', '\'))
            }
        }
    }
    if (Test-Path -LiteralPath $RunPaths.logs -PathType Container) {
        foreach ($item in @(Get-ChildItem -LiteralPath $RunPaths.logs -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $references += Get-PipelineLogRelativePath -RunPaths $RunPaths -Path $item.FullName
        }
    }
    return @($references | Where-Object { $_ } | Sort-Object -Unique)
}

function Invoke-MigrationEvents {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        Throw-MigrationError -Code 'run_id_required' -Message '-RunId is required for events.' -Status blocked
    }
    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
    if (-not (Test-Path -LiteralPath $paths.state -PathType Leaf)) {
        Throw-MigrationError -Code 'run_not_found' -Message "Migration run not found: $RunId" -Status blocked
    }
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    $events = @(Get-PipelineRepairEvents -EventsPath $paths.events)
    return [PSCustomObject]@{
        ok     = $true
        status = $state.status
        data   = [PSCustomObject]@{
            runId      = $RunId
            count      = $events.Count
            events     = $events
            eventsFile = '.angular-migration/runs/' + $RunId + '/events.jsonl'
        }
        error  = $null
    }
}

function Invoke-MigrationDiagnose {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        Throw-MigrationError -Code 'run_id_required' -Message '-RunId is required for diagnose.' -Status blocked
    }
    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
    if (-not (Test-Path -LiteralPath $paths.state -PathType Leaf)) {
        Throw-MigrationError -Code 'run_not_found' -Message "Migration run not found: $RunId" -Status blocked
    }
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    $events = @(Get-PipelineRepairEvents -EventsPath $paths.events)
    $recentEvents = if ($events.Count -gt 20) { @($events | Select-Object -Last 20) } else { @($events) }
    $activeLock = $null
    $activeLockPath = Get-ActiveLockPath -ProjectRoot $root
    if (Test-Path -LiteralPath $activeLockPath -PathType Leaf) {
        try { $activeLock = Read-MigrationJson -Path $activeLockPath -Required } catch { $activeLock = [PSCustomObject]@{ invalid = $true } }
    }
    $operationLock = $null
    $operationLockPath = Get-MigrationOperationLockPath -ProjectRoot $root -RunId $RunId
    if (Test-Path -LiteralPath $operationLockPath -PathType Leaf) {
        try { $operationLock = Read-MigrationJson -Path $operationLockPath -Required } catch { $operationLock = [PSCustomObject]@{ invalid = $true } }
    }
    $manifestIntegrity = $null
    if (Test-Path -LiteralPath $paths.manifest -PathType Leaf) {
        try {
            $manifest = Read-MigrationJson -Path $paths.manifest -Required
            $manifestIntegrity = [bool]($manifest.runId -cne $RunId -or
                ($state.manifestSha256 -and ($manifest.manifestSha256 -cne $state.manifestSha256 -or (Get-ResolvedManifestHash -Manifest $manifest) -cne $state.manifestSha256))) -eq $false
        }
        catch { $manifestIntegrity = $false }
    }
    return [PSCustomObject]@{
        ok     = $true
        status = $state.status
        data   = [PSCustomObject]@{
            runId            = $RunId
            status           = $state.status
            stage            = $state.stage
            stageRevision    = $state.stageRevision
            attempt          = $state.attempt
            migrationStatus  = $state.migrationStatus
            resolutionStatus = $state.resolutionStatus
            lastDiagnostic   = $state.lastDiagnostic
            activeOperation  = $state.activeOperation
            activeLock       = $activeLock
            operationLock    = $operationLock
            recentEvents     = $recentEvents
            logFiles         = Get-PipelineRunLogReferences -ProjectRoot $root -RunId $RunId -RunPaths $paths -State $state
            integrity        = [PSCustomObject]@{ state = $true; manifest = $manifestIntegrity }
            state            = '.angular-migration/runs/' + $RunId + '/state.json'
            manifest         = '.angular-migration/runs/' + $RunId + '/manifest.json'
            events           = '.angular-migration/runs/' + $RunId + '/events.jsonl'
        }
        error  = $null
    }
}

function New-PipelineRecoveryLease {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    $operationLockCreated = $false
    $activeLockCreated = $false
    try {
        New-MigrationOperationLock -ProjectRoot $ProjectRoot -RunId $RunId -OperationId $OperationId
        $operationLockCreated = $true
        $activeLock = Read-ActiveRunLock -ProjectRoot $ProjectRoot
        if ($activeLock -and $activeLock.runId -cne $RunId) {
            Throw-PipelineError -Code 'active_run' -Message "Another migration run owns this project: $($activeLock.runId)" -Status blocked -Details $activeLock
        }
        if (-not $activeLock) {
            New-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $RunId
            $activeLockCreated = $true
        }
        return [PSCustomObject]@{
            operationLockCreated = $operationLockCreated
            activeLockCreated    = $activeLockCreated
        }
    }
    catch {
        if ($operationLockCreated) { Remove-MigrationOperationLock -ProjectRoot $ProjectRoot -RunId $RunId }
        throw
    }
}

function Remove-PipelineRecoveryLease {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [AllowNull()]$Lease
    )

    if ($Lease -and $Lease.operationLockCreated) {
        Remove-MigrationOperationLock -ProjectRoot $ProjectRoot -RunId $RunId
    }
    if ($Lease -and $Lease.activeLockCreated) {
        $state = $null
        try { $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId } catch { }
        if (-not $state -or $state.status -in @('blocked', 'failed')) {
            Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $RunId
        }
    }
}

function Get-PipelineRollbackVerification {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Rollback
    )

    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $stateIntegrity = $true
    $manifestIntegrity = $null
    try {
        $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        if (Test-Path -LiteralPath $paths.manifest -PathType Leaf) {
            $manifest = Read-MigrationJson -Path $paths.manifest -Required
            $manifestIntegrity = -not $state.manifestSha256 -or
            ($manifest.runId -ceq $RunId -and $manifest.manifestSha256 -ceq $state.manifestSha256 -and (Get-ResolvedManifestHash -Manifest $manifest) -ceq $state.manifestSha256)
        }
    }
    catch {
        $stateIntegrity = $false
        $manifestIntegrity = $false
    }
    return [PSCustomObject]@{
        checkpointCommit      = $Rollback.checkpointCommit
        headAfterRollback     = $Rollback.headAfterRollback
        restoredFiles         = @($Rollback.restoredFiles)
        removedUntrackedFiles = @($Rollback.removedUntrackedFiles)
        remainingProcesses    = @()
        gitStatusClean        = [bool]$Rollback.gitStatusClean
        gitInventoryVerified  = [bool]$Rollback.gitInventoryVerified
        manifestIntegrity     = $manifestIntegrity
        stateIntegrity        = $stateIntegrity
    }
}

function Get-PipelineRetryStageRequirements {
    return @{
        baseline              = @()
        resolve               = @('baseline')
        'update-angular'      = @('baseline', 'resolve-manifest', 'create-branch')
        'update-dependencies' = @('baseline', 'resolve-manifest', 'create-branch', 'update-angular')
        install               = @('baseline', 'resolve-manifest', 'create-branch', 'update-angular', 'update-dependencies')
        validate              = @('baseline', 'resolve-manifest', 'create-branch', 'update-angular', 'update-dependencies', 'install')
    }
}

function Invoke-MigrationRetryStage {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RunId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Stage,
        [switch]$Confirmed
    )

    if (-not $Confirmed) { Throw-PipelineError -Code 'confirmation_required' -Message 'Retrying a blocked stage requires explicit confirmation.' -Status blocked }
    if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-PipelineError -Code 'run_id_required' -Message '-RunId is required for retry-stage.' -Status blocked }
    if ([string]::IsNullOrWhiteSpace($Stage)) { Throw-PipelineError -Code 'stage_required' -Message '-Stage is required for retry-stage.' -Status blocked }
    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $requirements = Get-PipelineRetryStageRequirements
    if (-not $requirements.ContainsKey($Stage)) {
        Throw-PipelineError -Code 'stage_not_retryable' -Message "Stage cannot be retried through the public facade: $Stage" -Status blocked
    }
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    if ($state.status -eq 'needs-repair' -or ($state.repair -and $state.repair.context)) {
        Throw-PipelineError -Code 'repair_required' -Message 'A needs-repair run requires repair-context and record-repair before it can resume.' -Status 'needs-repair'
    }
    if ($state.status -ne 'blocked' -or $state.stage -cne $Stage) {
        Throw-PipelineError -Code 'retry_stage_unavailable' -Message 'retry-stage requires the requested stage to be currently blocked.' -Status blocked -Details ([PSCustomObject]@{ status = $state.status; stage = $state.stage; requestedStage = $Stage })
    }
    if ($state.activeOperation) {
        Throw-PipelineError -Code 'active_operation_present' -Message 'The blocked run still has an active operation and must be reconciled first.' -Status blocked -Details $state.activeOperation
    }
    foreach ($operation in @($requirements[$Stage])) {
        if ($operation -notin @($state.completedOperations)) {
            Throw-PipelineError -Code 'retry_checkpoint_invalid' -Message "The run has not completed the checkpoint required before retrying $Stage." -Status blocked -Details ([PSCustomObject]@{ requiredOperation = $operation; completedOperations = @($state.completedOperations) })
        }
    }

    $lease = $null
    try {
        $lease = New-PipelineRecoveryLease -ProjectRoot $root -RunId $RunId -OperationId ('retry-stage:' + $Stage)
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        if ($state.status -cne 'blocked' -or $state.stage -cne $Stage -or $state.activeOperation) {
            Throw-PipelineError -Code 'state_revision_conflict' -Message 'Migration state changed before retry-stage was accepted.' -Status blocked
        }
        foreach ($operation in @($requirements[$Stage])) {
            if ($operation -notin @($state.completedOperations)) {
                Throw-PipelineError -Code 'retry_checkpoint_invalid' -Message "The run no longer has the checkpoint required before retrying $Stage." -Status blocked
            }
        }
        Assert-PipelineRunGitContext -ProjectRoot $root -State $state
        $revision = [int]$state.stageRevision
        Move-MigrationState -ProjectRoot $root -RunId $RunId -ExpectedStatus 'blocked' -ExpectedStage $Stage -ExpectedRevision $revision -NewStatus 'running' -NewStage $Stage | Out-Null
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'stage-retry-requested' -Stage $Stage -Data ([PSCustomObject]@{ confirmed = $true; stageRevision = $revision + 1 })
        return Invoke-MigrationRun -ProjectRoot $root -RunId $RunId
    }
    finally {
        Remove-PipelineRecoveryLease -ProjectRoot $root -RunId $RunId -Lease $lease
    }
}

function Invoke-MigrationAbort {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RunId,
        [switch]$Confirmed
    )

    if (-not $Confirmed) { Throw-PipelineError -Code 'confirmation_required' -Message 'Aborting a migration run requires explicit confirmation.' -Status blocked }
    if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-PipelineError -Code 'run_id_required' -Message '-RunId is required for abort.' -Status blocked }
    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    if ($state.status -in @('verified', 'completed', 'failed')) {
        Throw-PipelineError -Code 'run_terminal' -Message 'A verified, completed or failed run cannot be aborted.' -Status blocked
    }

    $lease = $null
    try {
        $lease = New-PipelineRecoveryLease -ProjectRoot $root -RunId $RunId -OperationId 'abort'
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        if ($state.status -in @('verified', 'completed', 'failed')) {
            Throw-PipelineError -Code 'run_terminal' -Message 'A verified, completed or failed run cannot be aborted.' -Status blocked
        }
        $verification = [PSCustomObject]@{ rollback = $false; reason = 'no-active-mutation'; checkpointCommit = $state.checkpointCommit }
        if ($state.activeOperation) {
            Assert-PipelineCommitExists -ProjectRoot $root -Commit ([string]$state.activeOperation.checkpointCommit)
            $head = Get-PipelineGitHead -ProjectRoot $root
            if ($head -cne [string]$state.activeOperation.checkpointCommit) {
                Throw-PipelineError -Code 'git_head_changed' -Message 'Git HEAD changed while the migration operation was active; abort did not alter project files.' -Status blocked -Details ([PSCustomObject]@{ expected = $state.activeOperation.checkpointCommit; actual = $head })
            }
            $rollback = Invoke-PipelineRollback -ProjectRoot $root -CheckpointCommit ([string]$state.activeOperation.checkpointCommit) -BeforeItems @(Get-PipelineOperationPreexistingItems -Operation $state.activeOperation)
            $verification = Get-PipelineRollbackVerification -ProjectRoot $root -RunId $RunId -Rollback $rollback
            $verification | Add-Member -NotePropertyName rollback -NotePropertyValue $true
            Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'rollback-verified' -Stage $state.activeOperation.stage -Data $verification
        }
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'run-aborted' -Stage $state.stage -Data $verification
        Set-PipelineRecoveryOutcome -ProjectRoot $root -RunId $RunId -Status 'blocked' -Code 'run_aborted' -Message 'The migration run was explicitly aborted.' -Details $verification
        return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId
    }
    finally {
        Remove-PipelineRecoveryLease -ProjectRoot $root -RunId $RunId -Lease $lease
    }
}

function Invoke-MigrationRollback {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RunId,
        [switch]$Confirmed
    )

    if (-not $Confirmed) { Throw-PipelineError -Code 'confirmation_required' -Message 'Rolling back a migration operation requires explicit confirmation.' -Status blocked }
    if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-PipelineError -Code 'run_id_required' -Message '-RunId is required for rollback.' -Status blocked }
    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    if (-not $state.activeOperation) {
        Throw-PipelineError -Code 'rollback_target_missing' -Message 'No interrupted migration operation has a rollback target.' -Status blocked
    }
    if ($state.status -in @('verified', 'completed', 'failed')) {
        Throw-PipelineError -Code 'run_terminal' -Message 'A terminal run cannot be rolled back through the public facade.' -Status blocked
    }

    $lease = $null
    try {
        $lease = New-PipelineRecoveryLease -ProjectRoot $root -RunId $RunId -OperationId 'rollback'
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        if (-not $state.activeOperation) {
            Throw-PipelineError -Code 'rollback_target_missing' -Message 'The interrupted operation was already reconciled.' -Status blocked
        }
        $operation = $state.activeOperation
        Assert-PipelineCommitExists -ProjectRoot $root -Commit ([string]$operation.checkpointCommit)
        $head = Get-PipelineGitHead -ProjectRoot $root
        if ($head -cne [string]$operation.checkpointCommit) {
            Throw-PipelineError -Code 'git_head_changed' -Message 'Git HEAD changed while the migration operation was active; rollback did not alter project files.' -Status blocked -Details ([PSCustomObject]@{ expected = $operation.checkpointCommit; actual = $head })
        }
        $rollback = Invoke-PipelineRollback -ProjectRoot $root -CheckpointCommit ([string]$operation.checkpointCommit) -BeforeItems @(Get-PipelineOperationPreexistingItems -Operation $operation)
        $verification = Get-PipelineRollbackVerification -ProjectRoot $root -RunId $RunId -Rollback $rollback
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'rollback-verified' -Stage $operation.stage -Data $verification
        Set-PipelineRecoveryOutcome -ProjectRoot $root -RunId $RunId -Status 'blocked' -Code 'rollback_verified' -Message 'The interrupted migration operation was rolled back and verified.' -Details $verification
        return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId
    }
    finally {
        Remove-PipelineRecoveryLease -ProjectRoot $root -RunId $RunId -Lease $lease
    }
}

$script:TechnicalCheckIds = @('typecheck', 'lint', 'unit-test', 'build', 'e2e')
$script:DependencySections = @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')
$script:PackageRendererPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'js\render-package-json.js'

function Throw-PipelineError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('needs-repair', 'blocked', 'failed')][string]$Status = 'failed',
        $Details = $null
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['code'] = $Code
    $exception.Data['status'] = $Status
    $exception.Data['details'] = $Details
    throw $exception
}

function Get-PipelineRunError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    $details = if ($exception.Data['details']) { $exception.Data['details'] } else {
        [PSCustomObject]@{
            command          = if ($ErrorRecord.InvocationInfo) { [string]$ErrorRecord.InvocationInfo.MyCommand } else { $null }
            position         = if ($ErrorRecord.InvocationInfo) { [string]$ErrorRecord.InvocationInfo.PositionMessage } else { $null }
            scriptStackTrace = [string]$ErrorRecord.ScriptStackTrace
            exceptionTrace   = [string]$exception.StackTrace
        }
    }
    return [PSCustomObject]@{
        code    = if ($exception.Data['code']) { [string]$exception.Data['code'] } else { 'migration_internal_error' }
        message = $exception.Message
        details = $details
    }
}

function Get-PipelineGitExecutable {
    $git = Find-MigrationExecutable -Names @('git.exe', 'git')
    if (-not $git) { Throw-PipelineError -Code 'git_missing' -Message 'git is not available.' -Status blocked }
    return $git
}

function Invoke-PipelineGit {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    $git = Get-PipelineGitExecutable
    return Invoke-MigrationProcess -FilePath $git -Arguments $Arguments -WorkingDirectory $ProjectRoot -TimeoutSeconds $TimeoutSeconds
}

function Get-PipelineGitHead {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('rev-parse', 'HEAD')
    if ($result.exitCode -ne 0 -or [string]$result.stdout.Trim() -notmatch '^[a-fA-F0-9]{40}$') {
        Throw-PipelineError -Code 'git_head_changed' -Message 'Git HEAD could not be read.' -Status blocked
    }
    return $result.stdout.Trim()
}

function ConvertTo-PipelineRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
    $prefix = $root.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $candidate -cne $root) {
        Throw-PipelineError -Code 'path_outside_project' -Message "Git path is outside the project root: $Path" -Status blocked
    }
    if ($candidate -ceq $root) { return '' }
    return $candidate.Substring($prefix.Length).Replace('\', '/')
}

function ConvertFrom-PipelineGitStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [AllowEmptyString()][string]$Output
    )

    $tokens = @()
    if (-not [string]::IsNullOrEmpty($Output)) { $tokens = @($Output -split [char]0) }
    $items = @()
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = [string]$tokens[$index]
        if ([string]::IsNullOrEmpty($token)) { continue }
        if ($token.Length -lt 4) { continue }
        $status = $token.Substring(0, 2)
        $pathValue = $token.Substring(3)
        $paths = @($pathValue)
        if ($status -match '[RC]' -and $index + 1 -lt $tokens.Count -and -not [string]::IsNullOrEmpty($tokens[$index + 1])) {
            $index++
            $paths += [string]$tokens[$index]
        }
        foreach ($path in $paths) {
            $relative = ConvertTo-PipelineRelativePath -ProjectRoot $ProjectRoot -Path $path
            $items += [PSCustomObject]@{
                status    = $status
                path      = $relative
                untracked = $status -eq '??'
            }
        }
    }
    return @($items)
}

function Get-PipelineGitStatus {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all')
    if ($result.exitCode -ne 0) {
        Throw-PipelineError -Code 'git_status_failed' -Message 'Git status could not be read.' -Status failed -Details $result.stderr
    }
    return @(ConvertFrom-PipelineGitStatus -ProjectRoot $ProjectRoot -Output $result.stdout)
}

function Test-PipelineProtectedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path -match '^(?:\.git(?:/|$)|\.github(?:/|$)|\.angular-migration(?:/|$)|docs(?:/|$))'
}

function Assert-PipelineNoProtectedChanges {
    param([Parameter(Mandatory = $true)]$StatusItems)

    $protected = @($StatusItems | Where-Object { Test-PipelineProtectedPath -Path $_.path })
    if ($protected.Count -gt 0) {
        Throw-PipelineError -Code 'protected_path_modified' -Message 'Technical migration modified a protected path.' -Status blocked -Details ([PSCustomObject]@{ paths = @($protected.path) })
    }
}

function Get-PipelineLogRelativePath {
    param(
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $relative = $Path.Substring($RunPaths.root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
    return $relative
}

function Invoke-PipelineLoggedProcess {
    param(
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 0,
        [AllowNull()][AllowEmptyString()][string]$StandardInput = $null,
        [string]$NodeVersion = '',
        [string]$FnmPath = '',
        [string]$RunId = '',
        [string]$OperationId = '',
        [int]$InactivityTimeoutSeconds = 300
    )

    $directory = Join-Path $RunPaths.logs $Stage
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $stdoutPath = Join-Path $directory ($Prefix + '.stdout.log')
    $stderrPath = Join-Path $directory ($Prefix + '.stderr.log')
    $started = Get-MigrationUtcNow
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    $projectRoot = $null
    $activityCallback = $null
    try {
        if ($RunId -and $OperationId) {
            $projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $RunPaths.root))
            Update-PipelineOperationProgress -ProjectRoot $projectRoot -RunId $RunId -OperationId $OperationId -Step ('process:' + $Prefix) -CurrentFile $null -Health 'healthy'
            $activityCallback = {
                try {
                    Update-PipelineOperationProgress -ProjectRoot $projectRoot -RunId $RunId -OperationId $OperationId -Step ('activity:' + $Prefix) -CurrentFile $null -Health 'healthy'
                }
                catch { }
            }.GetNewClosure()
        }
        $parameters = @{
            FilePath                 = $FilePath
            Arguments                = $Arguments
            WorkingDirectory         = $WorkingDirectory
            TimeoutSeconds           = $TimeoutSeconds
            InactivityTimeoutSeconds = $InactivityTimeoutSeconds
        }
        if ($null -ne $StandardInput) { $parameters.StandardInput = $StandardInput }
        if ($activityCallback) { $parameters.OnActivity = $activityCallback }
        if ($NodeVersion) {
            if (-not $FnmPath) { Throw-PipelineError -Code 'fnm_missing' -Message 'An fnm executable is required for a Node-managed process.' -Status blocked }
            $nodeParameters = @{
                FnmPath = $FnmPath; NodeVersion = $NodeVersion; Executable = $FilePath; Arguments = $Arguments
                WorkingDirectory = $WorkingDirectory; TimeoutSeconds = $TimeoutSeconds
                InactivityTimeoutSeconds = $InactivityTimeoutSeconds; StandardInput = $StandardInput
            }
            if ($activityCallback) { $nodeParameters.OnActivity = $activityCallback }
            $process = Invoke-MigrationNodeProcess @nodeParameters
        }
        else {
            $process = Invoke-MigrationProcess @parameters
        }
        [IO.File]::WriteAllText($stdoutPath, [string]$process.stdout, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($stderrPath, [string]$process.stderr, (New-Object Text.UTF8Encoding($false)))
        if ($RunId -and $OperationId) {
            if ([bool]$process.processStalled) {
                Update-PipelineOperationProgress -ProjectRoot $projectRoot -RunId $RunId -OperationId $OperationId -Step ('stalled:' + $Prefix) -CurrentFile $null -Health 'stalled'
            }
            else {
                Update-PipelineOperationProgress -ProjectRoot $projectRoot -RunId $RunId -OperationId $OperationId -Step ('finished:' + $Prefix) -CurrentFile $null -Health 'healthy'
            }
        }
        return [PSCustomObject]@{
            exitCode          = $process.exitCode
            timedOut          = [bool]$process.timedOut
            processStalled    = [bool]$process.processStalled
            terminationReason = [string]$process.terminationReason
            startedAt         = $started
            finishedAt        = Get-MigrationUtcNow
            durationMs        = $timer.ElapsedMilliseconds
            stdout            = [string]$process.stdout
            stderr            = [string]$process.stderr
            stdoutLog         = Get-PipelineLogRelativePath -RunPaths $RunPaths -Path $stdoutPath
            stderrLog         = Get-PipelineLogRelativePath -RunPaths $RunPaths -Path $stderrPath
        }
    }
    catch {
        try { [IO.File]::WriteAllText($stderrPath, $_.Exception.Message, (New-Object Text.UTF8Encoding($false))) } catch { }
        throw
    }
    finally { $timer.Stop() }
}

function Start-PipelineOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.activeOperation) {
        Throw-PipelineError -Code 'active_operation_present' -Message 'Another migration operation is already active.' -Status blocked -Details $state.activeOperation
    }
    New-MigrationOperationLock -ProjectRoot $ProjectRoot -RunId $RunId -OperationId $Id
    try {
        $startedAt = Get-MigrationUtcNow
        $state.activeOperation = [ordered]@{
            id                     = $Id
            stage                  = $Stage
            startedAt              = $startedAt
            checkpointCommit       = [string]$state.checkpointCommit
            expectedManifestSha256 = $state.manifestSha256
            step                   = 'starting'
            operationIndex         = 0
            operationCount         = 0
            currentFile            = $null
            lastActivityAt         = $startedAt
            health                 = 'healthy'
            preexistingFiles       = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
        }
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'operation-started' -Stage $Stage -Data $state.activeOperation
        return $state
    }
    catch {
        Remove-MigrationOperationLock -ProjectRoot $ProjectRoot -RunId $RunId
        throw
    }
}

function Update-PipelineOperationProgress {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [AllowEmptyString()][string]$Step = '',
        [int]$OperationIndex = -1,
        [int]$OperationCount = -1,
        [AllowNull()][string]$CurrentFile = $null,
        [ValidateSet('healthy', 'stalled', 'unknown')][string]$Health = 'healthy'
    )

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if (-not $state.activeOperation -or [string]$state.activeOperation.id -cne $OperationId) {
        Throw-PipelineError -Code 'active_operation_missing' -Message 'The requested operation is not active.' -Status blocked
    }
    if ($Step) { $state.activeOperation.step = $Step }
    if ($OperationIndex -ge 0) { $state.activeOperation.operationIndex = $OperationIndex }
    if ($OperationCount -ge 0) { $state.activeOperation.operationCount = $OperationCount }
    if ($PSBoundParameters.ContainsKey('CurrentFile')) { $state.activeOperation.currentFile = $CurrentFile }
    $state.activeOperation.lastActivityAt = Get-MigrationUtcNow
    $state.activeOperation.health = $Health
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'operation-progress' -Stage $state.activeOperation.stage -Data $state.activeOperation
}

function Finish-PipelineOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$Stage
    )
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $payload = [ordered]@{
        operationId        = if ($state.activeOperation) { [string]$state.activeOperation.id } else { $null }
        operationStartedAt = if ($state.activeOperation) { [string]$state.activeOperation.startedAt } else { $null }
    }
    if ($Data -is [Collections.IDictionary]) {
        foreach ($key in $Data.Keys) { $payload[[string]$key] = $Data[$key] }
    }
    else {
        foreach ($property in $Data.PSObject.Properties) { $payload[$property.Name] = $property.Value }
    }
    Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'operation-finished' -Stage $Stage -Data ([PSCustomObject]$payload)
}

function Complete-PipelineOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$CheckpointCommit
    )

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($Id -notin @($state.completedOperations)) { $state.completedOperations = @($state.completedOperations) + $Id }
    if ($CheckpointCommit) { $state.checkpointCommit = $CheckpointCommit }
    $state.activeOperation = $null
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    Remove-MigrationOperationLock -ProjectRoot $ProjectRoot -RunId $RunId
    Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'operation-confirmed' -Stage $Stage -Data ([PSCustomObject]@{ id = $Id; checkpointCommit = $state.checkpointCommit })
    return $state
}

function Clear-PipelineOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.activeOperation) {
        $state.activeOperation = $null
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    }
    Remove-MigrationOperationLock -ProjectRoot $ProjectRoot -RunId $RunId
    return $state
}

function Get-PipelineOperationPreexistingItems {
    param([Parameter(Mandatory = $true)]$Operation)

    $items = @()
    foreach ($item in @($Operation.preexistingFiles)) {
        if ($item -is [string]) {
            $items += [PSCustomObject]@{ status = ''; path = [string]$item; untracked = $false }
        }
        elseif ($item -and $item.PSObject.Properties['path']) {
            $items += $item
        }
    }
    return @($items)
}

function Get-PipelineOperationFinish {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Operation
    )

    $eventsPath = (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId).events
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) { return $null }
    $finished = @()
    foreach ($line in @(Get-Content -LiteralPath $eventsPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.type -eq 'operation-finished' -and $event.stage -eq $Operation.stage -and $event.data -and
            $event.data.operationId -eq $Operation.id -and $event.data.operationStartedAt -eq $Operation.startedAt -and
            $event.data.status -eq 'passed') {
            $finished += $event
        }
    }
    if ($finished.Count -eq 0) { return $null }
    return $finished[-1].data
}

function Assert-PipelineCommitExists {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    if ([string]::IsNullOrWhiteSpace($Commit) -or $Commit -notmatch '^[a-fA-F0-9]{40}$') {
        Throw-PipelineError -Code 'checkpoint_missing' -Message 'The migration checkpoint is missing or invalid.' -Status failed
    }
    $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('cat-file', '-e', ('{0}^{{commit}}' -f $Commit))
    if ($result.exitCode -ne 0) {
        Throw-PipelineError -Code 'checkpoint_missing' -Message "Migration checkpoint does not exist: $Commit" -Status failed
    }
}

function Get-PipelineMigrationBranchName {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$RunId)

    if ($RunId.Length -lt 8) { Throw-PipelineError -Code 'invalid_run_id' -Message 'Run id is too short to form a migration branch.' -Status blocked }
    $suffix = $RunId.Substring($RunId.Length - 8)
    if ($suffix -notmatch '^[a-f0-9]{8}$') { Throw-PipelineError -Code 'invalid_run_id' -Message 'Run id suffix cannot form a migration branch.' -Status blocked }
    return "migration/angular-$($State.sourceMajor)-to-$($State.targetMajor)-$suffix"
}

function Set-PipelineRecoveryOutcome {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        $Details = $null
    )

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $stage = [string]$state.stage
    if ($state.activeOperation) { Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null }
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $diagnostic = [PSCustomObject]@{ code = $Code; message = $Message; details = $Details }
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus $state.status -ExpectedStage $stage -NewStatus $Status -NewStage $stage -ExpectedRevision $state.stageRevision -Diagnostic $diagnostic | Out-Null
    if ($Status -in @('blocked', 'failed')) { Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $RunId }
}

function Invoke-PipelineActiveOperationRecovery {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if (-not $state.activeOperation) { return $state }
    $operation = $state.activeOperation
    $operationId = [string]$operation.id
    $mutating = $operationId -in @('create-branch', 'update-angular', 'update-dependencies', 'install')
    $finish = Get-PipelineOperationFinish -ProjectRoot $ProjectRoot -RunId $RunId -Operation $operation

    if ($finish) {
        if ($mutating -and $operationId -ne 'install') {
            $confirmedCommit = [string]$finish.newCommit
            Assert-PipelineCommitExists -ProjectRoot $ProjectRoot -Commit $confirmedCommit
            $head = Get-PipelineGitHead -ProjectRoot $ProjectRoot
            if ($head -cne $confirmedCommit) {
                Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'blocked' -Code 'git_head_changed' -Message 'Git HEAD differs from the confirmed operation checkpoint.' -Details ([PSCustomObject]@{ expected = $confirmedCommit; actual = $head })
                return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
            }
            if ($operationId -eq 'create-branch') {
                $branchResult = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
                if ($branchResult.exitCode -ne 0 -or [string]$branchResult.stdout.Trim() -ne (Get-PipelineMigrationBranchName -State $state -RunId $RunId)) {
                    Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'blocked' -Code 'git_head_changed' -Message 'The confirmed migration branch is not checked out.' -Details $branchResult.stderr
                    return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
                }
                $state.migrationBranch = [string]$branchResult.stdout.Trim()
                Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
            }
            $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id $operationId -Stage $operation.stage -CheckpointCommit $confirmedCommit
            return $state
        }
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id $operationId -Stage $operation.stage
        return $state
    }

    if (-not $mutating) {
        Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'operation-recovered' -Stage $operation.stage -Data ([PSCustomObject]@{ id = $operationId; action = 'rerun' })
        return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    }

    try {
        Assert-PipelineCommitExists -ProjectRoot $ProjectRoot -Commit ([string]$operation.checkpointCommit)
        $head = Get-PipelineGitHead -ProjectRoot $ProjectRoot
        if ($head -cne [string]$operation.checkpointCommit) {
            Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'blocked' -Code 'git_head_changed' -Message 'Git HEAD changed while a migration operation was interrupted.' -Details ([PSCustomObject]@{ expected = $operation.checkpointCommit; actual = $head })
            return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        }
        $before = @(Get-PipelineOperationPreexistingItems -Operation $operation)
        $after = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
        $beforePaths = @($before | ForEach-Object { $_.path })
        $dirty = @($after | Where-Object { $_.path -notin $beforePaths }).Count -gt 0
        if ($dirty) {
            Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit ([string]$operation.checkpointCommit) -BeforeItems $before
        }
        Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'blocked' -Code 'interrupted_operation_rolled_back' -Message 'An interrupted mutating operation was restored to its checkpoint and requires explicit review.' -Details ([PSCustomObject]@{ operation = $operationId; rolledBack = $dirty; checkpointCommit = $operation.checkpointCommit })
    }
    catch {
        $errorInfo = Get-PipelineRunError -ErrorRecord $_
        try { Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'failed' -Code ([string]$errorInfo.code) -Message ([string]$errorInfo.message) -Details $errorInfo.details } catch { }
    }
    return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
}

function Assert-PipelineRunGitContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$State,
        [switch]$AllowDirty
    )

    Assert-PipelineCommitExists -ProjectRoot $ProjectRoot -Commit ([string]$State.checkpointCommit)
    $head = Get-PipelineGitHead -ProjectRoot $ProjectRoot
    if ($State.migrationBranch) {
        $branch = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
        if ($branch.exitCode -ne 0 -or [string]$branch.stdout.Trim() -cne [string]$State.migrationBranch) {
            Throw-PipelineError -Code 'git_head_changed' -Message 'The migration branch is not checked out.' -Status blocked -Details ([PSCustomObject]@{ expectedBranch = $State.migrationBranch; actualBranch = $branch.stdout.Trim() })
        }
    }
    elseif ($State.initialBranch) {
        $branch = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
        if ($branch.exitCode -ne 0 -or [string]$branch.stdout.Trim() -cne [string]$State.initialBranch) {
            Throw-PipelineError -Code 'git_head_changed' -Message 'The initial project branch is not checked out.' -Status blocked -Details ([PSCustomObject]@{ expectedBranch = $State.initialBranch; actualBranch = $branch.stdout.Trim() })
        }
    }
    if ($head -cne [string]$State.checkpointCommit) {
        Throw-PipelineError -Code 'git_head_changed' -Message 'Git HEAD differs from the migration checkpoint.' -Status blocked -Details ([PSCustomObject]@{ expected = $State.checkpointCommit; actual = $head })
    }
    $status = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    Assert-PipelineNoProtectedChanges -StatusItems $status
    if (-not $AllowDirty -and $status.Count -gt 0) {
        Throw-PipelineError -Code 'git_dirty' -Message 'The migration working tree must be clean before resuming.' -Status blocked -Details ([PSCustomObject]@{ paths = @($status.path) })
    }
}

function New-PipelineCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $status = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    Assert-PipelineNoProtectedChanges -StatusItems $status
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $preexisting = @{}
    if ($state.activeOperation -and $state.activeOperation.preexistingFiles) {
        foreach ($item in @(Get-PipelineOperationPreexistingItems -Operation $state.activeOperation)) { $preexisting[[string]$item.path] = $true }
    }
    $paths = @($status | Where-Object { -not $preexisting.ContainsKey($_.path) } | Select-Object -ExpandProperty path -Unique)
    if ($paths.Count -eq 0) { return Get-PipelineGitHead -ProjectRoot $ProjectRoot }
    $add = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments (@('add', '--') + $paths)
    if ($add.exitCode -ne 0) { Throw-PipelineError -Code 'checkpoint_add_failed' -Message 'Could not stage the exact migration paths.' -Status failed -Details $add.stderr }
    $commit = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('commit', '-m', $Message)
    if ($commit.exitCode -ne 0) { Throw-PipelineError -Code 'checkpoint_commit_failed' -Message 'Could not create the migration checkpoint.' -Status failed -Details $commit.stderr }
    return Get-PipelineGitHead -ProjectRoot $ProjectRoot
}

function Invoke-PipelineRollback {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$CheckpointCommit,
        [Parameter(Mandatory = $true)]$BeforeItems
    )

    $after = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $restoredFiles = @()
    $removedUntrackedFiles = @()
    $beforePaths = @($BeforeItems | Select-Object -ExpandProperty path -Unique)
    $beforeUntracked = @($BeforeItems | Where-Object untracked | Select-Object -ExpandProperty path -Unique)
    $beforePathMap = @{}
    foreach ($path in $beforePaths) { $beforePathMap[[string]$path] = $true }
    $trackedPaths = @($after | Where-Object { -not $_.untracked -and -not $beforePathMap.ContainsKey($_.path) } | Select-Object -ExpandProperty path -Unique)
    foreach ($path in $trackedPaths) {
        $restore = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('restore', '--source', $CheckpointCommit, '--staged', '--worktree', '--', $path)
        if ($restore.exitCode -ne 0) { Throw-PipelineError -Code 'rollback_failed' -Message "Could not restore tracked path: $path" -Status failed -Details $restore.stderr }
        $restoredFiles += $path
    }
    $beforeUntrackedMap = @{}
    foreach ($path in $beforeUntracked) { $beforeUntrackedMap[$path] = $true }
    foreach ($item in @($after | Where-Object untracked)) {
        if (-not $beforeUntrackedMap.ContainsKey($item.path)) {
            $fullPath = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path $item.path
            if (Test-Path -LiteralPath $fullPath -PathType Container) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
            elseif (Test-Path -LiteralPath $fullPath -PathType Leaf) { Remove-Item -LiteralPath $fullPath -Force }
            $removedUntrackedFiles += $item.path
        }
    }
    $remaining = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $remainingPaths = @($remaining | Select-Object -ExpandProperty path -Unique | Sort-Object)
    $expectedPaths = @($BeforeItems | Select-Object -ExpandProperty path -Unique | Sort-Object)
    if (($remainingPaths -join '|') -cne ($expectedPaths -join '|')) {
        Throw-PipelineError -Code 'rollback_failed' -Message 'Rollback did not restore the previous working tree inventory.' -Status failed -Details ([PSCustomObject]@{ expected = $expectedPaths; actual = $remainingPaths })
    }
    $headAfterRollback = Get-PipelineGitHead -ProjectRoot $ProjectRoot
    if ($headAfterRollback -cne $CheckpointCommit) {
        Throw-PipelineError -Code 'rollback_failed' -Message 'Rollback changed Git HEAD unexpectedly.' -Status failed -Details ([PSCustomObject]@{ expected = $CheckpointCommit; actual = $headAfterRollback })
    }
    return [PSCustomObject]@{
        checkpointCommit      = $CheckpointCommit
        headAfterRollback     = $headAfterRollback
        restoredFiles         = @($restoredFiles | Sort-Object -Unique)
        removedUntrackedFiles = @($removedUntrackedFiles | Sort-Object -Unique)
        gitStatusClean        = $remaining.Count -eq 0
        gitInventoryVerified  = $true
    }
}

function Get-PipelineLocalNg {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $path = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'node_modules/.bin/ng.cmd'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Throw-PipelineError -Code 'local_angular_cli_missing' -Message 'The project local Angular CLI was not found at node_modules/.bin/ng.cmd.' -Status blocked
    }
    return $path
}

function Get-PipelineRuntimeProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ProfileId
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    if ($state.runtimePlan -and (Get-PipelineObjectHash -Value ([PSCustomObject]$state.runtimePlan)) -cne (Get-PipelineObjectHash -Value ([PSCustomObject]$manifest.runtimePlan))) {
        Throw-PipelineError -Code 'runtime_plan_invalidated' -Message 'The run runtime plan differs between state and manifest.' -Status blocked
    }
    $profile = @($manifest.runtimePlan.profiles | Where-Object id -ceq $ProfileId)
    if ($profile.Count -ne 1) {
        Throw-PipelineError -Code 'runtime_profile_missing' -Message "Runtime profile is not present in the immutable plan: $ProfileId" -Status blocked
    }
    $profile = $profile[0]
    if ($profile.status -ne 'installed' -or [string]::IsNullOrWhiteSpace([string]$profile.selectedNodeVersion)) {
        Throw-PipelineError -Code 'runtime_missing' -Message "The selected runtime is not installed for profile $ProfileId." -Status blocked -Details $profile
    }
    $fnmPath = if ($state.runtimeFnmPath) { [string]$state.runtimeFnmPath } else { [string]$manifest.project.runtimeToolchain.fnm.executable }
    if ([string]::IsNullOrWhiteSpace($fnmPath)) {
        Throw-PipelineError -Code 'fnm_missing' -Message 'The immutable run plan does not contain an fnm executable.' -Status blocked
    }
    try {
        $identity = Get-MigrationNodeIdentity -FnmPath $fnmPath -NodeVersion ([string]$profile.selectedNodeVersion) -WorkingDirectory $root -TimeoutSeconds 60
    }
    catch {
        Throw-PipelineError -Code 'runtime_missing' -Message "The selected runtime is unavailable for profile $ProfileId." -Status blocked -Details $_.Exception.Message
    }
    if ($identity.status -ne 'usable' -or $identity.nodeVersion -cne [string]$profile.selectedNodeVersion) {
        Throw-PipelineError -Code 'runtime_identity_mismatch' -Message "The selected runtime identity does not match profile $ProfileId." -Status blocked -Details $identity
    }
    return [PSCustomObject]@{
        id          = $ProfileId
        nodeVersion = [string]$profile.selectedNodeVersion
        npmVersion  = [string]$identity.npmVersion
        fnmPath     = $fnmPath
    }
}

function Get-PipelineResolvedDependencies {
    param([Parameter(Mandatory = $true)]$Manifest)
    return @($Manifest.dependencies | Sort-Object name)
}

function Get-PipelineAngularUpdateCommands {
    param([Parameter(Mandatory = $true)]$Manifest)

    $dependencies = @(Get-PipelineResolvedDependencies -Manifest $Manifest | Where-Object { $_.change -ne 'unchanged' })
    $core = @($dependencies | Where-Object name -eq '@angular/core' | Select-Object -First 1)
    $cli = @($dependencies | Where-Object name -eq '@angular/cli' | Select-Object -First 1)
    if ($core.Count -ne 1 -or $cli.Count -ne 1) {
        Throw-PipelineError -Code 'angular_cli_missing' -Message 'Resolved manifest must contain exact @angular/core and @angular/cli entries.' -Status blocked
    }
    $commands = @([PSCustomObject]@{ id = 'angular-core-cli'; arguments = @('update', "@angular/core@$($core[0].targetVersion)", "@angular/cli@$($cli[0].targetVersion)") })
    $official = @($dependencies | Where-Object { $_.name -like '@angular/*' -and $_.name -notin @('@angular/core', '@angular/cli') -and $null -ne $_.metadata.ngUpdate } | Sort-Object name)
    foreach ($dependency in $official) {
        $commands += [PSCustomObject]@{ id = $dependency.name; arguments = @('update', "$($dependency.name)@$($dependency.targetVersion)") }
    }
    $external = @($dependencies | Where-Object { $_.role -eq 'angular-aware-external' -and $null -ne $_.metadata.ngUpdate } | Sort-Object name)
    foreach ($dependency in $external) {
        $commands += [PSCustomObject]@{ id = $dependency.name; arguments = @('update', "$($dependency.name)@$($dependency.targetVersion)") }
    }
    return @($commands)
}

function Assert-PipelineManifestTargets {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$FnmPath = '',
        [string]$NodeVersion = ''
    )

    try { $package = Get-ProjectPackage -ProjectRoot $ProjectRoot } catch { Throw-PipelineError -Code 'package_invalid' -Message 'package.json is invalid after migration.' -Status blocked }
    $angularNames = @($Manifest.dependencies | Where-Object { $_.name -like '@angular/*' } | Select-Object -ExpandProperty name)
    foreach ($name in $angularNames) {
        $entry = $Manifest.dependencies | Where-Object name -eq $name | Select-Object -First 1
        $section = Get-ProjectProperty -Object $package -Name $entry.section
        if ($null -eq $section -or -not $section.PSObject.Properties[$name]) { continue }
        $major = Get-VersionMajor -Spec ([string]$section.$name)
        if ($null -ne $major -and $major -gt [int]$Manifest.targetMajor) {
            Throw-PipelineError -Code 'angular_target_exceeded' -Message "Angular package exceeds target major: $name" -Status blocked
        }
    }
    try { Get-ProjectLockfile -ProjectRoot $ProjectRoot -FnmPath $FnmPath -NodeVersion $NodeVersion | Out-Null } catch { Throw-PipelineError -Code 'lockfile_invalid' -Message 'package-lock.json is invalid after Angular update.' -Status blocked }
    Assert-PipelineNoProtectedChanges -StatusItems @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
}

function Invoke-PipelineRenderer {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)][ValidateSet('exact', 'declared')][string]$Mode,
        [Parameter(Mandatory = $true)]$Dependencies,
        [Parameter(Mandatory = $true)][string]$FnmPath,
        [Parameter(Mandatory = $true)][string]$NodeVersion
    )

    $helper = $script:PackageRendererPath
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        Throw-PipelineError -Code 'package_manifest_writer_missing' -Message 'The package manifest renderer is missing from the plugin.' -Status failed
    }
    $packagePath = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json' -MustExist
    $packageText = [IO.File]::ReadAllText($packagePath)
    $payload = [ordered]@{ mode = $Mode; packageText = $packageText; dependencies = @($Dependencies) }
    $inputText = $payload | ConvertTo-Json -Depth 50 -Compress
    $result = Invoke-PipelineLoggedProcess -RunPaths $RunPaths -Stage 'update-dependencies' -Prefix ('01-render-' + $Mode) -FilePath 'node' -Arguments @($helper) -WorkingDirectory $ProjectRoot -TimeoutSeconds 30 -StandardInput $inputText -NodeVersion $NodeVersion -FnmPath $FnmPath
    if ($result.exitCode -ne 0 -or $result.timedOut) {
        Throw-PipelineError -Code 'package_manifest_write_failed' -Message "package.json renderer failed in $Mode mode." -Status blocked -Details ([PSCustomObject]@{ stderrLog = $result.stderrLog; stdoutLog = $result.stdoutLog })
    }
    return [PSCustomObject]@{ text = $result.stdout; logs = $result }
}

function Get-PipelineVersionTuple {
    param([Parameter(Mandatory = $true)][string]$Version)

    $match = [regex]::Match($Version, '^([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if (-not $match.Success) { return @() }
    return @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Compare-PipelineVersionTuple {
    param(
        [Parameter(Mandatory = $true)][int[]]$Left,
        [Parameter(Mandatory = $true)][int[]]$Right
    )

    for ($index = 0; $index -lt 3; $index++) {
        if ($Left[$index] -lt $Right[$index]) { return -1 }
        if ($Left[$index] -gt $Right[$index]) { return 1 }
    }
    return 0
}

function Test-PipelineVersionSpec {
    param([Parameter(Mandatory = $true)][string]$Spec, [Parameter(Mandatory = $true)][string]$Version)

    $versionTuple = @(Get-PipelineVersionTuple -Version $Version)
    if ($versionTuple.Count -ne 3) { return $false }
    if ($Spec -eq $Version) { return $true }

    $match = [regex]::Match($Spec, '^\^([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if ($match.Success) {
        $baseTuple = @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
        $upperTuple = if ($baseTuple[0] -gt 0) {
            @(($baseTuple[0] + 1), 0, 0)
        }
        elseif ($baseTuple[1] -gt 0) {
            @(0, ($baseTuple[1] + 1), 0)
        }
        else {
            @(0, 0, ($baseTuple[2] + 1))
        }
        return (Compare-PipelineVersionTuple -Left $versionTuple -Right $baseTuple) -ge 0 -and
        (Compare-PipelineVersionTuple -Left $versionTuple -Right $upperTuple) -lt 0
    }

    $match = [regex]::Match($Spec, '^~([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if ($match.Success) {
        $baseTuple = @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
        $upperTuple = @($baseTuple[0], ($baseTuple[1] + 1), 0)
        return (Compare-PipelineVersionTuple -Left $versionTuple -Right $baseTuple) -ge 0 -and
        (Compare-PipelineVersionTuple -Left $versionTuple -Right $upperTuple) -lt 0
    }

    $match = [regex]::Match($Spec, '^>=([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if ($match.Success) {
        $baseTuple = @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
        return (Compare-PipelineVersionTuple -Left $versionTuple -Right $baseTuple) -ge 0
    }

    $match = [regex]::Match($Spec, '^([0-9]+)\.(x|X|\*)$')
    if ($match.Success) { return $versionTuple[0] -eq [int]$match.Groups[1].Value }

    $match = [regex]::Match($Spec, '^([0-9]+)\.([0-9]+)\.(x|X|\*)$')
    if ($match.Success) {
        return $versionTuple[0] -eq [int]$match.Groups[1].Value -and $versionTuple[1] -eq [int]$match.Groups[2].Value
    }

    return $false
}

function Assert-PipelineDirectDependencyLock {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$FnmPath = '',
        [string]$NodeVersion = ''
    )
    $lock = Get-ProjectLockfile -ProjectRoot $ProjectRoot -FnmPath $FnmPath -NodeVersion $NodeVersion
    foreach ($dependency in @($Manifest.dependencies)) {
        $locked = [string]$lock.versions[$dependency.name]
        if ($locked -cne [string]$dependency.targetVersion) {
            Throw-PipelineError -Code 'lockfile_resolution_mismatch' -Message "Lockfile version differs from manifest: $($dependency.name)" -Status blocked -Details ([PSCustomObject]@{ expected = $dependency.targetVersion; actual = $locked })
        }
    }
    return $lock
}

function Assert-PipelineDeclaredDependencies {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)]$Manifest)
    $package = Get-ProjectPackage -ProjectRoot $ProjectRoot
    $expected = @{}
    foreach ($dependency in @($Manifest.dependencies)) {
        $section = Get-ProjectProperty -Object $package -Name $dependency.section
        if ($dependency.change -eq 'added-required-tooling' -and $dependency.section -eq 'devDependencies') {
            if ($null -eq $section -or -not $section.PSObject.Properties[$dependency.name]) {
                Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Required tooling was not added to package.json: $($dependency.name)" -Status blocked
            }
            $expected[$dependency.name] = $dependency.section
            if (-not (Test-PipelineVersionSpec -Spec ([string]$section.$($dependency.name)) -Version ([string]$dependency.targetVersion))) {
                Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Declared spec does not admit locked version: $($dependency.name)" -Status blocked
            }
            continue
        }
        if ($null -eq $section -or -not $section.PSObject.Properties[$dependency.name]) {
            Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Manifest dependency is missing after rendering: $($dependency.name)" -Status blocked
        }
        $expected[$dependency.name] = $dependency.section
        if (-not (Test-PipelineVersionSpec -Spec ([string]$section.$($dependency.name)) -Version ([string]$dependency.targetVersion))) {
            Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Declared spec does not admit locked version: $($dependency.name)" -Status blocked
        }
    }
    foreach ($sectionName in $script:DependencySections) {
        $section = Get-ProjectProperty -Object $package -Name $sectionName
        if ($null -eq $section) { continue }
        foreach ($property in $section.PSObject.Properties) {
            if (-not $expected.ContainsKey($property.Name) -or $expected[$property.Name] -cne $sectionName) {
                Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Direct dependency was added or moved without a manifest decision: $($property.Name)" -Status blocked
            }
        }
    }
}

function Get-PipelineRepairPaths {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$CheckId,
        [string]$Output,
        [switch]$ConfigRepairAllowed
    )

    $paths = @()
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    foreach ($match in [regex]::Matches([string]$Output, '(?:^|[\s(])(src[\\/][a-zA-Z0-9_./\\-]+)(?::\d+(?::\d+)?)?')) {
        $candidate = $match.Groups[1].Value.TrimEnd('.', ',', ';')
        if ($candidate -notmatch '(^|[\\/])\.\.([\\/]|$)') {
            try { $paths += ConvertTo-PipelineRelativePath -ProjectRoot $root -Path $candidate } catch { }
        }
    }
    $configFiles = @('angular.json', 'tsconfig.json', 'tsconfig.app.json', 'tsconfig.spec.json', 'tsconfig.base.json', '.eslintrc.json', '.eslintrc.js', 'eslint.config.js', 'tslint.json', 'karma.conf.js', 'jest.config.js', 'browserslist', 'polyfills.ts')
    if ($Stage -eq 'update-angular' -and $ConfigRepairAllowed -and $Output -cmatch '(?<![\w/\\.-])angular\.json(?=[:\s(]|$)') { $paths += 'angular.json' }
    if ($Stage -ne 'update-angular') {
        if ($CheckId -notin @('typecheck', 'lint', 'test', 'unit-test', 'build', 'e2e')) { return @() }
        $paths += 'src/**/*'
        foreach ($file in $configFiles) {
            if ($Output -cmatch ('(?<![\w/\\.-])' + [regex]::Escape($file) + '(?=[:\s(]|$)')) { $paths += $file }
        }
    }
    $paths = @($paths | Where-Object { $_ -and $_ -notmatch '^(?:\.git|\.github|\.angular-migration|docs)(?:/|$)' -and $_ -notin @('package.json', 'package-lock.json', 'plugin.json') } | Sort-Object -Unique)
    return $paths
}

function Get-RepairHistoryRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    Assert-MigrationRunId -RunId $RunId
    if ($Fingerprint -notmatch '^sha256:([0-9a-f]{64})$') {
        Throw-PipelineError -Code 'repair_history_fingerprint_invalid' -Message 'Repair history fingerprint is invalid.' -Status failed
    }
    return '.angular-migration/runs/' + $RunId + '/repair-history/' + $Matches[1] + '/repair.jsonl'
}

function Get-RepairHistoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $relative = Get-RepairHistoryRelativePath -RunId $RunId -Fingerprint $Fingerprint
    return Resolve-RepairPath -Root $root -Path $relative
}

function ConvertTo-RepairHistoryIoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path.Length -ge 248 -and $Path -match '^[A-Za-z]:\\') { return '\\?\' + $Path }
    return $Path
}

function Protect-RepairHistoryValue {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [int]$MaxLength = 4000
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $safe = Protect-RepairText -Text $Value -Root $ProjectRoot
        if ($safe.Length -gt $MaxLength) { return $safe.Substring(0, $MaxLength) }
        return $safe
    }
    if ($Value -is [array]) { return , @($Value | ForEach-Object { Protect-RepairHistoryValue -Value $_ -ProjectRoot $ProjectRoot -MaxLength $MaxLength }) }
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) { $result[[string]$key] = Protect-RepairHistoryValue -Value $Value[$key] -ProjectRoot $ProjectRoot -MaxLength $MaxLength }
        return $result
    }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -gt 0 -and $Value -isnot [ValueType]) {
        $result = [ordered]@{}
        foreach ($property in $properties) { $result[$property.Name] = Protect-RepairHistoryValue -Value $property.Value -ProjectRoot $ProjectRoot -MaxLength $MaxLength }
        return $result
    }
    return $Value
}

function Get-RepairHistorySchema {
    $path = Join-Path $PSScriptRoot '../../schemas/repair-history-entry.schema.json'
    try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Throw-PipelineError -Code 'repair_history_schema_invalid' -Message 'Repair history schema cannot be loaded.' -Status failed }
}

function Throw-RepairHistoryCorrupt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Sequence = 0,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Throw-PipelineError -Code 'repair_history_corrupt' -Message $Message -Status failed -Details ([PSCustomObject]@{ path = $Path; sequence = $Sequence })
}

function Assert-RepairHistoryEntries {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Entries,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    $schema = Get-RepairHistorySchema
    $seenIds = @{}
    $previousAttempt = 0
    $previousType = $null
    $previousEntry = $null
    $common = $null
    for ($index = 0; $index -lt @($Entries).Count; $index++) {
        $entry = $Entries[$index]
        $sequence = $index + 1
        try { Assert-MigrationJsonSchemaValue -Value $entry -Schema $schema -RootSchema $schema -Path '$' }
        catch { Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history entry does not match its schema.' }
        if ([int]$entry.sequence -ne $sequence -or $seenIds.ContainsKey([string]$entry.entryId)) {
            Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history sequence or entry identity is invalid.'
        }
        $seenIds[[string]$entry.entryId] = $true
        if ($entry.runId -cne $RunId -or $entry.fingerprint -cne $Fingerprint) {
            Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history identity does not match its path.'
        }
        $priorAttempt = $previousAttempt
        if ($previousAttempt -gt 0 -and [int]$entry.attempt -lt $previousAttempt) {
            Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history attempts are not monotonic.'
        }
        $previousAttempt = [int]$entry.attempt
        if ($null -eq $common) {
            $common = [PSCustomObject]@{ stage = [string]$entry.stage; failedCheck = [string]$entry.failedCheck; checkpointCommit = [string]$entry.checkpointCommit; manifestSha256 = [string]$entry.manifestSha256 }
        }
        elseif ($entry.stage -cne $common.stage -or $entry.failedCheck -cne $common.failedCheck -or
            $entry.checkpointCommit -cne $common.checkpointCommit -or $entry.manifestSha256 -cne $common.manifestSha256) {
            Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history entries do not share one repair context.'
        }
        if ([string]$entry.entrySha256 -cne (Get-PipelineObjectHash -Value $entry -ExcludedProperty 'entrySha256')) {
            Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history entry hash is invalid.'
        }
        if ($sequence -eq 1 -and $entry.type -notin @('context-issued', 'attempts-exhausted')) {
            Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history must begin with context-issued or attempts-exhausted.'
        }
        if ($previousEntry) {
            $allowedNext = switch ($previousType) {
                'context-issued' { @('submission-received', 'submission-rejected', 'attempts-exhausted'); break }
                'submission-received' { @('submission-rejected', 'submission-accepted'); break }
                'submission-rejected' { @('context-issued', 'attempts-exhausted'); break }
                'submission-accepted' { @('verification-failed', 'verification-passed'); break }
                'verification-failed' { if ($previousEntry.data.sameFingerprint -eq $true) { @('context-issued', 'attempts-exhausted') } else { @() }; break }
                default { @() }
            }
            if ($entry.type -notin $allowedNext) {
                Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history entry order is invalid.'
            }
            if ($entry.type -eq 'context-issued' -and [int]$entry.attempt -ne ($priorAttempt + 1)) {
                Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history context attempts are not sequential.'
            }
            if ($entry.type -ne 'context-issued' -and [int]$entry.attempt -ne $priorAttempt) {
                Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history entry attempt does not match its context.'
            }
        }
        if ($entry.type -eq 'context-issued' -and @($Entries | Where-Object { $_.type -eq 'context-issued' -and $_.attempt -eq $entry.attempt }).Count -gt 1) {
            Throw-RepairHistoryCorrupt -Path $Path -Sequence $sequence -Message 'Repair history issues one context more than once for an attempt.'
        }
        $previousType = [string]$entry.type
        $previousEntry = $entry
    }
    return $common
}

function Read-RepairHistory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $path = $null
    try { $path = Get-RepairHistoryPath -ProjectRoot $root -RunId $RunId -Fingerprint $Fingerprint }
    catch {
        if ($_.Exception.Data['code']) { throw }
        Throw-RepairHistoryCorrupt -Path (Join-Path $root '.angular-migration/runs') -Sequence 0 -Message 'Repair history path is not canonical.'
    }
    $ioPath = ConvertTo-RepairHistoryIoPath -Path $path
    if (-not [IO.File]::Exists($ioPath)) {
        return [PSCustomObject]@{ path = $path; exists = $false; entries = @(); entryCount = 0 }
    }
    try {
        if ([IO.File]::GetAttributes($ioPath) -band [IO.FileAttributes]::ReparsePoint) { throw 'Repair history is a reparse point.' }
        $bytes = [IO.File]::ReadAllBytes($ioPath)
        if ($bytes.Length -eq 0 -or ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)) { throw 'Repair history is empty or has a BOM.' }
        $decoder = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
        $text = $decoder.GetString($bytes)
        if (-not $text.EndsWith("`n")) { throw 'Repair history does not end with a newline.' }
        $lines = @($text -split "`n")
        if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
        if ($lines.Count -eq 0) { throw 'Repair history has no entries.' }
        $entries = @()
        foreach ($line in $lines) {
            $jsonLine = $line.TrimEnd("`r")
            if ([string]::IsNullOrWhiteSpace($jsonLine)) { throw 'Repair history contains an empty line.' }
            $jsonParameters = @{}
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonParameters.DateKind = 'String' }
            $entries += ($jsonLine | ConvertFrom-Json @jsonParameters)
        }
        $common = Assert-RepairHistoryEntries -ProjectRoot $root -Path $path -Entries $entries -RunId $RunId -Fingerprint $Fingerprint
        return [PSCustomObject]@{ path = $path; exists = $true; entries = @($entries); entryCount = @($entries).Count; checkpointCommit = [string]$common.checkpointCommit; stage = [string]$common.stage; failedCheck = [string]$common.failedCheck; manifestSha256 = [string]$common.manifestSha256 }
    }
    catch {
        if ($_.Exception.Data['code'] -eq 'repair_history_corrupt') { throw }
        Throw-RepairHistoryCorrupt -Path $path -Sequence 0 -Message 'Repair history cannot be read as valid UTF-8 JSONL.'
    }
}

function Get-RepairAttemptSummary {
    param([Parameter(Mandatory = $true)]$History)

    $entries = @($History.entries)
    $rejected = @($entries | Where-Object { $_.type -eq 'submission-rejected' }).Count
    $verificationFailed = @($entries | Where-Object { $_.type -eq 'verification-failed' }).Count
    $sameFingerprintFailures = @($entries | Where-Object { $_.type -eq 'verification-failed' -and $_.data.sameFingerprint -eq $true }).Count
    $accepted = @($entries | Where-Object { $_.type -eq 'submission-accepted' }).Count
    $consumed = $rejected + $verificationFailed
    $last = @($entries | Where-Object { $_.type -notin @('context-issued', 'submission-received') } | Select-Object -Last 1)
    $last = if ($last.Count -gt 0) { $last[0] } else { $null }
    $nextAttempt = 1 + $rejected + $sameFingerprintFailures
    return [PSCustomObject]@{
        path = $History.path; entryCount = $entries.Count; previousAttempts = $rejected + $sameFingerprintFailures
        nextAttempt = $nextAttempt; consumedAttempts = $consumed; lastOutcome = if ($last) { [string]$last.type } else { $null }
        pendingVerification = $entries.Count -gt 0 -and $entries[-1].type -eq 'submission-accepted'
        terminal = $entries.Count -gt 0 -and $entries[-1].type -in @('verification-passed', 'attempts-exhausted')
    }
}

function Get-RepairRunAttemptSummary {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $relativeRoot = '.angular-migration/runs/' + $RunId + '/repair-history'
    try { $historyRoot = Resolve-RepairPath -Root $root -Path $relativeRoot }
    catch {
        if ($_.Exception.Data['code']) { throw }
        Throw-RepairHistoryCorrupt -Path (Join-Path $root $relativeRoot) -Sequence 0 -Message 'Repair history root is not canonical.'
    }
    if (-not (Test-Path -LiteralPath $historyRoot -PathType Container)) {
        return [PSCustomObject]@{ consumedAttempts = 0; histories = @(); lastOutcome = $null }
    }
    $rootItem = Get-Item -LiteralPath $historyRoot -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { Throw-RepairHistoryCorrupt -Path $historyRoot -Sequence 0 -Message 'Repair history root is a reparse point.' }
    $histories = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $historyRoot -Force)) {
        if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $directory.Name -notmatch '^[0-9a-f]{64}$') {
            Throw-RepairHistoryCorrupt -Path $historyRoot -Sequence 0 -Message 'Repair history contains an invalid fingerprint directory.'
        }
        $history = Read-RepairHistory -ProjectRoot $root -RunId $RunId -Fingerprint ('sha256:' + $directory.Name)
        if ($history.exists) { $histories += $history }
    }
    $summary = @($histories | ForEach-Object { Get-RepairAttemptSummary -History $_ })
    return [PSCustomObject]@{
        consumedAttempts = [int](($summary | Measure-Object -Property consumedAttempts -Sum).Sum)
        histories        = @($histories)
        lastOutcome      = if ($summary.Count -gt 0) { $summary[-1].lastOutcome } else { $null }
    }
}

function Get-PipelineRepairEvents {
    param([Parameter(Mandatory = $true)][string]$EventsPath)

    if (-not (Test-Path -LiteralPath $EventsPath -PathType Leaf)) { return @() }
    $events = @()
    foreach ($line in @(Get-Content -LiteralPath $EventsPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events += ($line | ConvertFrom-Json) } catch { }
    }
    return @($events)
}

function Assert-PipelineRepairAcceptedEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Entry
    )

    $report = [string]$Entry.data.report
    $prefix = '.angular-migration/runs/' + $RunId + '/repairs/'
    if (-not $report.StartsWith($prefix, [StringComparison]::Ordinal) -or $report -match '(^|/|\\)\.\.($|/|\\)') {
        Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Accepted repair report is outside the run.' -Status failed
    }
    $reportPath = Resolve-RepairPath -Root $ProjectRoot -Path $report
    $reportIoPath = ConvertTo-RepairHistoryIoPath -Path $reportPath
    if (-not [IO.File]::Exists($reportIoPath)) {
        Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Accepted repair report is missing.' -Status failed
    }
    $reportItem = [IO.FileInfo]::new($reportIoPath)
    if ($reportItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Accepted repair report is linked.' -Status failed
    }
    $reportHash = [Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($reportIoPath))
    $reportHash = ([BitConverter]::ToString($reportHash) -replace '-', '').ToLowerInvariant()
    if ($reportHash -cne [string]$Entry.data.reportSha256) {
        Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Accepted repair report hash differs from history.' -Status failed
    }
    Assert-PipelineCommitExists -ProjectRoot $ProjectRoot -Commit ([string]$Entry.data.commit)
    if ((Get-PipelineGitHead -ProjectRoot $ProjectRoot) -cne [string]$Entry.data.commit) {
        Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Accepted repair commit is not the current Git HEAD.' -Status failed
    }
}

function Set-PipelineRepairHistoryMirror {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$History,
        [Parameter(Mandatory = $true)]$HistorySummary,
        [Parameter(Mandatory = $true)][int]$ConsumedAttempts
    )

    $State.repairTotal = $ConsumedAttempts
    if ($State.repair -and $State.repair.context -and $State.repair.context.PSObject.Properties['history']) {
        $State.repair.context.history.path = Get-RepairHistoryRelativePath -RunId $State.runId -Fingerprint $State.repair.context.fingerprint
        $State.repair.context.history.entryCount = [int]$History.entryCount
        $State.repair.context.history.previousAttempts = [int]$HistorySummary.previousAttempts
        $State.repair.context.history.lastOutcome = $HistorySummary.lastOutcome
    }
}

function Add-PipelineRepairAcceptedEventIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Accepted,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $eventsPath = (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId).events
    $events = @(Get-PipelineRepairEvents -EventsPath $eventsPath)
    $matching = @($events | Where-Object {
            $_.type -eq 'repair-accepted' -and $_.data -and
            $_.data.fingerprint -ceq $Accepted.fingerprint -and
            [int]$_.data.attempt -eq [int]$Accepted.attempt
        })
    foreach ($event in $matching) {
        if ([string]$event.data.commit -cne [string]$Accepted.commit -or [string]$event.data.reportSha256 -cne [string]$Accepted.reportSha256) {
            Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Repair accepted event conflicts with history.' -Status failed
        }
    }
    if ($matching.Count -eq 0) {
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'repair-accepted' -Stage $Stage -Data ([PSCustomObject]@{
                fingerprint = $Accepted.fingerprint; attempt = $Accepted.attempt; commit = $Accepted.commit
                report = $Accepted.report; reportSha256 = $Accepted.reportSha256
            })
    }
}

function Add-PipelineRepairRequiredEventIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Fingerprint,
        [Parameter(Mandatory = $true)][int]$Attempt
    )

    $eventsPath = (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId).events
    $events = @(Get-PipelineRepairEvents -EventsPath $eventsPath)
    if (@($events | Where-Object {
                $_.type -eq 'repair-required' -and $_.data -and
                $_.data.fingerprint -ceq $Fingerprint -and [int]$_.data.attempt -eq $Attempt
            }).Count -eq 0) {
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'repair-required' -Stage $Stage -Data ([PSCustomObject]@{
                fingerprint = $Fingerprint; attempt = $Attempt
            })
    }
}

function Get-PipelinePersistedRepairFailureOutput {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Entry
    )

    $parts = @()
    foreach ($log in @($Entry.data.logFiles)) {
        if ($log -isnot [string] -or [string]::IsNullOrWhiteSpace($log)) { continue }
        $relative = [string]$log
        $runPrefix = '.angular-migration/runs/' + $RunId + '/'
        if ($relative.StartsWith($runPrefix, [StringComparison]::Ordinal)) {
            $relative = $relative.Substring($runPrefix.Length)
        }
        try {
            $full = Resolve-RepairPath -Root $ProjectRoot -Path ('.angular-migration/runs/' + $RunId + '/' + $relative)
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $item = Get-Item -LiteralPath $full -Force
                if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $parts += [IO.File]::ReadAllText($full) }
            }
        }
        catch { }
    }
    if ($parts.Count -eq 0) { return [string]$Entry.data.diagnosticSummary }
    return ($parts -join "`n")
}

function Invoke-PipelineRepairHistoryRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.status -notin @('running', 'needs-repair') -or -not $state.repair -or -not $state.repair.context) { return $state }
    $context = $state.repair.context
    $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint
    if (-not $history.exists) { return $state }
    $historySummary = Get-RepairAttemptSummary -History $history
    $runSummary = Get-RepairRunAttemptSummary -ProjectRoot $ProjectRoot -RunId $RunId
    $acceptedEntry = @($history.entries | Where-Object {
            $_.type -eq 'submission-accepted' -and [int]$_.attempt -eq [int]$context.attempt
        } | Select-Object -Last 1)
    if ($acceptedEntry.Count -gt 0) {
        Assert-PipelineRepairAcceptedEvidence -ProjectRoot $ProjectRoot -RunId $RunId -Entry $acceptedEntry[0]
        $accepted = [PSCustomObject]@{
            fingerprint  = [string]$context.fingerprint
            attempt      = [int]$acceptedEntry[0].attempt
            commit       = [string]$acceptedEntry[0].data.commit
            report       = [string]$acceptedEntry[0].data.report
            reportSha256 = [string]$acceptedEntry[0].data.reportSha256
        }
        $postAcceptanceOutcome = @($history.entries | Where-Object {
                [int]$_.sequence -gt [int]$acceptedEntry[0].sequence -and
                [int]$_.attempt -eq [int]$acceptedEntry[0].attempt -and
                $_.type -in @('verification-passed', 'verification-failed')
            } | Select-Object -Last 1)
        if ($state.repair.accepted -and (
                [string]$state.repair.accepted.commit -cne $accepted.commit -or
                [string]$state.repair.accepted.reportSha256 -cne $accepted.reportSha256)) {
            Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'State accepted repair conflicts with history.' -Status failed
        }
        $existing = @($state.repairs | Where-Object { $_.fingerprint -ceq $accepted.fingerprint -and [int]$_.attempt -eq $accepted.attempt })
        foreach ($item in $existing) {
            if ([string]$item.commit -cne $accepted.commit -or [string]$item.reportSha256 -cne $accepted.reportSha256) {
                Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Accepted repair summary conflicts with history.' -Status failed
            }
        }
        if ($existing.Count -eq 0) { $state.repairs = @($state.repairs) + $accepted }
        $state.checkpointCommit = $accepted.commit
        Set-PipelineRepairHistoryMirror -State $state -History $history -HistorySummary $historySummary -ConsumedAttempts $runSummary.consumedAttempts
        Add-PipelineRepairAcceptedEventIfMissing -ProjectRoot $ProjectRoot -RunId $RunId -Accepted $accepted -Stage $context.stage
        if ($postAcceptanceOutcome.Count -gt 0 -and $postAcceptanceOutcome[0].type -eq 'verification-passed') {
            $state.repair = $null
            Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
            $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
            if ($state.status -eq 'needs-repair') {
                Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'needs-repair' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus 'running' -NewStage $state.stage | Out-Null
            }
            return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        }
        $state.repair.accepted = $accepted
        $state.repair.context.checkpointCommit = $accepted.commit
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
        if ($postAcceptanceOutcome.Count -gt 0 -and $postAcceptanceOutcome[0].type -eq 'verification-failed') {
            $failure = $postAcceptanceOutcome[0]
            $failureOutput = Get-PipelinePersistedRepairFailureOutput -ProjectRoot $ProjectRoot -RunId $RunId -Entry $failure
            $failureCode = if ($context.stage -ceq 'update-angular') { 'angular_update_failed' } else { 'validation_failed' }
            $issuedContext = New-PipelineFailureContext -ProjectRoot $ProjectRoot -RunPaths (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId) -Stage $context.stage -CheckId ([string]$failure.data.checkId) -Code $failureCode -Message ([string]$failure.data.diagnosticSummary) -Output $failureOutput -ExitCode ([int]$failure.data.exitCode) -LogFiles @($failure.data.logFiles)
            if (@($issuedContext.allowedPaths).Count -eq 0) {
                Throw-PipelineError -Code 'repair_scope_unknown' -Message 'Persisted verification failure has no safe repair scope.' -Status blocked -Details $issuedContext
            }
            $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
            if ($state.status -eq 'running') {
                $state = Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus 'needs-repair' -NewStage $state.stage
            }
            return $state
        }
        if ($state.status -eq 'needs-repair') {
            Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'needs-repair' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus 'running' -NewStage $state.stage | Out-Null
        }
        return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    }
    if ($history.entries[-1].type -eq 'submission-rejected' -and $state.status -eq 'needs-repair') {
        $nextAttempt = [int]$historySummary.nextAttempt
        if ($nextAttempt -gt 3 -or [int]$runSummary.consumedAttempts -ge 5) {
            if (@($history.entries | Where-Object { $_.type -eq 'attempts-exhausted' }).Count -eq 0) {
                $limit = if ($nextAttempt -gt 3) { 3 } else { 5 }
                $scope = if ($nextAttempt -gt 3) { 'fingerprint' } else { 'run' }
                Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint -Stage $context.stage -FailedCheck $context.failedCheck -Attempt ([Math]::Min([int]$context.attempt, 3)) -CheckpointCommit $context.historyCheckpointCommit -ManifestSha256 $context.manifestSha256 -Type 'attempts-exhausted' -Data ([PSCustomObject]@{ limit = $limit; scope = $scope; nextAction = 'human-review' }) | Out-Null
            }
            $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint
            $historySummary = Get-RepairAttemptSummary -History $history
            $runSummary = Get-RepairRunAttemptSummary -ProjectRoot $ProjectRoot -RunId $RunId
            Set-PipelineRepairHistoryMirror -State $state -History $history -HistorySummary $historySummary -ConsumedAttempts $runSummary.consumedAttempts
            Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
            $events = @(Get-PipelineRepairEvents -EventsPath (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId).events)
            if (@($events | Where-Object { $_.type -eq 'repair-exhausted' -and $_.data -and $_.data.fingerprint -ceq $context.fingerprint }).Count -eq 0) {
                Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'repair-exhausted' -Stage $context.stage -Data ([PSCustomObject]@{ fingerprint = $context.fingerprint; attempt = [Math]::Min([int]$context.attempt, 3); limit = if ($nextAttempt -gt 3) { 3 } else { 5 } })
            }
            Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'needs-repair' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus 'blocked' -NewStage $state.stage -Diagnostic ([PSCustomObject]@{ code = 'repair_attempts_exhausted'; message = 'Repair attempts are exhausted.'; details = $null }) | Out-Null
            Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $RunId
            return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        }
        $state.attempt = $nextAttempt
        $context.attempt = $nextAttempt
        Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint -Stage $context.stage -FailedCheck $context.failedCheck -Attempt $nextAttempt -CheckpointCommit $context.historyCheckpointCommit -ManifestSha256 $context.manifestSha256 -Type 'context-issued' -Data ([PSCustomObject]@{
                allowedPaths = @($context.allowedPaths); diagnosticSummary = $context.diagnostic.summary; logFiles = @($context.diagnostic.logFiles)
            }) | Out-Null
        $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint
        $historySummary = Get-RepairAttemptSummary -History $history
        $runSummary = Get-RepairRunAttemptSummary -ProjectRoot $ProjectRoot -RunId $RunId
        Set-PipelineRepairHistoryMirror -State $state -History $history -HistorySummary $historySummary -ConsumedAttempts $runSummary.consumedAttempts
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
        return $state
    }
    $acceptedForAttempt = @($history.entries | Where-Object {
            $_.type -eq 'submission-accepted' -and [int]$_.attempt -eq [int]$context.attempt
        } | Select-Object -Last 1)
    if ($acceptedForAttempt.Count -eq 0) {
        $head = Get-PipelineGitHead -ProjectRoot $ProjectRoot
        if ($head -cne [string]$context.checkpointCommit) {
            Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Git HEAD advanced without a persisted accepted repair.' -Status failed
        }
        if ($state.status -eq 'running') {
            $state = Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus 'needs-repair' -NewStage $state.stage
        }
    }
    if ($state.repairTotal -ne $runSummary.consumedAttempts -or
        $context.history.entryCount -ne $history.entryCount -or
        $context.history.previousAttempts -ne $historySummary.previousAttempts -or
        $context.history.lastOutcome -cne $historySummary.lastOutcome) {
        Set-PipelineRepairHistoryMirror -State $state -History $history -HistorySummary $historySummary -ConsumedAttempts $runSummary.consumedAttempts
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    }
    return $state
}

function Add-RepairHistoryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Fingerprint,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$FailedCheck,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$CheckpointCommit,
        [Parameter(Mandatory = $true)][string]$ManifestSha256,
        [Parameter(Mandatory = $true)][ValidateSet('context-issued', 'submission-received', 'submission-rejected', 'submission-accepted', 'verification-failed', 'verification-passed', 'attempts-exhausted')][string]$Type,
        [Parameter(Mandatory = $true)]$Data
    )

    Assert-ActiveRunOwnership -ProjectRoot $ProjectRoot -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $path = $null
    $directory = $null
    $relativeDirectory = $null
    try {
        $path = Get-RepairHistoryPath -ProjectRoot $root -RunId $RunId -Fingerprint $Fingerprint
        $directory = Split-Path -Parent $path
        $relativeDirectory = Split-Path -Parent (Get-RepairHistoryRelativePath -RunId $RunId -Fingerprint $Fingerprint)
        $null = Resolve-RepairPath -Root $root -Path $relativeDirectory
    }
    catch {
        if ($_.Exception.Data['code']) { throw }
        Throw-RepairHistoryCorrupt -Path (Join-Path $root ('.angular-migration/runs/' + $RunId + '/repair-history')) -Sequence 0 -Message 'Repair history path is not canonical.'
    }
    $ioDirectory = ConvertTo-RepairHistoryIoPath -Path $directory
    $ioPath = ConvertTo-RepairHistoryIoPath -Path $path
    if (-not [IO.Directory]::Exists($ioDirectory)) { [IO.Directory]::CreateDirectory($ioDirectory) | Out-Null }
    $null = Resolve-RepairPath -Root $root -Path $relativeDirectory
    if ([IO.File]::GetAttributes($ioDirectory) -band [IO.FileAttributes]::ReparsePoint) { Throw-PipelineError -Code 'repair_history_write_failed' -Message 'Repair history directory is linked.' -Status failed }
    $leasePath = $path + '.lock'
    $ioLeasePath = ConvertTo-RepairHistoryIoPath -Path $leasePath
    $lease = $null
    $leaseAcquired = $false
    try {
        $lease = [IO.File]::Open($ioLeasePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $leaseAcquired = $true
        $history = Read-RepairHistory -ProjectRoot $root -RunId $RunId -Fingerprint $Fingerprint
        $sequence = $history.entryCount + 1
        if ($Type -eq 'context-issued' -and @($history.entries | Where-Object { $_.type -eq 'context-issued' -and [int]$_.attempt -eq $Attempt }).Count -gt 0) {
            Throw-RepairHistoryCorrupt -Path $path -Sequence $sequence -Message 'Repair history issues one context more than once for an attempt.'
        }
        $safeData = Protect-RepairHistoryValue -Value $Data -ProjectRoot $root
        $entry = [ordered]@{
            schemaVersion = 1; sequence = $sequence; entryId = [guid]::NewGuid().ToString('N'); runId = $RunId
            fingerprint = $Fingerprint; attempt = $Attempt; type = $Type; timestamp = Get-MigrationUtcNow
            stage = $Stage; failedCheck = $FailedCheck; checkpointCommit = $CheckpointCommit
            manifestSha256 = $ManifestSha256; data = $safeData; entrySha256 = $null
        }
        $entry.entrySha256 = Get-PipelineObjectHash -Value ([PSCustomObject]$entry) -ExcludedProperty 'entrySha256'
        $schema = Get-RepairHistorySchema
        Assert-MigrationJsonSchemaValue -Value ([PSCustomObject]$entry) -Schema $schema -RootSchema $schema -Path '$'
        $candidate = [PSCustomObject]$entry
        Assert-RepairHistoryEntries -ProjectRoot $root -Path $path -Entries (@($history.entries) + @($candidate)) -RunId $RunId -Fingerprint $Fingerprint
        $line = ($entry | ConvertTo-Json -Depth 50 -Compress) + [Environment]::NewLine
        $stream = $null
        try {
            $stream = [IO.File]::Open($ioPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { if ($stream) { $stream.Dispose() } }
        $published = Read-RepairHistory -ProjectRoot $root -RunId $RunId -Fingerprint $Fingerprint
        $last = $published.entries[-1]
        if ($last.entryId -cne $entry.entryId -or $last.entrySha256 -cne $entry.entrySha256) {
            Throw-PipelineError -Code 'repair_history_write_failed' -Message 'Repair history append could not be verified.' -Status failed
        }
        return $last
    }
    catch {
        if ($_.Exception.Data['code'] -in @('repair_history_corrupt', 'repair_history_write_failed')) { throw }
        Throw-PipelineError -Code 'repair_history_write_failed' -Message 'Could not append repair history.' -Status failed -Details $_.Exception.Message
    }
    finally {
        if ($leaseAcquired) {
            if ($lease) { $lease.Dispose() }
            if ([IO.File]::Exists($ioLeasePath)) { [IO.File]::Delete($ioLeasePath) }
        }
    }
}

function New-PipelineFailureContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$CheckId,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Output,
        [int]$ExitCode = 1,
        [string[]]$LogFiles = @()
    )
    $runId = Split-Path -Leaf $RunPaths.root
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $runId
    $paths = @(Get-PipelineRepairPaths -ProjectRoot $ProjectRoot -Stage $Stage -CheckId $CheckId -Output $Output -ConfigRepairAllowed:$state.configRepairAllowed)
    if ($paths.Count -eq 0) {
        Throw-PipelineError -Code 'repair_scope_unknown' -Message 'The diagnostic does not identify a safe repair scope.' -Status blocked -Details ([PSCustomObject]@{
                stage = $Stage; checkId = $CheckId; diagnostic = Protect-RepairText -Text $Message -Root $ProjectRoot
            })
    }
    $safeOutput = Protect-RepairText -Text $Output -Root $ProjectRoot
    $normalized = [regex]::Replace($safeOutput, '\b\d{4}[-/]\d{1,2}[-/]\d{1,2}[T\s][^\s]+|\b\d+(?:\.\d+)?\s*(?:ms|seconds)\b', '<time>')
    $normalized = [regex]::Replace($normalized, '\s+', ' ').Trim()
    $identity = [PSCustomObject]@{ stage = $Stage; check = $CheckId; exitCode = $ExitCode; diagnostic = $normalized; manifest = $state.manifestSha256 }
    $diagnosticHash = Get-PipelineObjectHash -Value $identity
    $stateCheckpoint = [string]$state.checkpointCommit
    $historyCheckpointCommit = $stateCheckpoint
    $fingerprint = Get-PipelineRepairFailureFingerprint -State $state -Stage $Stage -CheckId $CheckId -Output $Output -ExitCode $ExitCode -CheckpointCommit $stateCheckpoint
    if ($state.repair -and $state.repair.context -and $state.repair.context.stage -ceq $Stage -and $state.repair.context.failedCheck -ceq $CheckId -and $state.repair.context.PSObject.Properties['historyCheckpointCommit']) {
        $activeFingerprint = Get-PipelineRepairFailureFingerprint -State $state -Stage $Stage -CheckId $CheckId -Output $Output -ExitCode $ExitCode -CheckpointCommit ([string]$state.repair.context.historyCheckpointCommit)
        if ($activeFingerprint -ceq [string]$state.repair.context.fingerprint) {
            $fingerprint = $activeFingerprint
            $historyCheckpointCommit = [string]$state.repair.context.historyCheckpointCommit
        }
    }
    $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $runId -Fingerprint $fingerprint
    $historySummary = Get-RepairAttemptSummary -History $history
    $runSummary = Get-RepairRunAttemptSummary -ProjectRoot $ProjectRoot -RunId $runId
    if ([int]$state.repairTotal -ne [int]$runSummary.consumedAttempts) {
        Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Repair history and state attempt totals do not match.' -Status failed
    }
    $attempt = if ($history.exists) { [int]$historySummary.nextAttempt } else { 1 }
    if ($attempt -gt 3 -or $runSummary.consumedAttempts -ge 5) {
        if (-not $history.exists -or @($history.entries | Where-Object { $_.type -eq 'attempts-exhausted' }).Count -eq 0) {
            $limit = if ($attempt -gt 3) { 3 } else { 5 }
            $scope = if ($attempt -gt 3) { 'fingerprint' } else { 'run' }
            Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $runId -Fingerprint $fingerprint -Stage $Stage -FailedCheck $CheckId -Attempt ([Math]::Min($attempt, 3)) -CheckpointCommit $historyCheckpointCommit -ManifestSha256 $state.manifestSha256 -Type 'attempts-exhausted' -Data ([PSCustomObject]@{ limit = $limit; scope = $scope; nextAction = 'human-review' }) | Out-Null
        }
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $runId -Type 'repair-exhausted' -Stage $Stage -Data ([PSCustomObject]@{ fingerprint = $fingerprint; attempt = [Math]::Min($attempt, 3); limit = if ($attempt -gt 3) { 3 } else { 5 } })
        Throw-PipelineError -Code 'repair_attempts_exhausted' -Message 'Repair attempts are exhausted.' -Status blocked
    }
    $forbidden = @('.git/**', '.github/**', '.angular-migration/**', 'package.json', 'package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml', 'scripts/**', 'hooks.json', 'agents/**', 'docs/**', 'plugin.json', '**/.npmrc', '**/.env*', '**/*.pem', '**/*.key', '**/*.pfx', '**/*.p12')
    if ($paths -cnotcontains 'angular.json') { $forbidden += 'angular.json' }
    $logs = @()
    foreach ($log in $LogFiles) {
        if (-not $log) { continue }
        $relative = '.angular-migration/runs/' + $runId + '/' + $log.Replace('\', '/')
        $full = Resolve-RepairPath $ProjectRoot $relative
        $safeLog = Protect-RepairText -Text ([IO.File]::ReadAllText($full)) -Root $ProjectRoot
        Write-MigrationTextAtomic -Text $safeLog -Path $full
        $logs += $relative
    }
    $context = [PSCustomObject][ordered]@{
        schemaVersion = 1; runId = $runId; sourceMajor = $state.sourceMajor; targetMajor = $state.targetMajor
        status = 'needs-repair'; stage = $Stage; failedCheck = $CheckId; fingerprint = $fingerprint
        attempt = $attempt; maxAttempts = 3; checkpointCommit = $stateCheckpoint; historyCheckpointCommit = $historyCheckpointCommit; manifestSha256 = $state.manifestSha256
        allowedPaths = @($paths); forbiddenPaths = $forbidden
        diagnostic = [PSCustomObject]@{
            summary = Protect-RepairText -Text $Message -Root $ProjectRoot
            exitCode = $ExitCode; logFiles = $logs
            relatedFiles = @($paths | Where-Object { $_ -notmatch '\*' }); warnings = @()
        }
        history = [PSCustomObject][ordered]@{
            path             = Get-RepairHistoryRelativePath -RunId $runId -Fingerprint $fingerprint
            entryCount       = [Math]::Max(1, [int]$history.entryCount)
            previousAttempts = [int]$historySummary.previousAttempts
            lastOutcome      = $historySummary.lastOutcome
        }
        submissionPath = '.angular-migration/runs/' + $runId + '/inbox/repair.json'
    }
    if (@($history.entries | Where-Object { $_.type -eq 'context-issued' -and $_.attempt -eq $attempt }).Count -eq 0) {
        Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $runId -Fingerprint $fingerprint -Stage $Stage -FailedCheck $CheckId -Attempt $attempt -CheckpointCommit $historyCheckpointCommit -ManifestSha256 $state.manifestSha256 -Type 'context-issued' -Data ([PSCustomObject]@{
                allowedPaths = @($context.allowedPaths); diagnosticSummary = $context.diagnostic.summary; logFiles = @($context.diagnostic.logFiles)
            }) | Out-Null
    }
    $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $runId -Fingerprint $fingerprint
    $historySummary = Get-RepairAttemptSummary -History $history
    $context.history.entryCount = $history.entryCount
    $context.history.previousAttempts = $historySummary.previousAttempts
    $context.history.lastOutcome = $historySummary.lastOutcome
    $before = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $tracked = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('ls-files', '-z')
    if ($tracked.exitCode -ne 0) { Throw-PipelineError -Code 'git_status_failed' -Message 'Cannot inventory repair files.' }
    $protected = @()
    foreach ($path in @($tracked.stdout -split [char]0 | Where-Object { $_ })) {
        $full = Resolve-RepairPath $ProjectRoot $path
        if (-not (Test-RepairAllowedPath $path $context) -or $path -in @($before | ForEach-Object { $_.path })) {
            $hash = if (Test-Path -LiteralPath $full -PathType Leaf) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash } else { $null }
            $protected += [PSCustomObject]@{ path = $path; hash = $hash }
        }
    }
    foreach ($item in $before | Where-Object untracked) {
        $full = Resolve-RepairPath $ProjectRoot $item.path
        $protected += [PSCustomObject]@{ path = $item.path; hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
    }
    $inbox = Resolve-RepairPath $ProjectRoot ('.angular-migration/runs/' + $runId + '/inbox')
    New-Item -ItemType Directory -Path $inbox -Force | Out-Null
    Write-MigrationJsonAtomic -Value @() -Path (Join-Path $inbox 'edit-inventory.json')
    $state.repair = [PSCustomObject]@{
        context = $context; diagnosticHash = $diagnosticHash; before = $before; protected = $protected
        accepted = $null; facadePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../angular-migration.ps1'))
    }
    $state.attempt = $attempt
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $runId -State $state
    Add-PipelineRepairRequiredEventIfMissing -ProjectRoot $ProjectRoot -RunId $runId -Stage $Stage -Fingerprint $fingerprint -Attempt $attempt
    Write-MigrationJsonAtomic -Value $context -Path (Join-Path $RunPaths.root 'failure-context.json')
    return $context
}

function Assert-RepairSchema {
    param($Value, $Schema)
    try { Assert-MigrationJsonSchemaValue -Value $Value -Schema $Schema -RootSchema $Schema -Path '$' }
    catch { throw 'Invalid repair contract.' }
}

function Get-ValidatedRepairContext {
    param([string]$ProjectRoot, [string]$RunId)
    Assert-ActiveRunOwnership -ProjectRoot $ProjectRoot -RunId $RunId
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.status -cne 'needs-repair' -or -not $state.repair -or $state.repair.context.stage -cne $state.stage -or @($state.repair.context.allowedPaths).Count -eq 0) {
        Throw-PipelineError -Code 'invalid_repair_stage' -Message 'Repair requires needs-repair and a controller context.' -Status blocked
    }
    if ($state.repair.context.runId -cne $RunId -or $state.repair.context.checkpointCommit -cne $state.checkpointCommit -or
        $state.repair.context.manifestSha256 -cne $state.manifestSha256 -or $state.repair.context.attempt -ne $state.attempt) {
        Throw-PipelineError -Code 'invalid_repair_context' -Message 'Repair context does not match current state.'
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path (Resolve-RepairPath $ProjectRoot $paths.manifest) -Required
    if (-not $state.manifestSha256 -or (Get-ResolvedManifestHash $manifest) -cne $state.manifestSha256 -or $manifest.manifestSha256 -cne $state.manifestSha256) {
        Throw-PipelineError -Code 'manifest_integrity_failed' -Message 'Repair manifest integrity failed.'
    }
    $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $state.repair.context.fingerprint
    $historySummary = Get-RepairAttemptSummary -History $history
    $runSummary = Get-RepairRunAttemptSummary -ProjectRoot $ProjectRoot -RunId $RunId
    if (-not $history.exists -or [int]$state.attempt -ne [int]$historySummary.nextAttempt -or
        [int]$state.repairTotal -ne [int]$runSummary.consumedAttempts -or
        -not $state.repair.context.PSObject.Properties['history'] -or
        -not $state.repair.context.PSObject.Properties['historyCheckpointCommit'] -or
        [string]$state.repair.context.historyCheckpointCommit -cne [string]$history.checkpointCommit -or
        $state.repair.context.history.path -cne (Get-RepairHistoryRelativePath -RunId $RunId -Fingerprint $state.repair.context.fingerprint) -or
        [int]$state.repair.context.history.entryCount -ne [int]$history.entryCount -or
        [int]$state.repair.context.history.previousAttempts -ne [int]$historySummary.previousAttempts -or
        $state.repair.context.history.lastOutcome -cne $historySummary.lastOutcome) {
        Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Repair context does not match its validated history.' -Status failed
    }
    Assert-RepairSchema $state.repair.context (Read-MigrationJson -Path (Join-Path $PSScriptRoot '../../schemas/repair-context.schema.json') -Required)
    return $state.repair.context
}

function Invoke-MigrationRepairContext {
    param([string]$ProjectRoot, [string]$RunId)
    $context = Get-ValidatedRepairContext $ProjectRoot $RunId
    return [PSCustomObject]@{ ok = $true; status = 'needs-repair'; data = $context; error = $null }
}

function Undo-MigrationRepair {
    param([string]$ProjectRoot, $State)
    $context = $State.repair.context
    $beforePaths = @($State.repair.before | ForEach-Object { $_.path })
    $changes = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    foreach ($item in $changes | Where-Object { -not $_.untracked -and $_.path -notin $beforePaths }) {
        try { $null = Resolve-RepairPath $ProjectRoot $item.path } catch { continue }
        $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('restore', '--source', $context.checkpointCommit, '--staged', '--worktree', '--', $item.path)
        if ($result.exitCode -ne 0) { Throw-PipelineError -Code 'repair_rollback_failed' -Message 'Repair rollback requires manual review.' }
    }
    $inventoryPath = Resolve-RepairPath $ProjectRoot ('.angular-migration/runs/' + $State.runId + '/inbox/edit-inventory.json')
    $inventory = @(Read-MigrationJson -Path $inventoryPath)
    foreach ($item in $changes | Where-Object { $_.untracked -and $_.path -notin $beforePaths -and $_.path -cin $inventory }) {
        try { $full = Resolve-RepairPath $ProjectRoot $item.path } catch { continue }
        if (Test-RepairAllowedPath $item.path $context) { Remove-Item -LiteralPath $full -Force }
    }
}

function Get-RepairRejectionInfo {
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [bool]$ScopeViolation,
        [bool]$RollbackFailed
    )

    $rawCode = if ($ErrorRecord.Exception.Data['code']) { [string]$ErrorRecord.Exception.Data['code'] } else { $null }
    $code = if ($ScopeViolation) { 'repair_scope_violation' } elseif ($RollbackFailed) { 'repair_rollback_failed' } else {
        switch ($rawCode) {
            'invalid_json' { 'invalid_json'; break }
            'repair_history_corrupt' { 'repair_history_corrupt'; break }
            'repair_history_state_mismatch' { 'repair_history_state_mismatch'; break }
            'repair_history_write_failed' { 'repair_history_write_failed'; break }
            'repair_attempts_exhausted' { 'repair_attempts_exhausted'; break }
            default {
                if ([string]$ErrorRecord.Exception.Message -match '(?i)submission path') { 'submission_path_invalid' }
                elseif ([string]$ErrorRecord.Exception.Message -match '(?i)schema|property|contract') { 'repair_schema_invalid' }
                elseif ([string]$ErrorRecord.Exception.Message -match '(?i)HEAD|stale') { 'repair_head_changed' }
                elseif ([string]$ErrorRecord.Exception.Message -match '(?i)diff') { 'repair_diff_mismatch' }
                elseif ([string]$ErrorRecord.Exception.Message -match '(?i)mode|link|submodule|rename') { 'repair_mode_invalid' }
                elseif ([string]$ErrorRecord.Exception.Message -match '(?i)protected') { 'protected_file_changed' }
                elseif ([string]$ErrorRecord.Exception.Message -match '(?i)runtime') { 'repair_runtime_changed' }
                elseif ([string]$ErrorRecord.Exception.Message -match '(?i)evidence') { 'repair_evidence_invalid' }
                elseif ([string]$ErrorRecord.Exception.Message -match '(?i)sensitive') { 'repair_submission_sensitive' }
                else { 'repair_rejected' }
            }
        }
    }
    $message = switch ($code) {
        'invalid_json' { 'Repair submission is not valid JSON.'; break }
        'submission_path_invalid' { 'Repair submission path is invalid.'; break }
        'repair_schema_invalid' { 'Repair submission does not match its contract.'; break }
        'repair_head_changed' { 'Repair checkpoint or HEAD changed.'; break }
        'repair_diff_mismatch' { 'Repair diff does not match declared changes.'; break }
        'repair_scope_violation' { 'Repair changed a path outside the controller scope.'; break }
        'repair_mode_invalid' { 'Repair changed a file mode, link or submodule.'; break }
        'protected_file_changed' { 'A protected file changed during repair.'; break }
        'repair_runtime_changed' { 'The repair runtime changed during repair.'; break }
        'repair_evidence_invalid' { 'Repair evidence is not part of the active context.'; break }
        'repair_submission_sensitive' { 'Repair submission contains sensitive data.'; break }
        'repair_attempts_exhausted' { 'Repair attempts are exhausted.'; break }
        'repair_history_state_mismatch' { 'Repair history and state do not match.'; break }
        'repair_history_corrupt' { 'Repair history is corrupt.'; break }
        'repair_history_write_failed' { 'Repair history could not be persisted.'; break }
        'repair_rollback_failed' { 'Repair rollback requires manual review.'; break }
        default { 'Repair submission was rejected by the controller.'; break }
    }
    return [PSCustomObject]@{ code = $code; message = $message }
}

function Invoke-MigrationRecordRepair {
    param([string]$ProjectRoot, [string]$RunId, [string]$InputFile)
    Assert-ActiveRunOwnership -ProjectRoot $ProjectRoot -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $leasePath = Resolve-RepairPath $ProjectRoot ('.angular-migration/runs/' + $RunId + '/record-repair.lock')
    $lease = $null
    try { $lease = [IO.File]::Open($leasePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { Throw-PipelineError -Code 'repair_process_not_owner' -Message 'Another process owns record-repair for this run.' -Status blocked }
    $state = $null
    $scopeViolation = $false
    $actual = @()
    $report = $null
    $submissionHash = $null
    $history = $null
    $acceptedHistoryAppended = $false
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$PID)
        $lease.Write($bytes, 0, $bytes.Length)
        $lease.Flush($true)
        $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        if ($state.status -eq 'running' -and $state.repair -and $state.repair.accepted) {
            $recovered = Invoke-PipelineRepairHistoryRecovery -ProjectRoot $ProjectRoot -RunId $RunId
            return [PSCustomObject]@{ ok = $true; status = [string]$recovered.status; data = [PSCustomObject]@{ runId = $RunId; nextAction = 'rerun-failed-check'; repair = if ($recovered.repair) { $recovered.repair.accepted } else { $null } }; error = $null }
        }
        if ($state.status -cne 'needs-repair' -or -not $state.repair) { Throw-PipelineError -Code 'invalid_repair_stage' -Message 'No active repair contract.' -Status blocked }
        $context = $state.repair.context
        if ($context.runId -cne $RunId -or $context.stage -cne $state.stage -or $context.attempt -ne $state.attempt) { throw 'Stale repair context.' }
        try {
            $expected = Resolve-RepairPath $ProjectRoot $context.submissionPath
            $inputPath = Resolve-RepairPath $ProjectRoot $InputFile
            if ($inputPath -cne $expected) { throw 'Invalid submission path.' }
        }
        catch { $scopeViolation = $true; throw }
        try {
            $context = Get-ValidatedRepairContext -ProjectRoot $ProjectRoot -RunId $RunId
        }
        catch {
            $contextErrorCode = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { $null }
            if ($contextErrorCode -eq 'manifest_integrity_failed' -or
                ($contextErrorCode -eq 'invalid_json' -and [string]$_.Exception.Message -match '(?i)manifest')) {
                $scopeViolation = $true
            }
            throw
        }
        $report = Read-MigrationJson -Path $inputPath -Required
        $submissionHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint
        $runSummary = Get-RepairRunAttemptSummary -ProjectRoot $ProjectRoot -RunId $RunId
        if ([int]$state.repairTotal -ne [int]$runSummary.consumedAttempts) {
            Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Repair history and state attempt totals do not match.' -Status failed
        }
        $priorReceived = @($history.entries | Where-Object { $_.type -eq 'submission-received' -and $_.data.submissionSha256 -eq $submissionHash } | Select-Object -Last 1)
        if ($priorReceived.Count -gt 0) {
            $priorOutcome = @($history.entries | Where-Object {
                    [int]$_.sequence -gt [int]$priorReceived[0].sequence -and [int]$_.attempt -eq [int]$priorReceived[0].attempt -and
                    $_.type -in @('submission-rejected', 'submission-accepted')
                } | Select-Object -First 1)
            if ($priorOutcome.Count -gt 0) {
                if ($priorOutcome[0].type -eq 'submission-accepted') {
                    $recovered = Invoke-PipelineRepairHistoryRecovery -ProjectRoot $ProjectRoot -RunId $RunId
                    return [PSCustomObject]@{ ok = $true; status = [string]$recovered.status; data = [PSCustomObject]@{ runId = $RunId; nextAction = 'rerun-failed-check'; repair = if ($recovered.repair) { $recovered.repair.accepted } else { $null } }; error = $null }
                }
                $priorDiagnostic = [PSCustomObject]@{ code = [string]$priorOutcome[0].data.code; message = [string]$priorOutcome[0].data.message; details = $null }
                return [PSCustomObject]@{ ok = $false; status = [string]$state.status; data = @{}; error = $priorDiagnostic }
            }
        }
        if (@($history.entries | Where-Object { $_.type -eq 'submission-received' -and $_.attempt -eq $context.attempt -and $_.data.submissionSha256 -eq $submissionHash }).Count -eq 0) {
            $declaredChanges = @()
            if ($report.PSObject.Properties['changes']) {
                foreach ($change in @($report.changes)) {
                    if ($change -and $change.PSObject.Properties['path'] -and $change.PSObject.Properties['summary']) {
                        $declaredChanges += [PSCustomObject]@{ path = [string]$change.path; summary = [string]$change.summary }
                    }
                }
            }
            $declaredRootCause = if ($report.PSObject.Properties['rootCause'] -and -not [string]::IsNullOrWhiteSpace([string]$report.rootCause)) { [string]$report.rootCause } else { 'unavailable' }
            Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint -Stage $context.stage -FailedCheck $context.failedCheck -Attempt $context.attempt -CheckpointCommit $context.historyCheckpointCommit -ManifestSha256 $context.manifestSha256 -Type 'submission-received' -Data ([PSCustomObject]@{
                    submissionSha256 = $submissionHash; declaredRootCause = $declaredRootCause; declaredChanges = @($declaredChanges)
                }) | Out-Null
        }
        if ($report.runId -cne $RunId -or $report.fingerprint -cne $context.fingerprint -or $report.attempt -ne $context.attempt) { throw 'Stale repair submission.' }
        $schema = Read-MigrationJson -Path (Join-Path $PSScriptRoot '../../schemas/repair-input.schema.json') -Required
        Assert-RepairSchema $report $schema
        if ((Get-PipelineGitHead $ProjectRoot) -cne $context.checkpointCommit) { $scopeViolation = $true; throw 'Repair HEAD changed.' }
        $changes = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
        $before = @($state.repair.before | ForEach-Object { $_.path })
        $actual = @($changes | Where-Object { $_.path -notin $before } | ForEach-Object { $_.path } | Sort-Object -Unique)
        foreach ($path in $actual) {
            try { $null = Resolve-RepairPath $ProjectRoot $path } catch { $scopeViolation = $true; throw }
            if (-not (Test-RepairAllowedPath $path $context)) { $scopeViolation = $true; throw 'Repair scope violation.' }
        }
        $declared = @($report.changes | ForEach-Object { $_.path } | Sort-Object -Unique)
        foreach ($path in $declared) {
            try { $null = Resolve-RepairPath $ProjectRoot $path } catch { $scopeViolation = $true; throw }
        }
        if ($actual.Count -eq 0 -or ($actual -join "`n") -cne ($declared -join "`n") -or $declared.Count -ne @($report.changes).Count) { throw 'Repair diff does not match report.' }
        $raw = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('diff', '--raw', '--no-abbrev', '--no-renames', 'HEAD')
        if ($raw.exitCode -ne 0) { throw 'Repair diff unavailable.' }
        foreach ($line in $raw.stdout -split "`n") {
            if ($line -match '^:(\d{6}) (\d{6}) ') {
                if ($Matches[1] -in @('120000', '160000') -or $Matches[2] -in @('120000', '160000') -or
                    ($Matches[1] -ne '000000' -and $Matches[2] -ne '000000' -and $Matches[1] -ne $Matches[2])) { $scopeViolation = $true; throw 'Repair mode or link changed.' }
            }
        }
        foreach ($protected in $state.repair.protected) {
            try { $full = Resolve-RepairPath $ProjectRoot $protected.path } catch { $scopeViolation = $true; throw }
            $hash = if (Test-Path -LiteralPath $full -PathType Leaf) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash } else { $null }
            if ($hash -cne $protected.hash) { $scopeViolation = $true; throw 'Protected repair file changed.' }
        }
        $runtime = Resolve-RepairPath $ProjectRoot '.angular-migration/runtime/copilot-policy.ps1'
        if ((Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant() -cne $state.runtimeSha256) { $scopeViolation = $true; throw 'Repair runtime changed.' }
        foreach ($evidence in $report.evidence) {
            if ($evidence.reference -cnotin $context.diagnostic.logFiles) { throw 'Unknown repair evidence.' }
        }
        if ($context.attempt -gt 3 -or $state.repairTotal -ge 5) { throw 'Repair attempts exhausted.' }
        $reportText = [IO.File]::ReadAllText($inputPath)
        if ((Protect-RepairText -Text $reportText -Root $ProjectRoot) -cne $reportText) { throw 'Repair submission contains sensitive data.' }
        $archiveName = $context.fingerprint.Substring(7) + '-attempt-' + $context.attempt + '.json'
        $archive = Resolve-RepairPath $ProjectRoot ('.angular-migration/runs/' + $RunId + '/repairs/' + $archiveName)
        New-Item -ItemType Directory -Path (Split-Path -Parent $archive) -Force | Out-Null
        $archiveFilePath = if ($archive.Length -ge 248 -and $archive -match '^[A-Za-z]:\\') { '\\?\' + $archive } else { $archive }
        Move-Item -LiteralPath $inputPath -Destination $archiveFilePath -ErrorAction Stop
        $add = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments (@('add', '--') + $actual)
        if ($add.exitCode -ne 0) { throw 'Cannot stage repair.' }
        $commit = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments (@('-c', 'core.hooksPath=NUL', 'commit', '--only', '-m', "chore(angular-migration): repair $($context.failedCheck) attempt $($context.attempt)", '--') + $actual)
        if ($commit.exitCode -ne 0) { throw 'Cannot commit repair.' }
        $accepted = [PSCustomObject]@{
            fingerprint = $context.fingerprint; attempt = $context.attempt; commit = Get-PipelineGitHead $ProjectRoot
            report = '.angular-migration/runs/' + $RunId + '/repairs/' + $archiveName
            reportSha256 = (Get-FileHash -LiteralPath $archiveFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint -Stage $context.stage -FailedCheck $context.failedCheck -Attempt $context.attempt -CheckpointCommit $context.historyCheckpointCommit -ManifestSha256 $context.manifestSha256 -Type 'submission-accepted' -Data ([PSCustomObject]@{
                report = $accepted.report; reportSha256 = $accepted.reportSha256; commit = $accepted.commit; changedPaths = @($actual)
            }) | Out-Null
        $acceptedHistoryAppended = $true
        $state.repair.accepted = $accepted
        $state.repairs = @($state.repairs) + $accepted
        $state.checkpointCommit = $accepted.commit
        $state.repair.context.checkpointCommit = $accepted.commit
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'repair-accepted' -Stage $state.stage -Data $accepted
        $null = Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'needs-repair' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus running -NewStage $state.stage
        return [PSCustomObject]@{ ok = $true; status = 'running'; data = [PSCustomObject]@{ runId = $RunId; nextAction = 'rerun-failed-check'; repair = $accepted }; error = $null }
    }
    catch {
        if ($acceptedHistoryAppended) {
            throw
        }
        if ($state -and $state.status -eq 'needs-repair' -and $state.repair) {
            $rollbackFailed = $false
            try { Undo-MigrationRepair $ProjectRoot $state } catch { $rollbackFailed = $true }
            $rejection = Get-RepairRejectionInfo -ErrorRecord $_ -ScopeViolation:$scopeViolation -RollbackFailed:$rollbackFailed
            $historyWriteFailed = $false
            $historyErrorCode = $null
            $historyErrorMessage = $null
            if ($rejection.code -notin @('repair_history_corrupt', 'repair_history_state_mismatch', 'repair_history_write_failed')) {
                try {
                    if (-not $history) { $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $state.repair.context.fingerprint }
                    $rollbackStatus = if ($rollbackFailed) { 'failed' } elseif ($actual.Count -gt 0) { 'passed' } else { 'not-required' }
                    Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $state.repair.context.fingerprint -Stage $state.repair.context.stage -FailedCheck $state.repair.context.failedCheck -Attempt $state.repair.context.attempt -CheckpointCommit $state.repair.context.historyCheckpointCommit -ManifestSha256 $state.repair.context.manifestSha256 -Type 'submission-rejected' -Data ([PSCustomObject]@{
                            code = $rejection.code; message = $rejection.message; changedPaths = @($actual); scopeViolation = [bool]$scopeViolation; rollbackStatus = $rollbackStatus
                        }) | Out-Null
                }
                catch {
                    $historyWriteFailed = $true
                    $historyErrorCode = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'repair_history_write_failed' }
                    $historyErrorMessage = if ($historyErrorCode -eq 'repair_history_corrupt') { 'Repair history is corrupt.' } else { 'Repair history could not be persisted.' }
                }
            }
            if ($historyWriteFailed -or $rejection.code -in @('repair_history_corrupt', 'repair_history_state_mismatch', 'repair_history_write_failed')) {
                $code = if ($historyWriteFailed) { $historyErrorCode } else { $rejection.code }
                $diagnostic = [PSCustomObject]@{ code = $code; message = if ($historyWriteFailed) { $historyErrorMessage } else { $rejection.message }; details = $null }
                try {
                    $null = Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'needs-repair' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus 'failed' -NewStage $state.stage -Diagnostic $diagnostic
                }
                catch { }
                Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $RunId
                return [PSCustomObject]@{ ok = $false; status = 'failed'; data = @{}; error = $diagnostic }
            }
            $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $state.repair.context.fingerprint
            $historySummary = Get-RepairAttemptSummary -History $history
            $runSummary = Get-RepairRunAttemptSummary -ProjectRoot $ProjectRoot -RunId $RunId
            $state.repairTotal = [int]$runSummary.consumedAttempts
            $status = 'needs-repair'
            $code = $rejection.code
            if ($scopeViolation -or $rollbackFailed) { $status = 'failed' }
            elseif ($historySummary.nextAttempt -gt 3 -or $runSummary.consumedAttempts -ge 5) {
                if (@($history.entries | Where-Object { $_.type -eq 'attempts-exhausted' }).Count -eq 0) {
                    $limit = if ($historySummary.nextAttempt -gt 3) { 3 } else { 5 }
                    $scope = if ($historySummary.nextAttempt -gt 3) { 'fingerprint' } else { 'run' }
                    Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $state.repair.context.fingerprint -Stage $state.repair.context.stage -FailedCheck $state.repair.context.failedCheck -Attempt ([Math]::Min([int]$state.repair.context.attempt, 3)) -CheckpointCommit $state.repair.context.historyCheckpointCommit -ManifestSha256 $state.repair.context.manifestSha256 -Type 'attempts-exhausted' -Data ([PSCustomObject]@{ limit = $limit; scope = $scope; nextAction = 'human-review' }) | Out-Null
                }
                Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'repair-exhausted' -Stage $state.stage -Data ([PSCustomObject]@{ fingerprint = $state.repair.context.fingerprint; attempt = [Math]::Min([int]$state.repair.context.attempt, 3); limit = if ($historySummary.nextAttempt -gt 3) { 3 } else { 5 } })
                $status = 'blocked'
                $code = 'repair_attempts_exhausted'
            }
            else {
                $state.attempt = [int]$historySummary.nextAttempt
                $state.repair.context.attempt = $state.attempt
                Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $state.repair.context.fingerprint -Stage $state.repair.context.stage -FailedCheck $state.repair.context.failedCheck -Attempt $state.attempt -CheckpointCommit $state.repair.context.historyCheckpointCommit -ManifestSha256 $state.repair.context.manifestSha256 -Type 'context-issued' -Data ([PSCustomObject]@{
                        allowedPaths = @($state.repair.context.allowedPaths); diagnosticSummary = $state.repair.context.diagnostic.summary; logFiles = @($state.repair.context.diagnostic.logFiles)
                    }) | Out-Null
                $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $state.repair.context.fingerprint
                $historySummary = Get-RepairAttemptSummary -History $history
                $state.repair.context.history.entryCount = $history.entryCount
                $state.repair.context.history.previousAttempts = $historySummary.previousAttempts
                $state.repair.context.history.lastOutcome = $historySummary.lastOutcome
            }
            $publicCode = if ($status -eq 'needs-repair') { 'repair_rejected' } else { $code }
            $diagnostic = [PSCustomObject]@{ code = $publicCode; message = if ($status -eq 'blocked') { 'Repair attempts are exhausted.' } elseif ($status -eq 'failed') { $rejection.message } else { 'Repair submission was rejected by the controller.' }; details = $null }
            Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
            if ($status -ne 'needs-repair') {
                $null = Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'needs-repair' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus $status -NewStage $state.stage -Diagnostic $diagnostic
                Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $RunId
            }
            return [PSCustomObject]@{ ok = $false; status = $status; data = @{}; error = $diagnostic }
        }
        throw
    }
    finally {
        if ($lease) { $lease.Dispose(); Remove-Item -LiteralPath $leasePath -Force }
    }
}

function ConvertTo-PipelineCanonicalValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('o') }
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) { $ordered[$key] = ConvertTo-PipelineCanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) { return , @($Value | ForEach-Object { ConvertTo-PipelineCanonicalValue $_ }) }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -gt 0 -and $Value -isnot [ValueType] -and $Value -isnot [string]) {
        $ordered = [ordered]@{}
        foreach ($property in @($properties | Sort-Object Name)) { $ordered[$property.Name] = ConvertTo-PipelineCanonicalValue $property.Value }
        return $ordered
    }
    return $Value
}

function Get-PipelineObjectHash {
    param([Parameter(Mandatory = $true)]$Value, [string]$ExcludedProperty)
    $canonical = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Where-Object { $_.Name -cne $ExcludedProperty } | Sort-Object Name)) {
        $canonical[$property.Name] = ConvertTo-PipelineCanonicalValue $property.Value
    }
    $json = $canonical | ConvertTo-Json -Depth 100 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($json)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Get-PipelineChangedFiles {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$InitialCommit)
    $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('diff', '--name-only', "$InitialCommit..HEAD")
    if ($result.exitCode -ne 0) { Throw-PipelineError -Code 'git_status_failed' -Message 'Could not calculate changed migration files.' -Status failed }
    return @($result.stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { ConvertTo-PipelineRelativePath -ProjectRoot $ProjectRoot -Path $_ } | Sort-Object -Unique)
}

function Assert-PipelineTechnicalResult {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$RunPaths
    )

    $result = Read-MigrationJson -Path $RunPaths.result -Required
    if ($result.schemaVersion -ne (Get-MigrationSchemaVersion) -or $result.runId -cne $RunId -or $result.status -cne 'verified') {
        Throw-PipelineError -Code 'result_integrity_failed' -Message 'Technical result contract is invalid.' -Status failed
    }
    if ($result.resultSha256 -notmatch '^[0-9a-f]{64}$' -or $result.resultSha256 -cne (Get-PipelineObjectHash -Value $result -ExcludedProperty 'resultSha256')) {
        Throw-PipelineError -Code 'result_integrity_failed' -Message 'Technical result has been altered.' -Status failed
    }
    return $result
}

function Write-PipelineTechnicalResult {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$CheckResults,
        [Parameter(Mandatory = $true)]$RunPaths
    )
    $existing = Read-MigrationJson -Path $RunPaths.result
    if ($existing) {
        return Assert-PipelineTechnicalResult -ProjectRoot $ProjectRoot -RunId $RunId -RunPaths $RunPaths
    }
    $dependencyChanges = @($Manifest.dependencies | Where-Object { $_.change -ne 'unchanged' } | ForEach-Object {
            [PSCustomObject]@{ name = $_.name; section = $_.section; from = $_.currentVersion; to = $_.targetVersion; change = $_.change; writeSpec = $_.writeSpec }
        })
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $verifiedRepairs = @()
    foreach ($repair in @($state.repairs)) {
        $repairHistory = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $repair.fingerprint
        if (@($repairHistory.entries | Where-Object { $_.type -eq 'verification-passed' -and [int]$_.attempt -eq [int]$repair.attempt }).Count -gt 0) {
            $verifiedRepairs += $repair
        }
    }
    $result = [ordered]@{
        schemaVersion        = Get-MigrationSchemaVersion
        runId                = $RunId
        sourceMajor          = $Manifest.sourceMajor
        targetMajor          = $Manifest.targetMajor
        status               = 'verified'
        migrationStatus      = 'verified'
        documentationStatus  = 'pending'
        manifestSha256       = $Manifest.manifestSha256
        initialCommit        = $state.initialCommit
        finalTechnicalCommit = Get-PipelineGitHead -ProjectRoot $ProjectRoot
        changedFiles         = @(Get-PipelineChangedFiles -ProjectRoot $ProjectRoot -InitialCommit ((Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId).initialCommit))
        dependencyChanges    = $dependencyChanges
        checks               = @($CheckResults)
        skippedChecks        = @($state.skippedChecks)
        repairs              = @($verifiedRepairs)
        warnings             = @($Manifest.warnings)
        verifiedAt           = Get-MigrationUtcNow
    }
    $resultObject = [PSCustomObject]$result
    $result.resultSha256 = Get-PipelineObjectHash -Value $resultObject -ExcludedProperty 'resultSha256'
    Write-MigrationJsonAtomic -Value ([PSCustomObject]$result) -Path $RunPaths.result
    $published = Read-MigrationJson -Path $RunPaths.result -Required
    if ($published.resultSha256 -ne (Get-PipelineObjectHash -Value $published -ExcludedProperty 'resultSha256')) {
        Throw-PipelineError -Code 'result_integrity_failed' -Message 'Technical result failed its integrity check.' -Status failed
    }
    return $published
}

function Get-PipelineRepairFailureFingerprint {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$CheckId,
        [string]$Output,
        [int]$ExitCode = 1,
        [string]$CheckpointCommit = $null
    )

    $safeOutput = Protect-RepairText -Text $Output -Root $State.projectRoot
    $normalized = [regex]::Replace($safeOutput, '\b\d{4}[-/]\d{1,2}[-/]\d{1,2}[T\s][^\s]+|\b\d+(?:\.\d+)?\s*(?:ms|seconds)\b', '<time>')
    $normalized = [regex]::Replace($normalized, '\s+', ' ').Trim()
    $identity = [PSCustomObject]@{ stage = $Stage; check = $CheckId; exitCode = $ExitCode; diagnostic = $normalized; manifest = $State.manifestSha256 }
    $checkpoint = if ($CheckpointCommit) { $CheckpointCommit } elseif ($State.repair -and $State.repair.context -and $State.repair.context.PSObject.Properties['historyCheckpointCommit']) { [string]$State.repair.context.historyCheckpointCommit } elseif ($State.repair -and $State.repair.context) { [string]$State.repair.context.checkpointCommit } else { [string]$State.checkpointCommit }
    return 'sha256:' + (Get-PipelineObjectHash -Value ([PSCustomObject]@{ diagnostic = $identity; checkpoint = $checkpoint }))
}

function Invoke-PipelineRepairVerification {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$CheckId,
        [Parameter(Mandatory = $true)]$Result,
        [string]$Output = ''
    )

    if (-not $State.repair -or -not $State.repair.accepted -or $State.repair.context.stage -cne $Stage -or
        $State.repair.context.failedCheck -cne $CheckId) { return $null }
    $context = $State.repair.context
    $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint
    if (-not $history.exists) { Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Accepted repair has no history.' -Status failed }
    $acceptedEntry = @($history.entries | Where-Object {
            $_.type -eq 'submission-accepted' -and [int]$_.attempt -eq [int]$context.attempt
        } | Select-Object -Last 1)
    if ($acceptedEntry.Count -eq 0) {
        Throw-PipelineError -Code 'repair_history_state_mismatch' -Message 'Accepted repair is missing its history entry.' -Status failed
    }
    $lastVerification = @($history.entries | Where-Object {
            [int]$_.sequence -gt [int]$acceptedEntry[0].sequence -and
            [int]$_.attempt -eq [int]$context.attempt -and
            $_.type -in @('verification-passed', 'verification-failed')
        } | Select-Object -Last 1)
    if ($lastVerification.Count -gt 0) {
        if ($lastVerification[0].type -eq 'verification-passed' -and $State.repair) {
            $State.repair = $null
            Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $State
        }
        return [PSCustomObject]@{
            handled = $true; passed = $lastVerification[0].type -eq 'verification-passed';
            sameFingerprint = if ($lastVerification[0].type -eq 'verification-failed') { [bool]$lastVerification[0].data.sameFingerprint } else { $true }
            newFingerprint = if ($lastVerification[0].type -eq 'verification-failed') { $lastVerification[0].data.newFingerprint } else { $null }
        }
    }
    $logFiles = @($Result.stdoutLog, $Result.stderrLog | Where-Object { $_ })
    if ($Result.status -eq 'passed' -or ($Result.PSObject.Properties['exitCode'] -and $Result.exitCode -eq 0 -and -not $Result.timedOut)) {
        Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint -Stage $Stage -FailedCheck $CheckId -Attempt $context.attempt -CheckpointCommit $context.historyCheckpointCommit -ManifestSha256 $context.manifestSha256 -Type 'verification-passed' -Data ([PSCustomObject]@{
                checkId = $CheckId; exitCode = [int]$Result.exitCode; timedOut = [bool]$Result.timedOut; resultLogFiles = @($logFiles); verifiedCommit = Get-PipelineGitHead $ProjectRoot
            }) | Out-Null
        $State.repair = $null
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $State
        return [PSCustomObject]@{ handled = $true; passed = $true; sameFingerprint = $true; newFingerprint = $null }
    }
    $candidateFingerprint = Get-PipelineRepairFailureFingerprint -State $State -Stage $Stage -CheckId $CheckId -Output $Output -ExitCode ([int]$Result.exitCode) -CheckpointCommit ([string]$context.historyCheckpointCommit)
    $sameFingerprint = $candidateFingerprint -ceq $context.fingerprint
    $newFingerprint = if ($sameFingerprint) { $null } else { Get-PipelineRepairFailureFingerprint -State $State -Stage $Stage -CheckId $CheckId -Output $Output -ExitCode ([int]$Result.exitCode) -CheckpointCommit ([string]$State.checkpointCommit) }
    $historySummary = Get-RepairAttemptSummary -History $history
    $nextAttempt = if ($sameFingerprint) { [int]$historySummary.nextAttempt + 1 } else { 1 }
    Add-RepairHistoryEntry -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint -Stage $Stage -FailedCheck $CheckId -Attempt $context.attempt -CheckpointCommit $context.historyCheckpointCommit -ManifestSha256 $context.manifestSha256 -Type 'verification-failed' -Data ([PSCustomObject]@{
            checkId = $CheckId; exitCode = [int]$Result.exitCode; timedOut = [bool]$Result.timedOut
            diagnosticSummary = Protect-RepairText -Text ([string]$Result.diagnosticSummary) -Root $ProjectRoot
            logFiles = @($logFiles); nextAttempt = $nextAttempt; sameFingerprint = $sameFingerprint
            newFingerprint = if ($sameFingerprint) { $null } else { $newFingerprint }
        }) | Out-Null
    $history = Read-RepairHistory -ProjectRoot $ProjectRoot -RunId $RunId -Fingerprint $context.fingerprint
    $historySummary = Get-RepairAttemptSummary -History $history
    $runSummary = Get-RepairRunAttemptSummary -ProjectRoot $ProjectRoot -RunId $RunId
    Set-PipelineRepairHistoryMirror -State $State -History $history -HistorySummary $historySummary -ConsumedAttempts $runSummary.consumedAttempts
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $State
    return [PSCustomObject]@{ handled = $true; passed = $false; sameFingerprint = $sameFingerprint; newFingerprint = $newFingerprint }
}

function Invoke-PipelineBaselineStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('baseline' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'baseline' -NewStatus 'running' -NewStage 'resolve' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'baseline' -Stage 'baseline'
    $baseline = Invoke-MigrationBaseline -ProjectRoot $ProjectRoot -RunId $RunId
    if ($baseline.status -ne 'passed') {
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'baseline' -Data ([PSCustomObject]@{ status = $baseline.status; diagnostic = $baseline.diagnostic; checks = @($baseline.checks); logs = @($baseline.checks | ForEach-Object { $_.stdoutLog; $_.stderrLog }) })
        Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
        $status = if ($baseline.status -eq 'failed') { 'failed' } else { 'blocked' }
        Throw-PipelineError -Code ([string]$baseline.diagnostic.code) -Message 'Baseline checks did not pass.' -Status $status -Details $baseline.diagnostic
    }
    Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'baseline' -Data ([PSCustomObject]@{ status = 'passed'; checks = @($baseline.checks); logs = @($baseline.checks | ForEach-Object { $_.stdoutLog; $_.stderrLog }) })
    $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'baseline' -Stage 'baseline'
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'baseline' -NewStatus 'running' -NewStage 'resolve' -ExpectedRevision $state.stageRevision | Out-Null
}

function Invoke-PipelineResolveStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    if ('resolve-manifest' -notin @($state.completedOperations)) {
        $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'resolve-manifest' -Stage 'resolve'
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'resolve-manifest' -Step 'resolve-manifest' -OperationIndex 1 -OperationCount 1 -CurrentFile $null -Health 'healthy'
        $metadataRuntime = Get-PipelineRuntimeProfile -ProjectRoot $ProjectRoot -RunId $RunId -ProfileId 'metadata'
        $resolution = Invoke-MigrationResolution -ProjectRoot $ProjectRoot -RunId $RunId -FnmPath $metadataRuntime.fnmPath -NodeVersion $metadataRuntime.nodeVersion
        if ($resolution.status -ne 'resolved') {
            Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'resolve' -Data ([PSCustomObject]@{ status = $resolution.status; diagnostic = $resolution.diagnostic; logs = @($resolution.queryEvents | ForEach-Object { $_.stdoutLog; $_.stderrLog }) })
            Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
            $status = if ($resolution.status -eq 'failed') { 'failed' } else { 'blocked' }
            Throw-PipelineError -Code ([string]$resolution.diagnostic.code) -Message 'Dependency resolution did not complete.' -Status $status -Details $resolution.diagnostic
        }
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'resolve' -Data ([PSCustomObject]@{ status = 'resolved'; logs = @($resolution.queryEvents | ForEach-Object { $_.stdoutLog; $_.stderrLog }) })
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'resolve-manifest' -Stage 'resolve'
    }
    else { $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId }
    if ('create-branch' -notin @($state.completedOperations)) {
        $suffix = $RunId.Substring($RunId.Length - 8)
        if ($suffix -notmatch '^[a-f0-9]{8}$') { Throw-PipelineError -Code 'invalid_run_id' -Message 'Run id suffix cannot form a migration branch.' -Status blocked }
        $branch = "migration/angular-$($state.sourceMajor)-to-$($state.targetMajor)-$suffix"
        if ($branch -notmatch '^migration/angular-[0-9]+-to-[0-9]+-[a-f0-9]{8}$') { Throw-PipelineError -Code 'invalid_migration_branch' -Message 'Migration branch name is invalid.' -Status blocked }
        $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'create-branch' -Stage 'resolve'
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'create-branch' -Step 'create-migration-branch' -OperationIndex 1 -OperationCount 1 -CurrentFile $null -Health 'healthy'
        $exists = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch")
        if ($exists.exitCode -eq 0) {
            Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
            Throw-PipelineError -Code 'migration_branch_exists' -Message "Migration branch already exists: $branch" -Status blocked
        }
        $switch = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('switch', '-c', $branch, $state.initialCommit)
        if ($switch.exitCode -ne 0 -and $switch.stderr -match '(?i)(unknown|not a git command|not available|unsupported).*switch') {
            $switch = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('checkout', '-b', $branch, $state.initialCommit)
        }
        if ($switch.exitCode -ne 0) {
            Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
            Throw-PipelineError -Code 'migration_branch_create_failed' -Message 'Could not create the migration branch.' -Status failed -Details $switch.stderr
        }
        $head = Get-PipelineGitHead -ProjectRoot $ProjectRoot
        if ($head -cne $state.initialCommit) { Throw-PipelineError -Code 'git_head_changed' -Message 'Migration branch does not point to the initial commit.' -Status blocked }
        $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        $state.migrationBranch = $branch
        $state.checkpointCommit = $head
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'resolve' -Data ([PSCustomObject]@{ status = 'passed'; exitCode = $switch.exitCode; timedOut = $false; durationMs = 0; migrationBranch = $branch; newCommit = $head })
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'create-branch' -Stage 'resolve' -CheckpointCommit $head
    }
    else { $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId }
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'resolve' -NewStatus 'running' -NewStage 'update-angular' -ExpectedRevision $state.stageRevision | Out-Null
}

function Invoke-PipelineAngularStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('update-angular' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'update-angular' -NewStatus 'running' -NewStage 'update-dependencies' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    $expectedHash = Get-ResolvedManifestHash -Manifest $manifest
    if ($manifest.manifestSha256 -ne $state.manifestSha256 -or $expectedHash -ne $state.manifestSha256) { Throw-PipelineError -Code 'manifest_integrity_failed' -Message 'Resolved manifest integrity failed before Angular update.' -Status failed }
    $runtime = Get-PipelineRuntimeProfile -ProjectRoot $ProjectRoot -RunId $RunId -ProfileId 'update-angular'
    $ng = Get-PipelineLocalNg -ProjectRoot $ProjectRoot
    $before = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'update-angular' -Stage 'update-angular'
    $commandResults = @()
    try {
        $commands = @(Get-PipelineAngularUpdateCommands -Manifest $manifest)
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-angular' -Step 'angular-update-commands' -OperationIndex 0 -OperationCount $commands.Count -CurrentFile $null -Health 'healthy'
        $index = 0
        foreach ($command in $commands) {
            $index++
            if ($index -le $state.angularCommandIndex) { continue }
            Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-angular' -Step ('execute:' + $command.id) -OperationIndex $index -OperationCount $commands.Count -CurrentFile $null -Health 'healthy'
            $commandResults += Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'update-angular' -Prefix ('{0:D2}-{1}' -f $index, ($command.id -replace '[^a-zA-Z0-9._-]', '_')) -FilePath $ng -Arguments $command.arguments -WorkingDirectory $ProjectRoot -TimeoutSeconds 1800 -NodeVersion $runtime.nodeVersion -FnmPath $runtime.fnmPath -RunId $RunId -OperationId 'update-angular'
            $last = $commandResults[-1]
            Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-angular' -Step ('verify:' + $command.id) -OperationIndex $index -OperationCount $commands.Count -CurrentFile $null -Health 'healthy'
            $verification = Invoke-PipelineRepairVerification -ProjectRoot $ProjectRoot -RunId $RunId -State (Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId) -Stage 'update-angular' -CheckId $command.id -Result $last -Output ([string]$last.stdout + "`n" + [string]$last.stderr)
            if ($last.timedOut -or $last.exitCode -ne 0) {
                Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
                Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'update-angular' -Data ([PSCustomObject]@{ status = 'failed'; exitCode = $last.exitCode; timedOut = $last.timedOut; processStalled = $last.processStalled; terminationReason = $last.terminationReason; durationMs = $last.durationMs; stdoutLog = $last.stdoutLog; stderrLog = $last.stderrLog })
                Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
                $blocked = [string]$last.stderr + "`n" + [string]$last.stdout
                if ($last.processStalled) {
                    $context = New-PipelineFailureContext -ProjectRoot $ProjectRoot -RunPaths $paths -Stage 'update-angular' -CheckId $command.id -Code 'process_stalled' -Message 'Angular update stalled due to process inactivity.' -Output $blocked -ExitCode $last.exitCode -LogFiles @($last.stdoutLog, $last.stderrLog)
                    if (@($context.allowedPaths).Count -eq 0) { Throw-PipelineError -Code 'repair_scope_unknown' -Message 'Stalled Angular update has no safe repair scope.' -Status blocked -Details $context }
                    Throw-PipelineError -Code 'process_stalled' -Message 'Angular update was terminated after an inactivity timeout.' -Status needs-repair -Details ([PSCustomObject]@{ context = $context; process = $last })
                }
                if ($blocked -match '(?i)(ERESOLVE|peer depend|conflict|integrity|version)') { Throw-PipelineError -Code 'angular_update_conflict' -Message 'Angular update encountered a dependency or version conflict.' -Status blocked -Details $last }
                $context = New-PipelineFailureContext -ProjectRoot $ProjectRoot -RunPaths $paths -Stage 'update-angular' -CheckId $command.id -Code 'angular_update_failed' -Message 'Angular update failed.' -Output $blocked -ExitCode $last.exitCode -LogFiles @($last.stdoutLog, $last.stderrLog)
                if (@($context.allowedPaths).Count -eq 0) { Throw-PipelineError -Code 'repair_scope_unknown' -Message 'Angular update failure has no safe repair scope.' -Status blocked -Details $context }
                Throw-PipelineError -Code 'angular_update_failed' -Message 'Angular update requires a scoped repair.' -Status needs-repair -Details $context
            }
            Assert-PipelineManifestTargets -ProjectRoot $ProjectRoot -Manifest $manifest -FnmPath $runtime.fnmPath -NodeVersion $runtime.nodeVersion
            $checkpoint = New-PipelineCheckpoint -ProjectRoot $ProjectRoot -RunId $RunId -Message "chore(migration): Angular $($state.sourceMajor) to $($state.targetMajor) schematics [$RunId]"
            $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
            $state.checkpointCommit = $checkpoint
            $state.angularCommandIndex = $index
            $state.activeOperation.checkpointCommit = $checkpoint
            Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
        }
        Assert-PipelineManifestTargets -ProjectRoot $ProjectRoot -Manifest $manifest -FnmPath $runtime.fnmPath -NodeVersion $runtime.nodeVersion
        $checkpoint = New-PipelineCheckpoint -ProjectRoot $ProjectRoot -RunId $RunId -Message "chore(migration): Angular $($state.sourceMajor) to $($state.targetMajor) schematics [$RunId]"
        $summary = [PSCustomObject]@{ status = 'passed'; exitCode = 0; timedOut = $false; durationMs = ($commandResults | Measure-Object -Property durationMs -Sum).Sum; logs = @($commandResults | ForEach-Object { $_.stdoutLog; $_.stderrLog }); newCommit = $checkpoint }
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'update-angular' -Data $summary
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'update-angular' -Stage 'update-angular' -CheckpointCommit $checkpoint
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'update-angular' -NewStatus 'running' -NewStage 'update-dependencies' -ExpectedRevision $state.stageRevision | Out-Null
    }
    catch {
        $failure = $_
        $current = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        if ($current.activeOperation) {
            Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        }
        throw $failure
    }
}

function Invoke-PipelineDependencyStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('update-dependencies' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'update-dependencies' -NewStatus 'running' -NewStage 'install' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    if ($manifest.manifestSha256 -ne $state.manifestSha256 -or (Get-ResolvedManifestHash -Manifest $manifest) -ne $state.manifestSha256) { Throw-PipelineError -Code 'manifest_integrity_failed' -Message 'Resolved manifest integrity failed before dependency update.' -Status failed }
    $dependencies = @(Get-PipelineResolvedDependencies -Manifest $manifest)
    $runtime = Get-PipelineRuntimeProfile -ProjectRoot $ProjectRoot -RunId $RunId -ProfileId 'update-dependencies'
    $package = Get-ProjectPackage -ProjectRoot $ProjectRoot
    foreach ($dependency in $dependencies) {
        $section = Get-ProjectProperty -Object $package -Name $dependency.section
        if ($dependency.change -eq 'added-required-tooling' -and $dependency.section -eq 'devDependencies') { continue }
        if ($null -eq $section -or -not $section.PSObject.Properties[$dependency.name]) { Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Dependency is absent from package.json: $($dependency.name)" -Status blocked }
    }
    $before = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'update-dependencies' -Stage 'update-dependencies'
    try {
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-dependencies' -Step 'render-exact-package' -OperationIndex 1 -OperationCount 7 -CurrentFile 'package.json' -Health 'healthy'
        $exact = Invoke-PipelineRenderer -ProjectRoot $ProjectRoot -RunPaths $paths -Mode 'exact' -Dependencies $dependencies -FnmPath $runtime.fnmPath -NodeVersion $runtime.nodeVersion
        Write-MigrationTextAtomic -Text $exact.text -Path (Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json')
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-dependencies' -Step 'install-lockfile' -OperationIndex 2 -OperationCount 7 -CurrentFile 'package-lock.json' -Health 'healthy'
        $install = Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'update-dependencies' -Prefix '02-npm-install-lockfile' -FilePath 'npm' -Arguments @('install', '--package-lock-only') -WorkingDirectory $ProjectRoot -TimeoutSeconds 900 -NodeVersion $runtime.nodeVersion -FnmPath $runtime.fnmPath -RunId $RunId -OperationId 'update-dependencies'
        if ($install.timedOut -or $install.exitCode -ne 0) {
            Throw-PipelineError -Code 'dependency_install_failed' -Message 'npm install --package-lock-only failed.' -Status blocked -Details $install
        }
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-dependencies' -Step 'verify-lockfile' -OperationIndex 3 -OperationCount 7 -CurrentFile 'package-lock.json' -Health 'healthy'
        $null = Assert-PipelineDirectDependencyLock -ProjectRoot $ProjectRoot -Manifest $manifest -FnmPath $runtime.fnmPath -NodeVersion $runtime.nodeVersion
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-dependencies' -Step 'render-declared-package' -OperationIndex 4 -OperationCount 7 -CurrentFile 'package.json' -Health 'healthy'
        $declared = Invoke-PipelineRenderer -ProjectRoot $ProjectRoot -RunPaths $paths -Mode 'declared' -Dependencies $dependencies -FnmPath $runtime.fnmPath -NodeVersion $runtime.nodeVersion
        Write-MigrationTextAtomic -Text $declared.text -Path (Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json')
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-dependencies' -Step 'verify-declared-lockfile' -OperationIndex 5 -OperationCount 7 -CurrentFile 'package-lock.json' -Health 'healthy'
        Assert-PipelineDirectDependencyLock -ProjectRoot $ProjectRoot -Manifest $manifest -FnmPath $runtime.fnmPath -NodeVersion $runtime.nodeVersion | Out-Null
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-dependencies' -Step 'verify-declared-dependencies' -OperationIndex 6 -OperationCount 7 -CurrentFile 'package.json' -Health 'healthy'
        Assert-PipelineDeclaredDependencies -ProjectRoot $ProjectRoot -Manifest $manifest
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'update-dependencies' -Step 'checkpoint' -OperationIndex 7 -OperationCount 7 -CurrentFile $null -Health 'healthy'
        $checkpoint = New-PipelineCheckpoint -ProjectRoot $ProjectRoot -RunId $RunId -Message "chore(migration): align dependencies for Angular $($state.targetMajor) [$RunId]"
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'update-dependencies' -Data ([PSCustomObject]@{ status = 'passed'; exitCode = $install.exitCode; timedOut = $install.timedOut; durationMs = $install.durationMs; stdoutLog = $install.stdoutLog; stderrLog = $install.stderrLog; newCommit = $checkpoint })
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'update-dependencies' -Stage 'update-dependencies' -CheckpointCommit $checkpoint
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'update-dependencies' -NewStatus 'running' -NewStage 'install' -ExpectedRevision $state.stageRevision | Out-Null
    }
    catch {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        throw
    }
}

function Invoke-PipelineInstallStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('install' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'install' -NewStatus 'running' -NewStage 'validate' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $packagePath = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json' -MustExist
    $lockPath = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package-lock.json' -MustExist
    $packageHash = (Get-FileHash $packagePath).Hash
    $lockHash = (Get-FileHash $lockPath).Hash
    $runtime = Get-PipelineRuntimeProfile -ProjectRoot $ProjectRoot -RunId $RunId -ProfileId 'install'
    $before = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'install' -Stage 'install'
    Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'install' -Step 'npm-ci' -OperationIndex 1 -OperationCount 2 -CurrentFile 'node_modules' -Health 'healthy'
    try {
        $ci = Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'install' -Prefix '01-npm-ci' -FilePath 'npm' -Arguments @('ci') -WorkingDirectory $ProjectRoot -TimeoutSeconds 900 -NodeVersion $runtime.nodeVersion -FnmPath $runtime.fnmPath -RunId $RunId -OperationId 'install'
    }
    catch {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        throw
    }
    if ($ci.timedOut -or $ci.exitCode -ne 0) {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'install' -Data ([PSCustomObject]@{ status = 'blocked'; exitCode = $ci.exitCode; timedOut = $ci.timedOut; durationMs = $ci.durationMs; stdoutLog = $ci.stdoutLog; stderrLog = $ci.stderrLog })
        Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
        Throw-PipelineError -Code 'dependency_install_failed' -Message 'npm ci failed.' -Status blocked -Details $ci
    }
    if ((Get-FileHash $packagePath).Hash -ne $packageHash -or (Get-FileHash $lockPath).Hash -ne $lockHash) {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        Throw-PipelineError -Code 'dependency_install_failed' -Message 'npm ci modified package metadata.' -Status blocked
    }
    try {
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'install' -Step 'verify-dependency-tree' -OperationIndex 2 -OperationCount 2 -CurrentFile 'package-lock.json' -Health 'healthy'
        $ls = Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'install' -Prefix '02-npm-ls-all' -FilePath 'npm' -Arguments @('ls', '--all') -WorkingDirectory $ProjectRoot -TimeoutSeconds 300 -NodeVersion $runtime.nodeVersion -FnmPath $runtime.fnmPath -RunId $RunId -OperationId 'install'
    }
    catch {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        throw
    }
    if ($ls.timedOut -or $ls.exitCode -ne 0 -or ([string]$ls.stdout + "`n" + [string]$ls.stderr) -match '(?i)\b(invalid|extraneous|missing)\b') {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'install' -Data ([PSCustomObject]@{ status = 'blocked'; exitCode = $ls.exitCode; timedOut = $ls.timedOut; durationMs = $ls.durationMs; stdoutLog = $ls.stdoutLog; stderrLog = $ls.stderrLog })
        Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
        Throw-PipelineError -Code 'dependency_install_failed' -Message 'npm ls --all reported an invalid dependency tree.' -Status blocked -Details $ls
    }
    Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'install' -Data ([PSCustomObject]@{ status = 'passed'; exitCode = $ls.exitCode; timedOut = $ls.timedOut; durationMs = $ls.durationMs; stdoutLog = $ls.stdoutLog; stderrLog = $ls.stderrLog })
    $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'install' -Stage 'install'
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'install' -NewStatus 'running' -NewStage 'validate' -ExpectedRevision $state.stageRevision | Out-Null
}

function Invoke-PipelineValidationStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('validate' -in @($state.completedOperations) -and 'technical-result' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'validate' -NewStatus 'verified' -NewStage 'document' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'validate' -Stage 'validate'
    $results = @($state.validationResults)
    $checks = @($manifest.checks | Where-Object { $_.id -in $script:TechnicalCheckIds })
    Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'validate' -Step 'validation-checks' -OperationIndex 0 -OperationCount $checks.Count -CurrentFile $null -Health 'healthy'
    $checkIndex = 0
    foreach ($check in $checks) {
        if ($check.id -in @($results | ForEach-Object { $_.id })) { continue }
        $checkIndex++
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'validate' -Step ('validate:' + $check.id) -OperationIndex $checkIndex -OperationCount $checks.Count -CurrentFile $null -Health 'healthy'
        if ($check.status -eq 'not-configured') {
            $results += [PSCustomObject]@{
                id = $check.id; status = 'not-configured'; exitCode = $null; timedOut = $false
                startedAt = $null; finishedAt = $null; durationMs = 0
                stdoutLog = $null; stderrLog = $null; diagnosticSummary = $check.reason
                executable = $null
            }
            continue
        }
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'check-started' -Stage 'validate' -Data ([PSCustomObject]@{ checkId = $check.id })
        $runtime = Get-PipelineRuntimeProfile -ProjectRoot $ProjectRoot -RunId $RunId -ProfileId ('validate:' + [string]$check.id)
        $result = Invoke-ProjectCheck -Check $check -LogDirectory (Join-Path $paths.logs 'validate') -FnmPath $runtime.fnmPath -NodeVersion $runtime.nodeVersion
        $results += $result
        Update-PipelineOperationProgress -ProjectRoot $ProjectRoot -RunId $RunId -OperationId 'validate' -Step ('finished:' + $check.id) -OperationIndex $checkIndex -OperationCount $checks.Count -CurrentFile $null -Health 'healthy'
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'check-finished' -Stage 'validate' -Data $result
        $output = ''
        if ($result.stdoutLog) { $output += [IO.File]::ReadAllText((Join-Path $paths.root $result.stdoutLog)) }
        if ($result.stderrLog) { $output += "`n" + [IO.File]::ReadAllText((Join-Path $paths.root $result.stderrLog)) }
        $verification = Invoke-PipelineRepairVerification -ProjectRoot $ProjectRoot -RunId $RunId -State (Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId) -Stage 'validate' -CheckId $result.id -Result $result -Output $output
        if ($result.status -notin @('passed', 'not-configured')) {
            Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'validate' -Data ([PSCustomObject]@{ status = $result.status; exitCode = $result.exitCode; timedOut = $result.timedOut; stdoutLog = $result.stdoutLog; stderrLog = $result.stderrLog })
            Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
            $context = New-PipelineFailureContext -ProjectRoot $ProjectRoot -RunPaths $paths -Stage 'validate' -CheckId $result.id -Code 'validation_failed' -Message $result.diagnosticSummary -Output $output -ExitCode $result.exitCode -LogFiles @($result.stdoutLog, $result.stderrLog)
            if (@($context.allowedPaths).Count -eq 0) { Throw-PipelineError -Code 'repair_scope_unknown' -Message 'Validation failure has no safe repair scope.' -Status blocked -Details $context }
            Throw-PipelineError -Code 'validation_failed' -Message "Validation check failed: $($result.id)" -Status needs-repair -Details ([PSCustomObject]@{ context = $context; check = $result })
        }
        $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        $state.validationResults = @($results)
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    }
    Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'validate' -Data ([PSCustomObject]@{ status = 'passed'; checks = @($results) })
    $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'validate' -Stage 'validate'
    $state.migrationStatus = 'verified'
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    $result = Write-PipelineTechnicalResult -ProjectRoot $ProjectRoot -RunId $RunId -Manifest $manifest -CheckResults $results -RunPaths $paths
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $state.completedOperations = @($state.completedOperations) + @('technical-result')
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'technical-result-written' -Stage 'validate' -Data ([PSCustomObject]@{ resultSha256 = $result.resultSha256 })
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'validate' -NewStatus 'verified' -NewStage 'document' -ExpectedRevision $state.stageRevision | Out-Null
}

function ConvertTo-PipelineRunEnvelope {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $data = [ordered]@{
        runId                       = $state.runId
        status                      = $state.status
        stage                       = $state.stage
        stageRevision               = $state.stageRevision
        attempt                     = $state.attempt
        migrationStatus             = $state.migrationStatus
        documentationStatus         = $state.documentationStatus
        documentation               = $state.documentation
        completedOperations         = @($state.completedOperations)
        skippedChecks               = @($state.skippedChecks)
        documentationReady          = $state.status -eq 'verified' -and $state.documentation.status -ne 'completed'
        documentationContextCommand = if ($state.status -eq 'verified' -and $state.documentation.status -ne 'completed') { 'documentation-context' } else { $null }
        manifest                    = '.angular-migration/runs/' + $RunId + '/manifest.json'
        state                       = '.angular-migration/runs/' + $RunId + '/state.json'
        result                      = if (Test-Path -LiteralPath (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId).result -PathType Leaf) { '.angular-migration/runs/' + $RunId + '/result.json' } else { $null }
    }
    return [PSCustomObject]@{ ok = $state.status -eq 'verified'; status = $state.status; data = [PSCustomObject]$data; error = if ($state.lastDiagnostic) { $state.lastDiagnostic } else { $null } }
}

function Invoke-MigrationRun {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$RunId = ''
    )

    $operationLeaseCreated = $false
    try {
        if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-MigrationError -Code 'run_id_required' -Message '-RunId is required for run.' -Status blocked }
        Assert-MigrationRunId -RunId $RunId
        $root = Resolve-MigrationRoot -Path $ProjectRoot
        Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
        $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        $manifest = Read-MigrationJson -Path $paths.manifest -Required
        if ($manifest.runId -cne $RunId -or $manifest.project.root -cne $root -or $manifest.sourceMajor -ne $state.sourceMajor -or $manifest.targetMajor -ne $state.targetMajor) {
            Throw-PipelineError -Code 'invalid_run_manifest' -Message 'Manifest and state do not describe the same run.' -Status failed
        }
        if ($state.manifestSha256) {
            if ($manifest.manifestSha256 -ne $state.manifestSha256 -or (Get-ResolvedManifestHash -Manifest $manifest) -ne $state.manifestSha256) {
                Throw-PipelineError -Code 'manifest_integrity_failed' -Message 'Resolved migration manifest has been altered.' -Status failed
            }
        }
        if ($state.status -in @('running', 'needs-repair')) {
            $state = Invoke-PipelineRepairHistoryRecovery -ProjectRoot $root -RunId $RunId
        }
        if ($state.status -in @('verified', 'completed')) {
            Assert-PipelineTechnicalResult -ProjectRoot $root -RunId $RunId -RunPaths $paths | Out-Null
            return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId
        }
        if ($state.status -in @('needs-repair', 'blocked', 'failed')) { return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId }
        New-MigrationOperationLock -ProjectRoot $root -RunId $RunId -OperationId 'run'
        $operationLeaseCreated = $true
        $state = Invoke-PipelineActiveOperationRecovery -ProjectRoot $root -RunId $RunId
        if ($state.status -in @('blocked', 'failed')) { return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId }
        Assert-PipelineRunGitContext -ProjectRoot $root -State $state
        while ($true) {
            $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
            if ($state.status -ne 'running') { break }
            Assert-PipelineRunGitContext -ProjectRoot $root -State $state
            switch ($state.stage) {
                'baseline' { Invoke-PipelineBaselineStage -ProjectRoot $root -RunId $RunId }
                'resolve' { Invoke-PipelineResolveStage -ProjectRoot $root -RunId $RunId }
                'update-angular' { Invoke-PipelineAngularStage -ProjectRoot $root -RunId $RunId }
                'update-dependencies' { Invoke-PipelineDependencyStage -ProjectRoot $root -RunId $RunId }
                'install' { Invoke-PipelineInstallStage -ProjectRoot $root -RunId $RunId }
                'validate' { Invoke-PipelineValidationStage -ProjectRoot $root -RunId $RunId }
                default { Throw-PipelineError -Code 'invalid_stage' -Message "Unknown migration stage: $($state.stage)" -Status failed }
            }
        }
        return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId
    }
    catch {
        $errorRecord = $_
        $exception = $errorRecord.Exception
        $errorInfo = Get-PipelineRunError -ErrorRecord $errorRecord
        $status = if ($exception.Data['status']) { [string]$exception.Data['status'] } else { 'failed' }
        $root = $null
        try { $root = Resolve-MigrationRoot -Path $ProjectRoot } catch { }
        $hasRunId = -not [string]::IsNullOrWhiteSpace($RunId)
        if ($hasRunId -and $root -and (Test-Path -LiteralPath (Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId).state -PathType Leaf)) {
            try {
                $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
                if ($errorInfo.code -like 'operation_lock_*') {
                    return [PSCustomObject]@{
                        ok     = $false
                        status = $status
                        data   = [PSCustomObject]@{ runId = $RunId; stage = $state.stage; operation = $state.activeOperation }
                        error  = $errorInfo
                    }
                }
                if ($state.activeOperation) {
                    Finish-PipelineOperation -ProjectRoot $root -RunId $RunId -Stage $state.activeOperation.stage -Data ([PSCustomObject]@{ status = $status; diagnostic = $errorInfo })
                    Clear-PipelineOperation -ProjectRoot $root -RunId $RunId | Out-Null
                }
                if ($state.status -in @('running', 'needs-repair')) {
                    $targetStatus = if ($status -in @('needs-repair', 'blocked', 'failed')) { $status } else { 'failed' }
                    $diagnostic = [PSCustomObject]@{ code = $errorInfo.code; message = $errorInfo.message; details = $errorInfo.details }
                    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
                    Move-MigrationState -ProjectRoot $root -RunId $RunId -ExpectedStatus $state.status -ExpectedStage $state.stage -NewStatus $targetStatus -NewStage $state.stage -ExpectedRevision $state.stageRevision -Diagnostic $diagnostic | Out-Null
                    if ($targetStatus -in @('blocked', 'failed')) { Remove-ActiveRunLock -ProjectRoot $root -RunId $RunId }
                }
                if ($state.status -in @('verified', 'completed')) {
                    return [PSCustomObject]@{
                        ok     = $false
                        status = 'failed'
                        data   = [PSCustomObject]@{ runId = $RunId; result = '.angular-migration/runs/' + $RunId + '/result.json' }
                        error  = $errorInfo
                    }
                }
                return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId
            }
            catch {
                $errorInfo = Get-PipelineRunError -ErrorRecord $_
            }
        }
        return [PSCustomObject]@{ ok = $false; status = $status; data = [PSCustomObject]@{}; error = $errorInfo }
    }
    finally {
        if ($operationLeaseCreated) { Remove-MigrationOperationLock -ProjectRoot $ProjectRoot -RunId $RunId }
    }
}

$script:DocumentationRequiredFiles = @('README.md', 'changes.md', 'errors-and-repairs.md', 'warnings.md', 'new-concepts.md', 'dependencies.md', 'validation.md', 'sources.md')
$script:DocumentationFileOrder = @('README.md', 'changes.md', 'dependencies.md', 'errors-and-repairs.md', 'new-concepts.md', 'sources.md', 'validation.md', 'warnings.md')
$script:DocumentationQuestions = @(
    'Que breaking changes oficiales aplican al salto de Angular?',
    'Que migraciones automaticas declara cada paquete actualizado?',
    'Que conceptos nuevos afectan al mantenimiento del proyecto?',
    'Que warnings o deprecations oficiales pueden aparecer?'
)

function Throw-DocumentationError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('blocked', 'failed')][string]$Status = 'blocked',
        $Details = $null
    )
    Throw-PipelineError -Code $Code -Message $Message -Status $Status -Details $Details
}

function Assert-DocumentationObject {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -isnot [PSCustomObject]) { Throw-DocumentationError -Code 'documentation_schema_invalid' -Message "Documentation $Label must be an object." }
    $names = @($Value.PSObject.Properties.Name)
    if (@($names | Where-Object { $_ -cnotin $Allowed }).Count -gt 0) { Throw-DocumentationError -Code 'documentation_schema_invalid' -Message "Documentation $Label contains an unknown property." }
    foreach ($name in $Required) {
        if ($names -cnotcontains $name) { Throw-DocumentationError -Code 'documentation_schema_invalid' -Message "Documentation $Label is missing a required property: $name" }
    }
}

function Assert-DocumentationString {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$Maximum = 0,
        [switch]$AllowEmpty
    )
    if ($Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) {
        Throw-DocumentationError -Code 'documentation_schema_invalid' -Message "Documentation $Label must be a non-empty string."
    }
    if ($Maximum -gt 0 -and $Value.Length -gt $Maximum) { Throw-DocumentationError -Code 'documentation_text_too_long' -Message "Documentation $Label exceeds its length limit." }
}

function Assert-DocumentationArray {
    param([AllowNull()]$Value, [Parameter(Mandatory = $true)][string]$Label)
    if ($null -eq $Value -or $Value -isnot [array]) { Throw-DocumentationError -Code 'documentation_schema_invalid' -Message "Documentation $Label must be an array." }
}

function Assert-DocumentationUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or
        $uri.IsLoopback -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.Host -match '^(?i:localhost|127(?:\.\d+){3}|::1)$') {
        Throw-DocumentationError -Code 'documentation_source_url_invalid' -Message 'Documentation sources must use a public HTTPS URL without query, fragment or credentials.'
    }
    $address = $null
    if ([Net.IPAddress]::TryParse($uri.DnsSafeHost, [ref]$address)) {
        $bytes = $address.GetAddressBytes()
        if (($bytes.Length -eq 4 -and (($bytes[0] -eq 10) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254))) -or $address.IsIPv6LinkLocal -or $address.IsIPv6SiteLocal) {
            Throw-DocumentationError -Code 'documentation_source_url_invalid' -Message 'Documentation sources must use a public HTTPS URL without query, fragment or credentials.'
        }
    }
}

function Assert-DocumentationUtcTimestamp {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Label)
    try { $timestamp = [DateTimeOffset]::Parse($Value) } catch { Throw-DocumentationError -Code 'documentation_timestamp_invalid' -Message "Documentation $Label timestamp is invalid." }
    if ($timestamp.Offset -ne [TimeSpan]::Zero) { Throw-DocumentationError -Code 'documentation_timestamp_invalid' -Message "Documentation $Label timestamp must be UTC." }
}

function Get-DocumentationAllowedVersions {
    param([Parameter(Mandatory = $true)]$Manifest)
    $versions = @()
    foreach ($dependency in @($Manifest.dependencies)) {
        foreach ($property in @('currentVersion', 'targetVersion')) {
            if ($dependency.PSObject.Properties[$property] -and $dependency.$property) { $versions += [string]$dependency.$property }
        }
    }
    foreach ($container in @($Manifest.angular, $Manifest.node)) {
        if ($container) {
            foreach ($property in @('resolvedCoreVersion', 'activeVersion')) {
                if ($container.PSObject.Properties[$property] -and $container.$property) { $versions += [string]$container.$property }
            }
        }
    }
    return @($versions | Sort-Object -Unique)
}

function Assert-DocumentationTextSafe {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string[]]$AllowedVersions,
        [switch]$AllowOperationalText
    )
    if ($null -eq $Text) { return }
    if ($ProjectRoot -and $Text.IndexOf($ProjectRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $Text -match '(?i)(?:gh[pousr]_[a-z0-9_]+|github_pat_[a-z0-9_]+|npm_[a-z0-9]+|eyJ[a-z0-9_.-]+)' -or
        $Text -match '(?i)\b(?:authorization|proxy-authorization|cookie|password|secret)\s*[:=]' -or
        $Text -match '(?i)(?:\.npmrc|\.env(?:\.|\b))' -or
        $Text -match '(?i)(?:[A-Za-z]:\\|(?<!:)\/(?:Users|home|root)\/)' -or
        $Text -match '(?i)\bBearer\s+\S+' -or
        $Text -match '(?i)--(?:force|legacy-peer-deps|ignore-scripts)') {
        Throw-DocumentationError -Code 'documentation_sensitive_or_executable_text' -Message "Documentation $Label contains a secret, local path or executable fragment."
    }
    if (-not $AllowOperationalText -and ($Text -match '```' -or $Text -match '(?im)(?:^|[\s>])(?:npm|n(?:px)|ng|git|powershell|pwsh|cmd(?:\.exe)?|yarn|pnpm)\s+(?:install|ci|run|update|build|test|ls|status|commit|exec|view|config|add|restore|checkout|switch)\b')) {
        Throw-DocumentationError -Code 'documentation_sensitive_or_executable_text' -Message "Documentation $Label contains an executable fragment."
    }
    foreach ($match in [regex]::Matches($Text, '\b\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\b')) {
        if ($AllowedVersions -cnotcontains $match.Value) {
            Throw-DocumentationError -Code 'documentation_version_not_in_manifest' -Message "Documentation $Label contains a version not present in the manifest: $($match.Value)"
        }
    }
}

function Assert-DocumentationResearch {
    param(
        [Parameter(Mandatory = $true)]$Research,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    Assert-DocumentationObject -Value $Research -Allowed @('schemaVersion', 'runId', 'sourceMajor', 'targetMajor', 'manifestSha256', 'researchedAt', 'sources', 'findings', 'concepts', 'unresolved') -Required @('schemaVersion', 'runId', 'sourceMajor', 'targetMajor', 'manifestSha256', 'researchedAt', 'sources', 'findings', 'concepts', 'unresolved') -Label 'research'
    if ($Research.schemaVersion -ne 1 -or $Research.runId -cne $RunId -or $Research.sourceMajor -ne $State.sourceMajor -or $Research.targetMajor -ne $State.targetMajor -or $Research.manifestSha256 -cne $State.manifestSha256) {
        Throw-DocumentationError -Code 'documentation_identity_mismatch' -Message 'Research does not belong to the active run or manifest.'
    }
    Assert-DocumentationUtcTimestamp -Value ([string]$Research.researchedAt) -Label 'research'
    $allowedVersions = Get-DocumentationAllowedVersions -Manifest $Manifest
    $sourceIds = @()
    $primarySourceIds = @()
    Assert-DocumentationArray -Value $Research.sources -Label 'sources'
    if (@($Research.sources).Count -eq 0) { Throw-DocumentationError -Code 'documentation_source_required' -Message 'Research requires at least one source.' }
    foreach ($source in @($Research.sources)) {
        Assert-DocumentationObject -Value $source -Allowed @('id', 'title', 'url', 'publisher', 'primary', 'accessedAt') -Required @('id', 'title', 'url', 'publisher', 'primary', 'accessedAt') -Label 'source'
        Assert-DocumentationString -Value $source.id -Label 'source.id'
        if ($source.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Throw-DocumentationError -Code 'documentation_source_invalid' -Message "Invalid research source id: $($source.id)" }
        if ($sourceIds -ccontains $source.id) { Throw-DocumentationError -Code 'documentation_source_duplicate' -Message "Research source id is repeated: $($source.id)" }
        $sourceIds += [string]$source.id
        Assert-DocumentationString -Value $source.title -Label 'source.title' -Maximum 160
        Assert-DocumentationString -Value $source.publisher -Label 'source.publisher' -Maximum 160
        Assert-DocumentationString -Value $source.url -Label 'source.url'
        Assert-DocumentationUrl -Url $source.url
        if ($source.primary -isnot [bool]) { Throw-DocumentationError -Code 'documentation_schema_invalid' -Message 'source.primary must be boolean.' }
        Assert-DocumentationString -Value $source.accessedAt -Label 'source.accessedAt'
        Assert-DocumentationUtcTimestamp -Value ([string]$source.accessedAt) -Label 'source'
        Assert-DocumentationTextSafe -Text ([string]$source.title) -Label 'source.title' -ProjectRoot $ProjectRoot -AllowedVersions $allowedVersions
        Assert-DocumentationTextSafe -Text ([string]$source.publisher) -Label 'source.publisher' -ProjectRoot $ProjectRoot -AllowedVersions $allowedVersions
        if ($source.primary) { $primarySourceIds += [string]$source.id }
    }
    $manifestNames = @($Manifest.dependencies | ForEach-Object { [string]$_.name })
    Assert-DocumentationArray -Value $Research.findings -Label 'findings'
    $findingIds = @()
    foreach ($finding in @($Research.findings)) {
        Assert-DocumentationObject -Value $finding -Allowed @('id', 'kind', 'area', 'title', 'summary', 'affectedPackages', 'sourceIds', 'applicability') -Required @('id', 'kind', 'area', 'title', 'summary', 'affectedPackages', 'sourceIds', 'applicability') -Label 'finding'
        Assert-DocumentationString -Value $finding.id -Label 'finding.id'
        if ($finding.id -notmatch '^F-[0-9]+$' -or $findingIds -ccontains $finding.id) { Throw-DocumentationError -Code 'documentation_finding_invalid' -Message "Finding id is invalid or repeated: $($finding.id)" }
        $findingIds += [string]$finding.id
        if ($finding.kind -notin @('official-change', 'observed-change', 'inference', 'not-applicable')) { Throw-DocumentationError -Code 'documentation_kind_invalid' -Message "Unknown finding kind: $($finding.kind)" }
        Assert-DocumentationString -Value $finding.area -Label 'finding.area' -Maximum 120
        Assert-DocumentationString -Value $finding.title -Label 'finding.title' -Maximum 160
        Assert-DocumentationString -Value $finding.summary -Label 'finding.summary' -Maximum 2000
        Assert-DocumentationArray -Value $finding.affectedPackages -Label 'finding.affectedPackages'
        if (@($finding.affectedPackages | Sort-Object -Unique).Count -ne @($finding.affectedPackages).Count) { Throw-DocumentationError -Code 'documentation_package_duplicate' -Message "Finding repeats an affected package: $($finding.id)" }
        foreach ($package in @($finding.affectedPackages)) {
            Assert-DocumentationString -Value $package -Label 'finding.affectedPackages.item'
            if ($manifestNames -cnotcontains $package) { Throw-DocumentationError -Code 'documentation_package_not_in_manifest' -Message "Finding names a package absent from the manifest: $package" }
        }
        Assert-DocumentationArray -Value $finding.sourceIds -Label 'finding.sourceIds'
        if (@($finding.sourceIds).Count -eq 0 -or @($finding.sourceIds | Sort-Object -Unique).Count -ne @($finding.sourceIds).Count) { Throw-DocumentationError -Code 'documentation_source_invalid' -Message "Finding sourceIds are empty or repeated: $($finding.id)" }
        $findingSources = @()
        foreach ($sourceId in @($finding.sourceIds)) {
            Assert-DocumentationString -Value $sourceId -Label 'finding.sourceIds.item'
            if ($findingSources -ccontains $sourceId -or $sourceIds -cnotcontains $sourceId) { Throw-DocumentationError -Code 'documentation_source_unknown' -Message "Finding references an unknown or repeated source: $sourceId" }
            $findingSources += [string]$sourceId
        }
        if ($finding.kind -eq 'official-change' -and @($findingSources | Where-Object { $primarySourceIds -ccontains $_ }).Count -eq 0) {
            Throw-DocumentationError -Code 'documentation_primary_source_required' -Message "Official finding has no primary source: $($finding.id)"
        }
        if ($finding.applicability -notin @('unknown-until-verified', 'applicable', 'not-applicable')) { Throw-DocumentationError -Code 'documentation_applicability_invalid' -Message "Unknown finding applicability: $($finding.applicability)" }
        foreach ($text in @($finding.area, $finding.title, $finding.summary)) { Assert-DocumentationTextSafe -Text ([string]$text) -Label 'finding' -ProjectRoot $ProjectRoot -AllowedVersions $allowedVersions }
    }
    Assert-DocumentationArray -Value $Research.concepts -Label 'concepts'
    $conceptIds = @()
    foreach ($concept in @($Research.concepts)) {
        Assert-DocumentationObject -Value $concept -Allowed @('id', 'name', 'whyItMatters', 'sourceIds') -Required @('id', 'name', 'whyItMatters', 'sourceIds') -Label 'concept'
        Assert-DocumentationString -Value $concept.id -Label 'concept.id'
        if ($concept.id -notmatch '^C-[0-9]+$' -or $conceptIds -ccontains $concept.id) { Throw-DocumentationError -Code 'documentation_concept_invalid' -Message "Concept id is invalid or repeated: $($concept.id)" }
        $conceptIds += [string]$concept.id
        Assert-DocumentationString -Value $concept.name -Label 'concept.name' -Maximum 160
        Assert-DocumentationString -Value $concept.whyItMatters -Label 'concept.whyItMatters' -Maximum 2000
        Assert-DocumentationArray -Value $concept.sourceIds -Label 'concept.sourceIds'
        if (@($concept.sourceIds).Count -eq 0 -or @($concept.sourceIds | Sort-Object -Unique).Count -ne @($concept.sourceIds).Count) { Throw-DocumentationError -Code 'documentation_source_invalid' -Message "Concept sourceIds are empty or repeated: $($concept.id)" }
        $conceptSources = @()
        foreach ($sourceId in @($concept.sourceIds)) {
            Assert-DocumentationString -Value $sourceId -Label 'concept.sourceIds.item'
            if ($conceptSources -ccontains $sourceId -or $sourceIds -cnotcontains $sourceId) { Throw-DocumentationError -Code 'documentation_source_unknown' -Message "Concept references an unknown or repeated source: $sourceId" }
            $conceptSources += [string]$sourceId
        }
        foreach ($text in @($concept.name, $concept.whyItMatters)) { Assert-DocumentationTextSafe -Text ([string]$text) -Label 'concept' -ProjectRoot $ProjectRoot -AllowedVersions $allowedVersions }
    }
    Assert-DocumentationArray -Value $Research.unresolved -Label 'unresolved'
    $unresolvedIds = @()
    foreach ($unresolved in @($Research.unresolved)) {
        if ($unresolved -is [string]) {
            Assert-DocumentationString -Value $unresolved -Label 'unresolved.item' -Maximum 2000
            Assert-DocumentationTextSafe -Text $unresolved -Label 'unresolved.item' -ProjectRoot $ProjectRoot -AllowedVersions $allowedVersions
            continue
        }
        Assert-DocumentationObject -Value $unresolved -Allowed @('id', 'question', 'critical', 'resolution', 'sourceIds') -Required @('id', 'question', 'critical') -Label 'unresolved.item'
        Assert-DocumentationString -Value $unresolved.id -Label 'unresolved.id'
        if ($unresolved.id -notmatch '^U-[0-9]+$') { Throw-DocumentationError -Code 'documentation_unresolved_invalid' -Message "Unresolved id is invalid: $($unresolved.id)" }
        if ($unresolvedIds -ccontains $unresolved.id) { Throw-DocumentationError -Code 'documentation_unresolved_invalid' -Message "Unresolved id is repeated: $($unresolved.id)" }
        $unresolvedIds += [string]$unresolved.id
        Assert-DocumentationString -Value $unresolved.question -Label 'unresolved.question' -Maximum 2000
        if ($unresolved.critical -isnot [bool]) { Throw-DocumentationError -Code 'documentation_schema_invalid' -Message 'unresolved.critical must be boolean.' }
        $unresolvedResolution = $null
        if ($unresolved.PSObject.Properties['resolution']) {
            $unresolvedResolution = $unresolved.resolution
            if ($null -ne $unresolvedResolution) { Assert-DocumentationString -Value $unresolvedResolution -Label 'unresolved.resolution' -Maximum 2000 }
        }
        if ($unresolved.PSObject.Properties['sourceIds']) {
            Assert-DocumentationArray -Value $unresolved.sourceIds -Label 'unresolved.sourceIds'
            if (@($unresolved.sourceIds | Sort-Object -Unique).Count -ne @($unresolved.sourceIds).Count) { Throw-DocumentationError -Code 'documentation_source_invalid' -Message "Unresolved sourceIds are repeated: $($unresolved.id)" }
            foreach ($sourceId in @($unresolved.sourceIds)) {
                Assert-DocumentationString -Value $sourceId -Label 'unresolved.sourceIds.item'
                if ($sourceIds -cnotcontains $sourceId) { Throw-DocumentationError -Code 'documentation_source_unknown' -Message "Unresolved item references an unknown source: $sourceId" }
            }
        }
        if ($unresolved.critical -and [string]$unresolvedResolution -eq 'not-applicable' -and (-not $unresolved.PSObject.Properties['sourceIds'] -or @($unresolved.sourceIds).Count -eq 0)) {
            Throw-DocumentationError -Code 'documentation_unresolved_evidence_missing' -Message "Critical unresolved item lacks not-applicable evidence: $($unresolved.id)"
        }
        foreach ($text in @($unresolved.question, $unresolvedResolution)) { Assert-DocumentationTextSafe -Text ([string]$text) -Label 'unresolved.item' -ProjectRoot $ProjectRoot -AllowedVersions $allowedVersions }
    }
}

function Get-DocumentationExpectedOutputDirectory {
    param([Parameter(Mandatory = $true)]$State)
    return 'docs/migration/v' + [string]$State.targetMajor
}

function Get-DocumentationExpectedSubmissionPath {
    param([Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)][ValidateSet('research', 'publish')][string]$Mode)
    return '.angular-migration/runs/' + $RunId + '/inbox/' + $(if ($Mode -eq 'research') { 'research.json' } else { 'documentation.json' })
}

function Get-DocumentationManifest {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)]$RunPaths)
    if (-not $State.manifestSha256 -or -not (Test-Path -LiteralPath $RunPaths.manifest -PathType Leaf)) { Throw-DocumentationError -Code 'manifest_not_resolved' -Message 'Documentation requires a resolved manifest.' }
    $manifest = Read-MigrationJson -Path $RunPaths.manifest -Required
    if ($manifest.project.root -cne (Resolve-MigrationRoot -Path $ProjectRoot)) { Throw-DocumentationError -Code 'manifest_project_mismatch' -Message 'Documentation manifest belongs to another project.' -Status failed }
    if ($manifest.schemaVersion -ne (Get-MigrationSchemaVersion) -or $manifest.manifestType -cne 'migration' -or $manifest.runId -cne $RunId -or $manifest.resolutionStatus -cne 'resolved' -or $manifest.manifestSha256 -cne $State.manifestSha256 -or (Get-ResolvedManifestHash -Manifest $manifest) -cne $State.manifestSha256) {
        Throw-DocumentationError -Code 'manifest_integrity_failed' -Message 'Documentation manifest integrity failed.' -Status failed
    }
    return $manifest
}

function Get-DocumentationResearchArtifact {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)]$RunPaths)
    if ($State.documentation.status -notin @('researched', 'publishing', 'completed') -and -not ($State.documentation.status -eq 'failed' -and $State.documentation.phase -eq 'publish') -or -not $State.documentation.researchSha256) { Throw-DocumentationError -Code 'research_required' -Message 'A valid research artifact is required before publish.' }
    if (-not (Test-Path -LiteralPath $RunPaths.researchArtifact -PathType Leaf)) { Throw-DocumentationError -Code 'research_missing' -Message 'Research artifact is missing.' }
    $research = Read-MigrationJson -Path $RunPaths.researchArtifact -Required
    Assert-DocumentationResearch -Research $research -Manifest $Manifest -State $State -ProjectRoot $ProjectRoot -RunId $RunId
    $hash = (Get-FileHash -LiteralPath $RunPaths.researchArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne [string]$State.documentation.researchSha256) { Throw-DocumentationError -Code 'research_integrity_failed' -Message 'Research artifact hash differs from state.' -Status failed }
    return $research
}

function Get-DocumentationTechnicalResult {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)]$RunPaths)
    if ($State.migrationStatus -cne 'verified' -or $State.status -cne 'verified' -or $State.stage -cne 'document') { Throw-DocumentationError -Code 'technical_result_required' -Message 'Publish requires a verified technical migration.' }
    $result = Assert-PipelineTechnicalResult -ProjectRoot $ProjectRoot -RunId $RunId -RunPaths $RunPaths
    if ($result.manifestSha256 -cne $State.manifestSha256 -or $result.migrationStatus -cne 'verified' -or $result.finalTechnicalCommit -notmatch '^[a-fA-F0-9]{40}$') { Throw-DocumentationError -Code 'result_integrity_failed' -Message 'Technical result is not valid for documentation.' -Status failed }
    return $result
}

function Assert-DocumentationInput {
    param([Parameter(Mandatory = $true)]$DocumentationInput, [Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$RunId)
    Assert-DocumentationObject -Value $DocumentationInput -Allowed @('schemaVersion', 'runId', 'mode', 'manifestSha256', 'researchSha256', 'technicalVerifiedCommit', 'outputDirectory', 'files', 'claims', 'remainingWarnings') -Required @('schemaVersion', 'runId', 'mode', 'manifestSha256', 'researchSha256', 'technicalVerifiedCommit', 'outputDirectory', 'files', 'claims', 'remainingWarnings') -Label 'publish input'
    if ($DocumentationInput.schemaVersion -ne 1 -or $DocumentationInput.mode -cne 'publish' -or $DocumentationInput.runId -cne $RunId -or $DocumentationInput.manifestSha256 -cne $State.manifestSha256 -or $DocumentationInput.manifestSha256 -notmatch '^[0-9a-f]{64}$' -or $DocumentationInput.researchSha256 -notmatch '^[0-9a-f]{64}$' -or $DocumentationInput.technicalVerifiedCommit -notmatch '^[a-fA-F0-9]{40}$') { Throw-DocumentationError -Code 'documentation_identity_mismatch' -Message 'Documentation input does not belong to the active run.' }
    $expectedOutput = Get-DocumentationExpectedOutputDirectory -State $State
    if ($DocumentationInput.outputDirectory -cne $expectedOutput) { Throw-DocumentationError -Code 'documentation_output_invalid' -Message 'Documentation output directory is controller-owned.' }
    Assert-DocumentationArray -Value $DocumentationInput.files -Label 'publish input.files'
    if (@($DocumentationInput.files).Count -ne $script:DocumentationFileOrder.Count) { Throw-DocumentationError -Code 'documentation_file_set_invalid' -Message 'Documentation must contain exactly eight files.' }
    for ($index = 0; $index -lt $script:DocumentationFileOrder.Count; $index++) {
        $expectedPath = $expectedOutput + '/' + $script:DocumentationFileOrder[$index]
        if ([string]$DocumentationInput.files[$index].path -cne $expectedPath) { Throw-DocumentationError -Code 'documentation_file_order_invalid' -Message 'Documentation files must be in ordinal filename order.' }
        $entry = @($DocumentationInput.files | Where-Object { $_.path -ceq $expectedPath })
        if ($entry.Count -ne 1) { Throw-DocumentationError -Code 'documentation_file_set_invalid' -Message "Documentation file is missing or out of order: $expectedPath" }
        Assert-DocumentationObject -Value $entry[0] -Allowed @('path', 'sha256') -Required @('path', 'sha256') -Label 'publish file'
        if ($entry[0].sha256 -notmatch '^[0-9a-f]{64}$') { Throw-DocumentationError -Code 'documentation_file_hash_invalid' -Message "Invalid documentation file hash: $expectedPath" }
    }
    Assert-DocumentationArray -Value $DocumentationInput.claims -Label 'publish claims'
    $claimIds = @()
    foreach ($claim in @($DocumentationInput.claims)) {
        Assert-DocumentationObject -Value $claim -Allowed @('id', 'kind', 'document', 'evidence') -Required @('id', 'kind', 'document', 'evidence') -Label 'claim'
        Assert-DocumentationString -Value $claim.id -Label 'claim.id'
        if ($claim.id -notmatch '^D-[0-9]+$') { Throw-DocumentationError -Code 'documentation_claim_invalid' -Message "Invalid documentation claim id: $($claim.id)" }
        if ($claimIds -ccontains $claim.id) { Throw-DocumentationError -Code 'documentation_claim_duplicate' -Message "Documentation claim is repeated: $($claim.id)" }
        $claimIds += [string]$claim.id
        if ($claim.kind -notin @('official-change', 'observed-change', 'inference', 'not-applicable')) { Throw-DocumentationError -Code 'documentation_kind_invalid' -Message "Unknown documentation claim kind: $($claim.kind)" }
        if ($script:DocumentationRequiredFiles -cnotcontains $claim.document) { Throw-DocumentationError -Code 'documentation_claim_document_invalid' -Message "Claim names an unknown document: $($claim.document)" }
        Assert-DocumentationArray -Value $claim.evidence -Label 'claim.evidence'
        if (@($claim.evidence).Count -eq 0) { Throw-DocumentationError -Code 'documentation_evidence_missing' -Message "Claim has no evidence: $($claim.id)" }
        if (@($claim.evidence | Sort-Object -Unique).Count -ne @($claim.evidence).Count) { Throw-DocumentationError -Code 'documentation_evidence_duplicate' -Message "Claim repeats evidence: $($claim.id)" }
        foreach ($evidence in @($claim.evidence)) {
            Assert-DocumentationString -Value $evidence -Label 'claim.evidence'
            if ($evidence -notmatch '^(event|commit|source|result|repair|check):[^\s]+$') { Throw-DocumentationError -Code 'documentation_evidence_invalid' -Message "Invalid claim evidence: $evidence" }
        }
    }
    Assert-DocumentationArray -Value $DocumentationInput.remainingWarnings -Label 'remainingWarnings'
    foreach ($warning in @($DocumentationInput.remainingWarnings)) { Assert-DocumentationString -Value $warning -Label 'remainingWarnings.item' }
}

function Get-DocumentationEventEntries {
    param([Parameter(Mandatory = $true)][string]$EventsPath)
    $entries = @()
    if (-not (Test-Path -LiteralPath $EventsPath -PathType Leaf)) { return @() }
    foreach ($line in @(Get-Content -LiteralPath $EventsPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $entries += ($line | ConvertFrom-Json) } catch { }
    }
    return @($entries)
}

function Assert-DocumentationEvidence {
    param(
        [Parameter(Mandatory = $true)]$DocumentationInput,
        [Parameter(Mandatory = $true)]$Research,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )
    $expectedEvidence = [ordered]@{
        manifest      = '.angular-migration/runs/' + $RunId + '/manifest.json'
        result        = '.angular-migration/runs/' + $RunId + '/result.json'
        research      = '.angular-migration/runs/' + $RunId + '/artifacts/research.json'
        events        = '.angular-migration/runs/' + $RunId + '/events.jsonl'
        repairs       = '.angular-migration/runs/' + $RunId + '/repairs'
        repairHistory = '.angular-migration/runs/' + $RunId + '/repair-history'
    }
    if ($DocumentationInput.PSObject.Properties['evidence']) {
        foreach ($name in $expectedEvidence.Keys) {
            if ($DocumentationInput.evidence.PSObject.Properties[$name] -and $DocumentationInput.evidence.$name -cne $expectedEvidence[$name]) {
                Throw-DocumentationError -Code 'documentation_evidence_path_invalid' -Message "Documentation evidence path is not controller-owned: $name"
            }
        }
    }
    $events = @(Get-DocumentationEventEntries -EventsPath $RunPaths.events)
    $eventIds = @($events | ForEach-Object { [string]$_.eventId })
    $findingIds = @($Research.findings | ForEach-Object { [string]$_.id })
    $sourceIds = @($Research.sources | ForEach-Object { [string]$_.id })
    $repairFingerprints = @($State.repairs | ForEach-Object { [string]$_.fingerprint })
    $checkIds = @($Result.checks | ForEach-Object { [string]$_.id })
    foreach ($claim in @($DocumentationInput.claims)) {
        $kinds = @()
        foreach ($evidence in @($claim.evidence)) {
            $separator = $evidence.IndexOf(':')
            if ($separator -lt 1 -or $separator -eq ($evidence.Length - 1)) { Throw-DocumentationError -Code 'documentation_evidence_invalid' -Message "Invalid evidence token: $evidence" }
            $kind = $evidence.Substring(0, $separator)
            $value = $evidence.Substring($separator + 1)
            $kinds += $kind
            switch ($kind) {
                'event' { if ($eventIds -cnotcontains $value) { Throw-DocumentationError -Code 'documentation_event_unknown' -Message "Claim cites an unknown event: $value" } }
                'commit' { Assert-PipelineCommitExists -ProjectRoot $ProjectRoot -Commit $value }
                'source' { if ($sourceIds -cnotcontains $value -and $findingIds -cnotcontains $value) { Throw-DocumentationError -Code 'documentation_source_unknown' -Message "Claim cites an unknown source or finding: $value" } }
                'result' { if ($value -cne [string]$Result.resultSha256 -and $value -cne 'verified') { Throw-DocumentationError -Code 'documentation_result_unknown' -Message "Claim cites an unknown result: $value" } }
                'repair' { if ($repairFingerprints -cnotcontains $value) { Throw-DocumentationError -Code 'documentation_repair_unknown' -Message "Claim cites an unknown repair: $value" } }
                'check' { if ($checkIds -cnotcontains $value) { Throw-DocumentationError -Code 'documentation_check_unknown' -Message "Claim cites an unknown check: $value" } }
                default { Throw-DocumentationError -Code 'documentation_evidence_invalid' -Message "Unknown evidence kind: $kind" }
            }
        }
        if ($claim.kind -eq 'official-change' -and $kinds -notcontains 'source') { Throw-DocumentationError -Code 'documentation_evidence_invalid' -Message "Official claim lacks a source: $($claim.id)" }
        if ($claim.kind -eq 'observed-change' -and @($kinds | Where-Object { $_ -in @('event', 'commit', 'check', 'repair') }).Count -eq 0) { Throw-DocumentationError -Code 'documentation_evidence_invalid' -Message "Observed claim lacks run evidence: $($claim.id)" }
        if ($claim.kind -eq 'not-applicable' -and $kinds -notcontains 'source') { Throw-DocumentationError -Code 'documentation_evidence_invalid' -Message "Not-applicable claim lacks a source: $($claim.id)" }
    }
}

function Get-DocumentationOutputFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$DocumentationInput
    )
    $relativeDirectory = Get-DocumentationExpectedOutputDirectory -State $State
    $directory = Resolve-RepairPath -Root $ProjectRoot -Path $relativeDirectory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { Throw-DocumentationError -Code 'documentation_output_missing' -Message 'Documentation output directory is missing.' }
    $directoryItem = Get-Item -LiteralPath $directory -Force
    if ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { Throw-DocumentationError -Code 'documentation_link_rejected' -Message 'Documentation output cannot be a linked directory.' }
    $children = @(Get-ChildItem -LiteralPath $directory -Force)
    $childNames = @($children | ForEach-Object { $_.Name })
    $actualNames = (($childNames | Sort-Object) -join '|')
    $requiredNames = (($script:DocumentationRequiredFiles | Sort-Object) -join '|')
    if (@($children | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count -gt 0 -or $actualNames -cne $requiredNames) {
        Throw-DocumentationError -Code 'documentation_file_set_invalid' -Message 'Documentation output must contain exactly the eight required files and no links.'
    }
    $files = @{}
    foreach ($name in $script:DocumentationRequiredFiles) {
        $path = Join-Path $directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Throw-DocumentationError -Code 'documentation_file_missing' -Message "Documentation file is missing: $name" }
        $files[$name] = [IO.File]::ReadAllText($path)
    }
    return [PSCustomObject]@{ directory = $directory; files = $files }
}

function Assert-DocumentationMarkdown {
    param(
        [Parameter(Mandatory = $true)]$Files,
        [Parameter(Mandatory = $true)]$DocumentationInput,
        [Parameter(Mandatory = $true)]$Research,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )
    $allowedVersions = Get-DocumentationAllowedVersions -Manifest $Manifest
    $sourceUrls = @($Research.sources | ForEach-Object { [string]$_.url })
    foreach ($name in $script:DocumentationRequiredFiles) {
        if ([string]::IsNullOrWhiteSpace($Files.files[$name])) { Throw-DocumentationError -Code 'documentation_file_empty' -Message "Documentation file is empty: $name" }
        Assert-DocumentationTextSafe -Text $Files.files[$name] -Label $name -ProjectRoot $ProjectRoot -AllowedVersions $allowedVersions -AllowOperationalText
        foreach ($match in [regex]::Matches($Files.files[$name], 'https://[^\s\)\]>"`]+')) {
            $url = $match.Value.TrimEnd([char[]]@('.', ',', ';'))
            Assert-DocumentationUrl -Url $url
            if ($name -cne 'sources.md' -and $sourceUrls -cnotcontains $url) { Throw-DocumentationError -Code 'documentation_source_missing' -Message "External URL is not registered in sources.md: $url" }
        }
    }
    $readme = [string]$Files.files['README.md']
    if ($readme -notmatch '(?im)^#.*' + [regex]::Escape([string]$State.sourceMajor) + '.*' + [regex]::Escape([string]$State.targetMajor)) { Throw-DocumentationError -Code 'documentation_readme_invalid' -Message 'README does not identify the migration majors.' }
    foreach ($name in $script:DocumentationRequiredFiles | Where-Object { $_ -ne 'README.md' }) {
        if ($readme -notmatch '\]\(' + [regex]::Escape($name) + '(?:#|\))') { Throw-DocumentationError -Code 'documentation_link_broken' -Message "README does not link to $name" }
    }
    foreach ($name in $script:DocumentationRequiredFiles) {
        if ($Files.files[$name] -notmatch '(?im)^#\s+') { Throw-DocumentationError -Code 'documentation_template_invalid' -Message "Documentation file has no heading: $name" }
    }
    $outputDirectory = Get-DocumentationExpectedOutputDirectory -State $State
    foreach ($name in $script:DocumentationRequiredFiles) {
        foreach ($match in [regex]::Matches($Files.files[$name], '\[[^\]]*\]\(([^\)]+)\)')) {
            $target = [string]$match.Groups[1].Value
            if ($target -match '^(?i:https?://)') { continue }
            if ($target.StartsWith('#')) { continue }
            $linkPath = $target.Split('#')[0]
            if ([string]::IsNullOrWhiteSpace($linkPath) -or [IO.Path]::IsPathRooted($linkPath) -or $linkPath -match '[:\\]' -or $linkPath -match '(^|/)\.\.(?:/|$)') { Throw-DocumentationError -Code 'documentation_link_broken' -Message "Documentation link is not a safe relative link: $target" }
            $linkFull = Resolve-RepairPath -Root $Files.directory -Path $linkPath
            if (-not (Test-Path -LiteralPath $linkFull -PathType Leaf)) { Throw-DocumentationError -Code 'documentation_link_broken' -Message "Documentation link does not exist: $target" }
        }
    }
    $sourcesText = [string]$Files.files['sources.md']
    foreach ($source in @($Research.sources)) {
        if ($sourcesText.IndexOf([string]$source.id, [StringComparison]::Ordinal) -lt 0 -or $sourcesText.IndexOf([string]$source.url, [StringComparison]::Ordinal) -lt 0) { Throw-DocumentationError -Code 'documentation_source_missing' -Message "Source is not listed in sources.md: $($source.id)" }
    }
    foreach ($concept in @($Research.concepts)) {
        if ($Files.files['new-concepts.md'].IndexOf([string]$concept.name, [StringComparison]::Ordinal) -lt 0) { Throw-DocumentationError -Code 'documentation_concept_missing' -Message "Concept is not documented: $($concept.name)" }
    }
    $dependencyText = [string]$Files.files['dependencies.md']
    foreach ($dependency in @($Manifest.dependencies)) {
        $before = if ($dependency.currentVersion) { [regex]::Escape([string]$dependency.currentVersion) } else { '(?:-|n/a|none)' }
        $after = if ($dependency.targetVersion) { [regex]::Escape([string]$dependency.targetVersion) } else { '(?:-|n/a|none)' }
        $row = '(?im)^\|\s*' + [regex]::Escape([string]$dependency.name) + '\s*\|[^\r\n]*\|\s*' + $before + '\s*\|\s*' + $after + '\s*\|'
        if ($dependencyText -notmatch $row) { Throw-DocumentationError -Code 'documentation_dependency_mismatch' -Message "Dependency table does not match manifest: $($dependency.name)" }
    }
    if (@($Result.repairs).Count -eq 0) {
        if ($Files.files['errors-and-repairs.md'] -notmatch '(?i)La ejecuci(?:o|\u00f3)n no requiri(?:o|\u00f3) reparaciones manuales') { Throw-DocumentationError -Code 'documentation_repair_text_missing' -Message 'No-repair contractual text is missing.' }
    }
    else {
        foreach ($repair in @($Result.repairs)) { if ($Files.files['errors-and-repairs.md'].IndexOf([string]$repair.fingerprint, [StringComparison]::Ordinal) -lt 0) { Throw-DocumentationError -Code 'documentation_repair_missing' -Message "Repair fingerprint is not documented: $($repair.fingerprint)" } }
    }
    if (@($Result.warnings).Count -eq 0) {
        if ($Files.files['warnings.md'] -notmatch '(?i)No quedaron warnings registrados por la pipeline') { Throw-DocumentationError -Code 'documentation_warning_text_missing' -Message 'No-warning contractual text is missing.' }
    }
    else {
        if ($Files.files['warnings.md'] -notmatch '(?i)\b(resolved|accepted|action-required)\b') { Throw-DocumentationError -Code 'documentation_warning_classification_missing' -Message 'Warnings are not classified.' }
    }
    foreach ($unresolved in @($Research.unresolved)) {
        $unresolvedResolution = if ($unresolved -isnot [string] -and $unresolved.PSObject.Properties['resolution']) { [string]$unresolved.resolution } else { $null }
        if ($unresolved -isnot [string] -and $unresolved.critical -eq $true -and $unresolvedResolution -notmatch '^(?i:resolved|not-applicable)$') {
            Throw-DocumentationError -Code 'documentation_critical_unresolved' -Message "Critical unresolved item blocks publication: $($unresolved.id)"
        }
    }
    $hasSuccessClaim = @($Files.files.Values | Where-Object { $_ -match '(?i)\b(?:verified|passed|successful|success)\b' }).Count -gt 0
    if ($hasSuccessClaim -and @($DocumentationInput.claims | Where-Object { @($_.evidence) -match '^result:' }).Count -eq 0) { Throw-DocumentationError -Code 'documentation_result_evidence_missing' -Message 'Technical success text lacks result evidence.' }
}

function Assert-DocumentationOutput {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$DocumentationInput,
        [Parameter(Mandatory = $true)]$Research,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$RunPaths
    )
    $files = Get-DocumentationOutputFiles -ProjectRoot $ProjectRoot -State $State -DocumentationInput $DocumentationInput
    foreach ($entry in @($DocumentationInput.files)) {
        $name = [IO.Path]::GetFileName([string]$entry.path)
        $path = Join-Path $files.directory $name
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne [string]$entry.sha256) { Throw-DocumentationError -Code 'documentation_file_hash_mismatch' -Message "Documentation file hash differs from declaration: $name" }
    }
    $statusItems = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $prefix = (Get-DocumentationExpectedOutputDirectory -State $State) + '/'
    $unexpected = @($statusItems | Where-Object { -not $_.path.StartsWith($prefix, [StringComparison]::Ordinal) })
    if ($unexpected.Count -gt 0) { Throw-DocumentationError -Code 'documentation_scope_violation' -Message 'Only the target documentation directory may change.' -Details ([PSCustomObject]@{ paths = @($unexpected.path) }) }
    Assert-DocumentationMarkdown -Files $files -DocumentationInput $DocumentationInput -Research $Research -Manifest $Manifest -Result $Result -State $State -ProjectRoot $ProjectRoot
    Assert-DocumentationEvidence -DocumentationInput $DocumentationInput -Research $Research -Result $Result -State $State -RunPaths $RunPaths -RunId $State.runId -ProjectRoot $ProjectRoot
    return $files
}

function Restore-DocumentationOutput {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$CheckpointCommit)
    $prefix = (Get-DocumentationExpectedOutputDirectory -State $State) + '/'
    foreach ($item in @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot) | Where-Object { $_.path.StartsWith($prefix, [StringComparison]::Ordinal) }) {
        $full = Resolve-RepairPath -Root $ProjectRoot -Path $item.path
        if ($item.untracked) {
            if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force }
            continue
        }
        $exists = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('cat-file', '-e', "$CheckpointCommit`:$($item.path)")
        if ($exists.exitCode -eq 0) {
            $restore = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('restore', '--source', $CheckpointCommit, '--staged', '--worktree', '--', $item.path)
            if ($restore.exitCode -ne 0) { Throw-DocumentationError -Code 'documentation_rollback_failed' -Message 'Documentation rollback failed.' -Status failed }
        }
        else {
            $unstage = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('restore', '--staged', '--', $item.path)
            if ($unstage.exitCode -ne 0) { Throw-DocumentationError -Code 'documentation_rollback_failed' -Message 'Documentation rollback failed.' -Status failed }
            if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force }
        }
    }
}

function Set-DocumentationFailure {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)][string]$Mode, [Parameter(Mandatory = $true)]$ErrorInfo)
    try {
        $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        if ($state.documentation.status -ne 'completed') {
            $state.documentation.status = 'failed'
            $state.documentation.phase = $Mode
            $state.documentation.lastError = [PSCustomObject]@{ code = [string]$ErrorInfo.code; message = Protect-RepairText -Text ([string]$ErrorInfo.message) -Root $ProjectRoot }
            $state.documentationStatus = 'failed'
            Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
            Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'documentation-failed' -Stage 'document' -Data $state.documentation.lastError
        }
    }
    catch { }
}


function Complete-DocumentationPublish {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPaths,
        [string]$PublishedCommit
    )
    if ([string]::IsNullOrWhiteSpace($PublishedCommit)) { $PublishedCommit = Get-PipelineGitHead -ProjectRoot $ProjectRoot }
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.documentation.publishedCommit -and $state.documentation.publishedCommit -cne $PublishedCommit) {
        Throw-DocumentationError -Code 'documentation_state_conflict' -Message 'Documentation state points to a different published commit.' -Status failed
    }
    if ($state.status -eq 'verified' -and $state.stage -eq 'document') {
        $state.documentation.status = 'completed'
        $state.documentation.phase = 'publish'
        $state.documentation.publishedCommit = $PublishedCommit
        if (-not $state.documentation.completedAt) { $state.documentation.completedAt = Get-MigrationUtcNow }
        $state.documentation.lastError = $null
        $state.documentationStatus = 'completed'
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    }
    $events = @(Get-DocumentationEventEntries -EventsPath (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId).events)
    $publishedEvent = @($events | Where-Object { $_.type -ceq 'documentation-published' -and $_.data -and $_.data.publishedCommit -ceq $PublishedCommit })
    if ($publishedEvent.Count -eq 0) {
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'documentation-published' -Stage 'document' -Data ([PSCustomObject]@{ publishedCommit = $PublishedCommit; outputDirectory = $OutputDirectory; files = $ExpectedPaths })
    }
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.status -eq 'verified' -and $state.stage -eq 'document') {
        $null = Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'verified' -ExpectedStage 'document' -ExpectedRevision $state.stageRevision -NewStatus 'completed' -NewStage 'done'
    }
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.status -ne 'completed' -or $state.stage -ne 'done' -or $state.documentation.status -ne 'completed') {
        Throw-DocumentationError -Code 'documentation_state_incomplete' -Message 'Documentation publish did not reach the completed state.' -Status failed
    }
    Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $RunId
    return [PSCustomObject]@{ ok = $true; status = 'completed'; data = [PSCustomObject]@{ runId = $RunId; outputDirectory = $OutputDirectory; publishedCommit = $PublishedCommit; files = $ExpectedPaths }; error = $null }
}
function New-DocumentationResearchContext {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$RunId)
    $questionStart = [string][char]0x00bf + 'Qu' + [char]0x00e9
    $dependencies = @($Manifest.dependencies | ForEach-Object {
            [PSCustomObject]@{
                name           = $_.name
                currentVersion = $_.currentVersion
                targetVersion  = $_.targetVersion
                change         = $_.change
                reason         = $_.reason
            }
        })
    return [PSCustomObject][ordered]@{
        schemaVersion    = 1
        mode             = 'research'
        runId            = $RunId
        sourceMajor      = [int]$State.sourceMajor
        targetMajor      = [int]$State.targetMajor
        manifestSha256   = [string]$State.manifestSha256
        dependencies     = $dependencies
        questions        = @(
            "$questionStart breaking changes oficiales aplican de Angular $($State.sourceMajor) a $($State.targetMajor)?"
            ($questionStart + ' migraciones autom' + [char]0x00e1 + 'ticas declara cada paquete actualizado?')
            ($questionStart + ' conceptos nuevos afectan al mantenimiento del proyecto?')
            ($questionStart + ' warnings/deprecations oficiales pueden aparecer?')
        )
        allowedWritePath = Get-DocumentationExpectedSubmissionPath -RunId $RunId -Mode research
    }
}

function New-DocumentationPublishContext {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $evidenceRoot = '.angular-migration/runs/' + $RunId
    return [PSCustomObject][ordered]@{
        schemaVersion           = 1
        mode                    = 'publish'
        runId                   = $RunId
        sourceMajor             = [int]$State.sourceMajor
        targetMajor             = [int]$State.targetMajor
        migrationStatus         = 'verified'
        manifestSha256          = [string]$State.manifestSha256
        researchSha256          = [string]$State.documentation.researchSha256
        technicalVerifiedCommit = [string]$Result.finalTechnicalCommit
        outputDirectory         = Get-DocumentationExpectedOutputDirectory -State $State
        requiredFiles           = @($script:DocumentationRequiredFiles)
        evidence                = [PSCustomObject][ordered]@{
            manifest      = $evidenceRoot + '/manifest.json'
            result        = $evidenceRoot + '/result.json'
            research      = $evidenceRoot + '/artifacts/research.json'
            events        = $evidenceRoot + '/events.jsonl'
            repairs       = $evidenceRoot + '/repairs'
            repairHistory = $evidenceRoot + '/repair-history'
        }
        submissionPath          = Get-DocumentationExpectedSubmissionPath -RunId $RunId -Mode publish
    }
}

function Invoke-DocumentationContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateSet('research', 'publish')][string]$Mode
    )
    if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-DocumentationError -Code 'run_id_required' -Message '-RunId is required for documentation.' }
    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    $manifest = Get-DocumentationManifest -ProjectRoot $root -RunId $RunId -State $state -RunPaths $paths
    if ($Mode -eq 'research') {
        if ($state.documentation.status -in @('researched', 'publishing', 'completed') -or ($state.documentation.status -eq 'failed' -and $state.documentation.phase -eq 'publish')) {
            Throw-DocumentationError -Code 'documentation_research_already_recorded' -Message 'Research is already recorded for this run.'
        }
        $context = New-DocumentationResearchContext -State $state -Manifest $manifest -RunId $RunId
        if ($state.documentation.status -ne 'researching') {
            $state.documentation.status = 'researching'
            $state.documentation.phase = 'research'
            $state.documentation.lastError = $null
            $state.documentationStatus = 'researching'
            Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $state
            Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'documentation-context-issued' -Stage 'document' -Data ([PSCustomObject]@{ mode = 'research'; manifestSha256 = $state.manifestSha256; allowedWritePath = $context.allowedWritePath })
        }
        return [PSCustomObject]@{ ok = $true; status = 'researching'; data = $context; error = $null }
    }
    if ($state.migrationStatus -cne 'verified' -or $state.status -cne 'verified' -or $state.stage -cne 'document') { Throw-DocumentationError -Code 'publish_requires_verified' -Message 'Documentation publish requires migrationStatus=verified.' }
    if ($state.documentation.status -notin @('researched', 'failed', 'publishing') -or ($state.documentation.status -eq 'failed' -and $state.documentation.phase -ne 'publish')) {
        Throw-DocumentationError -Code 'research_required' -Message 'Research must be recorded before publish.'
    }
    $result = Get-DocumentationTechnicalResult -ProjectRoot $root -RunId $RunId -State $state -RunPaths $paths
    $null = Get-DocumentationResearchArtifact -ProjectRoot $root -RunId $RunId -State $state -Manifest $manifest -RunPaths $paths
    if ($result.finalTechnicalCommit -cne (Get-PipelineGitHead -ProjectRoot $root)) { Throw-DocumentationError -Code 'git_head_changed' -Message 'Git HEAD differs from the technical verified commit.' }
    $context = New-DocumentationPublishContext -State $state -Manifest $manifest -Result $result -RunId $RunId
    if ($state.documentation.status -ne 'publishing') {
        $state.documentation.status = 'publishing'
        $state.documentation.phase = 'publish'
        $state.documentation.publishAttempt = [int]$state.documentation.publishAttempt + 1
        $state.documentation.lastError = $null
        $state.documentationStatus = 'publishing'
        Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $state
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'documentation-context-issued' -Stage 'document' -Data ([PSCustomObject]@{ mode = 'publish'; attempt = $state.documentation.publishAttempt; technicalVerifiedCommit = $result.finalTechnicalCommit; outputDirectory = $context.outputDirectory })
    }
    return [PSCustomObject]@{ ok = $true; status = 'publishing'; data = $context; error = $null }
}

function Invoke-RecordDocumentation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateSet('research', 'publish')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$InputFile
    )
    if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-DocumentationError -Code 'run_id_required' -Message '-RunId is required for documentation.' }
    if ([string]::IsNullOrWhiteSpace($InputFile)) { Throw-DocumentationError -Code 'documentation_input_required' -Message '-InputFile is required for documentation.' }
    Assert-MigrationRunId -RunId $RunId
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
    $leasePath = Join-Path $paths.root 'record-documentation.lock'
    $lease = $null
    try { $lease = [IO.File]::Open($leasePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { Throw-DocumentationError -Code 'documentation_process_not_owner' -Message 'Another process owns documentation registration.' }
    $state = $null
    $committed = $false
    try {
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        $expectedRelative = Get-DocumentationExpectedSubmissionPath -RunId $RunId -Mode $Mode
        $expectedInput = Resolve-RepairPath -Root $root -Path $expectedRelative
        $inputPath = Resolve-RepairPath -Root $root -Path $InputFile
        if ($inputPath -cne $expectedInput) { Throw-DocumentationError -Code 'documentation_input_path_invalid' -Message 'Documentation input path is not controller-owned.' }
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { Throw-DocumentationError -Code 'documentation_input_missing' -Message 'Documentation input is missing.' }
        $manifest = Get-DocumentationManifest -ProjectRoot $root -RunId $RunId -State $state -RunPaths $paths
        if ($Mode -eq 'research') {
            if ($state.documentation.status -ne 'researching') { Throw-DocumentationError -Code 'documentation_research_context_required' -Message 'Research registration requires a researching context.' }
            $research = Read-MigrationJson -Path $inputPath -Required
            Assert-DocumentationResearch -Research $research -Manifest $manifest -State $state -ProjectRoot $root -RunId $RunId
            if (Test-Path -LiteralPath $paths.researchArtifact -PathType Leaf) { Remove-Item -LiteralPath $paths.researchArtifact -Force }
            New-Item -ItemType Directory -Path $paths.artifacts -Force | Out-Null
            Move-Item -LiteralPath $inputPath -Destination $paths.researchArtifact -Force
            $researchHash = (Get-FileHash -LiteralPath $paths.researchArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
            $researchCommit = Get-PipelineGitHead -ProjectRoot $root
            $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
            $state.documentation.status = 'researched'
            $state.documentation.phase = 'research'
            $state.documentation.researchSha256 = $researchHash
            $state.documentation.researchCommit = $researchCommit
            $state.documentation.lastError = $null
            $state.documentationStatus = 'researched'
            Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $state
            Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'documentation-researched' -Stage 'document' -Data ([PSCustomObject]@{ researchSha256 = $researchHash; researchCommit = $researchCommit })
            return [PSCustomObject]@{ ok = $true; status = 'researched'; data = [PSCustomObject]@{ runId = $RunId; research = '.angular-migration/runs/' + $RunId + '/artifacts/research.json'; researchSha256 = $researchHash }; error = $null }
        }
        if ($state.documentation.status -ne 'publishing') { Throw-DocumentationError -Code 'documentation_publish_context_required' -Message 'Publish registration requires a publishing context.' }
        $result = Get-DocumentationTechnicalResult -ProjectRoot $root -RunId $RunId -State $state -RunPaths $paths
        $research = Get-DocumentationResearchArtifact -ProjectRoot $root -RunId $RunId -State $state -Manifest $manifest -RunPaths $paths
        $documentation = Read-MigrationJson -Path $inputPath -Required
        Assert-DocumentationInput -DocumentationInput $documentation -State $state -RunId $RunId
        if ($documentation.researchSha256 -cne $state.documentation.researchSha256 -or $documentation.technicalVerifiedCommit -cne $result.finalTechnicalCommit) { Throw-DocumentationError -Code 'documentation_evidence_mismatch' -Message 'Documentation input hashes or technical commit do not match evidence.' }
        if ((Get-PipelineGitHead -ProjectRoot $root) -cne $result.finalTechnicalCommit) { Throw-DocumentationError -Code 'git_head_changed' -Message 'Git HEAD changed after the technical verification.' }
        $null = Assert-DocumentationOutput -ProjectRoot $root -State $state -DocumentationInput $documentation -Research $research -Manifest $manifest -Result $result -RunPaths $paths
        $outputDirectory = Get-DocumentationExpectedOutputDirectory -State $state
        $add = Invoke-PipelineGit -ProjectRoot $root -Arguments @('add', '--', $outputDirectory)
        if ($add.exitCode -ne 0) { Throw-DocumentationError -Code 'documentation_commit_failed' -Message 'Could not stage documentation.' -Status failed -Details $add.stderr }
        $staged = Invoke-PipelineGit -ProjectRoot $root -Arguments @('diff', '--cached', '--name-only', '-z', '--')
        if ($staged.exitCode -ne 0) { Throw-DocumentationError -Code 'documentation_commit_failed' -Message 'Could not inspect staged documentation.' -Status failed }
        $stagedPaths = @($staged.stdout -split [char]0 | Where-Object { $_ })
        $expectedPaths = @($script:DocumentationRequiredFiles | ForEach-Object { $outputDirectory + '/' + $_ })
        $publishedCommit = $null
        $stagedNames = (($stagedPaths | Sort-Object) -join '|')
        $expectedNames = (($expectedPaths | Sort-Object) -join '|')
        if ($stagedNames -cne $expectedNames) { Throw-DocumentationError -Code 'documentation_scope_violation' -Message 'Staged documentation paths are not exactly the required eight files.' }
        $message = "docs(angular-migration): document Angular $($state.sourceMajor) to $($state.targetMajor)"
        $commit = Invoke-PipelineGit -ProjectRoot $root -Arguments @('-c', 'core.hooksPath=NUL', 'commit', '-m', $message)
        if ($commit.exitCode -ne 0) { Throw-DocumentationError -Code 'documentation_commit_failed' -Message 'Could not create the documentation commit.' -Status failed -Details $commit.stderr }
        $committed = $true
        $publishedCommit = Get-PipelineGitHead -ProjectRoot $root
        return Complete-DocumentationPublish -ProjectRoot $root -RunId $RunId -OutputDirectory $outputDirectory -ExpectedPaths $expectedPaths -PublishedCommit $publishedCommit
    }
    catch {
        $errorRecord = $_
        $errorInfo = Get-PipelineRunError -ErrorRecord $errorRecord
        if ($Mode -eq 'publish' -and $committed) {
            return Complete-DocumentationPublish -ProjectRoot $root -RunId $RunId -OutputDirectory $outputDirectory -ExpectedPaths $expectedPaths -PublishedCommit $publishedCommit
        }
        if ($Mode -eq 'publish' -and -not $committed -and $state) {
            try { Restore-DocumentationOutput -ProjectRoot $root -State $state -CheckpointCommit ([string]$state.checkpointCommit) } catch { }
        }
        Set-DocumentationFailure -ProjectRoot $root -RunId $RunId -Mode $Mode -ErrorInfo $errorInfo
        throw
    }
    finally {
        if ($lease) { $lease.Dispose(); Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function @(
    'Invoke-MigrationBaseline',
    'Invoke-MigrationResolution',
    'Invoke-InspectMigration',
    'Invoke-MigrationPreflight',
    'Invoke-MigrationResolveDiagnostics',
    'Invoke-MigrationDiscover',
    'Invoke-ApproveMigrationRuntimeInstall',
    'Invoke-StartMigration',
    'Invoke-MigrationStatus',
    'Invoke-MigrationEvents',
    'Invoke-MigrationDiagnose',
    'Invoke-MigrationRetryStage',
    'Invoke-MigrationAbort',
    'Invoke-MigrationRollback',
    'Invoke-MigrationBaselineDependencyContext',
    'Invoke-ApproveMigrationBaselineDependencies',
    'Invoke-MigrationSkipCheck',
    'Invoke-MigrationSkipChecks',
    'Invoke-MigrationRepairContext',
    'Invoke-MigrationRecordRepair',
    'Invoke-MigrationRun',
    'Invoke-DocumentationContext',
    'Invoke-RecordDocumentation'
)
