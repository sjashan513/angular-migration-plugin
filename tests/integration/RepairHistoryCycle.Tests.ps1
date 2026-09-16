#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../../scripts/modules'
foreach ($name in @('Core', 'State', 'Dependencies', 'Pipeline')) { Import-Module (Join-Path $modules "Migration.$name.psm1") -Force -DisableNameChecking }
$pipeline = Get-Module Migration.Pipeline
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('repair-history-cycle-' + [guid]::NewGuid().ToString('N'))

function Assert-HistoryCycle {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name" -ForegroundColor Green
}

function New-HistoryCycleFixture {
    param([string]$Name)
    $root = Join-Path $temporary $Name
    New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".angular-migration/`n")
    [IO.File]::WriteAllText((Join-Path $root 'src/app.ts'), 'original')
    foreach ($file in @('package.json', 'package-lock.json', 'angular.json')) { [IO.File]::WriteAllText((Join-Path $root $file), '{}') }
    & git -C $root init --quiet
    & git -C $root config user.name 'Repair history fixture'
    & git -C $root config user.email 'repair-history@example.invalid'
    & git -C $root add .
    & git -C $root commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture initialization failed.' }
    $head = (& git -C $root rev-parse HEAD).Trim().ToLowerInvariant()
    $runId = 'angular-7-to-8-' + $Name + '-a1b2c3d4'
    New-ActiveRunLock -ProjectRoot $root -RunId $runId
    $state = New-MigrationRunState -ProjectRoot $root -RunId $runId -SourceMajor 7 -TargetMajor 8 -InitialCommit $head -InitialBranch ((& git -C $root branch --show-current).Trim())
    $state.stage = 'validate'
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $runId
    $manifest = [PSCustomObject]@{ schemaVersion = 5; manifestType = 'migration'; runId = $runId; sourceMajor = 7; targetMajor = 8; project = [PSCustomObject]@{ root = $root }; manifestSha256 = $null }
    $manifest.manifestSha256 = Get-ResolvedManifestHash $manifest
    $state.manifestSha256 = $manifest.manifestSha256
    $runtime = Join-Path $root '.angular-migration/runtime/copilot-policy.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $runtime) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $modules '../hooks/copilot-policy.ps1') -Destination $runtime
    $state.runtimeSha256 = (Get-FileHash -LiteralPath $runtime).Hash.ToLowerInvariant()
    Write-MigrationRunState -ProjectRoot $root -RunId $runId -State $state
    Write-MigrationJsonAtomic -Value $manifest -Path $paths.manifest
    New-Item -ItemType Directory -Path (Join-Path $paths.logs 'validate') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $paths.logs 'validate/build.stderr.log'), 'src/app.ts:1 TS2554')
    [IO.File]::WriteAllText((Join-Path $paths.logs 'validate/build.stdout.log'), '')
    $context = & $pipeline {
        param($Root, $Paths)
        New-PipelineFailureContext -ProjectRoot $Root -RunPaths $Paths -Stage validate -CheckId build -Code validation_failed -Message 'Compilation failed.' -Output 'src/app.ts:1 TS2554' -ExitCode 1 -LogFiles @('logs/validate/build.stderr.log')
    } $root $paths
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $runId
    $null = Move-MigrationState -ProjectRoot $root -RunId $runId -ExpectedStatus running -ExpectedStage validate -ExpectedRevision $state.stageRevision -NewStatus needs-repair -NewStage validate
    return [PSCustomObject]@{ root = $root; runId = $runId; paths = $paths; context = $context; initialCommit = $head }
}

