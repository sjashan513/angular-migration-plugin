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

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($Required) {
            Throw-MigrationError -Code 'json_not_found' -Message "JSON file not found: $Path" -Status failed
        }
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
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
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    $json = $Value | ConvertTo-Json -Depth 50 -Compress
    try {
        [IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($tempPath, $Path, $backupPath)
        }
        else {
            [IO.File]::Move($tempPath, $Path)
        }
    }
    catch {
        Throw-MigrationError -Code 'atomic_write_failed' -Message "Could not write JSON atomically: $Path" -Status failed -Details $_.Exception.Message
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
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
        [int]$TimeoutSeconds = 0
    )

    $processId = [guid]::NewGuid().ToString('N')
    $temporaryDirectory = [IO.Path]::GetTempPath()
    $stdoutPath = Join-Path $temporaryDirectory "angular-migration-$processId.out"
    $stderrPath = Join-Path $temporaryDirectory "angular-migration-$processId.err"
    $process = $null
    $timedOut = $false

    try {
        $startParameters = @{
            FilePath             = $FilePath
            WorkingDirectory     = $WorkingDirectory
            NoNewWindow          = $true
            PassThru              = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
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
            stdout = $stdout
            stderr = $stderr
            timedOut = $timedOut
        }
    }
    catch {
        Throw-MigrationError -Code 'process_failed' -Message "Could not execute process: $FilePath" -Status failed -Details $_.Exception.Message
    }
    finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
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
    'Find-MigrationExecutable',
    'Invoke-MigrationProcess'
)
