#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Command,
    [int]$TargetMajor = 0,
    [string]$RunId,
    [ValidateSet('baseline', 'resolve', 'update-angular', 'update-dependencies', 'install', 'validate')][string]$Stage,
    [string]$CheckId,
    [string]$Reason,
    [string]$ProposalHash,
    [switch]$Confirmed,
    [ValidateSet('research', 'publish')][string]$Mode,
    [string]$InputFile,
    [string]$ProjectRoot
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
        command       = $CommandName
        ok            = $Ok
        status        = $Status
        data          = $Data
        error         = $ErrorInfo
    }
    [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Depth 50 -Compress))
}

function Get-MigrationExitCode {
    param([Parameter(Mandatory = $true)][string]$Status)

    if (@('ready', 'running', 'researching', 'researched', 'publishing', 'verified', 'completed') -contains $Status) { return 0 }
    if (@('blocked', 'needs-repair') -contains $Status) { return 2 }
    return 1
}

$commandName = if ([string]::IsNullOrWhiteSpace($Command)) { 'unknown' } else { $Command.ToLowerInvariant() }
try {
    $moduleDirectory = Join-Path $PSScriptRoot 'modules'
    Import-Module (Join-Path $moduleDirectory 'Migration.Core.psm1') -DisableNameChecking
    Import-Module (Join-Path $moduleDirectory 'Migration.Pipeline.psm1') -DisableNameChecking
    $requestedProjectRoot = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { (Get-Location).Path } else { $ProjectRoot }
    $projectRoot = Resolve-MigrationRoot -Path $requestedProjectRoot

    $result = switch ($commandName) {
        'inspect' { Invoke-InspectMigration -ProjectRoot $projectRoot }
        'preflight' { Invoke-MigrationPreflight -ProjectRoot $projectRoot }
        'resolve-diagnostics' { Invoke-MigrationResolveDiagnostics -ProjectRoot $projectRoot -TargetMajor $TargetMajor }
        'discover' { Invoke-MigrationDiscover -ProjectRoot $projectRoot -TargetMajor $TargetMajor }
        'approve-runtime-install' { Invoke-ApproveMigrationRuntimeInstall -ProjectRoot $projectRoot -TargetMajor $TargetMajor -ProposalHash $ProposalHash -Confirmed:$Confirmed }
        'start' { Invoke-StartMigration -ProjectRoot $projectRoot -TargetMajor $TargetMajor }
        'status' { Invoke-MigrationStatus -ProjectRoot $projectRoot -RunId $RunId }
        'events' { Invoke-MigrationEvents -ProjectRoot $projectRoot -RunId $RunId }
        'diagnose' { Invoke-MigrationDiagnose -ProjectRoot $projectRoot -RunId $RunId }
        'retry-stage' { Invoke-MigrationRetryStage -ProjectRoot $projectRoot -RunId $RunId -Stage $Stage -Confirmed:$Confirmed }
        'abort' { Invoke-MigrationAbort -ProjectRoot $projectRoot -RunId $RunId -Confirmed:$Confirmed }
        'rollback' { Invoke-MigrationRollback -ProjectRoot $projectRoot -RunId $RunId -Confirmed:$Confirmed }
        'run' { Invoke-MigrationRun -ProjectRoot $projectRoot -RunId $RunId }
        'baseline-dependency-context' { Invoke-MigrationBaselineDependencyContext -ProjectRoot $projectRoot -RunId $RunId }
        'approve-baseline-dependencies' { Invoke-ApproveMigrationBaselineDependencies -ProjectRoot $projectRoot -RunId $RunId -ProposalHash $ProposalHash -Confirmed:$Confirmed }
        'skip-check' { Invoke-MigrationSkipCheck -ProjectRoot $projectRoot -RunId $RunId -CheckId $CheckId -Reason $Reason -Confirmed:$Confirmed }
        'skip-checks' { Invoke-MigrationSkipChecks -ProjectRoot $projectRoot -RunId $RunId -InputFile $InputFile -Confirmed:$Confirmed }
        'repair-context' { Invoke-MigrationRepairContext -ProjectRoot $projectRoot -RunId $RunId }
        'record-repair' { Invoke-MigrationRecordRepair -ProjectRoot $projectRoot -RunId $RunId -InputFile $InputFile }
        'documentation-context' { Invoke-DocumentationContext -ProjectRoot $projectRoot -RunId $RunId -Mode $Mode }
        'record-documentation' { Invoke-RecordDocumentation -ProjectRoot $projectRoot -RunId $RunId -Mode $Mode -InputFile $InputFile }
        default {
            Throw-MigrationError -Code 'unsupported_command' -Message "Unsupported v5 command: $Command" -Status blocked -Details ([PSCustomObject]@{ supported = @('inspect', 'preflight', 'resolve-diagnostics', 'discover', 'approve-runtime-install', 'start', 'status', 'events', 'diagnose', 'retry-stage', 'abort', 'rollback', 'baseline-dependency-context', 'approve-baseline-dependencies', 'skip-check', 'skip-checks', 'run', 'repair-context', 'record-repair', 'documentation-context', 'record-documentation') })
        }
    }

    Write-MigrationEnvelope -CommandName $commandName -Ok $result.ok -Status $result.status -Data $result.data -ErrorInfo $result.error
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
        code    = $code
        message = $exception.Message
        details = $details
    }
    Write-MigrationEnvelope -CommandName $commandName -Ok $false -Status $status -Data @{} -ErrorInfo $errorInfo
    exit (Get-MigrationExitCode -Status $status)
}
