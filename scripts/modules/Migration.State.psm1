Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -DisableNameChecking

$script:RunIdPattern = '^[a-z0-9TZ]+(?:-[a-z0-9TZ]+)*$'
$script:OperationLockCounts = @{}
$script:AllowedStages = @('baseline', 'resolve', 'update-angular', 'update-dependencies', 'install', 'validate', 'document', 'done')
$script:CriticalCheckIds = @('install', 'dependency-tree', 'build')
$script:SkippableCheckIds = @('typecheck', 'lint', 'unit-test', 'e2e')
$script:AllowedTransitions = @{
    'running|baseline'            = @('running|resolve', 'blocked|baseline', 'failed|baseline')
    'blocked|baseline'            = @('running|baseline', 'blocked|baseline')
    'running|resolve'             = @('running|update-angular', 'blocked|resolve', 'failed|resolve')
    'running|update-angular'      = @('running|update-dependencies', 'needs-repair|update-angular', 'blocked|update-angular', 'failed|update-angular')
    'running|update-dependencies' = @('running|install', 'blocked|update-dependencies', 'failed|update-dependencies')
    'running|install'             = @('running|validate', 'blocked|install', 'failed|install')
    'running|validate'            = @('verified|document', 'needs-repair|validate', 'blocked|validate', 'failed|validate')
    'needs-repair|update-angular' = @('running|update-angular', 'blocked|update-angular', 'failed|update-angular')
    'needs-repair|validate'       = @('running|validate', 'blocked|validate', 'failed|validate')
    'blocked|resolve'             = @('running|resolve', 'blocked|resolve')
    'blocked|update-angular'      = @('running|update-angular', 'blocked|update-angular')
    'blocked|update-dependencies' = @('running|update-dependencies', 'blocked|update-dependencies')
    'blocked|install'             = @('running|install', 'blocked|install')
    'blocked|validate'            = @('running|validate', 'blocked|validate')
    'verified|document'           = @('verified|document', 'completed|done')
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
        root               = $runDirectory
        manifest           = Join-Path $runDirectory 'manifest.json'
        state              = Join-Path $runDirectory 'state.json'
        events             = Join-Path $runDirectory 'events.jsonl'
        result             = Join-Path $runDirectory 'result.json'
        research           = Join-Path $runDirectory 'research.json'
        inbox              = Join-Path $runDirectory 'inbox'
        artifacts          = Join-Path $runDirectory 'artifacts'
        researchArtifact   = Join-Path (Join-Path $runDirectory 'artifacts') 'research.json'
        skipsArtifact      = Join-Path (Join-Path $runDirectory 'artifacts') 'skips.json'
        documentationInput = Join-Path (Join-Path $runDirectory 'inbox') 'documentation.json'
        logs               = Join-Path $runDirectory 'logs'
        skipsInput         = Join-Path (Join-Path $runDirectory 'inbox') 'skips.json'
    }
}

function Get-MigrationDiscoveryPath {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Join-Path (Get-MigrationDirectory -ProjectRoot $ProjectRoot) 'repo.json'
}

function Get-MigrationDiscoveryLockPath {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Join-Path (Get-MigrationDirectory -ProjectRoot $ProjectRoot) 'discovery.lock'
}

function Get-MigrationOperationLockPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    return Join-Path (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId).root 'operation.lock'
}

function New-MigrationOperationLock {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    $path = Get-MigrationOperationLockPath -ProjectRoot $ProjectRoot -RunId $RunId
    if ($script:OperationLockCounts.ContainsKey($path)) {
        $script:OperationLockCounts[$path] = [int]$script:OperationLockCounts[$path] + 1
        return
    }
    $processStart = $null
    try { $processStart = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { }
    $lock = [ordered]@{
        schemaVersion = Get-MigrationSchemaVersion
        runId         = $RunId
        operationId   = $OperationId
        processId     = $PID
        processStart  = $processStart
        createdAt     = Get-MigrationUtcNow
    }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $stream = $null
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($lock | ConvertTo-Json -Depth 10 -Compress))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            $script:OperationLockCounts[$path] = 1
            return
        }
        catch [IO.IOException] {
            if ($attempt -eq 0 -and (Test-MigrationOperationLockStale -Path $path)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                continue
            }
            $existing = $null
            try { $existing = Read-MigrationJson -Path $path -Required } catch { }
            Throw-MigrationError -Code 'operation_lock_owned' -Message "Another operation owns migration run: $RunId" -Status blocked -Details $existing
        }
        catch {
            Throw-MigrationError -Code 'operation_lock_create_failed' -Message 'Could not create the migration operation lock.' -Status failed -Details $_.Exception.Message
        }
        finally {
            if ($stream) { $stream.Dispose() }
        }
    }
}

