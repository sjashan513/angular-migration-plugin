Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -DisableNameChecking

$script:RunIdPattern = '^[a-z0-9]+(?:-[a-z0-9]+)*$'
$script:AllowedStages = @('baseline', 'resolve', 'update-angular', 'update-dependencies', 'install', 'validate', 'document')
$script:AllowedTransitions = @{
    'running|baseline'            = @('running|resolve', 'blocked|baseline', 'failed|baseline')
    'running|resolve'             = @('running|update-angular', 'blocked|resolve', 'failed|resolve')
    'running|update-angular'      = @('running|update-dependencies', 'needs-repair|update-angular', 'blocked|update-angular', 'failed|update-angular')
    'running|update-dependencies' = @('running|install', 'blocked|update-dependencies', 'failed|update-dependencies')
    'running|install'             = @('running|validate', 'blocked|install', 'failed|install')
    'running|validate'            = @('verified|document', 'needs-repair|validate', 'blocked|validate', 'failed|validate')
    'needs-repair|update-angular' = @('running|update-angular', 'blocked|update-angular', 'failed|update-angular')
    'needs-repair|validate'       = @('running|validate', 'blocked|validate', 'failed|validate')
}
$script:CompletedOperationIds = @('baseline', 'resolve-manifest', 'create-branch', 'update-angular', 'update-dependencies', 'install', 'validate', 'technical-result')

function Get-MigrationMember {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) {
        return [PSCustomObject]@{ exists = $true; value = $Object[$Name] }
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return [PSCustomObject]@{ exists = $true; value = $property.Value }
    }
    return [PSCustomObject]@{ exists = $false; value = $null }
}

function Get-MigrationDirectory {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    return Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path '.angular-migration' -PathType Container
}

function Get-MigrationRunPaths {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    Assert-MigrationRunId -RunId $RunId
    $runDirectory = Join-Path (Join-Path (Get-MigrationDirectory -ProjectRoot $ProjectRoot) 'runs') $RunId
    return [PSCustomObject]@{
        root     = $runDirectory
        manifest = Join-Path $runDirectory 'manifest.json'
        state    = Join-Path $runDirectory 'state.json'
        events   = Join-Path $runDirectory 'events.jsonl'
        result   = Join-Path $runDirectory 'result.json'
        research = Join-Path $runDirectory 'research.json'
        logs     = Join-Path $runDirectory 'logs'
    }
}

function Assert-MigrationRunId {
    param([Parameter(Mandatory = $true)][string]$RunId)

    if ($RunId -notmatch $script:RunIdPattern) {
        Throw-MigrationError -Code 'invalid_run_id' -Message "Invalid run id: $RunId" -Status blocked
    }
}

function New-MigrationRunId {
    param(
        [Parameter(Mandatory = $true)][int]$SourceMajor,
        [Parameter(Mandatory = $true)][int]$TargetMajor
    )

    if ($TargetMajor -ne ($SourceMajor + 1)) {
        Throw-MigrationError -Code 'non_sequential_target' -Message 'A run id can only be created for the next Angular major.' -Status blocked
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "angular-$SourceMajor-to-$TargetMajor-$timestamp-$suffix"
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
        $lock = Read-MigrationJson -Path $path -Required
        $schemaProperty = Get-MigrationMember -Object $lock -Name 'schemaVersion'
        $runIdProperty = Get-MigrationMember -Object $lock -Name 'runId'
        if (-not $schemaProperty.exists -or $schemaProperty.value -ne (Get-MigrationSchemaVersion) -or
            -not $runIdProperty.exists -or [string]::IsNullOrWhiteSpace([string]$runIdProperty.value)) {
            throw 'Invalid active lock contract.'
        }
        Assert-MigrationRunId -RunId ([string]$runIdProperty.value)
        return $lock
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
        runId         = $RunId
        processId     = $PID
        createdAt     = Get-MigrationUtcNow
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
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Throw-MigrationError -Code 'lock_create_failed' -Message 'Could not create the migration ownership lock.' -Status failed -Details $_.Exception.Message
        }
        $existing = $null
        try { $existing = Read-MigrationJson -Path $path -Required }
        catch { }
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

function New-MigrationRunState {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$SourceMajor,
        [Parameter(Mandatory = $true)][int]$TargetMajor,
        [Parameter(Mandatory = $true)][string]$InitialCommit,
        [string]$InitialBranch = $null
    )

    Assert-MigrationRunId -RunId $RunId
    if ($TargetMajor -ne ($SourceMajor + 1)) {
        Throw-MigrationError -Code 'non_sequential_target' -Message 'Run state requires a sequential Angular major.' -Status blocked
    }

    return [ordered]@{
        schemaVersion       = Get-MigrationSchemaVersion
        runId               = $RunId
        projectRoot         = $ProjectRoot
        sourceMajor         = $SourceMajor
        targetMajor         = $TargetMajor
        status              = 'running'
        stage               = 'baseline'
        stageRevision       = 0
        attempt             = 1
        migrationStatus     = 'running'
        documentationStatus = 'pending'
        baselineStatus      = 'pending'
        resolutionStatus    = 'pending'
        initialBranch       = $InitialBranch
        manifestSha256      = $null
        migrationBranch     = $null
        initialCommit       = $InitialCommit
        checkpointCommit    = $InitialCommit
        activeOperation     = $null
        completedOperations = @()
        lastDiagnostic      = $null
        repair              = $null
        repairTotal         = 0
        repairs             = @()
        validationResults   = @()
        angularCommandIndex = 0
        runtimeSha256       = $null
        configRepairAllowed = $false
        createdAt           = Get-MigrationUtcNow
        updatedAt           = Get-MigrationUtcNow
    }
}