function Submit-HistoryRepair {
    param($Fixture, [string]$RootCause, [string]$Content)
    $context = (Read-MigrationRunState -ProjectRoot $Fixture.root -RunId $Fixture.runId).repair.context
    [IO.File]::WriteAllText((Join-Path $Fixture.root 'src/app.ts'), $Content)
    $report = [PSCustomObject]@{
        schemaVersion = 1; runId = $context.runId; fingerprint = $context.fingerprint; attempt = $context.attempt
        rootCause = $RootCause
        changes = @([PSCustomObject]@{ path = 'src/app.ts'; summary = 'Adapt the failing source.'; reason = 'The build diagnostic identifies the source.' })
        evidence = @([PSCustomObject]@{ kind = 'diagnostic'; reference = $context.diagnostic.logFiles[0]; claim = 'The build log identifies the source diagnostic.' })
        unresolvedWarnings = @()
    }
    Write-MigrationJsonAtomic -Value $report -Path (Join-Path $Fixture.root $context.submissionPath)
    Invoke-MigrationRecordRepair -ProjectRoot $Fixture.root -RunId $Fixture.runId -InputFile $context.submissionPath
}

function Invoke-HistoryFailure {
    param($Fixture, [string]$Output = 'src/app.ts:1 TS2554', [string]$DiagnosticSummary = 'Compilation failed.')
    [IO.File]::WriteAllText((Join-Path $Fixture.paths.logs 'validate/build.stderr.log'), $Output)
    $state = Read-MigrationRunState -ProjectRoot $Fixture.root -RunId $Fixture.runId
    $result = [PSCustomObject]@{ status = 'failed'; exitCode = 1; timedOut = $false; diagnosticSummary = $DiagnosticSummary; stdoutLog = 'logs/validate/build.stdout.log'; stderrLog = 'logs/validate/build.stderr.log' }
    & $pipeline {
        param($Root, $RunId, $State, $Result, $FailureOutput)
        Invoke-PipelineRepairVerification -ProjectRoot $Root -RunId $RunId -State $State -Stage validate -CheckId build -Result $Result -Output $FailureOutput
    } $Fixture.root $Fixture.runId $state $result $Output
}

