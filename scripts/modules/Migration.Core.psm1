Set-StrictMode -Version 2.0

$script:MigrationSchemaVersion = 5

function Get-NormalizedMigrationPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $pathRoot
    }
    return $fullPath.TrimEnd([char[]]@('\', '/'))
}

function Get-MigrationSchemaVersion {
    return $script:MigrationSchemaVersion
}

function Get-MigrationUtcNow {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Throw-MigrationError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('blocked', 'failed')][string]$Status = 'failed',
        $Details = $null
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['code'] = $Code
    $exception.Data['status'] = $Status
    $exception.Data['details'] = $Details
    throw $exception
}

function Resolve-MigrationRoot {
    param([string]$Path)

    $candidate = if ($Path) { $Path } else { (Get-Location).Path }
    try {
        $root = [IO.Path]::GetFullPath($candidate)
    }
    catch {
        Throw-MigrationError -Code 'invalid_project_root' -Message "Invalid project root: $candidate" -Status blocked
    }

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Throw-MigrationError -Code 'project_root_not_found' -Message "Project root not found: $root" -Status blocked
    }

    return Get-NormalizedMigrationPath -Path $root
}

function Resolve-MigrationPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$MustExist,
        [ValidateSet('Leaf', 'Container')][string]$PathType = 'Leaf'
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Throw-MigrationError -Code 'path_required' -Message 'A project-relative path is required.' -Status blocked
    }

    $root = Get-NormalizedMigrationPath -Path $ProjectRoot
    $fullPath = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $root $Path))
    }

    $rootPrefix = if ($root.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $root
    }
    else {
        $root + [IO.Path]::DirectorySeparatorChar
    }
    $insideRoot = $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
    $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    if (-not $insideRoot) {
        Throw-MigrationError -Code 'path_outside_project' -Message "Path is outside the project root: $Path" -Status blocked
    }

    if ($MustExist -and -not (Test-Path -LiteralPath $fullPath -PathType $PathType)) {
        Throw-MigrationError -Code 'path_not_found' -Message "Path not found: $Path" -Status blocked
    }

    return $fullPath
}

function Read-MigrationJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Required
    )

    $ioPath = if ($Path.Length -ge 248 -and $Path -match '^[A-Za-z]:\\') { '\\?\' + $Path } else { $Path }
    if (-not [IO.File]::Exists($ioPath)) {
        if ($Required) {
            Throw-MigrationError -Code 'json_not_found' -Message "JSON file not found: $Path" -Status failed
        }
        return $null
    }

    try {
        $jsonParameters = @{}
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonParameters.DateKind = 'String' }
        return ([IO.File]::ReadAllText($ioPath, [Text.Encoding]::UTF8) | ConvertFrom-Json @jsonParameters)
    }
    catch {
        Throw-MigrationError -Code 'invalid_json' -Message "Invalid JSON file: $Path" -Status failed -Details $_.Exception.Message
    }
}

function Write-MigrationJsonAtomic {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    $directoryIoPath = if ($directory.Length -ge 248 -and $directory -match '^[A-Za-z]:\\') { '\\?\' + $directory } else { $directory }
    if (-not [IO.Directory]::Exists($directoryIoPath)) {
        [IO.Directory]::CreateDirectory($directoryIoPath) | Out-Null
    }

    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    $pathIo = if ($Path.Length -ge 248 -and $Path -match '^[A-Za-z]:\\') { '\\?\' + $Path } else { $Path }
    $tempIoPath = if ($tempPath.Length -ge 248 -and $tempPath -match '^[A-Za-z]:\\') { '\\?\' + $tempPath } else { $tempPath }
    $backupIoPath = if ($backupPath.Length -ge 248 -and $backupPath -match '^[A-Za-z]:\\') { '\\?\' + $backupPath } else { $backupPath }
    $json = $Value | ConvertTo-Json -Depth 50 -Compress
    try {
        [IO.File]::WriteAllText($tempIoPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($pathIo)) {
            [IO.File]::Replace($tempIoPath, $pathIo, $backupIoPath)
        }
        else {
            [IO.File]::Move($tempIoPath, $pathIo)
        }
    }
    catch {
        Throw-MigrationError -Code 'atomic_write_failed' -Message "Could not write JSON atomically: $Path" -Status failed -Details $_.Exception.Message
    }
    finally {
        if ([IO.File]::Exists($tempIoPath)) {
            [IO.File]::Delete($tempIoPath)
        }
        if ([IO.File]::Exists($backupIoPath)) {
            [IO.File]::Delete($backupIoPath)
        }
    }
}

function Write-MigrationTextAtomic {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    $directoryIoPath = if ($directory.Length -ge 248 -and $directory -match '^[A-Za-z]:\\') { '\\?\' + $directory } else { $directory }
    if (-not [IO.Directory]::Exists($directoryIoPath)) {
        [IO.Directory]::CreateDirectory($directoryIoPath) | Out-Null
    }

    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    $pathIo = if ($Path.Length -ge 248 -and $Path -match '^[A-Za-z]:\\') { '\\?\' + $Path } else { $Path }
    $tempIoPath = if ($tempPath.Length -ge 248 -and $tempPath -match '^[A-Za-z]:\\') { '\\?\' + $tempPath } else { $tempPath }
    $backupIoPath = if ($backupPath.Length -ge 248 -and $backupPath -match '^[A-Za-z]:\\') { '\\?\' + $backupPath } else { $backupPath }
    try {
        [IO.File]::WriteAllText($tempIoPath, $Text, (New-Object System.Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($pathIo)) {
            [IO.File]::Replace($tempIoPath, $pathIo, $backupIoPath)
        }
        else {
            [IO.File]::Move($tempIoPath, $pathIo)
        }
    }
    catch {
        Throw-MigrationError -Code 'atomic_write_failed' -Message "Could not write text atomically: $Path" -Status failed -Details $_.Exception.Message
    }
    finally {
        if ([IO.File]::Exists($tempIoPath)) {
            [IO.File]::Delete($tempIoPath)
        }
        if ([IO.File]::Exists($backupIoPath)) {
            [IO.File]::Delete($backupIoPath)
        }
    }
}

function Find-MigrationExecutable {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }

    return $null
}

function Get-MigrationVersionTuple {
    param([Parameter(Mandatory = $true)][string]$Version)

    $match = [regex]::Match($Version, '^([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if (-not $match.Success) { return $null }
    return @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Get-MigrationAngularToolingVersionPolicy {
    param(
        [Parameter(Mandatory = $true)][int]$AngularMajor,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    if ($PackageName -notlike '@angular-devkit/*' -and $PackageName -notlike '@ngtools/*') {
        return [PSCustomObject][ordered]@{ selector = [string]$AngularMajor; major = $AngularMajor; requiredRange = $null }
    }
    $range = switch ($AngularMajor) {
        6 { '>=0.6.0 <0.7.0' }
        7 { '>=0.10.0 <0.14.0' }
        8 { '>=0.800.0 <0.900.0' }
        9 { '>=0.900.0 <0.1000.0' }
        10 { '>=0.1000.0 <0.1003.0' }
        default {
            $nextMajor = $AngularMajor + 1
            '>=0.' + $AngularMajor + '00.0 <0.' + $nextMajor + '00.0'
        }
    }
    return [PSCustomObject][ordered]@{ selector = $range; major = -1; requiredRange = $range }
}

function Compare-MigrationVersionTuple {
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

function ConvertTo-MigrationSemVer {
    param([string]$Version)

    $match = [regex]::Match(([string]$Version).Trim(), '^v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')
    if (-not $match.Success) { return $null }
    $prerelease = @()
    if ($match.Groups[4].Success) {
        foreach ($identifier in @($match.Groups[4].Value -split '\.')) {
            if ($identifier -match '^\d+$' -and $identifier -match '^0\d') { return $null }
            $prerelease += $identifier
        }
    }
    try {
        $major = [int64]$match.Groups[1].Value
        $minor = [int64]$match.Groups[2].Value
        $patch = [int64]$match.Groups[3].Value
    }
    catch {
        return $null
    }
    return [PSCustomObject]@{
        major      = $major
        minor      = $minor
        patch      = $patch
        prerelease = @($prerelease)
    }
}

function New-MigrationSemVerValue {
    param(
        [Parameter(Mandatory = $true)][int64]$Major,
        [Parameter(Mandatory = $true)][int64]$Minor,
        [Parameter(Mandatory = $true)][int64]$Patch,
        [string[]]$Prerelease = @()
    )

    return [PSCustomObject]@{
        major      = $Major
        minor      = $Minor
        patch      = $Patch
        prerelease = @($Prerelease)
    }
}

function Compare-MigrationSemVer {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    foreach ($name in @('major', 'minor', 'patch')) {
        if ($Left.$name -lt $Right.$name) { return -1 }
        if ($Left.$name -gt $Right.$name) { return 1 }
    }
    $leftPrerelease = @($Left.prerelease)
    $rightPrerelease = @($Right.prerelease)
    if ($leftPrerelease.Count -eq 0 -and $rightPrerelease.Count -eq 0) { return 0 }
    if ($leftPrerelease.Count -eq 0) { return 1 }
    if ($rightPrerelease.Count -eq 0) { return -1 }
    $count = [Math]::Min($leftPrerelease.Count, $rightPrerelease.Count)
    for ($index = 0; $index -lt $count; $index++) {
        $leftIdentifier = [string]$leftPrerelease[$index]
        $rightIdentifier = [string]$rightPrerelease[$index]
        $leftNumeric = $leftIdentifier -match '^\d+$'
        $rightNumeric = $rightIdentifier -match '^\d+$'
        if ($leftNumeric -and $rightNumeric) {
            if ([int64]$leftIdentifier -lt [int64]$rightIdentifier) { return -1 }
            if ([int64]$leftIdentifier -gt [int64]$rightIdentifier) { return 1 }
        }
        elseif ($leftNumeric -and -not $rightNumeric) { return -1 }
        elseif (-not $leftNumeric -and $rightNumeric) { return 1 }
        else {
            $comparison = [string]::CompareOrdinal($leftIdentifier, $rightIdentifier)
            if ($comparison -lt 0) { return -1 }
            if ($comparison -gt 0) { return 1 }
        }
    }
    if ($leftPrerelease.Count -lt $rightPrerelease.Count) { return -1 }
    if ($leftPrerelease.Count -gt $rightPrerelease.Count) { return 1 }
    return 0
}

function ConvertTo-MigrationRangeVersion {
    param([string]$Value)

    $text = ([string]$Value).Trim()
    if ($text -in @('*', 'x', 'X')) {
        return [PSCustomObject]@{ any = $true; major = 0; minor = 0; patch = 0; minorSpecified = $false; patchSpecified = $false; hasPrerelease = $false; value = $null }
    }
    $match = [regex]::Match($text, '^v?([0-9]+)(?:\.([0-9]+|[xX*]))?(?:\.([0-9]+|[xX*]))?(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')
    if (-not $match.Success) { return $null }
    $minorWildcard = $match.Groups[2].Success -and $match.Groups[2].Value -in @('x', 'X', '*')
    $patchWildcard = $match.Groups[3].Success -and $match.Groups[3].Value -in @('x', 'X', '*')
    if ($minorWildcard -and $match.Groups[3].Success) { return $null }
    if ($patchWildcard -and $match.Groups[4].Success) { return $null }
    $minorSpecified = $match.Groups[2].Success -and -not $minorWildcard
    $patchSpecified = $match.Groups[3].Success -and -not $patchWildcard
    if ($match.Groups[4].Success -and (-not $minorSpecified -or -not $patchSpecified)) { return $null }
    try {
        $major = [int64]$match.Groups[1].Value
        $minor = if ($minorSpecified) { [int64]$match.Groups[2].Value } else { 0 }
        $patch = if ($patchSpecified) { [int64]$match.Groups[3].Value } else { 0 }
    }
    catch {
        return $null
    }
    $normalized = '{0}.{1}.{2}' -f $major, $minor, $patch
    if ($match.Groups[4].Success) { $normalized += '-' + $match.Groups[4].Value }
    $version = ConvertTo-MigrationSemVer -Version $normalized
    if ($null -eq $version) { return $null }
    return [PSCustomObject]@{
        any             = $false
        major           = $major
        minor           = $minor
        patch           = $patch
        minorSpecified  = [bool]$minorSpecified
        patchSpecified  = [bool]$patchSpecified
        hasPrerelease   = [bool]$match.Groups[4].Success
        value           = $version
    }
}

function Test-MigrationSemVerComparator {
    param(
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)]$Comparator
    )

    $rangeVersion = $Comparator.range
    if ($rangeVersion.any) { return $true }
    if ($null -eq $Version) { return $false }
    $operator = [string]$Comparator.operator
    $comparison = Compare-MigrationSemVer -Left $Version -Right $rangeVersion.value
    if ($operator -in @('', '=')) {
        if (-not $rangeVersion.minorSpecified) { return $Version.major -eq $rangeVersion.major }
        if (-not $rangeVersion.patchSpecified) { return $Version.major -eq $rangeVersion.major -and $Version.minor -eq $rangeVersion.minor }
        return $comparison -eq 0
    }
    if ($operator -eq '^') {
        if ($rangeVersion.major -gt 0) { $upper = New-MigrationSemVerValue -Major ($rangeVersion.major + 1) -Minor 0 -Patch 0 }
        elseif ($rangeVersion.minorSpecified -and $rangeVersion.minor -gt 0) { $upper = New-MigrationSemVerValue -Major 0 -Minor ($rangeVersion.minor + 1) -Patch 0 }
        elseif ($rangeVersion.patchSpecified -and $rangeVersion.patch -gt 0) { $upper = New-MigrationSemVerValue -Major 0 -Minor 0 -Patch ($rangeVersion.patch + 1) }
        elseif ($rangeVersion.minorSpecified) { $upper = New-MigrationSemVerValue -Major 0 -Minor ($rangeVersion.minor + 1) -Patch 0 }
        else { $upper = New-MigrationSemVerValue -Major 1 -Minor 0 -Patch 0 }
        return $comparison -ge 0 -and (Compare-MigrationSemVer -Left $Version -Right $upper) -lt 0
    }
    if ($operator -eq '~') {
        $upper = if ($rangeVersion.minorSpecified) { New-MigrationSemVerValue -Major $rangeVersion.major -Minor ($rangeVersion.minor + 1) -Patch 0 } else { New-MigrationSemVerValue -Major ($rangeVersion.major + 1) -Minor 0 -Patch 0 }
        return $comparison -ge 0 -and (Compare-MigrationSemVer -Left $Version -Right $upper) -lt 0
    }
    if ($operator -eq '>=') { return $comparison -ge 0 }
    if ($operator -eq '>') {
        if (-not $rangeVersion.minorSpecified) { $lower = New-MigrationSemVerValue -Major ($rangeVersion.major + 1) -Minor 0 -Patch 0; return (Compare-MigrationSemVer -Left $Version -Right $lower) -ge 0 }
        if (-not $rangeVersion.patchSpecified) { $lower = New-MigrationSemVerValue -Major $rangeVersion.major -Minor ($rangeVersion.minor + 1) -Patch 0; return (Compare-MigrationSemVer -Left $Version -Right $lower) -ge 0 }
        return $comparison -gt 0
    }
    if ($operator -eq '<') {
        if (-not $rangeVersion.minorSpecified) { $upper = New-MigrationSemVerValue -Major $rangeVersion.major -Minor 0 -Patch 0; return (Compare-MigrationSemVer -Left $Version -Right $upper) -lt 0 }
        if (-not $rangeVersion.patchSpecified) { $upper = New-MigrationSemVerValue -Major $rangeVersion.major -Minor $rangeVersion.minor -Patch 0; return (Compare-MigrationSemVer -Left $Version -Right $upper) -lt 0 }
        return $comparison -lt 0
    }
    if ($operator -eq '<=') {
        if (-not $rangeVersion.minorSpecified) { $upper = New-MigrationSemVerValue -Major ($rangeVersion.major + 1) -Minor 0 -Patch 0; return (Compare-MigrationSemVer -Left $Version -Right $upper) -lt 0 }
        if (-not $rangeVersion.patchSpecified) { $upper = New-MigrationSemVerValue -Major $rangeVersion.major -Minor ($rangeVersion.minor + 1) -Patch 0; return (Compare-MigrationSemVer -Left $Version -Right $upper) -lt 0 }
        return $comparison -le 0
    }
    return $false
}

function Get-MigrationVersionRangeAlternativeEvaluation {
    param(
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)][string]$Alternative
    )

    $text = $Alternative.Trim()
    if ($text -in @('', '*', 'x', 'X')) {
        return [PSCustomObject]@{ supported = $true; matches = $null -ne $Version -and @($Version.prerelease).Count -eq 0 }
    }
    $comparators = @()
    $hyphen = [regex]::Match($text, '^(.+?)\s+-\s+(.+?)$')
    if ($hyphen.Success) {
        $lower = ConvertTo-MigrationRangeVersion -Value $hyphen.Groups[1].Value
        $upper = ConvertTo-MigrationRangeVersion -Value $hyphen.Groups[2].Value
        if ($null -eq $lower -or $null -eq $upper) { return [PSCustomObject]@{ supported = $false; matches = $false } }
        if (-not $lower.any) { $comparators += [PSCustomObject]@{ operator = '>='; range = $lower } }
        if (-not $upper.any) {
            if ($upper.patchSpecified) { $upperBound = $upper; $upperOperator = '<=' }
            elseif ($upper.minorSpecified) { $upperBound = New-MigrationSemVerValue -Major $upper.major -Minor ($upper.minor + 1) -Patch 0; $upperOperator = '<' }
            else { $upperBound = New-MigrationSemVerValue -Major ($upper.major + 1) -Minor 0 -Patch 0; $upperOperator = '<' }
            $comparators += [PSCustomObject]@{ operator = $upperOperator; range = [PSCustomObject]@{ any = $false; major = $upperBound.major; minor = $upperBound.minor; patch = $upperBound.patch; minorSpecified = $true; patchSpecified = $true; hasPrerelease = $false; value = $upperBound } }
        }
    }
    else {
        $tokens = @($text -split '\s+' | Where-Object { $_ })
        foreach ($token in $tokens) {
            $operator = ''
            $value = $token
            if ($token -match '^(\^|~|>=|<=|>|<|=)(.+)$') { $operator = $Matches[1]; $value = $Matches[2] }
            $rangeVersion = ConvertTo-MigrationRangeVersion -Value $value
            if ($null -eq $rangeVersion) { return [PSCustomObject]@{ supported = $false; matches = $false } }
            $comparators += [PSCustomObject]@{ operator = $operator; range = $rangeVersion }
        }
    }
    if ($comparators.Count -eq 0) { return [PSCustomObject]@{ supported = $true; matches = $null -ne $Version -and @($Version.prerelease).Count -eq 0 } }
    $isMatch = $true
    foreach ($comparator in $comparators) {
        if (-not (Test-MigrationSemVerComparator -Version $Version -Comparator $comparator)) { $isMatch = $false; break }
    }
    if ($isMatch -and $null -ne $Version -and @($Version.prerelease).Count -gt 0) {
        $allowsPrerelease = $false
        foreach ($comparator in $comparators) {
            $rangeVersion = $comparator.range
            if ($rangeVersion.hasPrerelease -and $rangeVersion.major -eq $Version.major -and $rangeVersion.minor -eq $Version.minor -and $rangeVersion.patch -eq $Version.patch) { $allowsPrerelease = $true; break }
        }
        if (-not $allowsPrerelease) { $isMatch = $false }
    }
    return [PSCustomObject]@{ supported = $true; matches = $isMatch }
}

function Get-MigrationVersionRangeEvaluation {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Range
    )

    if ([string]::IsNullOrWhiteSpace($Range)) { return [PSCustomObject]@{ supported = $false; matches = $false } }
    $versionValue = ConvertTo-MigrationSemVer -Version $Version
    $normalizedRange = $Range.Trim() -replace '(?<!\S)(>=|<=|>|<|\||\^|~|=)\s+(?=\d|[vV])', '$1'
    $matched = $false
    $unsupported = $false
    foreach ($alternative in @($normalizedRange -split '\|\|')) {
        $evaluation = Get-MigrationVersionRangeAlternativeEvaluation -Version $versionValue -Alternative ([string]$alternative)
        if (-not $evaluation.supported) { $unsupported = $true }
        elseif ($evaluation.matches) { $matched = $true }
    }
    if ($unsupported) { return [PSCustomObject]@{ supported = $false; matches = $false } }
    return [PSCustomObject]@{ supported = $true; matches = $matched }
}

function Test-MigrationVersionRange {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Range,
        [switch]$Detailed
    )

    $evaluation = Get-MigrationVersionRangeEvaluation -Version $Version -Range $Range
    if ($Detailed) { return $evaluation }
    return [bool]$evaluation.matches
}

function Assert-MigrationExactNodeVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        Throw-MigrationError -Code 'invalid_node_version' -Message "Node version must be an exact stable version: $Version" -Status blocked
    }
    return $Version
}

function Invoke-MigrationNodeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$NodeVersion,
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 0,
        [AllowNull()][AllowEmptyString()][string]$StandardInput = $null,
        [string]$FnmPath = '',
        [int]$InactivityTimeoutSeconds = 0,
        [scriptblock]$OnActivity = $null
    )

    Assert-MigrationExactNodeVersion -Version $NodeVersion | Out-Null
    if ([string]::IsNullOrWhiteSpace($Executable) -or $Executable.IndexOf([char]0) -ge 0 -or $Executable.IndexOf([char]13) -ge 0 -or $Executable.IndexOf([char]10) -ge 0) {
        Throw-MigrationError -Code 'invalid_node_executable' -Message 'Node-managed executable is invalid.' -Status blocked
    }
    $resolvedFnm = if ($FnmPath) { $FnmPath } else { Find-MigrationExecutable -Names @('fnm.exe', 'fnm') }
    if (-not $resolvedFnm) {
        Throw-MigrationError -Code 'fnm_missing' -Message 'fnm is required for Node-managed processes.' -Status blocked
    }
    $nodeManagedExecutable = $Executable
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $nodeManagedExecutable -ieq 'npm') {
        $nodeManagedExecutable = 'npm.cmd'
    }
    $fnmArguments = @('exec', '--using', $NodeVersion, '--', $nodeManagedExecutable) + @($Arguments)
    return Invoke-MigrationProcess -FilePath $resolvedFnm -Arguments $fnmArguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -InactivityTimeoutSeconds $InactivityTimeoutSeconds -StandardInput $StandardInput -OnActivity $OnActivity
}

function Get-MigrationNodeIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$FnmPath,
        [Parameter(Mandatory = $true)][string]$NodeVersion,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 30
    )

    Assert-MigrationExactNodeVersion -Version $NodeVersion | Out-Null
    $node = Invoke-MigrationNodeProcess -FnmPath $FnmPath -NodeVersion $NodeVersion -Executable 'node' -Arguments @('--version') -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    $npm = Invoke-MigrationNodeProcess -FnmPath $FnmPath -NodeVersion $NodeVersion -Executable 'npm' -Arguments @('--version') -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    $observedNode = if ($node.exitCode -eq 0) { ([string]$node.stdout).Trim() -replace '^v', '' } else { $null }
    $observedNpm = if ($npm.exitCode -eq 0) { ([string]$npm.stdout).Trim() -replace '^v', '' } else { $null }
    $usable = $node.exitCode -eq 0 -and $npm.exitCode -eq 0 -and $observedNode -ceq $NodeVersion -and $observedNode -match '^[0-9]+\.[0-9]+\.[0-9]+$' -and $observedNpm -match '^[0-9]+\.[0-9]+\.[0-9]+$'
    return [PSCustomObject]@{
        nodeVersion = $NodeVersion
        npmVersion  = if ($observedNpm -match '^[0-9]+\.[0-9]+\.[0-9]+$') { $observedNpm } else { $null }
        status      = if ($usable) { 'usable' } else { 'unusable' }
        reason      = if ($usable) { $null } else { 'Node or npm identity did not match the selected exact runtime.' }
    }
}

