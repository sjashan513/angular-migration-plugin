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
    $historyRelative = ".angular-migration/runs/$runId/repair-history/$('a' * 64)/repair.jsonl"
    $historyPath = Join-Path $temporary $historyRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $historyPath) -Force | Out-Null
    [IO.File]::WriteAllText($historyPath, "{}" + [Environment]::NewLine)
    $context = [PSCustomObject]@{ runId = $runId; status = 'needs-repair'; fingerprint = ('sha256:' + ('a' * 64)); attempt = 1; allowedPaths = @('src/**/*'); forbiddenPaths = @('src/protected.ts', 'package.json'); history = [PSCustomObject]@{ path = $historyRelative; entryCount = 1; previousAttempts = 0; lastOutcome = $null }; submissionPath = ".angular-migration/runs/$runId/inbox/repair.json" }
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
    $result = Invoke-HookFixture @{ toolName = 'read'; toolArgs = @{ path = $historyRelative } }
    Assert-Hook 'implementer can read the active history only' ($result.json.permissionDecision -eq 'allow')
    $foreignHistory = ".angular-migration/runs/$runId/repair-history/$('b' * 64)/repair.jsonl"
    $result = Invoke-HookFixture @{ toolName = 'read'; toolArgs = @{ path = $foreignHistory } }
    Assert-Hook 'implementer cannot read a foreign fingerprint history' ($result.json.permissionDecision -eq 'deny')
    foreach ($toolName in @('edit', 'create', 'move', 'delete')) {
        $result = Invoke-HookFixture @{ toolName = $toolName; toolArgs = @{ path = $historyRelative; content = '{}' } }
        Assert-Hook "$toolName on repair history is denied" ($result.json.permissionDecision -eq 'deny')
    }
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
    $documenterManifestHash = 'a' * 64
    $documenterState = [PSCustomObject]@{
        schemaVersion = 5
        runId = $runId
        status = 'running'
        stage = 'validate'
        migrationStatus = 'running'
        targetMajor = 8
        manifestSha256 = $documenterManifestHash
        documentation = [PSCustomObject]@{ status = 'researching'; phase = 'research' }
        repairs = @()
    }
    Write-MigrationJsonAtomic -Value $documenterState -Path $statePath
    $researchInputPath = Join-Path $runRoot 'inbox/research.json'
    Remove-Item -LiteralPath $researchInputPath -Force -ErrorAction SilentlyContinue
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter' } subagentStop
    Assert-Hook 'documenter research cannot stop without research input' ($result.json.decision -eq 'block')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'execute'; toolArgs = @{ command = 'anything' } }
    Assert-Hook 'documenter execute is always denied' ($result.json.permissionDecision -eq 'deny')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'web'; toolArgs = @{ url = 'https://angular.dev/update-guide' } }
    Assert-Hook 'documenter can use a public HTTPS source' ($result.json.permissionDecision -eq 'allow')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'web'; toolArgs = @{ url = 'https://angular.dev/update-guide?token=secret' } }
    Assert-Hook 'documenter web query strings are denied' ($result.json.permissionDecision -eq 'deny')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'edit'; toolArgs = @{ path = ".angular-migration/runs/$runId/inbox/research.json"; file_text = '{}' } }
    Assert-Hook 'documenter research edit is limited to inbox' ($result.json.permissionDecision -eq 'allow')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'edit'; toolArgs = @{ path = 'docs/migration/v8/README.md'; file_text = '#' } }
    Assert-Hook 'documenter research cannot edit final docs' ($result.json.permissionDecision -eq 'deny')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'read'; toolArgs = @{ path = $historyRelative } }
    Assert-Hook 'documenter research cannot read repair history' ($result.json.permissionDecision -eq 'deny')
    Write-MigrationJsonAtomic -Value ([PSCustomObject]@{ schemaVersion = 1; runId = $runId; manifestSha256 = $documenterManifestHash; sources = @(@{ id = 'S-001' }); findings = @(@{ id = 'F-001' }); researchedAt = '2026-09-10T10:30:00.0000000Z' }) -Path $researchInputPath
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter' } subagentStop
    Assert-Hook 'valid research input allows documenter to stop' ($result.json.decision -eq 'allow')
    $documenterState.documentation.status = 'publishing'
    $documenterState.documentation.phase = 'publish'
    $documenterState.migrationStatus = 'verified'
    $documenterState.repairs = @([PSCustomObject]@{ fingerprint = ('sha256:' + ('a' * 64)) })
    Write-MigrationJsonAtomic -Value $documenterState -Path $statePath
    $documenterHistoryRelative = ".angular-migration/runs/$runId/repair-history/$('a' * 64)/repair.jsonl"
    $documenterHistoryPath = Join-Path $temporary $documenterHistoryRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $documenterHistoryPath) -Force | Out-Null
    [IO.File]::WriteAllText($documenterHistoryPath, "{}" + [Environment]::NewLine)
    $publishDirectory = Join-Path $temporary 'docs/migration/v8'
    New-Item -ItemType Directory -Path $publishDirectory -Force | Out-Null
    foreach ($name in @('README.md', 'changes.md', 'errors-and-repairs.md', 'warnings.md', 'new-concepts.md', 'dependencies.md', 'validation.md', 'sources.md')) {
        [IO.File]::WriteAllText((Join-Path $publishDirectory $name), '# fixture')
    }
    $documentationInputPath = Join-Path $runRoot 'inbox/documentation.json'
    Remove-Item -LiteralPath $documentationInputPath -Force -ErrorAction SilentlyContinue
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter' } subagentStop
    Assert-Hook 'documenter publish cannot stop without documentation input' ($result.json.decision -eq 'block')
    Write-MigrationJsonAtomic -Value ([PSCustomObject]@{ schemaVersion = 1; runId = $runId; mode = 'publish'; outputDirectory = 'docs/migration/v8'; manifestSha256 = $documenterManifestHash; researchSha256 = ('b' * 64); technicalVerifiedCommit = ('a' * 40) }) -Path $documentationInputPath
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'edit'; toolArgs = @{ path = 'docs/migration/v8/README.md'; file_text = '# updated' } }
    Assert-Hook 'documenter publish edit is limited to target docs' ($result.json.permissionDecision -eq 'allow')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'edit'; toolArgs = @{ path = $researchInputPath; file_text = '{}' } }
    Assert-Hook 'documenter publish cannot edit research artifact' ($result.json.permissionDecision -eq 'deny')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'read'; toolArgs = @{ path = $documenterHistoryRelative } }
    Assert-Hook 'documenter publish can read run repair history evidence' ($result.json.permissionDecision -eq 'allow')
    $foreignDocumenterHistoryRelative = ".angular-migration/runs/$runId/repair-history/$('b' * 64)/repair.jsonl"
    $foreignDocumenterHistoryPath = Join-Path $temporary $foreignDocumenterHistoryRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $foreignDocumenterHistoryPath) -Force | Out-Null
    [IO.File]::WriteAllText($foreignDocumenterHistoryPath, "{}" + [Environment]::NewLine)
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'read'; toolArgs = @{ path = $foreignDocumenterHistoryRelative } }
    Assert-Hook 'documenter publish cannot read a foreign repair history' ($result.json.permissionDecision -eq 'deny')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter'; toolName = 'read'; toolArgs = @{ path = ".angular-migration/runs/$runId/repair-history" } }
    Assert-Hook 'documenter publish cannot read the repair history container' ($result.json.permissionDecision -eq 'deny')
    $result = Invoke-HookFixture @{ agentName = 'migration-documenter' } subagentStop
    Assert-Hook 'valid publish input and files allow documenter to stop' ($result.json.decision -eq 'allow')
    $agentText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../agents/migration-documenter.agent.md') -Raw
    Assert-Hook 'documenter agent has no execute tool' ($agentText -match 'tools: \[read, search, web, edit\]' -and $agentText -notmatch 'tools:.*execute')
    [IO.File]::WriteAllText($statePath, '{')
    $result = Invoke-HookFixture @{ toolName = 'edit'; toolArgs = @{ path = 'src/app.ts' } }
    Assert-Hook 'internal preToolUse error exits 2 and denies' ($result.exitCode -eq 2 -and $result.json.permissionDecision -eq 'deny')
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }