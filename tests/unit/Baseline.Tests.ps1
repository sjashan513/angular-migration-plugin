#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../../scripts/modules'
Import-Module (Join-Path $modules 'Migration.Pipeline.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Project.psm1') -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.State.psm1') -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Core.psm1') -DisableNameChecking
$fixtures = Join-Path $PSScriptRoot '../fixtures'
$tools = (Resolve-Path (Join-Path $fixtures 'tools')).Path
$originalPath = $env:PATH
$root = Join-Path ([IO.Path]::GetTempPath()) ('migration-baseline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $env:PATH = $tools + [IO.Path]::PathSeparator + $originalPath
    Copy-Item (Join-Path $fixtures 'projects/ready/*') $root
    [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".angular-migration/`n.fixture-*`n")
    & git -C $root init --quiet
    & git -C $root config user.name 'Baseline Fixture'
    & git -C $root config user.email 'baseline@example.invalid'
    & git -C $root add .
    & git -C $root commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Git fixture setup failed' }
    $projectModule = Get-Module Migration.Project
    & $projectModule {
        param($ToolDirectory)
        $script:FixtureTools = $ToolDirectory
        function script:Find-MigrationExecutable {
            param($Names)
            if ($Names[0] -eq 'node.exe') { return Join-Path $script:FixtureTools 'node.cmd' }
            if ($Names[0] -eq 'npm.cmd') { return Join-Path $script:FixtureTools 'npm.cmd' }
            return (Get-Command $Names[0] -ErrorAction Stop).Source
        }
    } $tools
    $run = Invoke-StartMigration -ProjectRoot $root -TargetMajor 8
    $runId = $run.data.runId
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $runId
    $logDirectory = Join-Path $paths.logs 'baseline'
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    if ($manifest.angular.declaredCoreSpec -ne '^7.2.0' -or $manifest.angular.resolvedCoreVersion -ne '7.2.16' -or $manifest.project.lockfileVersion -ne 1 -or -not $manifest.project.toolchain.npm.executable) { throw 'Manifest lost inspection evidence' }
    $schema = Read-MigrationJson -Path (Join-Path $PSScriptRoot '../../schemas/manifest.schema.json') -Required
    if ($schema.properties.checks.items.type -ne 'object' -or $schema.properties.checks.items.required -notcontains 'timeoutSeconds') { throw 'Schema does not define structured checks' }
    foreach ($check in $manifest.checks) {
        foreach ($required in $schema.properties.checks.items.required) {
            if (-not $check.PSObject.Properties[$required]) { throw "Missing check schema property: $required" }
        }
    }
    $packageHash = (Get-FileHash (Join-Path $root 'package.json')).Hash
    $lockHash = (Get-FileHash (Join-Path $root 'package-lock.json')).Hash
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'passed') { throw "Baseline should pass: $($result | ConvertTo-Json -Depth 10 -Compress)" }
    $trace = @(Get-Content (Join-Path $root '.fixture-trace'))
    if (($trace -join ',') -ne 'install,dependency-tree,typecheck,lint,unit-test,build,e2e') { throw 'Execution order mismatch' }
    $events = @(Get-Content $paths.events | ForEach-Object { $_ | ConvertFrom-Json })
    if (@($events | Where-Object type -eq 'check-started').Count -ne 7 -or @($events | Where-Object type -eq 'check-finished').Count -ne 7 -or $events[-1].type -ne 'baseline-completed') { throw 'Missing baseline events' }
    if (@(Get-ChildItem $logDirectory -File).Count -ne 14) { throw 'Every execution must have two logs' }
    if (($result | ConvertTo-Json -Depth 10) -match 'fixture stdout|fixture stderr') { throw 'Logs leaked into result' }
    if ((Get-Content $paths.state -Raw) -match 'fixture stdout|fixture stderr') { throw 'Logs leaked into state' }
    if ((Read-MigrationRunState -ProjectRoot $root -RunId $runId).stage -ne 'baseline') { throw 'Phase 3 cannot advance the stage' }
    Write-Host 'PASS successful baseline order, events, external logs'

    [IO.File]::WriteAllText((Join-Path $root '.fixture-fail'), '')
    Remove-Item (Join-Path $root '.fixture-trace')
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'blocked' -or $result.diagnostic.code -ne 'baseline_check_failed' -or $result.diagnostic.checkId -ne 'build' -or $result.notStarted[0].id -ne 'e2e') { throw 'Build failure must block and stop before e2e' }
    if (@(Get-Content (Join-Path $root '.fixture-trace')).Count -ne 6) { throw 'A check ran after build failure' }
    if ((Get-FileHash (Join-Path $root 'package.json')).Hash -ne $packageHash -or (Get-FileHash (Join-Path $root 'package-lock.json')).Hash -ne $lockHash) { throw 'Baseline modified dependencies' }
    Remove-Item (Join-Path $root '.fixture-fail')
    Write-Host 'PASS failed baseline blocks without modifying dependency files'

    $checks = (Get-ProjectInspection -ProjectRoot $root).checks
    foreach ($field in @('cwd', 'arguments', 'executable', 'timeoutSeconds', 'id', 'status')) {
        $invalid = $checks[5] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        switch ($field) {
            cwd { $invalid.cwd = Split-Path $root }
            arguments { $invalid.arguments = @('run', 'build', '--force') }
            executable { $invalid.executable = 'evil.cmd' }
            timeoutSeconds { $invalid.timeoutSeconds = 1 }
            id { $invalid.id = '../evil' }
            status { $invalid.status = 'not-configured' }
        }
        $rejected = $false
        try { Invoke-ProjectCheck -Check $invalid -LogDirectory $logDirectory | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Tampered check accepted: $field" }
    }
    [IO.File]::WriteAllText((Join-Path $root '.fixture-empty'), '')
    $empty = Invoke-ProjectCheck -Check $checks[5] -LogDirectory $logDirectory
    if ([IO.File]::ReadAllText((Join-Path $paths.root $empty.stdoutLog)) -cne '' -or [IO.File]::ReadAllText((Join-Path $paths.root $empty.stderrLog)) -cne '') { throw 'Empty logs must be empty strings' }
    Remove-Item (Join-Path $root '.fixture-empty')
    Write-Host 'PASS tampered checks rejected and empty logs normalized'

    $originalState = [IO.File]::ReadAllText($paths.state)
    $foreignState = $originalState | ConvertFrom-Json
    $foreignState.runId = 'another-run'
    [IO.File]::WriteAllText($paths.state, ($foreignState | ConvertTo-Json))
    Remove-Item (Join-Path $root '.fixture-trace')
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'failed' -or (Test-Path (Join-Path $root '.fixture-trace'))) { throw 'Foreign state allowed execution' }
    [IO.File]::WriteAllText($paths.state, $originalState)
    Remove-ActiveRunLock -ProjectRoot $root -RunId $runId
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'blocked' -or (Test-Path (Join-Path $root '.fixture-trace'))) { throw 'Non-owner allowed execution' }
    New-ActiveRunLock -ProjectRoot $root -RunId $runId
    Write-Host 'PASS ownership and foreign state checked before execution'

    $originalManifest = [IO.File]::ReadAllText($paths.manifest)
    $foreignManifest = $originalManifest | ConvertFrom-Json
    $foreignManifest.runId = 'another-run'
    [IO.File]::WriteAllText($paths.manifest, ($foreignManifest | ConvertTo-Json -Depth 20))
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'failed' -or (Test-Path (Join-Path $root '.fixture-trace'))) { throw 'Foreign manifest allowed execution' }
    [IO.File]::WriteAllText($paths.manifest, $originalManifest)
    [IO.File]::WriteAllText((Join-Path $root 'dirty.txt'), '')
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'blocked' -or $result.diagnostic.code -ne 'git_dirty') { throw 'Dirty baseline should block' }
    Remove-Item (Join-Path $root 'dirty.txt')

    & $projectModule {
        $script:OriginalProcess = (Get-Command Invoke-MigrationProcess).ScriptBlock
        function script:Invoke-MigrationProcess {
            param($FilePath, $Arguments, $WorkingDirectory, $TimeoutSeconds)
            if ($FilePath -like '*npm.cmd') {
                if ($TimeoutSeconds -ne 900) { throw 'Install timeout changed' }
                return [PSCustomObject]@{ exitCode = 124; stdout = ''; stderr = ''; timedOut = $true }
            }
            return & $script:OriginalProcess @PSBoundParameters
        }
    }
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'blocked' -or -not $result.diagnostic.timedOut -or $result.checks[0].status -ne 'timed-out' -or $result.notStarted.Count -ne 6) { throw 'Timeout must block, not request repair' }
    & $projectModule {
        function script:Invoke-MigrationProcess {
            param($FilePath, $Arguments, $WorkingDirectory, $TimeoutSeconds)
            if ($FilePath -like '*npm.cmd') { Throw-MigrationError -Code 'process_failed' -Message 'Fixture cannot start' -Status failed }
            return & $script:OriginalProcess @PSBoundParameters
        }
    }
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'failed' -or $result.diagnostic.code -ne 'process_failed') { throw 'Process launch error must fail' }
    & $projectModule { Set-Item Function:script:Invoke-MigrationProcess $script:OriginalProcess }
    $stdoutPath = Join-Path $logDirectory '01-install.stdout.log'
    Remove-Item $stdoutPath
    New-Item -ItemType Directory -Path $stdoutPath | Out-Null
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'failed') { throw 'Log write error must fail' }
    Remove-Item $stdoutPath
    $eventStream = [IO.File]::Open($paths.events, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
        if ($result.status -ne 'failed' -or $result.diagnostic.code -ne 'event_write_failed') { throw 'Event write error must fail' }
    }
    finally { $eventStream.Dispose() }
    Write-Host 'PASS foreign manifest, dirty tree, timeout, process/log/event failures'

    Remove-ActiveRunLock -ProjectRoot $root -RunId $runId
    Copy-Item (Join-Path $fixtures 'projects/missing-checks/package.json') (Join-Path $root 'package.json') -Force
    & git -C $root add package.json
    & git -C $root commit --quiet -m missing-checks
    $run = Invoke-StartMigration -ProjectRoot $root -TargetMajor 8
    $runId = $run.data.runId
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $runId
    Remove-Item (Join-Path $root '.fixture-trace') -ErrorAction SilentlyContinue
    $result = Invoke-MigrationBaseline -ProjectRoot $root -RunId $runId
    if ($result.status -ne 'passed' -or ($result.checks.status -join ',') -ne 'passed,passed,not-configured,not-configured,not-configured,passed,not-configured') { throw 'Missing checks must retain their positions without running' }
    if ((@(Get-Content (Join-Path $root '.fixture-trace')) -join ',') -ne 'install,dependency-tree,build') { throw 'Missing checks executed a process' }
    $checks = (Get-ProjectInspection -ProjectRoot $root).checks
    $result = Invoke-ProjectCheckSet -Checks $checks -LogDirectory (Join-Path $paths.logs 'baseline') -Mode baseline
    if ($result.status -ne 'passed' -or $result.checks[3].status -ne 'not-configured') { throw 'Check set did not preserve missing lint' }
    [IO.File]::WriteAllText((Join-Path $root '.fixture-fail'), '')
    $result = Invoke-ProjectCheckSet -Checks $checks -LogDirectory (Join-Path $paths.logs 'baseline') -Mode baseline
    if ($result.status -ne 'blocked' -or $result.notStarted.Count -ne 1 -or $result.checks.Count -ne 6) { throw 'Check set must stop at first failure' }
    Write-Host 'PASS missing checks and normalized check set'
}
finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath $root -Recurse -Force
}