function ConvertTo-MigrationCommandLineArgument {
    param([AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument) {
        Throw-MigrationError -Code 'invalid_process_argument' -Message 'Process arguments cannot be null.' -Status failed
    }
    if ($Argument.IndexOf([char]0) -ge 0 -or $Argument -match "[`r`n]") {
        Throw-MigrationError -Code 'invalid_process_argument' -Message 'Process arguments cannot contain null bytes or line breaks.' -Status failed
    }

    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-MigrationProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 0,
        [AllowNull()][AllowEmptyString()][string]$StandardInput = $null,
        [int]$InactivityTimeoutSeconds = 0,
        [scriptblock]$OnActivity = $null
    )

    $processId = [guid]::NewGuid().ToString('N')
    $temporaryDirectory = [IO.Path]::GetTempPath()
    $stdoutPath = Join-Path $temporaryDirectory "angular-migration-$processId.out"
    $stderrPath = Join-Path $temporaryDirectory "angular-migration-$processId.err"
    $stdinPath = Join-Path $temporaryDirectory "angular-migration-$processId.in"
    $process = $null
    $timedOut = $false
    $processStalled = $false
    $terminationReason = $null

    try {
        $startParameters = @{
            FilePath               = $FilePath
            WorkingDirectory       = $WorkingDirectory
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
        }
        if ($null -ne $StandardInput) {
            [IO.File]::WriteAllText($stdinPath, $StandardInput, (New-Object System.Text.UTF8Encoding($false)))
            $startParameters.RedirectStandardInput = $stdinPath
        }
        if ($Arguments -and $Arguments.Count -gt 0) {
            $startParameters.ArgumentList = (($Arguments | ForEach-Object {
                        ConvertTo-MigrationCommandLineArgument -Argument $_
                    }) -join ' ')
        }

        $process = Start-Process @startParameters
        [void]$process.Handle

        if ($TimeoutSeconds -gt 0 -or $InactivityTimeoutSeconds -gt 0) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $lastActivitySeconds = 0.0
            $lastOutputState = ''
            while ($true) {
                [void]$process.WaitForExit(250)
                $process.Refresh()
                if ($process.HasExited) { break }
                $outputState = ''
                foreach ($outputPath in @($stdoutPath, $stderrPath)) {
                    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
                        try {
                            $outputFile = Get-Item -LiteralPath $outputPath -Force
                            $outputState += '|' + [string]$outputFile.Length + ':' + [string]$outputFile.LastWriteTimeUtc.Ticks
                        }
                        catch { }
                    }
                }
                if ($outputState -ne $lastOutputState) {
                    $lastOutputState = $outputState
                    $lastActivitySeconds = $timer.Elapsed.TotalSeconds
                    if ($OnActivity) { [void](& $OnActivity $true) }
                }
                if ($TimeoutSeconds -gt 0 -and $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    $timedOut = $true
                    $terminationReason = 'timeout'
                    break
                }
                if ($InactivityTimeoutSeconds -gt 0 -and ($timer.Elapsed.TotalSeconds - $lastActivitySeconds) -ge $InactivityTimeoutSeconds) {
                    $processStalled = $true
                    $terminationReason = 'process_stalled'
                    break
                }
            }
            $timer.Stop()
        }
        else {
            [void]$process.WaitForExit()
        }

        if ($timedOut -or $processStalled) {
            $taskKill = Find-MigrationExecutable -Names @('taskkill.exe', 'taskkill')
            if ($taskKill) {
                & $taskKill /PID $process.Id /T /F 2>$null | Out-Null
            }
            try { [void]$process.WaitForExit(5000) } catch { }
            if (-not $process.HasExited) {
                try {
                    $process.Kill()
                    [void]$process.WaitForExit(5000)
                }
                catch { }
            }
            if (-not $process.HasExited) {
                Throw-MigrationError -Code 'process_termination_failed' -Message "Terminated process could not be stopped: $FilePath" -Status failed
            }
        }

        $process.Refresh()
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { [string](Get-Content -LiteralPath $stdoutPath -Raw) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { [string](Get-Content -LiteralPath $stderrPath -Raw) } else { '' }
        $exitCode = if ($timedOut) { 124 } elseif ($processStalled) { 125 } else { $process.ExitCode }

        return [PSCustomObject]@{
            exitCode        = $exitCode
            stdout          = $stdout
            stderr          = $stderr
            timedOut        = $timedOut
            processStalled  = $processStalled
            terminationReason = if ($terminationReason) { $terminationReason } else { 'completed' }
        }
    }
    catch {
        Throw-MigrationError -Code 'process_failed' -Message "Could not execute process: $FilePath" -Status failed -Details $_.Exception.Message
    }
    finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $stdinPath, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @(
    'Get-MigrationSchemaVersion',
    'Get-MigrationUtcNow',
    'Throw-MigrationError',
    'Resolve-MigrationRoot',
    'Resolve-MigrationPath',
    'Read-MigrationJson',
    'Write-MigrationJsonAtomic',
    'Write-MigrationTextAtomic',
    'Find-MigrationExecutable',
    'Get-MigrationVersionTuple',
    'Get-MigrationAngularToolingVersionPolicy',
    'Compare-MigrationVersionTuple',
    'Test-MigrationVersionRange',
    'Assert-MigrationExactNodeVersion',
    'Invoke-MigrationProcess',
    'Invoke-MigrationNodeProcess',
    'Get-MigrationNodeIdentity'
)
