#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../../scripts/modules'
Import-Module (Join-Path $modules 'Migration.State.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Core.psm1') -Force -DisableNameChecking

function New-StateFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('migration-state-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $runId = 'angular-7-to-8-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $runId
    New-Item -ItemType Directory -Path $paths.logs -Force | Out-Null
    New-ActiveRunLock -ProjectRoot $root -RunId $runId
    $state = New-MigrationRunState -RunId $runId -ProjectRoot $root -SourceMajor 7 -TargetMajor 8 -InitialCommit ('a' * 40) -InitialBranch 'main'
    Write-MigrationRunState -ProjectRoot $root -RunId $runId -State $state
    return [PSCustomObject]@{ root = $root; runId = $runId; paths = $paths }
}

function Assert-Code {
    param([scriptblock]$Action, [string]$ExpectedCode)
    try { & $Action; throw "Expected $ExpectedCode" }
    catch {
        if ($_.Exception.Data['code'] -ne $ExpectedCode) { throw }
    }
}

$fixture = New-StateFixture
try {
    $state = Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId
    if ($state.stageRevision -ne 0 -or $state.checkpointCommit -ne ('a' * 40) -or $state.completedOperations.Count -ne 0) { throw 'Initial state contract is incomplete' }
    $state.documentationStatus = 'researched'
    Assert-Code { Write-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId -State $state } 'invalid_run_state'

    $moved = Move-MigrationState -ProjectRoot $fixture.root -RunId $fixture.runId -ExpectedStatus 'running' -ExpectedStage 'baseline' -NewStatus 'running' -NewStage 'resolve' -ExpectedRevision 0
    if ($moved.stage -ne 'resolve' -or $moved.stageRevision -ne 1) { throw 'Allowed transition did not increment revision' }
    Assert-Code { Move-MigrationState -ProjectRoot $fixture.root -RunId $fixture.runId -ExpectedStatus 'running' -ExpectedStage 'resolve' -NewStatus 'running' -NewStage 'validate' -ExpectedRevision 0 } 'state_revision_conflict'
    Assert-Code { Move-MigrationState -ProjectRoot $fixture.root -RunId $fixture.runId -ExpectedStatus 'running' -ExpectedStage 'resolve' -NewStatus 'running' -NewStage 'validate' -ExpectedRevision 1 } 'invalid_state_transition'
    Write-Host 'PASS allowed transitions, stale revision and closed transition table'

    $allTransitions = @(
        @{ fromStatus = 'running'; fromStage = 'baseline'; toStatus = 'running'; toStage = 'resolve' },
        @{ fromStatus = 'blocked'; fromStage = 'baseline'; toStatus = 'running'; toStage = 'baseline' },
        @{ fromStatus = 'running'; fromStage = 'resolve'; toStatus = 'running'; toStage = 'update-angular' },
        @{ fromStatus = 'running'; fromStage = 'update-angular'; toStatus = 'needs-repair'; toStage = 'update-angular' },
        @{ fromStatus = 'needs-repair'; fromStage = 'update-angular'; toStatus = 'running'; toStage = 'update-angular' },
        @{ fromStatus = 'running'; fromStage = 'update-angular'; toStatus = 'running'; toStage = 'update-dependencies' },
        @{ fromStatus = 'running'; fromStage = 'update-dependencies'; toStatus = 'running'; toStage = 'install' },
        @{ fromStatus = 'running'; fromStage = 'install'; toStatus = 'running'; toStage = 'validate' },
        @{ fromStatus = 'running'; fromStage = 'validate'; toStatus = 'needs-repair'; toStage = 'validate' },
        @{ fromStatus = 'needs-repair'; fromStage = 'validate'; toStatus = 'running'; toStage = 'validate' },
        @{ fromStatus = 'running'; fromStage = 'validate'; toStatus = 'verified'; toStage = 'document' }
    )
    foreach ($transition in $allTransitions) {
        $case = New-StateFixture
        try {
            $value = Read-MigrationRunState -ProjectRoot $case.root -RunId $case.runId
            $value.status = $transition.fromStatus
            $value.stage = $transition.fromStage
            Write-MigrationRunState -ProjectRoot $case.root -RunId $case.runId -State $value
            $result = Move-MigrationState -ProjectRoot $case.root -RunId $case.runId -ExpectedStatus $transition.fromStatus -ExpectedStage $transition.fromStage -NewStatus $transition.toStatus -NewStage $transition.toStage -ExpectedRevision 0
            if ($result.status -ne $transition.toStatus -or $result.stage -ne $transition.toStage) { throw "Transition failed: $($transition.fromStatus)/$($transition.fromStage)" }
        }
        finally {
            Remove-Item -LiteralPath $case.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host 'PASS all technical transition families'

    $repairFixture = New-StateFixture
    try {
        $repairState = Read-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId
        $repairFingerprint = 'sha256:' + ('b' * 64)
        $repairState.status = 'needs-repair'
        $repairState.stage = 'validate'
        $repairState.manifestSha256 = 'c' * 64
        $repairState.repair = [PSCustomObject]@{
            context = [PSCustomObject]@{
                runId = $repairFixture.runId; status = 'needs-repair'; stage = 'validate'; failedCheck = 'build'
                fingerprint = $repairFingerprint; attempt = 1; checkpointCommit = 'a' * 40; historyCheckpointCommit = 'a' * 40
                manifestSha256 = $repairState.manifestSha256; allowedPaths = @('src/**/*'); forbiddenPaths = @('.angular-migration/**')
                diagnostic = [PSCustomObject]@{ summary = 'Build failed.'; exitCode = 1; logFiles = @(); relatedFiles = @(); warnings = @() }
                history = [PSCustomObject]@{ path = ".angular-migration/runs/$($repairFixture.runId)/repair-history/$('b' * 64)/repair.jsonl"; entryCount = 1; previousAttempts = 0; lastOutcome = $null }
                submissionPath = ".angular-migration/runs/$($repairFixture.runId)/inbox/repair.json"
            }
            diagnosticHash = 'd' * 64
            before = @()
            protected = @()
            accepted = $null
            facadePath = 'scripts/angular-migration.ps1'
        }
        Write-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId -State $repairState
        Write-Host 'PASS emitted active repair state satisfies strict nested contract'

        $repairState = Read-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId
        $repairState.repair.context.history.path = '.angular-migration/runs/other-run/repair-history/' + ('b' * 64) + '/repair.jsonl'
        Assert-Code { Write-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId -State $repairState } 'invalid_run_state'
        $repairState = Read-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId
        $repairState.repair.context = [PSCustomObject]@{ runId = $repairFixture.runId }
        Assert-Code { Write-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId -State $repairState } 'invalid_run_state'
        $repairState = Read-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId
        $repairState.repair.before = @([PSCustomObject]@{ path = 'src/app.ts'; untracked = $false })
        Assert-Code { Write-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId -State $repairState } 'invalid_run_state'
        $repairState = Read-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId
        $repairState.repair.accepted = [PSCustomObject]@{ fingerprint = 'sha256:' + ('e' * 64); attempt = 1; commit = 'a' * 40; report = ".angular-migration/runs/$($repairFixture.runId)/repairs/a.json"; reportSha256 = 'f' * 64 }
        Assert-Code { Write-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId -State $repairState } 'invalid_run_state'
        $repairState = Read-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId
        $repairState.repairs = @(
            [PSCustomObject]@{ fingerprint = $repairFingerprint; attempt = 1; commit = 'a' * 40; report = ".angular-migration/runs/$($repairFixture.runId)/repairs/a.json"; reportSha256 = 'f' * 64 },
            [PSCustomObject]@{ fingerprint = $repairFingerprint; attempt = 1; commit = 'a' * 40; report = ".angular-migration/runs/$($repairFixture.runId)/repairs/b.json"; reportSha256 = 'f' * 64 }
        )
        Assert-Code { Write-MigrationRunState -ProjectRoot $repairFixture.root -RunId $repairFixture.runId -State $repairState } 'invalid_run_state'
        Write-Host 'PASS malformed repair context, accepted summary and duplicate identity are rejected'
    }
    finally {
        Remove-Item -LiteralPath $repairFixture.root -Recurse -Force -ErrorAction SilentlyContinue
    }

    $state = Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId
    $state.targetMajor = 10
    Write-MigrationJsonAtomic -Value $state -Path $fixture.paths.state
    Assert-Code { Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId } 'invalid_run_state'
    $state.targetMajor = 8
    $state.runId = 'another-run'
    Write-MigrationJsonAtomic -Value $state -Path $fixture.paths.state
    Assert-Code { Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId } 'invalid_run_state'
    Write-Host 'PASS target and run identity tampering is rejected'

    $terminal = New-StateFixture
    try {
        $terminalState = Read-MigrationRunState -ProjectRoot $terminal.root -RunId $terminal.runId
        $terminalState.status = 'verified'
        $terminalState.stage = 'document'
        Write-MigrationRunState -ProjectRoot $terminal.root -RunId $terminal.runId -State $terminalState
        Assert-Code { Move-MigrationState -ProjectRoot $terminal.root -RunId $terminal.runId -ExpectedStatus 'verified' -ExpectedStage 'document' -NewStatus 'running' -NewStage 'validate' -ExpectedRevision 0 } 'invalid_state_transition'
        $terminalState.status = 'failed'
        $terminalState.stage = 'validate'
        Write-MigrationRunState -ProjectRoot $terminal.root -RunId $terminal.runId -State $terminalState
        Assert-Code { Move-MigrationState -ProjectRoot $terminal.root -RunId $terminal.runId -ExpectedStatus 'failed' -ExpectedStage 'validate' -NewStatus 'running' -NewStage 'validate' -ExpectedRevision 0 } 'invalid_state_transition'
        $terminalState.status = 'completed'
        $terminalState.stage = 'document'
        Write-MigrationRunState -ProjectRoot $terminal.root -RunId $terminal.runId -State $terminalState
        Assert-Code { Move-MigrationState -ProjectRoot $terminal.root -RunId $terminal.runId -ExpectedStatus 'completed' -ExpectedStage 'document' -NewStatus 'running' -NewStage 'document' -ExpectedRevision 0 } 'invalid_state_transition'
    }
    finally {
        Remove-Item -LiteralPath $terminal.root -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS verified, failed and completed are immutable'
}
finally {
    Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
}
