#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot '../../scripts/modules'
$fixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot '../fixtures/migrations')).Path
$projectFixture = Join-Path $fixtureRoot 'project'
$toolDirectory = Join-Path $fixtureRoot 'tools'
$registryFixture = Join-Path $fixtureRoot 'registry/responses.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('migration-pipeline-' + [guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
$originalFixtureRoot = $env:MIGRATION_FIXTURE_ROOT
$originalFixtureTools = $env:MIGRATION_FIXTURE_TOOLS
$originalProtectedProject = $env:MIGRATION_FIXTURE_PROTECTED_PROJECT
$originalRegistryFixture = $env:MIGRATION_REGISTRY_FIXTURE
$originalRegistryTrace = $env:MIGRATION_REGISTRY_TRACE

Import-Module (Join-Path $modules 'Migration.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.State.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Project.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Dependencies.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Pipeline.psm1') -Force -DisableNameChecking

foreach ($moduleName in @('Migration.Project', 'Migration.Dependencies', 'Migration.Pipeline')) {
    $module = Get-Module $moduleName
    & $module {
        param([string]$Tools)
        $script:FixtureTools = $Tools
        function script:Find-MigrationExecutable {
            param([Parameter(Mandatory = $true)][string[]]$Names)
            if ($Names -contains 'git.exe' -or $Names -contains 'git') { return (Get-Command git.exe -ErrorAction Stop).Source }
            if ($Names -contains 'node.exe' -or $Names -contains 'node') { return (Join-Path $script:FixtureTools 'node.cmd') }
            if ($Names -contains 'npm.cmd' -or $Names -contains 'npm.exe' -or $Names -contains 'npm') { return (Join-Path $script:FixtureTools 'npm.cmd') }
            return $null
        }
    } $toolDirectory
}

$pipelineModule = Get-Module 'Migration.Pipeline'

function Assert-Integration {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name" -ForegroundColor Green
}

function New-PipelineProject {
    param([string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $projectFixture -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Path $item.Name) -Recurse -Force
    }
    $ngDirectory = Join-Path $Path 'node_modules/.bin'
    New-Item -ItemType Directory -Path $ngDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $toolDirectory 'ng.cmd') -Destination (Join-Path $ngDirectory 'ng.cmd') -Force
    & git -C $Path init --quiet
    & git -C $Path config user.name 'Pipeline Fixture'
    & git -C $Path config user.email 'pipeline@example.invalid'
    & git -C $Path add .
    & git -C $Path commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Pipeline fixture Git setup failed' }
}

function Get-JsonHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-Trace {
    param([string]$ProjectRoot)
    $tracePath = Join-Path $ProjectRoot '.fixture-trace'
    if (-not (Test-Path -LiteralPath $tracePath -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $tracePath)
}

function Get-CurrentBranch {
    param([string]$ProjectRoot)
    return (& git -C $ProjectRoot symbolic-ref --quiet --short HEAD).Trim()
}

function Assert-RequiredProperties {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$SchemaPath)
    $schema = Read-MigrationJson -Path $SchemaPath -Required
    foreach ($name in @($schema.required)) {
        if (-not $Value.PSObject.Properties[[string]$name]) { throw "Schema-required property is missing: $name" }
    }
}

