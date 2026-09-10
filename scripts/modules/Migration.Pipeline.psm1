Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.Project.psm1') -DisableNameChecking

function New-StartManifest {
    param(
        [Parameter(Mandatory = $true)]$Inspection,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$Target
    )

    return [ordered]@{
        schemaVersion = Get-MigrationSchemaVersion
        manifestType = 'migration'
        runId = $RunId
        createdAt = Get-MigrationUtcNow
        project = [ordered]@{
            name = $Inspection.projectName
            root = $Inspection.projectRoot
            packageManager = $Inspection.packageManager
            files = $Inspection.files
            lockfileVersion = $Inspection.lockfileVersion
            scripts = $Inspection.scripts
            builders = $Inspection.builders
            toolchain = $Inspection.node
            git = [ordered]@{
                branch = $Inspection.git.branch
                initialCommit = $Inspection.git.head
            }
        }
        sourceMajor = $Inspection.angular.currentMajor
        targetMajor = $Target
        angular = [ordered]@{
            declaredCoreSpec = $Inspection.angular.declaredCoreSpec
            resolvedCoreVersion = $Inspection.angular.resolvedCoreVersion
            current = $Inspection.angular.packages
            target = [ordered]@{
                major = $Target
                resolved = $false
                resolutionStatus = 'pending'
            }
        }
        dependencies = $Inspection.dependencies
        policies = $Inspection.policies
        authorizedOperations = @(
            'resolve-manifest',
            'update-angular',
            'update-dependencies',
            'install',
            'dependency-tree',
            'typecheck',
            'lint',
            'unit-test',
            'build',
            'e2e'
        )
        policy = [ordered]@{
            sequentialMajor = $true
            exactManifestVersions = $true
            allowForce = $false
            allowDirty = $false
            allowLegacyPeerDeps = $false
        }
        checks = $Inspection.checks
        warnings = @()
    }
}

function Invoke-InspectMigration {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $inspection = Get-ProjectInspection -ProjectRoot $ProjectRoot
    return [PSCustomObject]@{
        ok = [bool]$inspection.ready
        status = $inspection.status
        data = $inspection
        error = if ($inspection.ready) { $null } else {
            [PSCustomObject]@{
                code = 'project_not_ready'
                message = 'Project inspection found blocking preconditions.'
                details = $inspection.blockers
            }
        }
    }
}

function Invoke-StartMigration {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$TargetMajor
    )

    if ($TargetMajor -lt 1) {
        Throw-MigrationError -Code 'target_major_required' -Message '-TargetMajor must be a positive Angular major.' -Status blocked
    }

    $inspection = Get-ProjectInspection -ProjectRoot $ProjectRoot
    if (-not $inspection.ready) {
        Throw-MigrationError -Code 'project_not_ready' -Message 'Project inspection found blocking preconditions.' -Status blocked -Details $inspection.blockers
    }

    $expectedTarget = [int]$inspection.angular.currentMajor + 1
    if ($TargetMajor -ne $expectedTarget) {
        Throw-MigrationError -Code 'non_sequential_target' -Message "Only the next Angular major is allowed. Expected $expectedTarget, received $TargetMajor." -Status blocked -Details ([PSCustomObject]@{
                sourceMajor = $inspection.angular.currentMajor
                expectedTargetMajor = $expectedTarget
                requestedTargetMajor = $TargetMajor
            })
    }

    $runId = New-MigrationRunId -SourceMajor $inspection.angular.currentMajor -TargetMajor $TargetMajor
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $runId
    $createdRunDirectory = $false
    $lockCreated = $false
    try {
        New-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $runId
        $lockCreated = $true

        New-Item -ItemType Directory -Path $paths.logs | Out-Null
        $createdRunDirectory = $true

        $manifest = New-StartManifest -Inspection $inspection -RunId $runId -Target $TargetMajor
        $state = New-MigrationRunState -RunId $runId -ProjectRoot $ProjectRoot -SourceMajor $inspection.angular.currentMajor -TargetMajor $TargetMajor -InitialCommit $inspection.git.head
        Write-MigrationJsonAtomic -Value $manifest -Path $paths.manifest
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $runId -State $state
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $runId -Type 'run-started' -Stage 'baseline' -Data ([PSCustomObject]@{
                sourceMajor = $inspection.angular.currentMajor
                targetMajor = $TargetMajor
                initialCommit = $inspection.git.head
            })

        return [PSCustomObject]@{
            ok = $true
            status = 'running'
            data = [PSCustomObject]@{
                runId = $runId
                sourceMajor = $inspection.angular.currentMajor
                targetMajor = $TargetMajor
                stage = 'baseline'
                manifest = '.angular-migration/runs/' + $runId + '/manifest.json'
                state = '.angular-migration/runs/' + $runId + '/state.json'
            }
            error = $null
        }
    }
    catch {
        if ($createdRunDirectory -and (Test-Path -LiteralPath $paths.root -PathType Container)) {
            Remove-Item -LiteralPath $paths.root -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($lockCreated) {
            Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $runId
        }
        throw
    }
}

