#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/modules/Migration.Core.psm1') -Force -DisableNameChecking
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('repair-hook-' + [guid]::NewGuid().ToString('N'))
$shell = (Get-Process -Id $PID).Path
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../scripts/hooks/copilot-policy.ps1'))
$runId = 'angular-7-to-8-fixture-a1b2c3d4'

function Assert-Hook {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name"
}

function Invoke-HookFixture {
    param($Payload, [string]$Event = 'preToolUse')
    $result = Invoke-MigrationProcess -FilePath $shell -Arguments @('-NoProfile', '-File', $source, '-Event', $Event) -WorkingDirectory $temporary -StandardInput (ConvertTo-Json -InputObject $Payload -Depth 20 -Compress) -TimeoutSeconds 10
    $json = $result.stdout | ConvertFrom-Json
    Assert-Hook 'stdout is a single JSON object' ($json -is [PSCustomObject])
    return [PSCustomObject]@{ json = $json; exitCode = $result.exitCode }
}

try {
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    $hooks = Read-MigrationJson -Path (Join-Path $PSScriptRoot '../../hooks.json') -Required
    $absent = Invoke-MigrationProcess -FilePath $shell -Arguments @('-NoProfile', '-Command', $hooks.hooks.preToolUse[0].powershell) -WorkingDirectory $temporary -StandardInput '{}'
    Assert-Hook 'runtime absent wrapper returns empty object' ($absent.stdout.Trim() -ceq '{}' -and $absent.exitCode -eq 0)
    $runtimePath = Join-Path $temporary '.angular-migration/runtime/copilot-policy.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $runtimePath) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $runtimePath
    $inactive = Invoke-MigrationProcess -FilePath $shell -Arguments @('-NoProfile', '-Command', $hooks.hooks.preToolUse[0].powershell) -WorkingDirectory $temporary -StandardInput '{}'
    Assert-Hook 'runtime present without active run returns empty object' ($inactive.stdout.Trim() -ceq '{}' -and $inactive.exitCode -eq 0)
    $runRoot = Join-Path $temporary ".angular-migration/runs/$runId"
    New-Item -ItemType Directory -Path (Join-Path $runRoot 'inbox') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $temporary 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $temporary 'src/app.ts'), 'old')
    Write-MigrationJsonAtomic -Value ([PSCustomObject]@{ schemaVersion = 5; runId = $runId; processId = $PID }) -Path (Join-Path $temporary '.angular-migration/active.lock')
    $facade = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../scripts/angular-migration.ps1'))
    $context = [PSCustomObject]@{ runId = $runId; status = 'needs-repair'; fingerprint = ('sha256:' + ('a' * 64)); attempt = 1; allowedPaths = @('src/**/*'); forbiddenPaths = @('src/protected.ts', 'package.json'); submissionPath = ".angular-migration/runs/$runId/inbox/repair.json" }
    $state = [PSCustomObject]@{ schemaVersion = 5; runId = $runId; status = 'needs-repair'; runtimeSha256 = (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant(); repair = [PSCustomObject]@{ context = $context; facadePath = $facade; accepted = $null } }
    $statePath = Join-Path $runRoot 'state.json'
    Write-MigrationJsonAtomic -Value $state -Path $statePath
    $cases = Read-MigrationJson -Path (Join-Path $PSScriptRoot '../fixtures/hooks/cases.json') -Required
    foreach ($case in $cases) {
        $result = Invoke-HookFixture ([PSCustomObject]@{ toolName = $case.toolName; toolArgs = $case.toolArgs })
        Assert-Hook $case.name ($result.exitCode -eq 0 -and $result.json.permissionDecision -ceq $case.decision)
    }
    $result = Invoke-HookFixture @{ toolName = 'grep'; toolArgs = @{ path = 'src'; pattern = 'old' } }
    Assert-Hook 'search of safe source directory allowed' ($result.json.permissionDecision -eq 'allow')
    $external = Join-Path $temporary 'external'
    New-Item -ItemType Directory -Path $external | Out-Null
    [IO.File]::WriteAllText((Join-Path $external 'outside.ts'), 'protected')
    $junction = Join-Path $temporary 'src/linked'
    New-Item -ItemType Junction -Path $junction -Target $external | Out-Null
    try {
        $result = Invoke-HookFixture @{ toolName = 'edit'; toolArgs = @{ path = 'src/linked/outside.ts' } }
        Assert-Hook 'edit through junction denied' ($result.json.permissionDecision -eq 'deny')
        $result = Invoke-HookFixture @{ toolName = 'grep'; toolArgs = @{ path = 'src'; pattern = 'protected' } }
        Assert-Hook 'recursive search cannot follow junction' ($result.json.permissionDecision -eq 'deny')
        Assert-Hook 'external junction target is unchanged' ([IO.File]::ReadAllText((Join-Path $external 'outside.ts')) -ceq 'protected')
    }
    finally { [IO.Directory]::Delete($junction) }
    foreach ($command in @("& '$facade' repair-context -RunId $runId", "& '$facade' record-repair -RunId $runId -InputFile '$($context.submissionPath)'")) {
        $result = Invoke-HookFixture @{ toolName = 'powershell'; toolArgs = (@{ command = $command } | ConvertTo-Json -Compress) }
        Assert-Hook 'exact facade execution allowed with JSON-string toolArgs' ($result.json.permissionDecision -eq 'allow')
        foreach ($suffix in @('; git status', ' -TargetMajor 9', "`nng build")) {
            $result = Invoke-HookFixture @{ toolName = 'powershell'; toolArgs = @{ command = $command + $suffix } }
            Assert-Hook 'compound or extra arguments denied' ($result.json.permissionDecision -eq 'deny')
        }
    }
    $result = Invoke-HookFixture @{ toolName = 'create'; toolArgs = @{ path = $context.submissionPath; file_text = '{}' } }
    Assert-Hook 'contractual submission is writable' ($result.json.permissionDecision -eq 'allow')
    $result = Invoke-HookFixture @{ agentName = 'migration-implementer'; response = 'Everything works.' } subagentStop
    Assert-Hook 'missing registration blocks even with success claim' ($result.json.decision -eq 'block')
    $result = Invoke-HookFixture @{ agentName = 'other-agent' } subagentStop
    Assert-Hook 'other agents not blocked' (@($result.json.PSObject.Properties).Count -eq 0)
    $archiveRelative = ".angular-migration/runs/$runId/repairs/accepted.json"
    $archivePath = Join-Path $temporary $archiveRelative
    Write-MigrationJsonAtomic -Value @{ rootCause = 'fixture' } -Path $archivePath
    $state.repair.accepted = [PSCustomObject]@{ fingerprint = $context.fingerprint; attempt = 1; report = $archiveRelative; reportSha256 = (Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant(); commit = ('a' * 40) }
    $acceptedEvent = [PSCustomObject]@{ type = 'repair-accepted'; runId = $runId; data = $state.repair.accepted }
    [IO.File]::WriteAllText((Join-Path $runRoot 'events.jsonl'), ($acceptedEvent | ConvertTo-Json -Depth 20 -Compress))
    $state.status = 'running'
    Write-MigrationJsonAtomic -Value $state -Path $statePath
    $result = Invoke-HookFixture @{ agentName = 'migration-implementer' } subagentStop
    Assert-Hook 'registered repair allows stopping' ($result.json.decision -eq 'allow')
    [IO.File]::WriteAllText($archivePath, '{}')
    $result = Invoke-HookFixture @{ agentName = 'migration-implementer' } subagentStop
    Assert-Hook 'tampered accepted report blocks stopping' ($result.json.decision -eq 'block')
    [IO.File]::WriteAllText($statePath, '{')
    $result = Invoke-HookFixture @{ toolName = 'edit'; toolArgs = @{ path = 'src/app.ts' } }
    Assert-Hook 'internal preToolUse error exits 2 and denies' ($result.exitCode -eq 2 -and $result.json.permissionDecision -eq 'deny')
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }