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

function Test-MigrationVersionRange {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Range
    )

    $versionTuple = Get-MigrationVersionTuple -Version $Version
    if ($null -eq $versionTuple -or [string]::IsNullOrWhiteSpace($Range)) { return $false }
    $Range = $Range -replace '(?<!\S)(>=|<=|>|<|\||\^|~)\s+(?=\d)', '$1'
    $Range = $Range -replace '(^|\s)v(?=\d)', '$1'
    foreach ($alternative in ($Range -split '\|\|')) {
        $alternativeText = $alternative.Trim()
        if ($alternativeText -in @('', '*', 'x', 'X')) { return $true }
        if ($alternativeText -match '^([0-9]+)\.([0-9]+)\.([0-9]+)\s+-\s+([0-9]+)\.([0-9]+)\.([0-9]+)$') {
            $lower = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
            $upper = @([int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
            if ((Compare-MigrationVersionTuple -Left $versionTuple -Right $lower) -ge 0 -and
                (Compare-MigrationVersionTuple -Left $versionTuple -Right $upper) -le 0) { return $true }
            continue
        }
        $tokens = @($alternativeText -split '\s+' | Where-Object { $_ })
        $matches = $true
        foreach ($token in $tokens) {
            $operator = ''
            $value = $token
            if ($token -match '^(\^|~|>=|<=|>|<)(.+)$') { $operator = $Matches[1]; $value = $Matches[2] }
            $parts = $value -split '\.'
            if ($parts.Count -gt 3 -or $parts[0] -notmatch '^\d+$') { $matches = $false; break }
            $major = [int]$parts[0]
            $minor = 0
            $patch = 0
            $minorWildcard = $parts.Count -lt 2 -or $parts[1] -in @('x', 'X', '*')
            $patchWildcard = $parts.Count -lt 3 -or $parts[2] -in @('x', 'X', '*')
            if (-not $minorWildcard -and $parts[1] -notmatch '^\d+$') { $matches = $false; break }
            if (-not $patchWildcard -and $parts[2] -notmatch '^\d+$') { $matches = $false; break }
            if (-not $minorWildcard) { $minor = [int]$parts[1] }
            if (-not $patchWildcard) { $patch = [int]$parts[2] }
            $base = @($major, $minor, $patch)
            $comparison = Compare-MigrationVersionTuple -Left $versionTuple -Right $base
            if ($operator -eq '^') {
                $upper = if ($major -gt 0) { @(($major + 1), 0, 0) } elseif ($minor -gt 0) { @(0, ($minor + 1), 0) } else { @(0, 0, ($patch + 1)) }
                if ((Compare-MigrationVersionTuple -Left $versionTuple -Right $base) -lt 0 -or
                    (Compare-MigrationVersionTuple -Left $versionTuple -Right $upper) -ge 0) { $matches = $false; break }
            }
            elseif ($operator -eq '~') {
                $upper = @($major, ($minor + 1), 0)
                if ($comparison -lt 0 -or (Compare-MigrationVersionTuple -Left $versionTuple -Right $upper) -ge 0) { $matches = $false; break }
            }
            elseif ($operator -eq '>=') { if ($comparison -lt 0) { $matches = $false; break } }
            elseif ($operator -eq '>') { if ($comparison -le 0) { $matches = $false; break } }
            elseif ($operator -eq '<=') { if ($comparison -gt 0) { $matches = $false; break } }
            elseif ($operator -eq '<') { if ($comparison -ge 0) { $matches = $false; break } }
            elseif ($minorWildcard) {
                if ($versionTuple[0] -ne $major) { $matches = $false; break }
            }
            elseif ($patchWildcard) {
                if ($versionTuple[0] -ne $major -or $versionTuple[1] -ne $minor) { $matches = $false; break }
            }
            elseif ($comparison -ne 0) { $matches = $false; break }
        }
        if ($matches) { return $true }
    }
    return $false
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
        [string]$FnmPath = ''
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
    return Invoke-MigrationProcess -FilePath $resolvedFnm -Arguments $fnmArguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -StandardInput $StandardInput
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
        [AllowNull()][AllowEmptyString()][string]$StandardInput = $null
    )

    $processId = [guid]::NewGuid().ToString('N')
    $temporaryDirectory = [IO.Path]::GetTempPath()
    $stdoutPath = Join-Path $temporaryDirectory "angular-migration-$processId.out"
    $stderrPath = Join-Path $temporaryDirectory "angular-migration-$processId.err"
    $stdinPath = Join-Path $temporaryDirectory "angular-migration-$processId.in"
    $process = $null
    $timedOut = $false

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

        if ($TimeoutSeconds -gt 0) {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $timedOut = $true
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
                    Throw-MigrationError -Code 'process_termination_failed' -Message "Timed-out process could not be terminated: $FilePath" -Status failed
                }
            }
        }
        else {
            [void]$process.WaitForExit()
        }

        $process.Refresh()
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { [string](Get-Content -LiteralPath $stdoutPath -Raw) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { [string](Get-Content -LiteralPath $stderrPath -Raw) } else { '' }
        $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }

        return [PSCustomObject]@{
            exitCode = $exitCode
            stdout   = $stdout
            stderr   = $stderr
            timedOut = $timedOut
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
    'Compare-MigrationVersionTuple',
    'Test-MigrationVersionRange',
    'Assert-MigrationExactNodeVersion',
    'Invoke-MigrationProcess',
    'Invoke-MigrationNodeProcess',
    'Get-MigrationNodeIdentity'
)