function Invoke-MigrationBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $results = @()
    $checks = @()
    try {
        $root = Resolve-MigrationRoot -Path $ProjectRoot
        Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
        $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        $manifest = Read-MigrationJson -Path $paths.manifest -Required
        if ($manifest.schemaVersion -ne (Get-MigrationSchemaVersion) -or $manifest.runId -cne $RunId -or
            $manifest.manifestType -cne 'migration' -or $manifest.project.root -cne $root -or $state.projectRoot -cne $root -or
            $manifest.sourceMajor -ne $state.sourceMajor -or $manifest.targetMajor -ne $state.targetMajor -or
            $manifest.project.git.initialCommit -cne $state.initialCommit) {
            Throw-MigrationError -Code 'invalid_run_manifest' -Message 'Manifest and state must describe the same run and project.' -Status failed
        }
        if ($state.status -cne 'running' -or $state.stage -cne 'baseline') {
            Throw-MigrationError -Code 'invalid_baseline_stage' -Message 'Baseline requires running/baseline.' -Status blocked
        }
        $git = Get-ProjectGit -ProjectRoot $root
        if ($git.errorCode) { Throw-MigrationError -Code $git.errorCode -Message $git.error -Status blocked }
        if ($git.head -cne $state.initialCommit) {
            Throw-MigrationError -Code 'baseline_head_changed' -Message 'Git HEAD differs from the initial commit.' -Status blocked
        }
        $checks = @($manifest.checks)
        $discovered = @(Get-ProjectChecks -Package (Get-ProjectPackage -ProjectRoot $root) -ProjectRoot $root -HasLockfile (Test-Path -LiteralPath (Join-Path $root 'package-lock.json') -PathType Leaf))
        if ((ConvertTo-Json -InputObject $checks -Depth 10 -Compress) -cne (ConvertTo-Json -InputObject $discovered -Depth 10 -Compress)) {
            Throw-MigrationError -Code 'invalid_check_contract' -Message 'Manifest checks differ from current discovery.' -Status blocked
        }
        foreach ($check in $checks) {
            if ($check.status -eq 'configured') {
                Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'check-started' -Stage 'baseline' -Data ([PSCustomObject]@{ checkId = $check.id })
            }
            $result = Invoke-ProjectCheck -Check $check -LogDirectory (Join-Path $paths.logs 'baseline')
            $results += $result
            if ($check.status -eq 'configured') {
                Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'check-finished' -Stage 'baseline' -Data $result
            }
            if ($result.status -notin @('passed', 'not-configured')) {
                return [PSCustomObject]@{
                    status = 'blocked'; checks = $results; notStarted = @($checks | Select-Object -Skip $results.Count)
                    diagnostic = [PSCustomObject]@{
                        code = 'baseline_check_failed'; checkId = $result.id; exitCode = $result.exitCode; timedOut = $result.timedOut
                        stdoutLog = $result.stdoutLog; stderrLog = $result.stderrLog
                        message = "The project does not pass its existing $($result.id) before migration."
                    }
                }
            }
        }
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'baseline-completed' -Stage 'baseline' -Data ([PSCustomObject]@{ checks = $results })
        return [PSCustomObject]@{ status = 'passed'; checks = $results; notStarted = @(); diagnostic = $null }
    }
    catch {
        $status = if ($_.Exception.Data['status'] -eq 'blocked') { 'blocked' } else { 'failed' }
        $code = if ($_.Exception.Data['code']) { $_.Exception.Data['code'] } else { 'baseline_internal_error' }
        return [PSCustomObject]@{
            status = $status; checks = $results; notStarted = @($checks | Select-Object -Skip $results.Count)
            diagnostic = [PSCustomObject]@{ code = $code; message = 'Baseline could not be completed.' }
        }
    }
}

function Invoke-MigrationStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        Throw-MigrationError -Code 'run_id_required' -Message '-RunId is required for status.' -Status blocked
    }
    Assert-MigrationRunId -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    if (-not (Test-Path -LiteralPath $paths.state -PathType Leaf)) {
        Throw-MigrationError -Code 'run_not_found' -Message "Migration run not found: $RunId" -Status blocked
    }

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $successful = @('running', 'verified', 'completed') -contains $state.status
    return [PSCustomObject]@{
        ok = $successful
        status = $state.status
        data = [PSCustomObject]@{
            runId = $state.runId
            status = $state.status
            stage = $state.stage
            attempt = $state.attempt
            migrationStatus = $state.migrationStatus
            documentationStatus = $state.documentationStatus
            lastDiagnostic = $state.lastDiagnostic
            manifest = '.angular-migration/runs/' + $RunId + '/manifest.json'
            state = '.angular-migration/runs/' + $RunId + '/state.json'
        }
        error = $null
    }
}

Export-ModuleMember -Function @(
    'Invoke-MigrationBaseline',
    'Invoke-InspectMigration',
    'Invoke-StartMigration',
    'Invoke-MigrationStatus'
)
