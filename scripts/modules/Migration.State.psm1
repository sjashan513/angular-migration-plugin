Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -DisableNameChecking

$script:RunIdPattern = '^[a-z0-9]+(?:-[a-z0-9]+)*$'

function Get-MigrationDirectory {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    return (Join-Path $ProjectRoot '.angular-migration')
}

function Get-MigrationRunPaths {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    Assert-MigrationRunId -RunId $RunId
    $runDirectory = Join-Path (Join-Path (Get-MigrationDirectory -ProjectRoot $ProjectRoot) 'runs') $RunId
    return [PSCustomObject]@{
        root = $runDirectory
        manifest = Join-Path $runDirectory 'manifest.json'
        state = Join-Path $runDirectory 'state.json'
        events = Join-Path $runDirectory 'events.jsonl'
        result = Join-Path $runDirectory 'result.json'
        research = Join-Path $runDirectory 'research.json'
        logs = Join-Path $runDirectory 'logs'
    }
}

function Assert-MigrationRunId {
    param([Parameter(Mandatory = $true)][string]$RunId)

    if ($RunId -notmatch $script:RunIdPattern) {
        Throw-MigrationError -Code 'invalid_run_id' -Message "Invalid run id: $RunId" -Status blocked
    }
}

function Assert-NoLegacyMigrationMetadata {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $migrationDirectory = Get-MigrationDirectory -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $migrationDirectory -PathType Container)) {
        return
    }

    $legacyFiles = @(@('config.json', 'state.json', 'progress.json') | ForEach-Object {
        $path = Join-Path $migrationDirectory $_
        if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
    })
    $legacyDirectories = @(Get-ChildItem -LiteralPath $migrationDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^v\d+-v\d+\.log$' } |
        Select-Object -ExpandProperty FullName)

    if ($legacyFiles.Count -gt 0 -or $legacyDirectories.Count -gt 0) {
        Throw-MigrationError -Code 'legacy_metadata_present' -Message 'Existing migration metadata is not accepted by v5. Preserve it in Git history and remove it before starting a v5 run.' -Status blocked
    }
}

function New-MigrationRunId {
    param(
        [Parameter(Mandatory = $true)][int]$SourceMajor,
        [Parameter(Mandatory = $true)][int]$TargetMajor,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $base = "angular-$SourceMajor-to-$TargetMajor-$timestamp"
    $candidate = $base
    $counter = 0
    while (Test-Path -LiteralPath (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $candidate).root -PathType Container) {
        $counter++
        $candidate = "$base-$counter"
    }
    return $candidate
}

function Get-ActiveLockPath {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    return (Join-Path (Get-MigrationDirectory -ProjectRoot $ProjectRoot) 'active.lock')
}

function Read-ActiveRunLock {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $path = Get-ActiveLockPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        return Read-MigrationJson -Path $path -Required
    }
    catch {
        Throw-MigrationError -Code 'active_lock_invalid' -Message 'The active migration lock is invalid. Inspect it and remove it only after confirming no migration is running.' -Status blocked
    }
}

function New-ActiveRunLock {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $migrationDirectory = Get-MigrationDirectory -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $migrationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $migrationDirectory -Force | Out-Null
    }

    $path = Get-ActiveLockPath -ProjectRoot $ProjectRoot
    $lock = [ordered]@{
        schemaVersion = Get-MigrationSchemaVersion
        runId = $RunId
        processId = $PID
        createdAt = Get-MigrationUtcNow
    }
    $stream = $null
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $json = $lock | ConvertTo-Json -Depth 10 -Compress
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch [IO.IOException] {
        $existing = Read-ActiveRunLock -ProjectRoot $ProjectRoot
        $owner = if ($existing) { $existing.runId } else { 'unknown' }
        Throw-MigrationError -Code 'active_run' -Message "Another migration run owns this project: $owner" -Status blocked -Details $existing
    }
    catch {
        Throw-MigrationError -Code 'lock_create_failed' -Message 'Could not create the migration ownership lock.' -Status failed -Details $_.Exception.Message
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Remove-ActiveRunLock {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $path = Get-ActiveLockPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $lock = Read-MigrationJson -Path $path
    if ($lock -and $lock.runId -eq $RunId) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ActiveRunOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $lock = Read-ActiveRunLock -ProjectRoot $ProjectRoot
    if (-not $lock -or $lock.runId -ne $RunId) {
        Throw-MigrationError -Code 'run_not_owner' -Message "Run does not own the project: $RunId" -Status blocked -Details $lock
    }
}

function Get-RunningMigrationRuns {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $runsDirectory = Join-Path (Get-MigrationDirectory -ProjectRoot $ProjectRoot) 'runs'
    if (-not (Test-Path -LiteralPath $runsDirectory -PathType Container)) { return @() }

    $running = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $runsDirectory -Directory -ErrorAction SilentlyContinue)) {
        $statePath = Join-Path $directory.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        $state = Read-MigrationJson -Path $statePath -Required
        if ($state.status -eq 'running') { $running += $state }
    }
    return $running
}

function New-MigrationRunState {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$SourceMajor,
        [Parameter(Mandatory = $true)][int]$TargetMajor,
        [Parameter(Mandatory = $true)][string]$InitialCommit
    )

    return [ordered]@{
        schemaVersion = Get-MigrationSchemaVersion
        runId = $RunId
        projectRoot = $ProjectRoot
        sourceMajor = $SourceMajor
        targetMajor = $TargetMajor
        status = 'running'
        stage = 'baseline'
        attempt = 1
        migrationStatus = 'running'
        documentationStatus = 'pending'
        initialCommit = $InitialCommit
        lastDiagnostic = $null
        createdAt = Get-MigrationUtcNow
        updatedAt = Get-MigrationUtcNow
    }
}

function Read-MigrationRunState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    return Read-MigrationJson -Path $paths.state -Required
}

function Write-MigrationRunState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$State
    )

    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $State.updatedAt = Get-MigrationUtcNow
    Write-MigrationJsonAtomic -Value $State -Path $paths.state
}

function Add-MigrationEvent {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Type,
        [string]$Stage,
        $Data = $null
    )

    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $event = [ordered]@{
        schemaVersion = Get-MigrationSchemaVersion
        eventId = [guid]::NewGuid().ToString('N')
        runId = $RunId
        type = $Type
        stage = $Stage
        timestamp = Get-MigrationUtcNow
        data = $Data
    }
    $line = ($event | ConvertTo-Json -Depth 30 -Compress) + [Environment]::NewLine
    [IO.File]::AppendAllText($paths.events, $line, (New-Object System.Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function @(
    'Get-MigrationDirectory',
    'Get-MigrationRunPaths',
    'Assert-MigrationRunId',
    'Assert-NoLegacyMigrationMetadata',
    'New-MigrationRunId',
    'Get-ActiveLockPath',
    'Read-ActiveRunLock',
    'New-ActiveRunLock',
    'Remove-ActiveRunLock',
    'Assert-ActiveRunOwnership',
    'Get-RunningMigrationRuns',
    'New-MigrationRunState',
    'Read-MigrationRunState',
    'Write-MigrationRunState',
    'Add-MigrationEvent'
)