function Read-MigrationRunState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $state = Read-MigrationJson -Path $paths.state -Required
    Assert-MigrationRunState -State $state -ExpectedRunId $RunId
    return $state
}

function Assert-MigrationRunState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ExpectedRunId
    )

    $schemaProperty = Get-MigrationMember -Object $State -Name 'schemaVersion'
    $runIdProperty = Get-MigrationMember -Object $State -Name 'runId'
    $statusProperty = Get-MigrationMember -Object $State -Name 'status'
    $stageProperty = Get-MigrationMember -Object $State -Name 'stage'
    $revisionProperty = Get-MigrationMember -Object $State -Name 'stageRevision'
    $sourceProperty = Get-MigrationMember -Object $State -Name 'sourceMajor'
    $targetProperty = Get-MigrationMember -Object $State -Name 'targetMajor'
    $baselineProperty = Get-MigrationMember -Object $State -Name 'baselineStatus'
    $resolutionProperty = Get-MigrationMember -Object $State -Name 'resolutionStatus'
    $manifestHashProperty = Get-MigrationMember -Object $State -Name 'manifestSha256'
    $initialBranchProperty = Get-MigrationMember -Object $State -Name 'initialBranch'
    $initialCommitProperty = Get-MigrationMember -Object $State -Name 'initialCommit'
    $checkpointProperty = Get-MigrationMember -Object $State -Name 'checkpointCommit'
    $activeOperationProperty = Get-MigrationMember -Object $State -Name 'activeOperation'
    $completedOperationsProperty = Get-MigrationMember -Object $State -Name 'completedOperations'
    $validStatuses = @('running', 'needs-repair', 'verified', 'completed', 'blocked', 'failed')
    $validBaselineStatuses = @('pending', 'passed')
    $validResolutionStatuses = @('pending', 'resolved')
    $hashValid = $null -eq $manifestHashProperty.value -or [string]$manifestHashProperty.value -match '^[0-9a-f]{64}$'
    $completedValid = $completedOperationsProperty.exists -and $null -ne $completedOperationsProperty.value -and
    @($completedOperationsProperty.value | Where-Object { $_ -notin $script:CompletedOperationIds }).Count -eq 0 -and
    @($completedOperationsProperty.value | Sort-Object -Unique).Count -eq @($completedOperationsProperty.value).Count
    $branchesValid = $initialBranchProperty.exists -and ($null -eq $initialBranchProperty.value -or [string]$initialBranchProperty.value -match '^[^\s]+$') -and
    $checkpointProperty.exists -and ($null -eq $checkpointProperty.value -or [string]$checkpointProperty.value -match '^[a-fA-F0-9]{40}$') -and
    $initialCommitProperty.exists -and [string]$initialCommitProperty.value -match '^[a-fA-F0-9]{40}$'
    if (-not $schemaProperty.exists -or $schemaProperty.value -ne (Get-MigrationSchemaVersion) -or
        -not $runIdProperty.exists -or $runIdProperty.value -ne $ExpectedRunId -or
        -not $statusProperty.exists -or $validStatuses -notcontains $statusProperty.value -or
        -not $stageProperty.exists -or @('baseline', 'resolve', 'update-angular', 'update-dependencies', 'install', 'validate', 'document') -notcontains $stageProperty.value -or
        -not $revisionProperty.exists -or [int]$revisionProperty.value -lt 0 -or
        -not $sourceProperty.exists -or -not $targetProperty.exists -or
        [int]$targetProperty.value -ne ([int]$sourceProperty.value + 1) -or
        -not $baselineProperty.exists -or $validBaselineStatuses -notcontains $baselineProperty.value -or
        -not $resolutionProperty.exists -or $validResolutionStatuses -notcontains $resolutionProperty.value -or
        -not $manifestHashProperty.exists -or -not $hashValid -or
        -not $activeOperationProperty.exists -or -not $completedValid -or -not $branchesValid) {
        Throw-MigrationError -Code 'invalid_run_state' -Message "Migration state is invalid for run: $ExpectedRunId" -Status failed
    }
}