try {
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    $fixture = New-HistoryCycleFixture 'two-attempts'
    $firstContext = Invoke-MigrationRepairContext -ProjectRoot $fixture.root -RunId $fixture.runId
    $sameContext = Invoke-MigrationRepairContext -ProjectRoot $fixture.root -RunId $fixture.runId
    Assert-HistoryCycle 'repair-context is idempotent before submission' ($firstContext.data.history.entryCount -eq 1 -and $sameContext.data.history.entryCount -eq 1 -and $firstContext.data.fingerprint -ceq $sameContext.data.fingerprint)
    $firstAccepted = Submit-HistoryRepair -Fixture $fixture -RootCause 'The first source adaptation was incomplete.' -Content 'first repair'
    Assert-HistoryCycle 'first repair is accepted but remains pending verification' ($firstAccepted.ok -and $firstAccepted.status -eq 'running')
    $verificationFailure = Invoke-HistoryFailure -Fixture $fixture
    Assert-HistoryCycle 'failed verification keeps the same history identity' ($verificationFailure.handled -and -not $verificationFailure.passed -and $verificationFailure.sameFingerprint)
    $recoveredAfterFailure = & $pipeline {
        param($Root, $RunId)
        Invoke-PipelineRepairHistoryRecovery -ProjectRoot $Root -RunId $RunId
    } $fixture.root $fixture.runId
    $secondContext = (Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId).repair.context
    Assert-HistoryCycle 'second context advances the same fingerprint attempt' ($secondContext.fingerprint -ceq $firstContext.data.fingerprint -and $secondContext.attempt -eq 2 -and $secondContext.history.previousAttempts -eq 1 -and $secondContext.history.lastOutcome -eq 'verification-failed')
    Assert-HistoryCycle 'persisted verification failure recovery enters needs-repair' ($recoveredAfterFailure.status -eq 'needs-repair' -and $recoveredAfterFailure.repair.context.attempt -eq 2)
    $secondAccepted = Submit-HistoryRepair -Fixture $fixture -RootCause 'The remaining evidence shows the API call needs a different adaptation.' -Content 'second repair'
    Assert-HistoryCycle 'second repair is accepted' ($secondAccepted.ok -and $secondAccepted.status -eq 'running')
    $state = Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId
    $verificationPassed = [PSCustomObject]@{ status = 'passed'; exitCode = 0; timedOut = $false; diagnosticSummary = ''; stdoutLog = 'logs/validate/build.stdout.log'; stderrLog = 'logs/validate/build.stderr.log' }
    $pass = & $pipeline {
        param($Root, $RunId, $State, $Result)
        Invoke-PipelineRepairVerification -ProjectRoot $Root -RunId $RunId -State $State -Stage validate -CheckId build -Result $Result -Output ''
    } $fixture.root $fixture.runId $state $verificationPassed
    Assert-HistoryCycle 'only verification-passed closes the active context' ($pass.passed -and (Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId).repair -eq $null)
    $history = & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $fixture.root $fixture.runId $firstContext.data.fingerprint
    $types = @($history.entries | ForEach-Object { [string]$_.type }) -join '|'
    Assert-HistoryCycle 'one history contains both accepted attempts and outcomes' ($types -eq 'context-issued|submission-received|submission-accepted|verification-failed|context-issued|submission-received|submission-accepted|verification-passed' -and $history.entryCount -eq 8)
    Assert-HistoryCycle 'history checkpoint stays stable across accepted commits' (@($history.entries | Select-Object -ExpandProperty checkpointCommit -Unique).Count -eq 1)
    $state = Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId
    Assert-HistoryCycle 'state retains accepted summaries but only consumed cycles' (@($state.repairs).Count -eq 2 -and $state.repairTotal -eq 1)
    $runHistoryRoot = Join-Path $fixture.paths.root 'repair-history'
    $historyDirectories = @(Get-ChildItem -LiteralPath $runHistoryRoot -Directory -Force)
    Assert-HistoryCycle 'same fingerprint does not create a foreign history directory' ($historyDirectories.Count -eq 1 -and $historyDirectories[0].Name -eq $firstContext.data.fingerprint.Substring(7))
    $events = @(Get-Content -LiteralPath $fixture.paths.events -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-HistoryCycle 'global events contain milestones, not local rejection detail' (@($events | Where-Object type -eq 'repair-required').Count -eq 2 -and @($events | Where-Object type -eq 'repair-accepted').Count -eq 2 -and @($events | Where-Object type -eq 'submission-rejected').Count -eq 0)

    $acceptedRecoveryFixture = New-HistoryCycleFixture 'accepted-recovery'
    $acceptedRecoveryContext = Invoke-MigrationRepairContext -ProjectRoot $acceptedRecoveryFixture.root -RunId $acceptedRecoveryFixture.runId
    $staleAcceptedState = Read-MigrationRunState -ProjectRoot $acceptedRecoveryFixture.root -RunId $acceptedRecoveryFixture.runId
    $acceptedRecoverySubmission = Submit-HistoryRepair -Fixture $acceptedRecoveryFixture -RootCause 'Recover an accepted repair after state persistence was interrupted.' -Content 'accepted recovery'
    Write-MigrationRunState -ProjectRoot $acceptedRecoveryFixture.root -RunId $acceptedRecoveryFixture.runId -State $staleAcceptedState
    $recoveredAccepted = & $pipeline {
        param($Root, $RunId)
        Invoke-PipelineRepairHistoryRecovery -ProjectRoot $Root -RunId $RunId
    } $acceptedRecoveryFixture.root $acceptedRecoveryFixture.runId
    $recoveredAcceptedState = Read-MigrationRunState -ProjectRoot $acceptedRecoveryFixture.root -RunId $acceptedRecoveryFixture.runId
    $recoveredAcceptedHistory = & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $acceptedRecoveryFixture.root $acceptedRecoveryFixture.runId $acceptedRecoveryContext.data.fingerprint
    Assert-HistoryCycle 'accepted history reconciles a stale state after interruption' ($acceptedRecoverySubmission.ok -and $recoveredAccepted.status -eq 'running' -and $recoveredAcceptedState.repair.accepted.commit -ceq $acceptedRecoverySubmission.data.repair.commit -and @($recoveredAcceptedHistory.entries | Where-Object type -eq 'submission-accepted').Count -eq 1)
    $duplicateReportPath = Join-Path $acceptedRecoveryFixture.root ($recoveredAcceptedState.repairs[0].report -replace '/', '\')
    $duplicateInputPath = Join-Path $acceptedRecoveryFixture.root ($recoveredAcceptedState.repair.context.submissionPath -replace '/', '\')
    $duplicateReportIoPath = if ($duplicateReportPath.Length -ge 248 -and $duplicateReportPath -match '^[A-Za-z]:\\') { '\\?\' + $duplicateReportPath } else { $duplicateReportPath }
    $duplicateInputIoPath = if ($duplicateInputPath.Length -ge 248 -and $duplicateInputPath -match '^[A-Za-z]:\\') { '\\?\' + $duplicateInputPath } else { $duplicateInputPath }
    [IO.File]::Copy($duplicateReportIoPath, $duplicateInputIoPath, $true)
    $duplicateState = Read-MigrationRunState -ProjectRoot $acceptedRecoveryFixture.root -RunId $acceptedRecoveryFixture.runId
    $duplicateState.status = 'needs-repair'
    Write-MigrationRunState -ProjectRoot $acceptedRecoveryFixture.root -RunId $acceptedRecoveryFixture.runId -State $duplicateState
    $duplicateSubmission = Invoke-MigrationRecordRepair -ProjectRoot $acceptedRecoveryFixture.root -RunId $acceptedRecoveryFixture.runId -InputFile $duplicateState.repair.context.submissionPath
    $duplicateHistory = & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $acceptedRecoveryFixture.root $acceptedRecoveryFixture.runId $acceptedRecoveryContext.data.fingerprint
    $duplicateRunningSubmission = Invoke-MigrationRecordRepair -ProjectRoot $acceptedRecoveryFixture.root -RunId $acceptedRecoveryFixture.runId -InputFile $duplicateState.repair.context.submissionPath
    $duplicateRunningHistory = & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $acceptedRecoveryFixture.root $acceptedRecoveryFixture.runId $acceptedRecoveryContext.data.fingerprint
    Assert-HistoryCycle 'duplicate accepted submission recovers without duplicate history' ($duplicateSubmission.ok -and $duplicateSubmission.status -eq 'running' -and $duplicateRunningSubmission.ok -and $duplicateRunningSubmission.status -eq 'running' -and @($duplicateRunningHistory.entries | Where-Object type -eq 'submission-accepted').Count -eq 1 -and $duplicateRunningHistory.entryCount -eq $recoveredAcceptedHistory.entryCount)

    $commitOnlyFixture = New-HistoryCycleFixture 'commit-before-history'
    $commitOnlyContext = Invoke-MigrationRepairContext -ProjectRoot $commitOnlyFixture.root -RunId $commitOnlyFixture.runId
    $staleCommitOnlyState = Read-MigrationRunState -ProjectRoot $commitOnlyFixture.root -RunId $commitOnlyFixture.runId
    $null = Submit-HistoryRepair -Fixture $commitOnlyFixture -RootCause 'Simulate a commit that precedes its accepted history entry.' -Content 'commit without history'
    $commitOnlyHistory = & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $commitOnlyFixture.root $commitOnlyFixture.runId $commitOnlyContext.data.fingerprint
    $commitOnlyHistoryIoPath = if ($commitOnlyHistory.path.Length -ge 248 -and $commitOnlyHistory.path -match '^[A-Za-z]:\\') { '\\?\' + $commitOnlyHistory.path } else { $commitOnlyHistory.path }
    $historyLines = [IO.File]::ReadAllLines($commitOnlyHistoryIoPath)
    $historyLines = @($historyLines[0..($historyLines.Count - 2)])
    [IO.File]::WriteAllText($commitOnlyHistoryIoPath, (($historyLines -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    Write-MigrationRunState -ProjectRoot $commitOnlyFixture.root -RunId $commitOnlyFixture.runId -State $staleCommitOnlyState
    $commitOnlyError = $null
    try {
        & $pipeline { param($Root, $RunId) Invoke-PipelineRepairHistoryRecovery -ProjectRoot $Root -RunId $RunId } $commitOnlyFixture.root $commitOnlyFixture.runId | Out-Null
    }
    catch { $commitOnlyError = $_.Exception.Data['code'] }
    Assert-HistoryCycle 'commit without accepted history fails closed' ($commitOnlyError -ceq 'repair_history_state_mismatch')

    $transitionFixture = New-HistoryCycleFixture 'context-transition-recovery'
    $null = Invoke-MigrationRepairContext -ProjectRoot $transitionFixture.root -RunId $transitionFixture.runId
    $interruptedTransitionState = Read-MigrationRunState -ProjectRoot $transitionFixture.root -RunId $transitionFixture.runId
    $interruptedTransitionState.status = 'running'
    Write-MigrationRunState -ProjectRoot $transitionFixture.root -RunId $transitionFixture.runId -State $interruptedTransitionState
    $recoveredTransition = & $pipeline { param($Root, $RunId) Invoke-PipelineRepairHistoryRecovery -ProjectRoot $Root -RunId $RunId } $transitionFixture.root $transitionFixture.runId
    $transitionHistory = & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $transitionFixture.root $transitionFixture.runId $interruptedTransitionState.repair.context.fingerprint
    Assert-HistoryCycle 'interrupted context transition returns to needs-repair' ($recoveredTransition.status -eq 'needs-repair' -and @($transitionHistory.entries | Where-Object type -eq 'context-issued').Count -eq 1)

    $passedRecoveryFixture = New-HistoryCycleFixture 'passed-recovery'
    $passedRecoveryContext = Invoke-MigrationRepairContext -ProjectRoot $passedRecoveryFixture.root -RunId $passedRecoveryFixture.runId
    $passedAccepted = Submit-HistoryRepair -Fixture $passedRecoveryFixture -RootCause 'Recover a persisted verification pass.' -Content 'passed recovery'
    $passedState = Read-MigrationRunState -ProjectRoot $passedRecoveryFixture.root -RunId $passedRecoveryFixture.runId
    & $pipeline {
        param($Root, $RunId, $Context, $State, $Accepted)
        Add-RepairHistoryEntry -ProjectRoot $Root -RunId $RunId -Fingerprint $Context.fingerprint -Stage $Context.stage -FailedCheck $Context.failedCheck -Attempt $Context.attempt -CheckpointCommit $Context.historyCheckpointCommit -ManifestSha256 $Context.manifestSha256 -Type 'verification-passed' -Data ([PSCustomObject]@{ checkId = $Context.failedCheck; exitCode = 0; timedOut = $false; resultLogFiles = @(); verifiedCommit = $Accepted.data.repair.commit }) | Out-Null
    } $passedRecoveryFixture.root $passedRecoveryFixture.runId $passedRecoveryContext.data $passedState $passedAccepted
    $passedState.status = 'needs-repair'
    Write-MigrationRunState -ProjectRoot $passedRecoveryFixture.root -RunId $passedRecoveryFixture.runId -State $passedState
    $recoveredPass = & $pipeline { param($Root, $RunId) Invoke-PipelineRepairHistoryRecovery -ProjectRoot $Root -RunId $RunId } $passedRecoveryFixture.root $passedRecoveryFixture.runId
    Assert-HistoryCycle 'persisted verification pass closes and resumes stale repair state' ($recoveredPass.status -eq 'running' -and $recoveredPass.repair -eq $null)

    $changedFingerprintFixture = New-HistoryCycleFixture 'changed-fingerprint-recovery'
    $changedFingerprintContext = Invoke-MigrationRepairContext -ProjectRoot $changedFingerprintFixture.root -RunId $changedFingerprintFixture.runId
    $null = Submit-HistoryRepair -Fixture $changedFingerprintFixture -RootCause 'The first repair exposed a different diagnostic.' -Content 'changed fingerprint repair'
    $changedFailure = Invoke-HistoryFailure -Fixture $changedFingerprintFixture -Output 'src/app.ts:2 TS2304' -DiagnosticSummary 'A different compilation failure.'
    $recoveredChanged = & $pipeline { param($Root, $RunId) Invoke-PipelineRepairHistoryRecovery -ProjectRoot $Root -RunId $RunId } $changedFingerprintFixture.root $changedFingerprintFixture.runId
    $changedState = Read-MigrationRunState -ProjectRoot $changedFingerprintFixture.root -RunId $changedFingerprintFixture.runId
    $changedHistoryRoot = Join-Path $changedFingerprintFixture.paths.root 'repair-history'
    Assert-HistoryCycle 'changed verification fingerprint gets a new history' ($changedFailure.handled -and -not $changedFailure.sameFingerprint -and $recoveredChanged.status -eq 'needs-repair' -and $changedState.repair.context.fingerprint -cne $changedFingerprintContext.data.fingerprint -and @(Get-ChildItem -LiteralPath $changedHistoryRoot -Directory -Force).Count -eq 2 -and $changedState.repair.context.attempt -eq 1)

    $rejectionFixture = New-HistoryCycleFixture 'rejection'
    $rejectionContext = Invoke-MigrationRepairContext -ProjectRoot $rejectionFixture.root -RunId $rejectionFixture.runId
    $rejected = Submit-HistoryRepair -Fixture $rejectionFixture -RootCause ' ' -Content 'rejected repair'
    $rejectionHistory = & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $rejectionFixture.root $rejectionFixture.runId $rejectionContext.data.fingerprint
    Assert-HistoryCycle 'rejection is local history and consumes one attempt' ($rejected.status -eq 'needs-repair' -and @($rejectionHistory.entries | Where-Object type -eq 'submission-rejected').Count -eq 1 -and (Read-MigrationRunState -ProjectRoot $rejectionFixture.root -RunId $rejectionFixture.runId).attempt -eq 2)
    $null = Submit-HistoryRepair -Fixture $rejectionFixture -RootCause ' ' -Content 'rejected repair attempt two'
    $thirdRejected = Submit-HistoryRepair -Fixture $rejectionFixture -RootCause ' ' -Content 'rejected repair attempt three'
    $rejectionHistory = & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $rejectionFixture.root $rejectionFixture.runId $rejectionContext.data.fingerprint
    Assert-HistoryCycle 'fourth same-fingerprint attempt is blocked' ($thirdRejected.status -eq 'blocked' -and @($rejectionHistory.entries | Where-Object type -eq 'attempts-exhausted').Count -eq 1 -and @($rejectionHistory.entries | Where-Object type -eq 'submission-rejected').Count -eq 3)
    $rejectionEvents = @(Get-Content -LiteralPath $rejectionFixture.paths.events -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-HistoryCycle 'rejection does not become a global event' (@($rejectionEvents | Where-Object type -eq 'submission-rejected').Count -eq 0)

    $globalLimitFixture = New-HistoryCycleFixture 'global-limit'
    $globalFingerprints = @(
        'sha256:' + (('a' * 64) -join '')
        'sha256:' + (('b' * 64) -join '')
        'sha256:' + (('c' * 64) -join '')
    )
    $globalLimitState = Read-MigrationRunState -ProjectRoot $globalLimitFixture.root -RunId $globalLimitFixture.runId
    foreach ($fingerprint in $globalFingerprints) {
        $fingerprintAttempts = if ($fingerprint -ceq $globalFingerprints[0]) { 3 } else { 1 }
        for ($attempt = 1; $attempt -le $fingerprintAttempts; $attempt++) {
            & $pipeline {
                param($Root, $RunId, $FingerprintValue, $AttemptValue, $Checkpoint, $Manifest)
                Add-RepairHistoryEntry -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue -Stage validate -FailedCheck build -Attempt $AttemptValue -CheckpointCommit $Checkpoint -ManifestSha256 $Manifest -Type 'context-issued' -Data ([PSCustomObject]@{ allowedPaths = @('src/**/*'); diagnosticSummary = 'Build failed.'; logFiles = @('logs/validate/build.stderr.log') }) | Out-Null
                Add-RepairHistoryEntry -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue -Stage validate -FailedCheck build -Attempt $AttemptValue -CheckpointCommit $Checkpoint -ManifestSha256 $Manifest -Type 'submission-received' -Data ([PSCustomObject]@{ submissionSha256 = ('3' * 64); declaredRootCause = 'The API changed.'; declaredChanges = @([PSCustomObject]@{ path = 'src/app.ts'; summary = 'Adapt the API call.' }) }) | Out-Null
                Add-RepairHistoryEntry -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue -Stage validate -FailedCheck build -Attempt $AttemptValue -CheckpointCommit $Checkpoint -ManifestSha256 $Manifest -Type 'submission-rejected' -Data ([PSCustomObject]@{ code = 'repair_diff_mismatch'; message = 'The declared diff differs.'; changedPaths = @('src/app.ts'); scopeViolation = $false; rollbackStatus = 'passed' }) | Out-Null
            } $globalLimitFixture.root $globalLimitFixture.runId $fingerprint $attempt $globalLimitFixture.initialCommit $globalLimitState.manifestSha256
        }
    }
    $globalLimitState = Read-MigrationRunState -ProjectRoot $globalLimitFixture.root -RunId $globalLimitFixture.runId
    $globalLimitState.repairTotal = 5
    Write-MigrationRunState -ProjectRoot $globalLimitFixture.root -RunId $globalLimitFixture.runId -State $globalLimitState
    $globalLimitError = $null
    try {
        & $pipeline {
            param($Root, $Paths)
            New-PipelineFailureContext -ProjectRoot $Root -RunPaths $Paths -Stage validate -CheckId build -Code validation_failed -Message 'A sixth repair is not allowed.' -Output 'src/app.ts:999 TS9999' -ExitCode 1 -LogFiles @('logs/validate/build.stderr.log') | Out-Null
        } $globalLimitFixture.root $globalLimitFixture.paths
    }
    catch { $globalLimitError = $_.Exception.Data['code'] }
    Assert-HistoryCycle 'sixth run-wide repair is blocked' ($globalLimitError -ceq 'repair_attempts_exhausted')

    $mismatchFixture = New-HistoryCycleFixture 'mirror-mismatch'
    $mismatchState = Read-MigrationRunState -ProjectRoot $mismatchFixture.root -RunId $mismatchFixture.runId
    $mismatchState.repairTotal = 1
    Write-MigrationRunState -ProjectRoot $mismatchFixture.root -RunId $mismatchFixture.runId -State $mismatchState
    $mismatch = $false
    try { Invoke-MigrationRepairContext -ProjectRoot $mismatchFixture.root -RunId $mismatchFixture.runId | Out-Null } catch { $mismatch = $_.Exception.Data['code'] -eq 'repair_history_state_mismatch' }
    Assert-HistoryCycle 'state/history mirror mismatch fails closed' $mismatch
    Write-Host 'Repair history cycle integration OK' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}