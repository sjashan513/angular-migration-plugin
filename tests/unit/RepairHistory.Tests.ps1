#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../../scripts/modules'
foreach ($name in @('Core', 'State', 'Dependencies', 'Pipeline')) { Import-Module (Join-Path $modules "Migration.$name.psm1") -Force -DisableNameChecking }
$pipeline = Get-Module Migration.Pipeline
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('repair-history-unit-' + [guid]::NewGuid().ToString('N'))

function Assert-History {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name"
}

function ConvertTo-TestHistoryIoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path.Length -ge 248 -and $Path -match '^[A-Za-z]:\\') { return '\\?\' + $Path }
    return $Path
}

function New-HistoryFixture {
    param([string]$Name)
    $root = Join-Path $temporary $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $runId = 'angular-7-to-8-' + $Name.ToLowerInvariant() + '-a1b2c3d4'
    New-ActiveRunLock -ProjectRoot $root -RunId $runId
    return [PSCustomObject]@{
        root = $root
        runId = $runId
        fingerprint = 'sha256:' + ('a' * 64)
        otherFingerprint = 'sha256:' + ('b' * 64)
        checkpoint = '1' * 40
        manifest = '2' * 64
    }
}

function Add-HistoryEntry {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][ValidateSet('context-issued', 'submission-received', 'submission-rejected', 'submission-accepted', 'verification-failed', 'verification-passed', 'attempts-exhausted')][string]$Type,
        [int]$Attempt = 1,
        [string]$Fingerprint,
        $Data
    )
    if (-not $Fingerprint) { $Fingerprint = $Fixture.fingerprint }
    if (-not $Data) {
        $Data = switch ($Type) {
            'context-issued' { [PSCustomObject]@{ allowedPaths = @('src/**/*'); diagnosticSummary = 'Build failed.'; logFiles = @('logs/build.stderr.log') }; break }
            'submission-received' { [PSCustomObject]@{ submissionSha256 = ('3' * 64); declaredRootCause = 'The API changed.'; declaredChanges = @([PSCustomObject]@{ path = 'src/app.ts'; summary = 'Adapt the API call.' }) }; break }
            'submission-rejected' { [PSCustomObject]@{ code = 'repair_diff_mismatch'; message = 'The declared diff differs.'; changedPaths = @('src/app.ts'); scopeViolation = $false; rollbackStatus = 'passed' }; break }
            'submission-accepted' { [PSCustomObject]@{ report = '.angular-migration/runs/' + $Fixture.runId + '/repairs/report.json'; reportSha256 = ('4' * 64); commit = $Fixture.checkpoint; changedPaths = @('src/app.ts') }; break }
            'verification-failed' { [PSCustomObject]@{ checkId = 'build'; exitCode = 1; timedOut = $false; diagnosticSummary = 'The build still fails.'; logFiles = @('logs/build.stderr.log'); nextAttempt = 2; sameFingerprint = $true }; break }
            'verification-passed' { [PSCustomObject]@{ checkId = 'build'; exitCode = 0; timedOut = $false; resultLogFiles = @(); verifiedCommit = $Fixture.checkpoint }; break }
            'attempts-exhausted' { [PSCustomObject]@{ limit = 3; scope = 'fingerprint'; nextAction = 'human-review' }; break }
        }
    }
    & $pipeline {
        param($Root, $RunId, $FingerprintValue, $AttemptValue, $Checkpoint, $Manifest, $EntryType, $EntryData)
        Add-RepairHistoryEntry -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue -Stage validate -FailedCheck build -Attempt $AttemptValue -CheckpointCommit $Checkpoint -ManifestSha256 $Manifest -Type $EntryType -Data $EntryData
    } $Fixture.root $Fixture.runId $Fingerprint $Attempt $Fixture.checkpoint $Fixture.manifest $Type $Data
}