function Test-MigrationOperationLockStale {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $lock = $null
    try { $lock = Read-MigrationJson -Path $Path -Required } catch { return $false }
    $processId = 0
    try { $processId = [int]$lock.processId } catch { return $false }
    if ($processId -le 0) { return $true }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $process) { return $true }
    if ($lock.processStart) {
        try {
            $actual = [DateTimeOffset]$process.StartTime.ToUniversalTime()
            $expected = [DateTimeOffset]::Parse([string]$lock.processStart)
            return $actual.Subtract($expected).Duration() -gt [TimeSpan]::FromSeconds(2)
        }
        catch { return $false }
    }
    return $false
}

function Remove-MigrationOperationLock {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $path = Get-MigrationOperationLockPath -ProjectRoot $ProjectRoot -RunId $RunId
    if ($script:OperationLockCounts.ContainsKey($path)) {
        $count = [int]$script:OperationLockCounts[$path] - 1
        if ($count -gt 0) {
            $script:OperationLockCounts[$path] = $count
            return
        }
        $script:OperationLockCounts.Remove($path)
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $lock = $null
        try { $lock = Read-MigrationJson -Path $path -Required } catch { }
        if (-not $lock -or [int]$lock.processId -eq $PID) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-MigrationDiscoveryLock {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $directory = Get-MigrationDirectory -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $path = Get-MigrationDiscoveryLockPath -ProjectRoot $ProjectRoot
    $lock = [ordered]@{
        schemaVersion = Get-MigrationSchemaVersion
        processId     = $PID
        createdAt     = Get-MigrationUtcNow
    }
    $stream = $null
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($lock | ConvertTo-Json -Depth 10 -Compress))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch [IO.IOException] {
        Throw-MigrationError -Code 'discovery_lock_owned' -Message 'Another runtime discovery installation owns the discovery lock.' -Status blocked
    }
    catch {
        Throw-MigrationError -Code 'discovery_lock_create_failed' -Message 'Could not create the discovery lock.' -Status failed -Details $_.Exception.Message
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Remove-MigrationDiscoveryLock {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $path = Get-MigrationDiscoveryLockPath -ProjectRoot $ProjectRoot
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Assert-MigrationRunId {
    param([Parameter(Mandatory = $true)][string]$RunId)

    if ($RunId -notmatch $script:RunIdPattern) {
        Throw-MigrationError -Code 'invalid_run_id' -Message "Invalid run id: $RunId" -Status blocked
    }
}

function Get-MigrationCheckSkipPolicy {
    return [PSCustomObject]@{
        critical  = @($script:CriticalCheckIds)
        skippable = @($script:SkippableCheckIds)
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
        [string]$InitialBranch = $null,
        [AllowNull()][string]$DiscoverySha256 = $null,
        [AllowNull()][string]$InputFingerprint = $null,
        [AllowNull()]$RuntimePlan = $null,
        [AllowNull()][string]$RuntimeFnmPath = $null
    )

    Assert-MigrationRunId -RunId $RunId
    if ($TargetMajor -ne ($SourceMajor + 1)) {
        Throw-MigrationError -Code 'non_sequential_target' -Message 'Run state requires a sequential Angular major.' -Status blocked
    }

    $normalizedInitialBranch = if ([string]::IsNullOrWhiteSpace($InitialBranch)) { $null } else { $InitialBranch }
    $normalizedDiscoverySha256 = if ([string]::IsNullOrWhiteSpace($DiscoverySha256)) { $null } else { $DiscoverySha256 }
    $normalizedInputFingerprint = if ([string]::IsNullOrWhiteSpace($InputFingerprint)) { $null } else { $InputFingerprint }
    $normalizedRuntimeFnmPath = if ([string]::IsNullOrWhiteSpace($RuntimeFnmPath)) { $null } else { $RuntimeFnmPath }

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
        documentation       = [ordered]@{
            status          = 'not-started'
            phase           = $null
            researchSha256  = $null
            researchCommit  = $null
            publishAttempt  = 0
            publishedCommit = $null
            completedAt     = $null
            lastError       = $null
        }
        baselineStatus      = 'pending'
        resolutionStatus    = 'pending'
        initialBranch       = $normalizedInitialBranch
        manifestSha256      = $null
        discoverySha256     = $normalizedDiscoverySha256
        inputFingerprint    = $normalizedInputFingerprint
        runtimePlan         = $RuntimePlan
        runtimeFnmPath      = $normalizedRuntimeFnmPath
        migrationBranch     = $null
        initialCommit       = $InitialCommit
        checkpointCommit    = $InitialCommit
        activeOperation     = $null
        completedOperations = @()
        skippedChecks       = @()
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
    if (-not $state.PSObject.Properties['skippedChecks']) {
        $state | Add-Member -NotePropertyName skippedChecks -NotePropertyValue @()
    }
    if (-not $state.PSObject.Properties['discoverySha256']) {
        $state | Add-Member -NotePropertyName discoverySha256 -NotePropertyValue $null
    }
    if (-not $state.PSObject.Properties['inputFingerprint']) {
        $state | Add-Member -NotePropertyName inputFingerprint -NotePropertyValue $null
    }
    if (-not $state.PSObject.Properties['runtimePlan']) {
        $state | Add-Member -NotePropertyName runtimePlan -NotePropertyValue $null
    }
    if (-not $state.PSObject.Properties['runtimeFnmPath']) {
        $state | Add-Member -NotePropertyName runtimeFnmPath -NotePropertyValue $null
    }
    if ($state.PSObject.Properties['activeOperation'] -and $null -ne $state.activeOperation) {
        $operation = $state.activeOperation
        $defaults = [ordered]@{
            step           = 'starting'
            operationIndex = 0
            operationCount = 0
            currentFile    = $null
            lastActivityAt = if ($operation.PSObject.Properties['startedAt']) { [string]$operation.startedAt } else { Get-MigrationUtcNow }
            health         = 'unknown'
        }
        foreach ($name in $defaults.Keys) {
            if (-not $operation.PSObject.Properties[$name]) {
                $operation | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name]
            }
        }
    }
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
    $attemptProperty = Get-MigrationMember -Object $State -Name 'attempt'
    $sourceProperty = Get-MigrationMember -Object $State -Name 'sourceMajor'
    $targetProperty = Get-MigrationMember -Object $State -Name 'targetMajor'
    $baselineProperty = Get-MigrationMember -Object $State -Name 'baselineStatus'
    $resolutionProperty = Get-MigrationMember -Object $State -Name 'resolutionStatus'
    $manifestHashProperty = Get-MigrationMember -Object $State -Name 'manifestSha256'
    $discoveryHashProperty = Get-MigrationMember -Object $State -Name 'discoverySha256'
    $inputFingerprintProperty = Get-MigrationMember -Object $State -Name 'inputFingerprint'
    $runtimePlanProperty = Get-MigrationMember -Object $State -Name 'runtimePlan'
    $runtimeFnmPathProperty = Get-MigrationMember -Object $State -Name 'runtimeFnmPath'
    $initialBranchProperty = Get-MigrationMember -Object $State -Name 'initialBranch'
    $initialCommitProperty = Get-MigrationMember -Object $State -Name 'initialCommit'
    $checkpointProperty = Get-MigrationMember -Object $State -Name 'checkpointCommit'
    $activeOperationProperty = Get-MigrationMember -Object $State -Name 'activeOperation'
    $completedOperationsProperty = Get-MigrationMember -Object $State -Name 'completedOperations'
    $skippedChecksProperty = Get-MigrationMember -Object $State -Name 'skippedChecks'
    $repairProperty = Get-MigrationMember -Object $State -Name 'repair'
    $repairTotalProperty = Get-MigrationMember -Object $State -Name 'repairTotal'
    $repairsProperty = Get-MigrationMember -Object $State -Name 'repairs'
    $validStatuses = @('running', 'needs-repair', 'verified', 'completed', 'blocked', 'failed')
    $validBaselineStatuses = @('pending', 'passed')
    $validResolutionStatuses = @('pending', 'resolved')
    $hashValid = $null -eq $manifestHashProperty.value -or [string]$manifestHashProperty.value -match '^[0-9a-f]{64}$'
    $discoveryHashValid = $null -eq $discoveryHashProperty.value -or [string]$discoveryHashProperty.value -match '^[0-9a-f]{64}$'
    $inputFingerprintValid = $null -eq $inputFingerprintProperty.value -or [string]$inputFingerprintProperty.value -match '^sha256:[0-9a-f]{64}$'
    $completedValid = $completedOperationsProperty.exists -and $null -ne $completedOperationsProperty.value -and
    @($completedOperationsProperty.value | Where-Object { $_ -notin $script:CompletedOperationIds }).Count -eq 0 -and
    @($completedOperationsProperty.value | Sort-Object -Unique).Count -eq @($completedOperationsProperty.value).Count
    $skippedValid = $skippedChecksProperty.exists -and $null -ne $skippedChecksProperty.value -and $skippedChecksProperty.value -is [array]
    $attemptValid = $attemptProperty.exists -and [int]$attemptProperty.value -ge 1 -and [int]$attemptProperty.value -le 3
    $repairTotalValid = $repairTotalProperty.exists -and [int]$repairTotalProperty.value -ge 0 -and [int]$repairTotalProperty.value -le 5
    $repairsValid = $repairsProperty.exists -and $null -ne $repairsProperty.value -and $repairsProperty.value -is [array]
    $activeOperationValid = $activeOperationProperty.exists
    if ($null -ne $activeOperationProperty.value) {
        $operation = $activeOperationProperty.value
        $operationNames = if ($operation -is [Collections.IDictionary]) { @($operation.Keys | ForEach-Object { [string]$_ }) } else { @($operation.PSObject.Properties | Select-Object -ExpandProperty Name) }
        $allowedOperationNames = @('id', 'stage', 'startedAt', 'checkpointCommit', 'expectedManifestSha256', 'preexistingFiles', 'step', 'operationIndex', 'operationCount', 'currentFile', 'lastActivityAt', 'health')
        $operationId = Get-MigrationMember -Object $operation -Name 'id'
        $operationStage = Get-MigrationMember -Object $operation -Name 'stage'
        $operationStarted = Get-MigrationMember -Object $operation -Name 'startedAt'
        $operationCheckpoint = Get-MigrationMember -Object $operation -Name 'checkpointCommit'
        $operationManifest = Get-MigrationMember -Object $operation -Name 'expectedManifestSha256'
        $operationFiles = Get-MigrationMember -Object $operation -Name 'preexistingFiles'
        $operationStep = Get-MigrationMember -Object $operation -Name 'step'
        $operationIndex = Get-MigrationMember -Object $operation -Name 'operationIndex'
        $operationCount = Get-MigrationMember -Object $operation -Name 'operationCount'
        $operationFile = Get-MigrationMember -Object $operation -Name 'currentFile'
        $operationActivity = Get-MigrationMember -Object $operation -Name 'lastActivityAt'
        $operationHealth = Get-MigrationMember -Object $operation -Name 'health'
        $startedValid = $false
        $activityValid = $false
        if ($operationStarted.exists) { try { [DateTimeOffset]::Parse([string]$operationStarted.value) | Out-Null; $startedValid = $true } catch { } }
        if ($operationActivity.exists) { try { [DateTimeOffset]::Parse([string]$operationActivity.value) | Out-Null; $activityValid = $true } catch { } }
        $activeOperationValid = $null -ne $operation -and
        (($operation -is [Collections.IDictionary]) -or ($operation -is [PSCustomObject])) -and
        @($operationNames | Where-Object { $_ -notin $allowedOperationNames }).Count -eq 0 -and
        $operationNames.Count -ge 6 -and $operationId.exists -and -not [string]::IsNullOrWhiteSpace([string]$operationId.value) -and
        $operationStage.exists -and -not [string]::IsNullOrWhiteSpace([string]$operationStage.value) -and
        $startedValid -and $operationCheckpoint.exists -and [string]$operationCheckpoint.value -match '^[a-fA-F0-9]{40}$' -and
        $operationManifest.exists -and ($null -eq $operationManifest.value -or [string]$operationManifest.value -match '^[0-9a-f]{64}$') -and
        $operationFiles.exists -and $operationFiles.value -is [array]
        if ($operationStep.exists) { $activeOperationValid = $activeOperationValid -and -not [string]::IsNullOrWhiteSpace([string]$operationStep.value) }
        if ($operationIndex.exists) { $activeOperationValid = $activeOperationValid -and ([int]$operationIndex.value -ge 0) }
        if ($operationCount.exists) { $activeOperationValid = $activeOperationValid -and ([int]$operationCount.value -ge 0) }
        if ($operationIndex.exists -and $operationCount.exists) { $activeOperationValid = $activeOperationValid -and ([int]$operationIndex.value -le [int]$operationCount.value) }
        if ($operationFile.exists) { $activeOperationValid = $activeOperationValid -and ($null -eq $operationFile.value -or $operationFile.value -is [string]) }
        if ($operationActivity.exists) { $activeOperationValid = $activeOperationValid -and $activityValid }
        if ($operationHealth.exists) { $activeOperationValid = $activeOperationValid -and ([string]$operationHealth.value -in @('healthy', 'stalled', 'unknown')) }
    }
    $repairSummaryKeys = @{}
    foreach ($repairSummary in @($repairsProperty.value)) {
        if ($null -eq $repairSummary -or $repairSummary -isnot [PSCustomObject]) { $repairsValid = $false; continue }
        $summaryNames = @($repairSummary.PSObject.Properties.Name)
        $summaryFingerprint = Get-MigrationMember -Object $repairSummary -Name 'fingerprint'
        $summaryAttempt = Get-MigrationMember -Object $repairSummary -Name 'attempt'
        $summaryCommit = Get-MigrationMember -Object $repairSummary -Name 'commit'
        $summaryReport = Get-MigrationMember -Object $repairSummary -Name 'report'
        $summaryReportHash = Get-MigrationMember -Object $repairSummary -Name 'reportSha256'
        $summaryKey = if ($summaryFingerprint.exists -and $summaryAttempt.exists) { [string]$summaryFingerprint.value + '|' + [string]$summaryAttempt.value } else { '' }
        if (($summaryNames | Where-Object { $_ -notin @('fingerprint', 'attempt', 'commit', 'report', 'reportSha256') }) -or
            $summaryNames.Count -ne 5 -or -not $summaryFingerprint.exists -or [string]$summaryFingerprint.value -notmatch '^sha256:[0-9a-f]{64}$' -or
            -not $summaryAttempt.exists -or [int]$summaryAttempt.value -lt 1 -or [int]$summaryAttempt.value -gt 3 -or
            -not $summaryCommit.exists -or [string]$summaryCommit.value -notmatch '^[a-fA-F0-9]{40}$' -or
            -not $summaryReport.exists -or [string]$summaryReport.value -notmatch ('^\.angular-migration/runs/' + [regex]::Escape($ExpectedRunId) + '/repairs/[^/]+\.json$') -or [string]$summaryReport.value -match '(^|/|\\)\.\.($|/|\\)' -or
            -not $summaryReportHash.exists -or [string]$summaryReportHash.value -notmatch '^[0-9a-f]{64}$' -or $repairSummaryKeys.ContainsKey($summaryKey)) { $repairsValid = $false }
        else { $repairSummaryKeys[$summaryKey] = $true }
    }
    $repairValid = $repairProperty.exists -and ($null -eq $repairProperty.value -or $repairProperty.value -is [PSCustomObject])
    if ($null -ne $repairProperty.value) {
        $repairNames = @($repairProperty.value.PSObject.Properties.Name)
        $repairContext = Get-MigrationMember -Object $repairProperty.value -Name 'context'
        $repairHistory = if ($repairContext.exists -and $null -ne $repairContext.value -and $repairContext.value -is [PSCustomObject]) { Get-MigrationMember -Object $repairContext.value -Name 'history' } else { [PSCustomObject]@{ exists = $false; value = $null } }
        $repairDiagnosticHash = Get-MigrationMember -Object $repairProperty.value -Name 'diagnosticHash'
        $repairBefore = Get-MigrationMember -Object $repairProperty.value -Name 'before'
        $repairProtected = Get-MigrationMember -Object $repairProperty.value -Name 'protected'
        $repairAccepted = Get-MigrationMember -Object $repairProperty.value -Name 'accepted'
        $repairFacadePath = Get-MigrationMember -Object $repairProperty.value -Name 'facadePath'
        if (($repairNames | Where-Object { $_ -notin @('context', 'diagnosticHash', 'before', 'protected', 'accepted', 'facadePath') }) -or
            $repairNames.Count -ne 6 -or -not $repairContext.exists -or $null -eq $repairContext.value -or
            -not $repairHistory.exists -or $null -eq $repairHistory.value -or $repairContext.value -isnot [PSCustomObject] -or $repairHistory.value -isnot [PSCustomObject] -or
            -not $repairDiagnosticHash.exists -or [string]$repairDiagnosticHash.value -notmatch '^[0-9a-f]{64}$' -or
            -not $repairBefore.exists -or $repairBefore.value -isnot [array] -or -not $repairProtected.exists -or $repairProtected.value -isnot [array] -or
            -not $repairFacadePath.exists -or [string]::IsNullOrWhiteSpace([string]$repairFacadePath.value) -or
            -not $repairAccepted.exists) { $repairValid = $false }
        foreach ($beforeItem in @($repairBefore.value)) {
            $beforeNames = if ($beforeItem -is [PSCustomObject]) { @($beforeItem.PSObject.Properties.Name) } else { @() }
            if ($beforeItem -isnot [PSCustomObject] -or ($beforeNames | Where-Object { $_ -notin @('status', 'path', 'untracked') }) -or $beforeNames.Count -ne 3 -or
                [string]::IsNullOrWhiteSpace([string](Get-MigrationMember -Object $beforeItem -Name 'path').value) -or (Get-MigrationMember -Object $beforeItem -Name 'untracked').value -isnot [bool]) { $repairValid = $false }
        }
        foreach ($protectedItem in @($repairProtected.value)) {
            $protectedNames = if ($protectedItem -is [PSCustomObject]) { @($protectedItem.PSObject.Properties.Name) } else { @() }
            $protectedPath = if ($protectedItem -is [PSCustomObject]) { Get-MigrationMember -Object $protectedItem -Name 'path' } else { [PSCustomObject]@{ exists = $false; value = $null } }
            $protectedHash = if ($protectedItem -is [PSCustomObject]) { Get-MigrationMember -Object $protectedItem -Name 'hash' } else { [PSCustomObject]@{ exists = $false; value = $null } }
            if ($protectedItem -isnot [PSCustomObject] -or ($protectedNames | Where-Object { $_ -notin @('path', 'hash') }) -or $protectedNames.Count -ne 2 -or
                -not $protectedPath.exists -or [string]::IsNullOrWhiteSpace([string]$protectedPath.value) -or -not $protectedHash.exists -or
                ($null -ne $protectedHash.value -and [string]$protectedHash.value -notmatch '^[0-9A-Fa-f]{64}$')) { $repairValid = $false }
        }
        if ($repairAccepted.value -ne $null) {
            $acceptedNames = if ($repairAccepted.value -is [PSCustomObject]) { @($repairAccepted.value.PSObject.Properties.Name) } else { @() }
            $acceptedFingerprint = if ($repairAccepted.value -is [PSCustomObject]) { Get-MigrationMember -Object $repairAccepted.value -Name 'fingerprint' } else { [PSCustomObject]@{ exists = $false; value = $null } }
            $acceptedAttempt = if ($repairAccepted.value -is [PSCustomObject]) { Get-MigrationMember -Object $repairAccepted.value -Name 'attempt' } else { [PSCustomObject]@{ exists = $false; value = $null } }
            $acceptedCommit = if ($repairAccepted.value -is [PSCustomObject]) { Get-MigrationMember -Object $repairAccepted.value -Name 'commit' } else { [PSCustomObject]@{ exists = $false; value = $null } }
            $acceptedReport = if ($repairAccepted.value -is [PSCustomObject]) { Get-MigrationMember -Object $repairAccepted.value -Name 'report' } else { [PSCustomObject]@{ exists = $false; value = $null } }
            $acceptedReportHash = if ($repairAccepted.value -is [PSCustomObject]) { Get-MigrationMember -Object $repairAccepted.value -Name 'reportSha256' } else { [PSCustomObject]@{ exists = $false; value = $null } }
            if ($repairAccepted.value -isnot [PSCustomObject] -or ($acceptedNames | Where-Object { $_ -notin @('fingerprint', 'attempt', 'commit', 'report', 'reportSha256') }) -or $acceptedNames.Count -ne 5 -or
                -not $acceptedFingerprint.exists -or [string]$acceptedFingerprint.value -notmatch '^sha256:[0-9a-f]{64}$' -or
                -not $acceptedAttempt.exists -or [int]$acceptedAttempt.value -lt 1 -or [int]$acceptedAttempt.value -gt 3 -or
                -not $acceptedCommit.exists -or [string]$acceptedCommit.value -notmatch '^[a-fA-F0-9]{40}$' -or
                -not $acceptedReport.exists -or [string]$acceptedReport.value -notmatch ('^\.angular-migration/runs/' + [regex]::Escape($ExpectedRunId) + '/repairs/[^/]+\.json$') -or
                -not $acceptedReportHash.exists -or [string]$acceptedReportHash.value -notmatch '^[0-9a-f]{64}$') { $repairValid = $false }
        }
        if ($repairContext.exists -and $null -ne $repairContext.value -and $repairContext.value -is [PSCustomObject] -and
            $repairHistory.exists -and $null -ne $repairHistory.value -and $repairHistory.value -is [PSCustomObject]) {
            $context = $repairContext.value
            $history = $repairHistory.value
            $contextRunId = Get-MigrationMember -Object $context -Name 'runId'
            $contextStatus = Get-MigrationMember -Object $context -Name 'status'
            $contextStage = Get-MigrationMember -Object $context -Name 'stage'
            $contextFailedCheck = Get-MigrationMember -Object $context -Name 'failedCheck'
            $contextFingerprint = Get-MigrationMember -Object $context -Name 'fingerprint'
            $contextAttempt = Get-MigrationMember -Object $context -Name 'attempt'
            $contextCheckpoint = Get-MigrationMember -Object $context -Name 'checkpointCommit'
            $historyCheckpoint = Get-MigrationMember -Object $context -Name 'historyCheckpointCommit'
            $contextManifest = Get-MigrationMember -Object $context -Name 'manifestSha256'
            $historyPath = Get-MigrationMember -Object $history -Name 'path'
            $historyEntryCount = Get-MigrationMember -Object $history -Name 'entryCount'
            $historyPreviousAttempts = Get-MigrationMember -Object $history -Name 'previousAttempts'
            $historyLastOutcome = Get-MigrationMember -Object $history -Name 'lastOutcome'
            $expectedHistoryPrefix = '.angular-migration/runs/' + $ExpectedRunId + '/repair-history/'
            $historyOutcomeValues = @('submission-rejected', 'submission-accepted', 'verification-failed', 'verification-passed', 'attempts-exhausted')
            $contextAllowedPaths = Get-MigrationMember -Object $context -Name 'allowedPaths'
            $contextForbiddenPaths = Get-MigrationMember -Object $context -Name 'forbiddenPaths'
            $contextDiagnostic = Get-MigrationMember -Object $context -Name 'diagnostic'
            $contextSubmissionPath = Get-MigrationMember -Object $context -Name 'submissionPath'
            $expectedHistoryPath = if ($contextFingerprint.exists -and [string]$contextFingerprint.value -match '^sha256:([0-9a-f]{64})$') { $expectedHistoryPrefix + $Matches[1] + '/repair.jsonl' } else { '' }
            if (-not $contextRunId.exists -or $contextRunId.value -cne $ExpectedRunId -or
                -not $contextStatus.exists -or $contextStatus.value -cne 'needs-repair' -or
                -not $contextStage.exists -or $contextStage.value -notin @('validate', 'update-angular') -or
                $contextStage.value -cne $stageProperty.value -or
                -not $contextFailedCheck.exists -or [string]::IsNullOrWhiteSpace([string]$contextFailedCheck.value) -or
                -not $contextFingerprint.exists -or [string]$contextFingerprint.value -notmatch '^sha256:[0-9a-f]{64}$' -or
                -not $contextAttempt.exists -or [int]$contextAttempt.value -lt 1 -or [int]$contextAttempt.value -gt 3 -or [int]$contextAttempt.value -ne [int]$attemptProperty.value -or
                -not $contextCheckpoint.exists -or [string]$contextCheckpoint.value -notmatch '^[a-fA-F0-9]{40}$' -or
                -not $historyCheckpoint.exists -or [string]$historyCheckpoint.value -notmatch '^[a-fA-F0-9]{40}$' -or
                -not $contextManifest.exists -or [string]$contextManifest.value -notmatch '^[0-9a-f]{64}$' -or
                -not $contextAllowedPaths.exists -or $contextAllowedPaths.value -isnot [array] -or $contextAllowedPaths.value.Count -lt 1 -or
                -not $contextForbiddenPaths.exists -or $contextForbiddenPaths.value -isnot [array] -or
                -not $contextDiagnostic.exists -or $contextDiagnostic.value -isnot [PSCustomObject] -or
                -not $contextSubmissionPath.exists -or [string]$contextSubmissionPath.value -cne ('.angular-migration/runs/' + $ExpectedRunId + '/inbox/repair.json') -or
                -not $historyPath.exists -or [string]$historyPath.value -cne $expectedHistoryPath -or
                -not $historyEntryCount.exists -or [int]$historyEntryCount.value -lt 1 -or
                -not $historyPreviousAttempts.exists -or [int]$historyPreviousAttempts.value -lt 0 -or [int]$historyPreviousAttempts.value -gt 3 -or
                -not $historyLastOutcome.exists -or ($null -ne $historyLastOutcome.value -and $historyOutcomeValues -notcontains [string]$historyLastOutcome.value)) {
                $repairValid = $false
            }
            if ($repairAccepted.value -ne $null) {
                if ([string]$repairAccepted.value.fingerprint -cne [string]$contextFingerprint.value -or [int]$repairAccepted.value.attempt -ne [int]$contextAttempt.value) { $repairValid = $false }
            }
        }
        else { $repairValid = $false }
    }
    $skipKeys = @{}
    foreach ($skip in @($skippedChecksProperty.value)) {
        if ($null -eq $skip -or $skip -isnot [PSCustomObject]) { $skippedValid = $false; continue }
        $skipNames = @($skip.PSObject.Properties.Name)
        $skipStage = Get-MigrationMember -Object $skip -Name 'stage'
        $skipCheckId = Get-MigrationMember -Object $skip -Name 'checkId'
        $skipReason = Get-MigrationMember -Object $skip -Name 'reason'
        $skipDiagnostic = Get-MigrationMember -Object $skip -Name 'diagnostic'
        $skipApprovedAt = Get-MigrationMember -Object $skip -Name 'approvedAt'
        $skipConfirmed = Get-MigrationMember -Object $skip -Name 'confirmed'
        $skipTimestampValid = $false
        if ($skipApprovedAt.exists -and $skipApprovedAt.value) {
            try { $skipTimestampValid = ([DateTimeOffset]::Parse([string]$skipApprovedAt.value)).Offset -eq [TimeSpan]::Zero } catch { $skipTimestampValid = $false }
        }
        $skipKey = if ($skipStage.exists -and $skipCheckId.exists) { [string]$skipStage.value + '|' + [string]$skipCheckId.value } else { '' }
        $skipShapeValid = @('stage', 'checkId', 'reason', 'diagnostic', 'approvedAt', 'confirmed') | ForEach-Object { $_ -in $skipNames } | Where-Object { -not $_ } | Measure-Object | Select-Object -ExpandProperty Count
        if ($skipNames | Where-Object { $_ -notin @('stage', 'checkId', 'reason', 'diagnostic', 'approvedAt', 'confirmed') }) { $skipShapeValid = 1 }
        if (-not $skipStage.exists -or $skipStage.value -cne 'baseline' -or
            -not $skipCheckId.exists -or $skipCheckId.value -notin $script:SkippableCheckIds -or
            -not $skipReason.exists -or $skipReason.value -isnot [string] -or [string]::IsNullOrWhiteSpace($skipReason.value) -or $skipReason.value.Length -gt 2000 -or
            -not $skipDiagnostic.exists -or $null -eq $skipDiagnostic.value -or
            -not $skipApprovedAt.exists -or -not $skipTimestampValid -or
            -not $skipConfirmed.exists -or $skipConfirmed.value -isnot [bool] -or -not $skipConfirmed.value -or
            $skipShapeValid -ne 0 -or $skipKeys.ContainsKey($skipKey)) {
            $skippedValid = $false
        }
        else { $skipKeys[$skipKey] = $true }
    }
    $branchesValid = $initialBranchProperty.exists -and ($null -eq $initialBranchProperty.value -or [string]$initialBranchProperty.value -match '^[^\s]+$') -and
    $checkpointProperty.exists -and ($null -eq $checkpointProperty.value -or [string]$checkpointProperty.value -match '^[a-fA-F0-9]{40}$') -and
    $initialCommitProperty.exists -and [string]$initialCommitProperty.value -match '^[a-fA-F0-9]{40}$'
    if (-not $schemaProperty.exists -or $schemaProperty.value -ne (Get-MigrationSchemaVersion) -or
        -not $runIdProperty.exists -or $runIdProperty.value -ne $ExpectedRunId -or
        -not $statusProperty.exists -or $validStatuses -notcontains $statusProperty.value -or
        -not $stageProperty.exists -or $script:AllowedStages -notcontains $stageProperty.value -or
        -not $revisionProperty.exists -or [int]$revisionProperty.value -lt 0 -or
        -not $sourceProperty.exists -or -not $targetProperty.exists -or
        [int]$targetProperty.value -ne ([int]$sourceProperty.value + 1) -or
        -not $attemptValid -or -not $repairTotalValid -or -not $repairsValid -or -not $repairValid -or
        -not $baselineProperty.exists -or $validBaselineStatuses -notcontains $baselineProperty.value -or
        -not $resolutionProperty.exists -or $validResolutionStatuses -notcontains $resolutionProperty.value -or
        -not $manifestHashProperty.exists -or -not $hashValid -or
        -not $discoveryHashProperty.exists -or -not $discoveryHashValid -or
        -not $inputFingerprintProperty.exists -or -not $inputFingerprintValid -or
        -not $runtimePlanProperty.exists -or -not $runtimeFnmPathProperty.exists -or
        -not $activeOperationProperty.exists -or -not $activeOperationValid -or -not $completedValid -or -not $skippedValid -or -not $branchesValid) {
        Throw-MigrationError -Code 'invalid_run_state' -Message "Migration state is invalid for run: $ExpectedRunId" -Status failed
    }

    $documentationProperty = Get-MigrationMember -Object $State -Name 'documentation'
    $legacyDocumentationProperty = Get-MigrationMember -Object $State -Name 'documentationStatus'
    $documentationStatuses = @('not-started', 'researching', 'researched', 'publishing', 'completed', 'failed')
    $documentationPhases = @('research', 'publish')
    if (-not $documentationProperty.exists -or $null -eq $documentationProperty.value) {
        Throw-MigrationError -Code 'invalid_run_state' -Message "Documentation state is missing for run: $ExpectedRunId" -Status failed
    }
    $documentation = $documentationProperty.value
    $documentationStatus = Get-MigrationMember -Object $documentation -Name 'status'
    $documentationPhase = Get-MigrationMember -Object $documentation -Name 'phase'
    $researchHash = Get-MigrationMember -Object $documentation -Name 'researchSha256'
    $researchCommit = Get-MigrationMember -Object $documentation -Name 'researchCommit'
    $publishAttempt = Get-MigrationMember -Object $documentation -Name 'publishAttempt'
    $publishedCommit = Get-MigrationMember -Object $documentation -Name 'publishedCommit'
    $completedAt = Get-MigrationMember -Object $documentation -Name 'completedAt'
    $lastError = Get-MigrationMember -Object $documentation -Name 'lastError'
    $documentationHashValid = $researchHash.exists -and ($null -eq $researchHash.value -or [string]$researchHash.value -match '^[0-9a-f]{64}$')
    $documentationCommitValid = $researchCommit.exists -and ($null -eq $researchCommit.value -or [string]$researchCommit.value -match '^[a-fA-F0-9]{40}$')
    $publishedCommitValid = $publishedCommit.exists -and ($null -eq $publishedCommit.value -or [string]$publishedCommit.value -match '^[a-fA-F0-9]{40}$')
    $phaseValid = $documentationPhase.exists -and ($null -eq $documentationPhase.value -or $documentationPhases -contains $documentationPhase.value)
    $expectedLegacyStatus = if ($documentationStatus.value -ceq 'not-started') { 'pending' } else { [string]$documentationStatus.value }
    $legacyStatusValid = $legacyDocumentationProperty.exists -and $legacyDocumentationProperty.value -in @('pending', 'researching', 'researched', 'publishing', 'completed', 'failed') -and $legacyDocumentationProperty.value -ceq $expectedLegacyStatus
    if (-not $documentationStatus.exists -or $documentationStatuses -notcontains $documentationStatus.value -or
        -not $phaseValid -or -not $documentationHashValid -or -not $documentationCommitValid -or
        -not $publishedCommitValid -or -not $publishAttempt.exists -or [int]$publishAttempt.value -lt 0 -or
        -not $completedAt.exists -or ($null -ne $completedAt.value -and [string]::IsNullOrWhiteSpace([string]$completedAt.value)) -or
        -not $lastError.exists -or -not $legacyStatusValid -or
        ($documentationStatus.value -eq 'failed' -and $null -eq $documentationPhase.value)) {
        Throw-MigrationError -Code 'invalid_run_state' -Message "Documentation state is invalid for run: $ExpectedRunId" -Status failed
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
    'Get-MigrationDiscoveryPath',
    'Get-MigrationDiscoveryLockPath',
    'Get-MigrationOperationLockPath',
    'New-MigrationDiscoveryLock',
    'Remove-MigrationDiscoveryLock',
    'New-MigrationOperationLock',
    'Remove-MigrationOperationLock',
    'Assert-MigrationRunId',
    'Get-MigrationCheckSkipPolicy',
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
