#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../../scripts/modules'
foreach ($name in @('Core', 'State', 'Dependencies', 'Pipeline')) { Import-Module (Join-Path $modules "Migration.$name.psm1") -Force -DisableNameChecking }
$pipeline = Get-Module Migration.Pipeline
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('repair-cycle-' + [guid]::NewGuid().ToString('N'))

function Assert-Repair {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name"
}

function New-RepairFixture {
    param([string]$Name, [switch]$Preexisting)
    $root = Join-Path $temporary $Name
    New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".angular-migration/`n")
    [IO.File]::WriteAllText((Join-Path $root 'src/app.ts'), 'original')
    foreach ($file in @('package.json', 'package-lock.json', 'angular.json', 'user.txt')) { [IO.File]::WriteAllText((Join-Path $root $file), '{}') }
    & git -C $root init --quiet
    & git -C $root config user.name 'Repair Fixture'
    & git -C $root config user.email 'repair@example.invalid'
    & git -C $root add .
    & git -C $root commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture initialization failed.' }
    $head = (& git -C $root rev-parse HEAD).Trim()
    $runId = 'angular-7-to-8-fixture-a1b2c3d4'
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
    if ($Preexisting) {
        [IO.File]::WriteAllText((Join-Path $root 'user.txt'), 'user tracked change')
        [IO.File]::WriteAllText((Join-Path $root 'user-new.txt'), 'user untracked change')
    }
    New-Item -ItemType Directory -Path (Join-Path $paths.logs 'validate') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $paths.logs 'validate/build.stderr.log'), 'src/app.ts:1 TS2554')
    $context = & $pipeline {
        param($Root, $Paths)
        New-PipelineFailureContext -ProjectRoot $Root -RunPaths $Paths -Stage validate -CheckId build -Code validation_failed -Message 'Compilation failed.' -Output 'src/app.ts:1 TS2554' -ExitCode 1 -LogFiles @('logs/validate/build.stderr.log')
    } $root $paths
    $state = Read-MigrationRunState -ProjectRoot $root -RunId $runId
    $null = Move-MigrationState -ProjectRoot $root -RunId $runId -ExpectedStatus running -ExpectedStage validate -ExpectedRevision $state.stageRevision -NewStatus needs-repair -NewStage validate
    return [PSCustomObject]@{ root = $root; runId = $runId; paths = $paths; context = $context; head = $head }
}

function Submit-Repair {
    param($Fixture, [string[]]$ChangedPaths = @('src/app.ts'), [string]$RootCause = 'Removed API signature.', [scriptblock]$MutateReport, [string]$InputOverride)
    $context = (Read-MigrationRunState -ProjectRoot $Fixture.root -RunId $Fixture.runId).repair.context
    $report = [PSCustomObject]@{
        schemaVersion = 1; runId = $context.runId; fingerprint = $context.fingerprint; attempt = $context.attempt
        rootCause = $RootCause
        changes = @($ChangedPaths | ForEach-Object { [PSCustomObject]@{ path = $_; summary = 'Adapt signature.'; reason = 'TS2554.' } })
        evidence = @([PSCustomObject]@{ kind = 'diagnostic'; reference = $context.diagnostic.logFiles[0]; claim = 'TS2554 in original log.' })
        unresolvedWarnings = @()
    }
    if ($MutateReport) { & $MutateReport $report }
    Write-MigrationJsonAtomic -Value $report -Path (Join-Path $Fixture.root $context.submissionPath)
    $inputFile = if ($InputOverride) { $InputOverride } else { $context.submissionPath }
    return Invoke-MigrationRecordRepair -ProjectRoot $Fixture.root -RunId $Fixture.runId -InputFile $inputFile
}

