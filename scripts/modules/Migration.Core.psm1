Set-StrictMode -Version 2.0

$script:MigrationSchemaVersion = 5

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

    return $root.TrimEnd('\')
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

    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
    $fullPath = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $root $Path))
    }

    $insideRoot = $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
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
    $json = $Value | ConvertTo-Json -Depth 50 -Compress
    try {
        [IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tempPath -Destination $Path -Force | Out-Null
    }
    catch {
        Throw-MigrationError -Code 'atomic_write_failed' -Message "Could not write JSON atomically: $Path" -Status failed -Details $_.Exception.Message
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
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

function Invoke-MigrationProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 0
    )

    $processId = [guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $env:TEMP "angular-migration-$processId.out"
    $stderrPath = Join-Path $env:TEMP "angular-migration-$processId.err"
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
            $startParameters.ArgumentList = $Arguments
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
            }
        }
        else {
            [void]$process.WaitForExit()
        }

        $process.Refresh()
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
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