try {
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    $fixture = New-HistoryFixture 'append'
    $relative = & $pipeline { param($RunId, $FingerprintValue) Get-RepairHistoryRelativePath -RunId $RunId -Fingerprint $FingerprintValue } $fixture.runId $fixture.fingerprint
    Assert-History 'history path strips sha256 prefix' ($relative -ceq ('.angular-migration/runs/' + $fixture.runId + '/repair-history/' + ('a' * 64) + '/repair.jsonl'))
    Add-HistoryEntry -Fixture $fixture -Type context-issued | Out-Null
    $historyPath = & $pipeline { param($Root, $RunId, $FingerprintValue) (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue).path } $fixture.root $fixture.runId $fixture.fingerprint
    $firstLine = [IO.File]::ReadAllLines((ConvertTo-TestHistoryIoPath $historyPath))[0]
    Add-HistoryEntry -Fixture $fixture -Type submission-received | Out-Null
    $bytes = [IO.File]::ReadAllBytes((ConvertTo-TestHistoryIoPath $historyPath))
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    Assert-History 'first sequence starts at one' ((($text -split "`n")[0] | ConvertFrom-Json).sequence -eq 1)
    Assert-History 'append preserves the first line' ([IO.File]::ReadAllLines((ConvertTo-TestHistoryIoPath $historyPath))[0] -ceq $firstLine)
    Assert-History 'history is UTF-8 without BOM and newline terminated' ($bytes[0] -ne 0xef -and $text.EndsWith("`n"))
    $entry = [IO.File]::ReadAllLines((ConvertTo-TestHistoryIoPath $historyPath))[1] | ConvertFrom-Json
    $entryHash = & $pipeline { param($Value) Get-PipelineObjectHash -Value $Value -ExcludedProperty entrySha256 } $entry
    Assert-History 'entry hash matches canonical object' ($entry.entrySha256 -ceq $entryHash)
    $other = New-HistoryFixture 'other-run'
    Add-HistoryEntry -Fixture $other -Type context-issued | Out-Null
    $otherPath = & $pipeline { param($Root, $RunId, $FingerprintValue) (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue).path } $other.root $other.runId $other.fingerprint
    Assert-History 'run histories are isolated' ($historyPath -cne $otherPath)
    Add-HistoryEntry -Fixture $fixture -Type context-issued -Fingerprint $fixture.otherFingerprint | Out-Null
    $foreignPath = & $pipeline { param($Root, $RunId, $FingerprintValue) (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue).path } $fixture.root $fixture.runId $fixture.otherFingerprint
    Assert-History 'fingerprint histories are isolated' ($foreignPath -cne $historyPath)

    $redacted = & $pipeline { param($Root) Protect-RepairHistoryValue -ProjectRoot $Root -Value 'Authorization: Bearer fixture-secret https://user:password@example.invalid/path' } $fixture.root
    Assert-History 'history data redacts secrets and URLs' ($redacted -notmatch 'fixture-secret|password|example.invalid')
    $long = & $pipeline { param($Root) Protect-RepairHistoryValue -ProjectRoot $Root -MaxLength 12 -Value ('x' * 50) } $fixture.root
    Assert-History 'history data is length limited' ($long.Length -eq 12)

    $fixture = New-HistoryFixture 'attempts'
    Add-HistoryEntry -Fixture $fixture -Type context-issued | Out-Null
    Add-HistoryEntry -Fixture $fixture -Type submission-received | Out-Null
    Add-HistoryEntry -Fixture $fixture -Type submission-rejected | Out-Null
    Add-HistoryEntry -Fixture $fixture -Type context-issued -Attempt 2 | Out-Null
    Add-HistoryEntry -Fixture $fixture -Type submission-received -Attempt 2 | Out-Null
    Add-HistoryEntry -Fixture $fixture -Type submission-accepted -Attempt 2 | Out-Null
    $summary = & $pipeline { param($Root, $RunId, $FingerprintValue) Get-RepairAttemptSummary -History (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue) } $fixture.root $fixture.runId $fixture.fingerprint
    Assert-History 'rejected submissions consume one attempt' ($summary.previousAttempts -eq 1 -and $summary.nextAttempt -eq 2)
    Assert-History 'accepted submission remains pending verification' ($summary.pendingVerification -eq $true -and $summary.consumedAttempts -eq 1)
    Add-HistoryEntry -Fixture $fixture -Type verification-failed -Attempt 2 | Out-Null
    $summary = & $pipeline { param($Root, $RunId, $FingerprintValue) Get-RepairAttemptSummary -History (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue) } $fixture.root $fixture.runId $fixture.fingerprint
    Assert-History 'same-fingerprint verification failure consumes a cycle' ($summary.previousAttempts -eq 2 -and $summary.consumedAttempts -eq 2 -and $summary.nextAttempt -eq 3)

    $corruptPath = & $pipeline { param($Root, $RunId, $FingerprintValue) (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue).path } $fixture.root $fixture.runId $fixture.fingerprint
    $lines = [IO.File]::ReadAllLines((ConvertTo-TestHistoryIoPath $corruptPath))
    $corruptEntry = $lines[0] | ConvertFrom-Json
    $corruptEntry.sequence = 9
    $lines[0] = $corruptEntry | ConvertTo-Json -Depth 20 -Compress
    [IO.File]::WriteAllText((ConvertTo-TestHistoryIoPath $corruptPath), (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    $corrupt = $false
    try { & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue | Out-Null } $fixture.root $fixture.runId $fixture.fingerprint } catch { $corrupt = $_.Exception.Data['code'] -eq 'repair_history_corrupt' }
    Assert-History 'altered sequence fails closed' $corrupt

    $fixture = New-HistoryFixture 'invalid-lines'
    $path = & $pipeline { param($Root, $RunId, $FingerprintValue) Get-RepairHistoryPath -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $fixture.root $fixture.runId $fixture.fingerprint
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText((ConvertTo-TestHistoryIoPath $path), '{"schemaVersion":1}', (New-Object Text.UTF8Encoding($false)))
    $invalid = $false
    try { & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue | Out-Null } $fixture.root $fixture.runId $fixture.fingerprint } catch { $invalid = $_.Exception.Data['code'] -eq 'repair_history_corrupt' }
    Assert-History 'partial JSONL line fails closed' $invalid

    $fixture = New-HistoryFixture 'duplicate-entry'
    Add-HistoryEntry -Fixture $fixture -Type context-issued | Out-Null
    $path = & $pipeline { param($Root, $RunId, $FingerprintValue) (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue).path } $fixture.root $fixture.runId $fixture.fingerprint
    $duplicate = [IO.File]::ReadAllLines((ConvertTo-TestHistoryIoPath $path))[0]
    [IO.File]::AppendAllText((ConvertTo-TestHistoryIoPath $path), $duplicate + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $duplicateRejected = $false
    try { & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue | Out-Null } $fixture.root $fixture.runId $fixture.fingerprint } catch { $duplicateRejected = $_.Exception.Data['code'] -eq 'repair_history_corrupt' }
    Assert-History 'duplicate entry id fails closed' $duplicateRejected

    $fixture = New-HistoryFixture 'path-security'
    Add-HistoryEntry -Fixture $fixture -Type context-issued | Out-Null
    $canonicalPath = & $pipeline { param($Root, $RunId, $FingerprintValue) (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue).path } $fixture.root $fixture.runId $fixture.fingerprint
    $traversalRejected = $false
    try { & $pipeline { param($Root, $Path) Resolve-RepairPath -Root $Root -Path $Path | Out-Null } $fixture.root '.angular-migration/runs/../outside' } catch { $traversalRejected = $true }
    $caseRejected = $false
    $caseAlias = $canonicalPath -replace ('a' * 64), ('A' * 64)
    try { & $pipeline { param($Root, $Path) Resolve-RepairPath -Root $Root -Path $Path | Out-Null } $fixture.root $caseAlias } catch { $caseRejected = $true }
    $adsRejected = $false
    try { & $pipeline { param($Root, $Path) Resolve-RepairPath -Root $Root -Path $Path | Out-Null } $fixture.root ($canonicalPath + ':stream') } catch { $adsRejected = $true }
    Assert-History 'traversal, case aliases and alternate data streams are rejected' ($traversalRejected -and $caseRejected -and $adsRejected)
    $leasePath = $canonicalPath + '.lock'
    $lease = [IO.File]::Open((ConvertTo-TestHistoryIoPath $leasePath), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $leaseRejected = $false
    try { Add-HistoryEntry -Fixture $fixture -Type submission-received | Out-Null } catch { $leaseRejected = $_.Exception.Data['code'] -eq 'repair_history_write_failed' }
    finally { $lease.Dispose(); if ([IO.File]::Exists((ConvertTo-TestHistoryIoPath $leasePath))) { [IO.File]::Delete((ConvertTo-TestHistoryIoPath $leasePath)) } }
    Add-HistoryEntry -Fixture $fixture -Type submission-received | Out-Null
    $serializedHistory = & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue } $fixture.root $fixture.runId $fixture.fingerprint
    Assert-History 'history lease excludes overlapping append and preserves the next sequence' ($leaseRejected -and $serializedHistory.entryCount -eq 2 -and $serializedHistory.entries[1].sequence -eq 2)

    $fixture = New-HistoryFixture 'closed-schema'
    Add-HistoryEntry -Fixture $fixture -Type context-issued | Out-Null
    $closedSchemaPath = & $pipeline { param($Root, $RunId, $FingerprintValue) (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue).path } $fixture.root $fixture.runId $fixture.fingerprint
    $closedEntry = [IO.File]::ReadAllLines((ConvertTo-TestHistoryIoPath $closedSchemaPath))[0] | ConvertFrom-Json
    $closedEntry.data | Add-Member -NotePropertyName unexpected -NotePropertyValue 'not allowed'
    $closedEntry.entrySha256 = & $pipeline { param($Value) Get-PipelineObjectHash -Value $Value -ExcludedProperty entrySha256 } $closedEntry
    [IO.File]::WriteAllText((ConvertTo-TestHistoryIoPath $closedSchemaPath), (($closedEntry | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    $closedSchemaRejected = $false
    try { & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue | Out-Null } $fixture.root $fixture.runId $fixture.fingerprint } catch { $closedSchemaRejected = $_.Exception.Data['code'] -eq 'repair_history_corrupt' }
    Assert-History 'closed history schema rejects additional properties' $closedSchemaRejected

    $fixture = New-HistoryFixture 'terminal-order'
    Add-HistoryEntry -Fixture $fixture -Type context-issued | Out-Null
    Add-HistoryEntry -Fixture $fixture -Type submission-received | Out-Null
    Add-HistoryEntry -Fixture $fixture -Type submission-accepted | Out-Null
    Add-HistoryEntry -Fixture $fixture -Type verification-passed | Out-Null
    $terminalOrderRejected = $false
    try { Add-HistoryEntry -Fixture $fixture -Type context-issued -Attempt 2 | Out-Null } catch { $terminalOrderRejected = $_.Exception.Data['code'] -eq 'repair_history_corrupt' }
    Assert-History 'terminal history cannot receive another context' $terminalOrderRejected

    $fixture = New-HistoryFixture 'reparse-history'
    Add-HistoryEntry -Fixture $fixture -Type context-issued | Out-Null
    $reparsePath = & $pipeline { param($Root, $RunId, $FingerprintValue) (Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue).path } $fixture.root $fixture.runId $fixture.fingerprint
    $reparseDirectory = Split-Path -Parent $reparsePath
    $reparseTarget = Join-Path $temporary 'reparse-target'
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    [IO.File]::Copy((ConvertTo-TestHistoryIoPath $reparsePath), (Join-Path $reparseTarget 'repair.jsonl'), $true)
    if ([IO.File]::Exists((ConvertTo-TestHistoryIoPath $reparsePath))) { [IO.File]::Delete((ConvertTo-TestHistoryIoPath $reparsePath)) }
    if ([IO.Directory]::Exists((ConvertTo-TestHistoryIoPath $reparseDirectory))) { [IO.Directory]::Delete((ConvertTo-TestHistoryIoPath $reparseDirectory)) }
    $reparseRejected = $false
    try {
        New-Item -ItemType Junction -Path $reparseDirectory -Target $reparseTarget | Out-Null
        try { & $pipeline { param($Root, $RunId, $FingerprintValue) Read-RepairHistory -ProjectRoot $Root -RunId $RunId -Fingerprint $FingerprintValue | Out-Null } $fixture.root $fixture.runId $fixture.fingerprint }
        catch { $reparseRejected = $_.Exception.Data['code'] -eq 'repair_history_corrupt' }
    }
    finally {
        if ([IO.Directory]::Exists($reparseDirectory)) { [IO.Directory]::Delete($reparseDirectory) }
        if ([IO.Directory]::Exists($reparseTarget)) { [IO.Directory]::Delete($reparseTarget, $true) }
    }
    Assert-History 'reparse history path fails closed' $reparseRejected
}
finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}