try {
    $fixture = New-RepairFixture 'accepted'
    $first = Invoke-MigrationRepairContext -ProjectRoot $fixture.root -RunId $fixture.runId
    $stateHash = (Get-FileHash -LiteralPath $fixture.paths.state).Hash
    $second = Invoke-MigrationRepairContext -ProjectRoot $fixture.root -RunId $fixture.runId
    Assert-Repair 'context is read-only with stable fingerprint and attempt' ($first.data.fingerprint -ceq $second.data.fingerprint -and $second.data.attempt -eq 1 -and (Get-FileHash -LiteralPath $fixture.paths.state).Hash -ceq $stateHash)
    [IO.File]::WriteAllText((Join-Path $fixture.root 'src/app.ts'), 'repaired')
    $result = Submit-Repair $fixture
    Assert-Repair 'minimal repair accepted' $result.ok
    Assert-Repair 'fixed repair commit message' ((& git -C $fixture.root log -1 --format=%s) -ceq 'chore(angular-migration): repair build attempt 1')
    Assert-Repair 'acceptance does not claim verification' ($result.status -eq 'running' -and (Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId).stage -eq 'validate')
    $rejected = $false
    try { Invoke-MigrationRepairContext -ProjectRoot $fixture.root -RunId $fixture.runId | Out-Null } catch { $rejected = $true }
    Assert-Repair 'context rejected outside needs-repair' $rejected
    $fixture = New-RepairFixture 'concurrent-owner'
    $leasePath = Join-Path $fixture.paths.root 'record-repair.lock'
    $lease = [IO.File]::Open($leasePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $rejected = $false
        try { Submit-Repair $fixture | Out-Null } catch { $rejected = $_.Exception.Data['code'] -eq 'repair_process_not_owner' }
        Assert-Repair 'concurrent process cannot register' $rejected
    }
    finally { $lease.Dispose(); Remove-Item -LiteralPath $leasePath -Force }

    foreach ($mode in @('package', 'lockfile', 'manifest', 'runtime', 'rename', 'mode', 'traversal', 'case', 'ads', 'symlink-index', 'submodule')) {
        $fixture = New-RepairFixture $mode
        [IO.File]::WriteAllText((Join-Path $fixture.root 'src/app.ts'), 'attempt')
        $inputOverride = $null
        $changed = @('src/app.ts')
        switch ($mode) {
            'package' { [IO.File]::WriteAllText((Join-Path $fixture.root 'package.json'), '{"tampered":true}') }
            'lockfile' { [IO.File]::WriteAllText((Join-Path $fixture.root 'package-lock.json'), '{"tampered":true}') }
            'manifest' { [IO.File]::AppendAllText($fixture.paths.manifest, 'invalid') }
            'runtime' { [IO.File]::AppendAllText((Join-Path $fixture.root '.angular-migration/runtime/copilot-policy.ps1'), 'invalid') }
            'rename' { & git -C $fixture.root mv src/app.ts outside.ts; $changed = @('src/app.ts', 'outside.ts') }
            'mode' { & git -C $fixture.root update-index --chmod=+x src/app.ts }
            'traversal' { $inputOverride = $fixture.context.submissionPath.Replace('/inbox/', '/inbox/../inbox/') }
            'case' { $inputOverride = $fixture.context.submissionPath.Replace('repair.json', 'Repair.json') }
            'ads' { $inputOverride = $fixture.context.submissionPath + ':stream' }
            'symlink-index' {
                $blob = ('../package.json' | & git -C $fixture.root hash-object -w --stdin).Trim()
                & git -C $fixture.root update-index --add --cacheinfo "120000,$blob,src/link"
                [IO.File]::WriteAllText((Join-Path $fixture.root 'src/link'), '../package.json')
                $changed += 'src/link'
            }
            'submodule' {
                & git -C $fixture.root update-index --add --cacheinfo "160000,$($fixture.head),src/module"
                New-Item -ItemType Directory -Path (Join-Path $fixture.root 'src/module') | Out-Null
                $changed += 'src/module'
            }
        }
        $result = Submit-Repair $fixture -ChangedPaths $changed -InputOverride $inputOverride
        Assert-Repair "$mode tampering is a scope violation" ($result.status -eq 'failed' -and $result.error.code -eq 'repair_scope_violation')
        Assert-Repair "$mode never creates a repair commit" ((& git -C $fixture.root rev-parse HEAD).Trim() -ceq $fixture.head)
    }

    $fixture = New-RepairFixture 'omitted-untracked' -Preexisting
    [IO.File]::WriteAllText((Join-Path $fixture.root 'src/app.ts'), 'attempt')
    [IO.File]::WriteAllText((Join-Path $fixture.root 'src/new.ts'), 'inventoried attempt file')
    [IO.File]::WriteAllText((Join-Path $fixture.root 'src/uninventoried.ts'), 'preserve uncertain origin')
    Write-MigrationJsonAtomic -Value @('src/new.ts') -Path (Join-Path $fixture.paths.root 'inbox/edit-inventory.json')
    $result = Submit-Repair $fixture
    Assert-Repair 'omitted untracked diff rejected' ($result.status -eq 'needs-repair' -and $result.error.code -eq 'repair_rejected')
    Assert-Repair 'tracked attempt rolled back' ([IO.File]::ReadAllText((Join-Path $fixture.root 'src/app.ts')) -ceq 'original')
    Assert-Repair 'only inventoried new files removed' (-not (Test-Path -LiteralPath (Join-Path $fixture.root 'src/new.ts')) -and (Test-Path -LiteralPath (Join-Path $fixture.root 'src/uninventoried.ts')))
    Assert-Repair 'rollback preserves prior tracked and untracked user work' ([IO.File]::ReadAllText((Join-Path $fixture.root 'user.txt')) -ceq 'user tracked change' -and [IO.File]::ReadAllText((Join-Path $fixture.root 'user-new.txt')) -ceq 'user untracked change')

    foreach ($mode in @('extra-property', 'nested-property', 'empty-cause', 'empty-summary', 'empty-reason', 'empty-claim', 'stale-fingerprint', 'stale-attempt', 'wrong-run')) {
        $fixture = New-RepairFixture $mode
        [IO.File]::WriteAllText((Join-Path $fixture.root 'src/app.ts'), 'attempt')
        $mutation = {
            param($Report)
            switch ($mode) {
                'extra-property' { $Report | Add-Member finalStatus verified }
                'nested-property' { $Report.changes[0] | Add-Member command 'npm install' }
                'empty-cause' { $Report.rootCause = ' ' }
                'empty-summary' { $Report.changes[0].summary = ' ' }
                'empty-reason' { $Report.changes[0].reason = ' ' }
                'empty-claim' { $Report.evidence[0].claim = ' ' }
                'stale-fingerprint' { $Report.fingerprint = 'sha256:' + ('0' * 64) }
                'stale-attempt' { $Report.attempt = 2 }
                'wrong-run' { $Report.runId = 'other-run' }
            }
        }
        $result = Submit-Repair $fixture -MutateReport $mutation
        Assert-Repair "$mode rejected without accepting" ($result.status -eq 'needs-repair' -and $result.error.code -eq 'repair_rejected')
    }

    $fixture = New-RepairFixture 'three-rejections'
    foreach ($attempt in 1..3) {
        [IO.File]::WriteAllText((Join-Path $fixture.root 'src/app.ts'), "attempt $attempt")
        $result = Submit-Repair $fixture -RootCause ' '
        $state = Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId
        if ($attempt -lt 3) { Assert-Repair "rejection advances attempt $attempt" ($state.attempt -eq ($attempt + 1) -and $state.status -eq 'needs-repair') }
    }
    Assert-Repair 'third rejected attempt blocks' ($result.status -eq 'blocked' -and $result.error.code -eq 'repair_attempts_exhausted')

    $fixture = New-RepairFixture 'equivalent-failure'
    foreach ($attempt in 1..3) {
        [IO.File]::WriteAllText((Join-Path $fixture.root 'src/app.ts'), "attempt $attempt")
        $accepted = Submit-Repair $fixture
        Assert-Repair "equivalent repair $attempt accepted pending gate" $accepted.ok
        $exhausted = $false
        try {
            $context = & $pipeline {
                param($Root, $Paths)
                New-PipelineFailureContext -ProjectRoot $Root -RunPaths $Paths -Stage validate -CheckId build -Code validation_failed -Message 'Compilation failed.' -Output 'src/app.ts:1 TS2554' -ExitCode 1 -LogFiles @('logs/validate/build.stderr.log')
            } $fixture.root $fixture.paths
        }
        catch { $exhausted = $_.Exception.Data['code'] -eq 'repair_attempts_exhausted' }
        if ($attempt -lt 3) {
            Assert-Repair 'equivalent diagnostics advance budget despite new checkpoint fingerprint' ($context.attempt -eq ($attempt + 1))
            $state = Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId
            $null = Move-MigrationState -ProjectRoot $fixture.root -RunId $fixture.runId -ExpectedStatus running -ExpectedStage validate -ExpectedRevision $state.stageRevision -NewStatus needs-repair -NewStage validate
        }
        else { Assert-Repair 'third equivalent gate failure exhausts budget' $exhausted }
    }

    $fixture = New-RepairFixture 'five-total'
    foreach ($attempt in 1..5) {
        [IO.File]::WriteAllText((Join-Path $fixture.root 'src/app.ts'), "attempt $attempt")
        $accepted = Submit-Repair $fixture
        Assert-Repair "total repair $attempt accepted pending gate" $accepted.ok
        $exhausted = $false
        try {
            $context = & $pipeline {
                param($Root, $Paths, $Attempt)
                New-PipelineFailureContext -ProjectRoot $Root -RunPaths $Paths -Stage validate -CheckId build -Code validation_failed -Message 'Compilation failed.' -Output "src/app.ts:1 TS$Attempt" -ExitCode 1 -LogFiles @('logs/validate/build.stderr.log')
            } $fixture.root $fixture.paths $attempt
        }
        catch { $exhausted = $_.Exception.Data['code'] -eq 'repair_attempts_exhausted' }
        if ($attempt -lt 5) {
            Assert-Repair 'new diagnostic starts attempt one' ($context.attempt -eq 1)
            $state = Read-MigrationRunState -ProjectRoot $fixture.root -RunId $fixture.runId
            $null = Move-MigrationState -ProjectRoot $fixture.root -RunId $fixture.runId -ExpectedStatus running -ExpectedStage validate -ExpectedRevision $state.stageRevision -NewStatus needs-repair -NewStage validate
        }
        else { Assert-Repair 'fifth total repair prevents another intervention' $exhausted }
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}