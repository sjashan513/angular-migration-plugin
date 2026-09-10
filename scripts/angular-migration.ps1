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

    if (@('ready', 'running', 'verified', 'completed') -contains $Status) { return 0 }
    if (@('blocked', 'needs-repair') -contains $Status) { return 2 }
    return 1
}

$commandName = if ([string]::IsNullOrWhiteSpace($Command)) { 'unknown' } else { $Command.ToLowerInvariant() }
try {
    $moduleDirectory = Join-Path $PSScriptRoot 'modules'
    Import-Module (Join-Path $moduleDirectory 'Migration.Core.psm1') -DisableNameChecking
    Import-Module (Join-Path $moduleDirectory 'Migration.Pipeline.psm1') -DisableNameChecking
    $projectRoot = Resolve-MigrationRoot -Path (Get-Location).Path

    $result = switch ($commandName) {
        'inspect' { Invoke-InspectMigration -ProjectRoot $projectRoot }
        'start' { Invoke-StartMigration -ProjectRoot $projectRoot -TargetMajor $TargetMajor }
        'status' { Invoke-MigrationStatus -ProjectRoot $projectRoot -RunId $RunId }
        'run' { Invoke-MigrationRun -ProjectRoot $projectRoot -RunId $RunId }
        default {
            Throw-MigrationError -Code 'unsupported_command' -Message "Unsupported v5 command: $Command" -Status blocked -Details ([PSCustomObject]@{ supported = @('inspect', 'start', 'status', 'run') })
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
        code = $code
        message = $exception.Message
        details = $details
    }
    Write-MigrationEnvelope -CommandName $commandName -Ok $false -Status $status -Data @{} -ErrorInfo $errorInfo
    exit (Get-MigrationExitCode -Status $status)
}
