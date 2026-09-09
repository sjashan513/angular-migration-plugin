#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Command,
    [int]$TargetMajor = 0,
    [string]$RunId
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-MigrationEnvelope {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][bool]$Ok,
        [Parameter(Mandatory = $true)][string]$Status,
        $Data = @{},
        $ErrorInfo = $null
    )

    $envelope = [ordered]@{
        schemaVersion = 5
        command = $CommandName
        ok = $Ok
        status = $Status
        data = $Data
        error = $ErrorInfo
    }
    [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Depth 50 -Compress))
}

function Get-MigrationExitCode {
    param([Parameter(Mandatory = $true)][string]$Status)

    if ($Status -eq 'blocked') { return 2 }
    if ($Status -eq 'failed') { return 1 }
    return 0
}

function New-StartManifest {
    param(
        [Parameter(Mandatory = $true)]$Inspection,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$Target
    )

    return [ordered]@{
        schemaVersion = 5
        manifestType = 'migration'
        runId = $RunId
        createdAt = Get-MigrationUtcNow
        project = [ordered]@{
            name = $Inspection.projectName
            root = $Inspection.projectRoot
            packageManager = 'npm'
            files = $Inspection.files
            git = [ordered]@{
                branch = $Inspection.git.branch
                initialCommit = $Inspection.git.head
            }
        }
        sourceMajor = $Inspection.angular.currentMajor
        targetMajor = $Target
        angular = [ordered]@{
            current = $Inspection.angular.packages
            target = [ordered]@{
                major = $Target
                resolved = $false
                resolutionStatus = 'pending'
            }
        }
        dependencies = $Inspection.dependencies
        policies = $Inspection.policies
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
            'e2e'
        )
        policy = [ordered]@{
            sequentialMajor = $true
            exactManifestVersions = $true
            allowForce = $false
            allowDirty = $false
            allowLegacyPeerDeps = $false
        }
        checks = $Inspection.checks
        warnings = @()
    }
}

function Invoke-InspectCommand {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $inspection = Get-ProjectInspection -ProjectRoot $ProjectRoot
    return [PSCustomObject]@{
        ok = [bool]$inspection.ready
        status = $inspection.status
        data = $inspection
        error = if ($inspection.ready) { $null } else {
            [PSCustomObject]@{
                code = 'project_not_ready'
                message = 'Project inspection found blocking preconditions.'
                details = $inspection.blockers
            }
        }
    }
}