function Move-MigrationState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ExpectedStatus,
        [Parameter(Mandatory = $true)][string]$ExpectedStage,
        [Parameter(Mandatory = $true)][string]$NewStatus,
        [Parameter(Mandatory = $true)][string]$NewStage,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        $Diagnostic = $null
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    if ($state.status -cne $ExpectedStatus -or $state.stage -cne $ExpectedStage -or [int]$state.stageRevision -ne $ExpectedRevision) {
        Throw-MigrationError -Code 'state_revision_conflict' -Message 'Migration state changed since the operation started.' -Status blocked -Details ([PSCustomObject]@{
                expectedStatus = $ExpectedStatus; expectedStage = $ExpectedStage; expectedRevision = $ExpectedRevision
                actualStatus = $state.status; actualStage = $state.stage; actualRevision = $state.stageRevision
            })
    }
    $transitionKey = "$ExpectedStatus|$ExpectedStage"
    $transition = "$NewStatus|$NewStage"
    if (-not $script:AllowedTransitions.ContainsKey($transitionKey) -or $transition -notin $script:AllowedTransitions[$transitionKey]) {
        Throw-MigrationError -Code 'invalid_state_transition' -Message "Transition is not allowed: $transitionKey -> $transition" -Status blocked
    }
    $state.status = $NewStatus
    $state.stage = $NewStage
    $state.stageRevision = $ExpectedRevision + 1
    $state.lastDiagnostic = $Diagnostic
    Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $state
    $verified = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
    if ($verified.status -cne $NewStatus -or $verified.stage -cne $NewStage -or [int]$verified.stageRevision -ne ($ExpectedRevision + 1)) {
        Throw-MigrationError -Code 'state_persistence_failed' -Message 'Persisted migration state did not match the requested transition.' -Status failed
    }
    Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'state-transitioned' -Stage $NewStage -Data ([PSCustomObject]@{
            expectedStatus = $ExpectedStatus; expectedStage = $ExpectedStage; expectedRevision = $ExpectedRevision
            status = $NewStatus; stage = $NewStage; stageRevision = $verified.stageRevision; diagnostic = $Diagnostic
        })
    return $verified
}

function Write-MigrationRunState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$State
    )

    Assert-ActiveRunOwnership -ProjectRoot $ProjectRoot -RunId $RunId
    Assert-MigrationRunState -State $State -ExpectedRunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $State.updatedAt = Get-MigrationUtcNow
    Write-MigrationJsonAtomic -Value $State -Path $paths.state
}

function Write-MigrationRunManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Manifest
    )

    Assert-ActiveRunOwnership -ProjectRoot $ProjectRoot -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.manifestSha256) {
        Throw-MigrationError -Code 'manifest_immutable' -Message 'The resolved migration manifest is immutable.' -Status failed
    }
    if ($Manifest.schemaVersion -ne (Get-MigrationSchemaVersion) -or $Manifest.manifestType -ne 'migration' -or $Manifest.runId -cne $RunId) {
        Throw-MigrationError -Code 'invalid_run_manifest' -Message 'Manifest does not belong to the active run.' -Status failed
    }
    Write-MigrationJsonAtomic -Value $Manifest -Path $paths.manifest
}

function Add-MigrationEvent {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Type,
        [string]$Stage,
        $Data = $null
    )

    Assert-ActiveRunOwnership -ProjectRoot $ProjectRoot -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $event = [ordered]@{
        schemaVersion = Get-MigrationSchemaVersion
        eventId       = [guid]::NewGuid().ToString('N')
        runId         = $RunId
        type          = $Type
        stage         = $Stage
        timestamp     = Get-MigrationUtcNow
        data          = $Data
    }
    $line = ($event | ConvertTo-Json -Depth 30 -Compress) + [Environment]::NewLine
    $stream = $null
    try {
        $stream = [IO.File]::Open($paths.events, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch {
        Throw-MigrationError -Code 'event_write_failed' -Message "Could not append migration event for run: $RunId" -Status failed -Details $_.Exception.Message
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

Export-ModuleMember -Function @(
    'Get-MigrationDirectory',
    'Get-MigrationRunPaths',
    'Assert-MigrationRunId',
    'New-MigrationRunId',
    'Get-ActiveLockPath',
    'Read-ActiveRunLock',
    'New-ActiveRunLock',
    'Remove-ActiveRunLock',
    'Assert-ActiveRunOwnership',
    'New-MigrationRunState',
    'Assert-MigrationRunState',
    'Move-MigrationState',
    'Read-MigrationRunState',
    'Write-MigrationRunState',
    'Write-MigrationRunManifest',
    'Add-MigrationEvent'
)