function Invoke-HappyPath {
    param([string]$ProjectRoot)

    $start = Invoke-StartMigration -ProjectRoot $ProjectRoot -TargetMajor 8
    $runId = [string]$start.data.runId
    $result = Invoke-MigrationRun -ProjectRoot $ProjectRoot -RunId $runId
    if (-not $result.ok) { throw ('Happy path failed: ' + ($result | ConvertTo-Json -Depth 20 -Compress)) }
    Assert-Integration 'happy path reaches verified' ($result.ok -and $result.status -eq 'verified')
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $runId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $runId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    $technicalResult = Read-MigrationJson -Path $paths.result -Required
    Assert-Integration 'state reaches document with all operations confirmed' ($state.stage -eq 'document' -and @($state.completedOperations).Count -eq 8 -and $state.migrationStatus -eq 'verified')
    Assert-Integration 'verified run keeps ownership lock' (Test-Path -LiteralPath (Join-Path $ProjectRoot '.angular-migration/active.lock') -PathType Leaf)
    Assert-Integration 'dedicated migration branch is checked out' ((Get-CurrentBranch -ProjectRoot $ProjectRoot) -eq $state.migrationBranch -and $state.migrationBranch -match '^migration/angular-7-to-8-[a-f0-9]{8}$')
    Assert-Integration 'Angular update uses only exact local CLI arguments' ((Get-Trace -ProjectRoot $ProjectRoot | Where-Object { $_ -like 'ng *' }) -eq 'ng update @angular/core@8.2.14 @angular/cli@8.3.29')
    $expectedTrace = 'npm-ci|npm-ls-all|npm-run:typecheck|npm-run:lint|npm-run:test:unit|npm-run:build|npm-run:e2e|ng update @angular/core@8.2.14 @angular/cli@8.3.29|npm-install-lockfile|npm-ci|npm-ls-all|npm-run:typecheck|npm-run:lint|npm-run:test:unit|npm-run:build|npm-run:e2e'
    Assert-Integration 'dependency and validation process order is deterministic' (((Get-Trace -ProjectRoot $ProjectRoot) -join '|') -eq $expectedTrace)
    $compilerCli = $manifest.dependencies | Where-Object name -eq '@angular/compiler-cli' | Select-Object -First 1
    Assert-Integration 'required compiler tooling is added from the manifest decision' ($compilerCli.change -eq 'added-required-tooling')
    $package = Read-MigrationJson -Path (Join-Path $ProjectRoot 'package.json') -Required
    $lock = Get-ProjectLockfile -ProjectRoot $ProjectRoot
    Assert-Integration 'declared package ranges admit exact lock versions' ($package.dependencies.'@angular/core' -eq '^8.2.14' -and $package.devDependencies.'@angular/cli' -eq '~8.3.29' -and $package.devDependencies.'@angular/compiler-cli' -eq '8.2.14' -and $lock.versions.'@angular/core' -eq '8.2.14' -and $lock.versions.'@angular/compiler-cli' -eq '8.2.14')
    Assert-Integration 'technical result references checks and has a hash' ($technicalResult.status -eq 'verified' -and $technicalResult.resultSha256 -match '^[0-9a-f]{64}$' -and @($technicalResult.checks).Count -eq 5)
    Assert-RequiredProperties -Value $technicalResult -SchemaPath (Join-Path $PSScriptRoot '../../schemas/result.schema.json')
    foreach ($check in @($technicalResult.checks)) {
        Assert-RequiredProperties -Value $check -SchemaPath (Join-Path $PSScriptRoot '../../schemas/check-result.schema.json')
    }
    Assert-Integration 'technical result satisfies required schema properties' $true
    $commitSubjects = @(& git -C $ProjectRoot log --format=%s "$($state.initialCommit)..HEAD")
    Assert-Integration 'technical checkpoints use the two fixed commit messages' ($commitSubjects.Count -eq 2 -and $commitSubjects[0] -eq "chore(migration): align dependencies for Angular 8 [$runId]" -and $commitSubjects[1] -eq "chore(migration): Angular 7 to 8 schematics [$runId]")
    $dependencyCommitPaths = @(& git -C $ProjectRoot show --pretty= --name-only HEAD | Where-Object { $_ })
    Assert-Integration 'dependency checkpoint contains only package metadata' ($dependencyCommitPaths.Count -eq 2 -and $dependencyCommitPaths -contains 'package.json' -and $dependencyCommitPaths -contains 'package-lock.json')
    $traceBefore = @(Get-Trace -ProjectRoot $ProjectRoot)
    $second = Invoke-MigrationRun -ProjectRoot $ProjectRoot -RunId $runId
    Assert-Integration 'second run returns the immutable verified result' ($second.ok -and $second.status -eq 'verified' -and ((Get-Trace -ProjectRoot $ProjectRoot) -join '|') -eq ($traceBefore -join '|'))
    return [PSCustomObject]@{ runId = $runId; state = $state; paths = $paths; result = $technicalResult }
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $env:PATH = $toolDirectory + [IO.Path]::PathSeparator + $originalPath
    $env:MIGRATION_FIXTURE_ROOT = $fixtureRoot
    $env:MIGRATION_FIXTURE_TOOLS = $toolDirectory
    $env:MIGRATION_REGISTRY_FIXTURE = $registryFixture

    $happyRoot = Join-Path $temporaryRoot 'happy'
    New-PipelineProject -Path $happyRoot
    $happy = Invoke-HappyPath -ProjectRoot $happyRoot
    $resultPath = $happy.paths.result
    $tamperedResult = Read-MigrationJson -Path $resultPath -Required
    $tamperedResult.warnings = @('tampered')
    Write-MigrationJsonAtomic -Value $tamperedResult -Path $resultPath
    $tamperedRun = Invoke-MigrationRun -ProjectRoot $happyRoot -RunId $happy.runId
    Assert-Integration 'tampered technical result is rejected on rerun' ($tamperedRun.status -eq 'failed' -and $tamperedRun.error.code -eq 'result_integrity_failed')

    $baselineRoot = Join-Path $temporaryRoot 'baseline-failure'
    New-PipelineProject -Path $baselineRoot
    New-Item -ItemType File -Path (Join-Path $baselineRoot '.fixture-fail-build') | Out-Null
    $baselineStart = Invoke-StartMigration -ProjectRoot $baselineRoot -TargetMajor 8
    $baselineRun = Invoke-MigrationRun -ProjectRoot $baselineRoot -RunId $baselineStart.data.runId
    Assert-Integration 'baseline failure blocks before branch creation' ($baselineRun.status -eq 'blocked' -and $baselineRun.error.code -eq 'baseline_check_failed' -and (Get-CurrentBranch -ProjectRoot $baselineRoot) -eq 'master' -and -not (Test-Path -LiteralPath (Join-Path $baselineRoot 'src/migrated-by-ng.ts')))
    Assert-Integration 'baseline failure releases ownership' (-not (Test-Path -LiteralPath (Join-Path $baselineRoot '.angular-migration/active.lock')))

    $branchRoot = Join-Path $temporaryRoot 'branch-exists'
    New-PipelineProject -Path $branchRoot
    $branchStart = Invoke-StartMigration -ProjectRoot $branchRoot -TargetMajor 8
    $branchName = 'migration/angular-7-to-8-' + $branchStart.data.runId.Substring($branchStart.data.runId.Length - 8)
    & git -C $branchRoot branch $branchName
    $branchRun = Invoke-MigrationRun -ProjectRoot $branchRoot -RunId $branchStart.data.runId
    Assert-Integration 'existing migration branch blocks before project mutation' ($branchRun.status -eq 'blocked' -and $branchRun.error.code -eq 'migration_branch_exists' -and (Get-CurrentBranch -ProjectRoot $branchRoot) -eq 'master' -and -not (Test-Path -LiteralPath (Join-Path $branchRoot 'src/migrated-by-ng.ts')))

    $protectedRoot = Join-Path $temporaryRoot 'protected-path'
    New-PipelineProject -Path $protectedRoot
    $env:MIGRATION_FIXTURE_PROTECTED_PROJECT = $protectedRoot
    $protectedStart = Invoke-StartMigration -ProjectRoot $protectedRoot -TargetMajor 8
    $protectedRun = Invoke-MigrationRun -ProjectRoot $protectedRoot -RunId $protectedStart.data.runId
    Remove-Item Env:MIGRATION_FIXTURE_PROTECTED_PROJECT -ErrorAction SilentlyContinue
    Assert-Integration 'protected path blocks and rolls back Angular changes' ($protectedRun.status -eq 'blocked' -and $protectedRun.error.code -eq 'protected_path_modified' -and -not (Test-Path -LiteralPath (Join-Path $protectedRoot 'docs/unexpected.md')) -and -not (Test-Path -LiteralPath (Join-Path $protectedRoot 'src/migrated-by-ng.ts')))

    $blockedRoot = Join-Path $temporaryRoot 'resolution-blocked'
    New-PipelineProject -Path $blockedRoot
    $blockedResponses = Join-Path $temporaryRoot 'blocked-responses.json'
    @{ '@angular/core@8' = @{ version = '8.2.14'; peerDependencies = @{}; peerDependenciesMeta = @{}; engines = @{}; deprecated = $false; 'dist-tags' = @{} } } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $blockedResponses -Encoding UTF8
    $env:MIGRATION_REGISTRY_FIXTURE = $blockedResponses
    $blockedStart = Invoke-StartMigration -ProjectRoot $blockedRoot -TargetMajor 8
    $blockedRun = Invoke-MigrationRun -ProjectRoot $blockedRoot -RunId $blockedStart.data.runId
    Assert-Integration 'resolver block leaves project dependency files untouched' ($blockedRun.status -eq 'blocked' -and $blockedRun.error.code -eq 'registry_metadata_unavailable' -and -not (Test-Path -LiteralPath (Join-Path $blockedRoot 'src/migrated-by-ng.ts')) -and -not (Test-Path -LiteralPath (Join-Path $blockedRoot '.angular-migration/active.lock')))
    $env:MIGRATION_REGISTRY_FIXTURE = $registryFixture

    $installRoot = Join-Path $temporaryRoot 'install-failure'
    New-PipelineProject -Path $installRoot
    New-Item -ItemType File -Path (Join-Path $installRoot '.fixture-fail-second-ci') | Out-Null
    $installStart = Invoke-StartMigration -ProjectRoot $installRoot -TargetMajor 8
    $installRun = Invoke-MigrationRun -ProjectRoot $installRoot -RunId $installStart.data.runId
    Assert-Integration 'npm ci failure blocks after dependency checkpoint' ($installRun.status -eq 'blocked' -and $installRun.error.code -eq 'dependency_install_failed' -and $installRun.data.stage -eq 'install')
    Assert-Integration 'install failure keeps no active ownership lock' (-not (Test-Path -LiteralPath (Join-Path $installRoot '.angular-migration/active.lock')))

    $repairRoot = Join-Path $temporaryRoot 'validation-repair'
    New-PipelineProject -Path $repairRoot
    New-Item -ItemType File -Path (Join-Path $repairRoot '.fixture-fail-second-build') | Out-Null
    $repairStart = Invoke-StartMigration -ProjectRoot $repairRoot -TargetMajor 8
    $repairFirst = Invoke-MigrationRun -ProjectRoot $repairRoot -RunId $repairStart.data.runId
    Assert-Integration 'final check failure produces scoped needs-repair' ($repairFirst.status -eq 'needs-repair' -and $repairFirst.error.code -eq 'validation_failed' -and (Test-Path -LiteralPath (Join-Path $repairRoot ('.angular-migration/runs/' + $repairStart.data.runId + '/failure-context.json'))))
    Assert-Integration 'needs-repair keeps ownership' (Test-Path -LiteralPath (Join-Path $repairRoot '.angular-migration/active.lock') -PathType Leaf)
    Remove-Item -LiteralPath (Join-Path $repairRoot '.fixture-fail-second-build') -Force
    $unregistered = Invoke-MigrationRun -ProjectRoot $repairRoot -RunId $repairStart.data.runId
    Assert-Integration 'run cannot resume without record-repair' ($unregistered.status -eq 'needs-repair')
    $context = (Invoke-MigrationRepairContext -ProjectRoot $repairRoot -RunId $repairStart.data.runId).data
    Add-Content -LiteralPath (Join-Path $repairRoot 'src/app.component.ts') -Value 'export const repaired = true;'
    $submission = [PSCustomObject]@{
        schemaVersion = 1; runId = $context.runId; fingerprint = $context.fingerprint; attempt = $context.attempt
        rootCause = 'Fixture compilation diagnostic requires source adaptation.'
        changes = @([PSCustomObject]@{ path = 'src/app.component.ts'; summary = 'Adapt fixture source.'; reason = 'Build diagnostic.' })
        evidence = @([PSCustomObject]@{ kind = 'diagnostic'; reference = $context.diagnostic.logFiles[0]; claim = 'Original build failed.' })
        unresolvedWarnings = @()
    }
    Write-MigrationJsonAtomic -Value $submission -Path (Join-Path $repairRoot $context.submissionPath)
    $accepted = Invoke-MigrationRecordRepair -ProjectRoot $repairRoot -RunId $context.runId -InputFile $context.submissionPath
    Assert-Integration 'record-repair accepts minimal source change' ($accepted.ok -and $accepted.data.nextAction -eq 'rerun-failed-check')
    $traceCount = @(Get-Trace $repairRoot).Count
    $repairSecond = Invoke-MigrationRun -ProjectRoot $repairRoot -RunId $repairStart.data.runId
    Assert-Integration 'registered repair reaches verified' ($repairSecond.status -eq 'verified')
    Assert-Integration 'rerun executes only failed check and remaining gates' (((Get-Trace $repairRoot | Select-Object -Skip $traceCount) -join '|') -eq 'npm-run:build|npm-run:e2e')

    $repairLimitRoot = Join-Path $temporaryRoot 'repair-limit'
    New-PipelineProject -Path $repairLimitRoot
    $repairLimitStart = Invoke-StartMigration -ProjectRoot $repairLimitRoot -TargetMajor 8
    $repairLimitState = Read-MigrationRunState -ProjectRoot $repairLimitRoot -RunId $repairLimitStart.data.runId
    $repairLimitState.status = 'needs-repair'
    $repairLimitState.stage = 'validate'
    $repairLimitState.attempt = 3
    $repairLimitState.lastDiagnostic = [PSCustomObject]@{ code = 'validation_failed'; details = [PSCustomObject]@{ context = [PSCustomObject]@{ fingerprint = 'same-fingerprint' } } }
    Write-MigrationRunState -ProjectRoot $repairLimitRoot -RunId $repairLimitStart.data.runId -State $repairLimitState
    $repairLimitRun = Invoke-MigrationRun -ProjectRoot $repairLimitRoot -RunId $repairLimitStart.data.runId
    Assert-Integration 'run leaves unregistered attempt unchanged' ($repairLimitRun.status -eq 'needs-repair' -and (Test-Path -LiteralPath (Join-Path $repairLimitRoot '.angular-migration/active.lock')))

    $recoveryRoot = Join-Path $temporaryRoot 'interrupted-operation'
    New-PipelineProject -Path $recoveryRoot
    $recoveryStart = Invoke-StartMigration -ProjectRoot $recoveryRoot -TargetMajor 8
    $recoveryState = Read-MigrationRunState -ProjectRoot $recoveryRoot -RunId $recoveryStart.data.runId
    $recoveryBranch = 'migration/angular-7-to-8-' + $recoveryStart.data.runId.Substring($recoveryStart.data.runId.Length - 8)
    & git -C $recoveryRoot switch -c $recoveryBranch $recoveryState.initialCommit | Out-Null
    $recoveryState.stage = 'update-angular'
    $recoveryState.stageRevision = 2
    $recoveryState.baselineStatus = 'passed'
    $recoveryState.resolutionStatus = 'resolved'
    $recoveryState.migrationBranch = $recoveryBranch
    $recoveryState.completedOperations = @('baseline', 'resolve-manifest', 'create-branch')
    $recoveryState.activeOperation = [PSCustomObject]@{
        id = 'update-angular'; stage = 'update-angular'; startedAt = Get-MigrationUtcNow
        checkpointCommit = $recoveryState.initialCommit; expectedManifestSha256 = $null; preexistingFiles = @()
    }
    Write-MigrationRunState -ProjectRoot $recoveryRoot -RunId $recoveryStart.data.runId -State $recoveryState
    [IO.File]::WriteAllText((Join-Path $recoveryRoot 'src/interrupted.ts'), 'interrupted')
    $recoveryRun = Invoke-MigrationRun -ProjectRoot $recoveryRoot -RunId $recoveryStart.data.runId
    Assert-Integration 'interrupted mutating operation rolls back and blocks' ($recoveryRun.status -eq 'blocked' -and $recoveryRun.error.code -eq 'interrupted_operation_rolled_back' -and -not (Test-Path -LiteralPath (Join-Path $recoveryRoot 'src/interrupted.ts')))

    $rollbackRoot = Join-Path $temporaryRoot 'rollback-inventory'
    New-PipelineProject -Path $rollbackRoot
    $rollbackHead = (& git -C $rollbackRoot rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $rollbackRoot 'preexisting.tmp'), 'keep')
    $beforeItems = & $pipelineModule { param($Root) @(Get-PipelineGitStatus -ProjectRoot $Root) } $rollbackRoot
    [IO.File]::WriteAllText((Join-Path $rollbackRoot 'package.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $rollbackRoot 'created.tmp'), 'remove')
    & $pipelineModule { param($Root, $Commit, $Before) Invoke-PipelineRollback -ProjectRoot $Root -CheckpointCommit $Commit -BeforeItems $Before } $rollbackRoot $rollbackHead $beforeItems
    Assert-Integration 'rollback preserves preexisting untracked and removes only new files' ((Test-Path -LiteralPath (Join-Path $rollbackRoot 'preexisting.tmp')) -and -not (Test-Path -LiteralPath (Join-Path $rollbackRoot 'created.tmp')) -and (Read-MigrationJson -Path (Join-Path $rollbackRoot 'package.json') -Required).name -eq 'pipeline-migration-fixture')

    $pipelineSource = [IO.File]::ReadAllText((Join-Path $modules 'Migration.Pipeline.psm1'))
    Assert-Integration 'pipeline contains no push, git clean, npx or broad add command' ($pipelineSource -notmatch "@\('push'" -and $pipelineSource -notmatch "@\('clean'" -and $pipelineSource -notmatch '(?i)\bnpx\b' -and $pipelineSource -notmatch "@\('add',\s*'\.'")

    Write-Host 'Pipeline execution integration OK' -ForegroundColor Green
}
finally {
    if ($env:KEEP_PIPELINE_FIXTURE) { Write-Host "Kept pipeline fixture: $temporaryRoot" }
    $env:PATH = $originalPath
    if ($null -eq $originalFixtureRoot) { Remove-Item Env:MIGRATION_FIXTURE_ROOT -ErrorAction SilentlyContinue } else { $env:MIGRATION_FIXTURE_ROOT = $originalFixtureRoot }
    if ($null -eq $originalFixtureTools) { Remove-Item Env:MIGRATION_FIXTURE_TOOLS -ErrorAction SilentlyContinue } else { $env:MIGRATION_FIXTURE_TOOLS = $originalFixtureTools }
    if ($null -eq $originalProtectedProject) { Remove-Item Env:MIGRATION_FIXTURE_PROTECTED_PROJECT -ErrorAction SilentlyContinue } else { $env:MIGRATION_FIXTURE_PROTECTED_PROJECT = $originalProtectedProject }
    if ($null -eq $originalRegistryFixture) { Remove-Item Env:MIGRATION_REGISTRY_FIXTURE -ErrorAction SilentlyContinue } else { $env:MIGRATION_REGISTRY_FIXTURE = $originalRegistryFixture }
    if ($null -eq $originalRegistryTrace) { Remove-Item Env:MIGRATION_REGISTRY_TRACE -ErrorAction SilentlyContinue } else { $env:MIGRATION_REGISTRY_TRACE = $originalRegistryTrace }
    if (-not $env:KEEP_PIPELINE_FIXTURE) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