function Invoke-StartCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$Target
    )

    if ($Target -lt 1) {
        Throw-MigrationError -Code 'target_major_required' -Message '-TargetMajor must be a positive Angular major.' -Status blocked
    }

    $inspection = Get-ProjectInspection -ProjectRoot $ProjectRoot
    if (-not $inspection.ready) {
        Throw-MigrationError -Code 'project_not_ready' -Message 'Project inspection found blocking preconditions.' -Status blocked -Details $inspection.blockers
    }

    $expectedTarget = [int]$inspection.angular.currentMajor + 1
    if ($Target -ne $expectedTarget) {
        Throw-MigrationError -Code 'non_sequential_target' -Message "Only the next Angular major is allowed. Expected $expectedTarget, received $Target." -Status blocked -Details ([PSCustomObject]@{
                sourceMajor = $inspection.angular.currentMajor
                expectedTargetMajor = $expectedTarget
                requestedTargetMajor = $Target
            })
    }

    Assert-NoLegacyMigrationMetadata -ProjectRoot $ProjectRoot
    $runningRuns = @(Get-RunningMigrationRuns -ProjectRoot $ProjectRoot)
    if ($runningRuns.Count -gt 0) {
        Throw-MigrationError -Code 'active_run' -Message "A migration run is already active: $($runningRuns[0].runId)" -Status blocked -Details $runningRuns[0]
    }

    $runId = New-MigrationRunId -SourceMajor $inspection.angular.currentMajor -TargetMajor $Target -ProjectRoot $ProjectRoot
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $runId
    $createdRunDirectory = $false
    $lockCreated = $false
    try {
        New-Item -ItemType Directory -Path $paths.logs -Force | Out-Null
        $createdRunDirectory = $true
        New-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $runId
        $lockCreated = $true

        $manifest = New-StartManifest -Inspection $inspection -RunId $runId -Target $Target
        $state = New-MigrationRunState -RunId $runId -ProjectRoot $ProjectRoot -SourceMajor $inspection.angular.currentMajor -TargetMajor $Target -InitialCommit $inspection.git.head
        Write-MigrationJsonAtomic -Value $manifest -Path $paths.manifest
        Write-MigrationJsonAtomic -Value $state -Path $paths.state
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $runId -Type 'run-started' -Stage 'baseline' -Data ([PSCustomObject]@{
                sourceMajor = $inspection.angular.currentMajor
                targetMajor = $Target
                initialCommit = $inspection.git.head
            })

        return [PSCustomObject]@{
            ok = $true
            status = 'running'
            data = [PSCustomObject]@{
                runId = $runId
                sourceMajor = $inspection.angular.currentMajor
                targetMajor = $Target
                stage = 'baseline'
                manifest = '.angular-migration/runs/' + $runId + '/manifest.json'
                state = '.angular-migration/runs/' + $runId + '/state.json'
            }
            error = $null
        }
    }
    catch {
        if ($lockCreated) { Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $runId }
        if ($createdRunDirectory -and (Test-Path -LiteralPath $paths.root -PathType Container)) {
            Remove-Item -LiteralPath $paths.root -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Invoke-StatusCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RequestedRunId
    )

    if ([string]::IsNullOrWhiteSpace($RequestedRunId)) {
        Throw-MigrationError -Code 'run_id_required' -Message '-RunId is required for status.' -Status blocked
    }
    Assert-MigrationRunId -RunId $RequestedRunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RequestedRunId
    if (-not (Test-Path -LiteralPath $paths.state -PathType Leaf)) {
        Throw-MigrationError -Code 'run_not_found' -Message "Migration run not found: $RequestedRunId" -Status blocked
    }

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RequestedRunId
    $successful = @('running', 'verified', 'completed') -contains $state.status
    return [PSCustomObject]@{
        ok = $successful
        status = $state.status
        data = [PSCustomObject]@{
            runId = $state.runId
            status = $state.status
            stage = $state.stage
            attempt = $state.attempt
            migrationStatus = $state.migrationStatus
            documentationStatus = $state.documentationStatus
            lastDiagnostic = $state.lastDiagnostic
            manifest = '.angular-migration/runs/' + $RequestedRunId + '/manifest.json'
            state = '.angular-migration/runs/' + $RequestedRunId + '/state.json'
        }
        error = $null
    }
}

$projectRoot = $null
try {
    $moduleDirectory = Join-Path $PSScriptRoot 'modules'
    Import-Module (Join-Path $moduleDirectory 'Migration.Core.psm1') -DisableNameChecking
    Import-Module (Join-Path $moduleDirectory 'Migration.State.psm1') -DisableNameChecking
    Import-Module (Join-Path $moduleDirectory 'Migration.Project.psm1') -DisableNameChecking
    $projectRoot = Resolve-MigrationRoot -Path (Get-Location).Path

    $result = switch ($Command.ToLowerInvariant()) {
        'inspect' { Invoke-InspectCommand -ProjectRoot $projectRoot }
        'start' { Invoke-StartCommand -ProjectRoot $projectRoot -Target $TargetMajor }
        'status' { Invoke-StatusCommand -ProjectRoot $projectRoot -RequestedRunId $RunId }
        default {
            Throw-MigrationError -Code 'unsupported_command' -Message "Unsupported v5 command: $Command" -Status blocked -Details ([PSCustomObject]@{ supported = @('inspect', 'start', 'status') })
        }
    }

    Write-MigrationEnvelope -CommandName $Command.ToLowerInvariant() -Ok $result.ok -Status $result.status -Data $result.data -ErrorInfo $result.error
    exit (Get-MigrationExitCode -Status $result.status)
}
catch {
    $exception = $_.Exception
    $status = 'failed'
    $code = 'internal_error'
    $details = $null
    if ($exception.Data.Contains('status')) { $status = [string]$exception.Data['status'] }
    if ($exception.Data.Contains('code')) { $code = [string]$exception.Data['code'] }
    if ($exception.Data.Contains('details')) { $details = $exception.Data['details'] }
    $errorInfo = [PSCustomObject]@{
        code = $code
        message = $exception.Message
        details = $details
    }
    Write-MigrationEnvelope -CommandName $Command.ToLowerInvariant() -Ok $false -Status $status -Data @{} -ErrorInfo $errorInfo
    exit (Get-MigrationExitCode -Status $status)
}
