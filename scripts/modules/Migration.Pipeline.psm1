Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.Project.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Migration.Dependencies.psm1') -DisableNameChecking
. (Join-Path $PSScriptRoot '../hooks/copilot-policy.ps1')

function New-StartManifest {
    param(
        [Parameter(Mandatory = $true)]$Inspection,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$Target
    )

    return [ordered]@{
        schemaVersion        = Get-MigrationSchemaVersion
        manifestType         = 'migration'
        runId                = $RunId
        createdAt            = Get-MigrationUtcNow
        project              = [ordered]@{
            name            = $Inspection.projectName
            root            = $Inspection.projectRoot
            packageManager  = $Inspection.packageManager
            files           = $Inspection.files
            lockfileVersion = $Inspection.lockfileVersion
            scripts         = $Inspection.scripts
            builders        = $Inspection.builders
            toolchain       = $Inspection.node
            git             = [ordered]@{
                branch        = $Inspection.git.branch
                initialCommit = $Inspection.git.head
            }
        }
        sourceMajor          = $Inspection.angular.currentMajor
        targetMajor          = $Target
        resolutionStatus     = 'pending'
        resolverVersion      = 1
        angular              = [ordered]@{
            declaredCoreSpec    = $Inspection.angular.declaredCoreSpec
            resolvedCoreVersion = $Inspection.angular.resolvedCoreVersion
            current             = $Inspection.angular.packages
            target              = [ordered]@{
                major            = $Target
                resolved         = $false
                resolutionStatus = 'pending'
            }
        }
        dependencies         = $Inspection.dependencies
        policies             = $Inspection.policies
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
        policy               = [ordered]@{
            sequentialMajor       = $true
            exactManifestVersions = $true
            allowForce            = $false
            allowDirty            = $false
            allowLegacyPeerDeps   = $false
        }
        checks               = $Inspection.checks
        warnings             = @()
    }
}

function Invoke-InspectMigration {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $inspection = Get-ProjectInspection -ProjectRoot $ProjectRoot
    return [PSCustomObject]@{
        ok     = [bool]$inspection.ready
        status = $inspection.status
        data   = $inspection
        error  = if ($inspection.ready) { $null } else {
            [PSCustomObject]@{
                code    = 'project_not_ready'
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
                sourceMajor          = $inspection.angular.currentMajor
                expectedTargetMajor  = $expectedTarget
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
        $state = New-MigrationRunState -RunId $runId -ProjectRoot $ProjectRoot -SourceMajor $inspection.angular.currentMajor -TargetMajor $TargetMajor -InitialCommit $inspection.git.head -InitialBranch $inspection.git.branch
        $runtime = Resolve-RepairPath $ProjectRoot '.angular-migration/runtime/copilot-policy.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $runtime) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../hooks/copilot-policy.ps1') -Destination $runtime -Force
        $state.runtimeSha256 = (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $runId -State $state
        Write-MigrationRunManifest -ProjectRoot $ProjectRoot -RunId $runId -Manifest $manifest
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $runId -Type 'run-started' -Stage 'baseline' -Data ([PSCustomObject]@{
                sourceMajor   = $inspection.angular.currentMajor
                targetMajor   = $TargetMajor
                initialCommit = $inspection.git.head
            })

        return [PSCustomObject]@{
            ok     = $true
            status = 'running'
            data   = [PSCustomObject]@{
                runId       = $runId
                sourceMajor = $inspection.angular.currentMajor
                targetMajor = $TargetMajor
                stage       = 'baseline'
                manifest    = '.angular-migration/runs/' + $runId + '/manifest.json'
                state       = '.angular-migration/runs/' + $runId + '/state.json'
            }
            error  = $null
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
                    status = 'blocked'; checks = @($results); notStarted = @($checks | Select-Object -Skip @($results).Count)
                    diagnostic = [PSCustomObject]@{
                        code = 'baseline_check_failed'; checkId = $result.id; exitCode = $result.exitCode; timedOut = $result.timedOut
                        stdoutLog = $result.stdoutLog; stderrLog = $result.stderrLog
                        message = "The project does not pass its existing $($result.id) before migration."
                    }
                }
            }
        }
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'baseline-completed' -Stage 'baseline' -Data ([PSCustomObject]@{ checks = $results })
        $state.baselineStatus = 'passed'
        Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $state
        return [PSCustomObject]@{ status = 'passed'; checks = $results; notStarted = @(); diagnostic = $null }
    }
    catch {
        $status = if ($_.Exception.Data['status'] -eq 'blocked') { 'blocked' } else { 'failed' }
        $code = if ($_.Exception.Data['code']) { $_.Exception.Data['code'] } else { 'baseline_internal_error' }
        return [PSCustomObject]@{
            status = $status; checks = @($results); notStarted = @($checks | Select-Object -Skip @($results).Count)
            diagnostic = [PSCustomObject]@{ code = $code; message = 'Baseline could not be completed.' }
        }
    }
}

function Invoke-MigrationResolution {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $queryEvents = @()
    try {
        $root = Resolve-MigrationRoot -Path $ProjectRoot
        Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
        $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        $manifest = Read-MigrationJson -Path $paths.manifest -Required
        if ($state.manifestSha256) {
            $actualHash = Get-ResolvedManifestHash -Manifest $manifest
            if ($actualHash -ne $state.manifestSha256 -or $manifest.manifestSha256 -ne $state.manifestSha256) {
                Throw-MigrationError -Code 'manifest_integrity_failed' -Message 'The resolved migration manifest has been altered.' -Status failed
            }
            Throw-MigrationError -Code 'manifest_already_resolved' -Message 'The migration manifest is already resolved.' -Status blocked
        }
        if ($state.status -cne 'running' -or $state.stage -notin @('baseline', 'resolve') -or $state.baselineStatus -cne 'passed') {
            Throw-MigrationError -Code 'invalid_resolution_stage' -Message 'Resolution requires a running run after a passed baseline.' -Status blocked
        }
        if ($manifest.schemaVersion -ne (Get-MigrationSchemaVersion) -or $manifest.manifestType -cne 'migration' -or
            $manifest.runId -cne $RunId -or $manifest.project.root -cne $root -or $manifest.resolutionStatus -cne 'pending') {
            Throw-MigrationError -Code 'invalid_run_manifest' -Message 'Manifest is not a pending manifest for the active run.' -Status failed
        }
        $resolution = Resolve-MigrationManifest -PendingManifest $manifest -ProjectRoot $root
        $queryEvents = @($resolution.queryEvents)
        foreach ($queryEvent in $queryEvents) {
            Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'registry-metadata-queried' -Stage 'resolve' -Data $queryEvent
        }
        if ($resolution.status -ne 'resolved') { return $resolution }
        $resolvedManifest = $resolution.manifest
        if (-not (Test-ResolvedManifest -Manifest $resolvedManifest)) {
            Throw-MigrationError -Code 'registry_metadata_invalid' -Message 'Resolved manifest failed its contract validation.' -Status blocked
        }
        $expectedHash = Get-ResolvedManifestHash -Manifest $resolvedManifest
        if ($resolvedManifest.manifestSha256 -ne $expectedHash) {
            Throw-MigrationError -Code 'manifest_integrity_failed' -Message 'Resolved manifest hash is not self-consistent.' -Status failed
        }
        Write-MigrationRunManifest -ProjectRoot $root -RunId $RunId -Manifest $resolvedManifest
        $published = Read-MigrationJson -Path $paths.manifest -Required
        if ($published.manifestSha256 -ne (Get-ResolvedManifestHash -Manifest $published)) {
            Throw-MigrationError -Code 'manifest_integrity_failed' -Message 'Published manifest failed its integrity check.' -Status failed
        }
        $state.manifestSha256 = [string]$published.manifestSha256
        $state.resolutionStatus = 'resolved'
        $state.stage = 'resolve'
        $state.lastDiagnostic = $null
        Write-MigrationRunState -ProjectRoot $root -RunId $RunId -State $state
        Add-MigrationEvent -ProjectRoot $root -RunId $RunId -Type 'manifest-resolved' -Stage 'resolve' -Data ([PSCustomObject]@{
                manifestSha256  = $published.manifestSha256
                dependencyCount = @($published.dependencies).Count
                resolvedAt      = $published.resolvedAt
            })
        return [PSCustomObject]@{ status = 'resolved'; manifest = $published; queryEvents = $queryEvents; diagnostic = $null }
    }
    catch {
        $status = if ($_.Exception.Data['status'] -eq 'blocked') { 'blocked' } else { 'failed' }
        $code = if ($_.Exception.Data['code']) { [string]$_.Exception.Data['code'] } else { 'resolver_internal_error' }
        return [PSCustomObject]@{
            status = $status; manifest = $null; queryEvents = $queryEvents
            diagnostic = [PSCustomObject]@{ code = $code; message = $_.Exception.Message; details = $_.Exception.Data['details'] }
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
    if ($state.manifestSha256) {
        $manifest = Read-MigrationJson -Path $paths.manifest -Required
        if ($manifest.manifestSha256 -ne $state.manifestSha256 -or (Get-ResolvedManifestHash -Manifest $manifest) -ne $state.manifestSha256) {
            Throw-MigrationError -Code 'manifest_integrity_failed' -Message 'The resolved migration manifest has been altered.' -Status failed
        }
    }
    $successful = @('running', 'verified', 'completed') -contains $state.status
    return [PSCustomObject]@{
        ok     = $successful
        status = $state.status
        data   = [PSCustomObject]@{
            runId               = $state.runId
            status              = $state.status
            stage               = $state.stage
            attempt             = $state.attempt
            migrationStatus     = $state.migrationStatus
            documentationStatus = $state.documentationStatus
            lastDiagnostic      = $state.lastDiagnostic
            manifest            = '.angular-migration/runs/' + $RunId + '/manifest.json'
            state               = '.angular-migration/runs/' + $RunId + '/state.json'
        }
        error  = $null
    }
}

$script:TechnicalCheckIds = @('typecheck', 'lint', 'unit-test', 'build', 'e2e')
$script:DependencySections = @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')
$script:PackageRendererPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'helpers\render-package-json.js'

function Throw-PipelineError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('needs-repair', 'blocked', 'failed')][string]$Status = 'failed',
        $Details = $null
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['code'] = $Code
    $exception.Data['status'] = $Status
    $exception.Data['details'] = $Details
    throw $exception
}

function Get-PipelineRunError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    $details = if ($exception.Data['details']) { $exception.Data['details'] } else {
        [PSCustomObject]@{
            command          = if ($ErrorRecord.InvocationInfo) { [string]$ErrorRecord.InvocationInfo.MyCommand } else { $null }
            position         = if ($ErrorRecord.InvocationInfo) { [string]$ErrorRecord.InvocationInfo.PositionMessage } else { $null }
            scriptStackTrace = [string]$ErrorRecord.ScriptStackTrace
            exceptionTrace   = [string]$exception.StackTrace
        }
    }
    return [PSCustomObject]@{
        code    = if ($exception.Data['code']) { [string]$exception.Data['code'] } else { 'migration_internal_error' }
        message = $exception.Message
        details = $details
    }
}

function Get-PipelineGitExecutable {
    $git = Find-MigrationExecutable -Names @('git.exe', 'git')
    if (-not $git) { Throw-PipelineError -Code 'git_missing' -Message 'git is not available.' -Status blocked }
    return $git
}

function Invoke-PipelineGit {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    $git = Get-PipelineGitExecutable
    return Invoke-MigrationProcess -FilePath $git -Arguments $Arguments -WorkingDirectory $ProjectRoot -TimeoutSeconds $TimeoutSeconds
}

function Get-PipelineGitHead {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('rev-parse', 'HEAD')
    if ($result.exitCode -ne 0 -or [string]$result.stdout.Trim() -notmatch '^[a-fA-F0-9]{40}$') {
        Throw-PipelineError -Code 'git_head_changed' -Message 'Git HEAD could not be read.' -Status blocked
    }
    return $result.stdout.Trim()
}

function ConvertTo-PipelineRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
    $prefix = $root.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $candidate -cne $root) {
        Throw-PipelineError -Code 'path_outside_project' -Message "Git path is outside the project root: $Path" -Status blocked
    }
    if ($candidate -ceq $root) { return '' }
    return $candidate.Substring($prefix.Length).Replace('\', '/')
}

function ConvertFrom-PipelineGitStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [AllowEmptyString()][string]$Output
    )

    $tokens = @()
    if (-not [string]::IsNullOrEmpty($Output)) { $tokens = @($Output -split [char]0) }
    $items = @()
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = [string]$tokens[$index]
        if ([string]::IsNullOrEmpty($token)) { continue }
        if ($token.Length -lt 4) { continue }
        $status = $token.Substring(0, 2)
        $pathValue = $token.Substring(3)
        $paths = @($pathValue)
        if ($status -match '[RC]' -and $index + 1 -lt $tokens.Count -and -not [string]::IsNullOrEmpty($tokens[$index + 1])) {
            $index++
            $paths += [string]$tokens[$index]
        }
        foreach ($path in $paths) {
            $relative = ConvertTo-PipelineRelativePath -ProjectRoot $ProjectRoot -Path $path
            $items += [PSCustomObject]@{
                status    = $status
                path      = $relative
                untracked = $status -eq '??'
            }
        }
    }
    return @($items)
}

function Get-PipelineGitStatus {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all')
    if ($result.exitCode -ne 0) {
        Throw-PipelineError -Code 'git_status_failed' -Message 'Git status could not be read.' -Status failed -Details $result.stderr
    }
    return @(ConvertFrom-PipelineGitStatus -ProjectRoot $ProjectRoot -Output $result.stdout)
}

function Test-PipelineProtectedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path -match '^(?:\.git(?:/|$)|\.github(?:/|$)|\.angular-migration(?:/|$)|docs(?:/|$))'
}

function Assert-PipelineNoProtectedChanges {
    param([Parameter(Mandatory = $true)]$StatusItems)

    $protected = @($StatusItems | Where-Object { Test-PipelineProtectedPath -Path $_.path })
    if ($protected.Count -gt 0) {
        Throw-PipelineError -Code 'protected_path_modified' -Message 'Technical migration modified a protected path.' -Status blocked -Details ([PSCustomObject]@{ paths = @($protected.path) })
    }
}

function Get-PipelineLogRelativePath {
    param(
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $relative = $Path.Substring($RunPaths.root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
    return $relative
}

function Invoke-PipelineLoggedProcess {
    param(
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 0,
        [AllowNull()][AllowEmptyString()][string]$StandardInput = $null
    )

    $directory = Join-Path $RunPaths.logs $Stage
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $stdoutPath = Join-Path $directory ($Prefix + '.stdout.log')
    $stderrPath = Join-Path $directory ($Prefix + '.stderr.log')
    $started = Get-MigrationUtcNow
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    try {
        $parameters = @{
            FilePath         = $FilePath
            Arguments        = $Arguments
            WorkingDirectory = $WorkingDirectory
            TimeoutSeconds   = $TimeoutSeconds
        }
        if ($null -ne $StandardInput) { $parameters.StandardInput = $StandardInput }
        $process = Invoke-MigrationProcess @parameters
        [IO.File]::WriteAllText($stdoutPath, [string]$process.stdout, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($stderrPath, [string]$process.stderr, (New-Object Text.UTF8Encoding($false)))
        return [PSCustomObject]@{
            exitCode   = $process.exitCode
            timedOut   = [bool]$process.timedOut
            startedAt  = $started
            finishedAt = Get-MigrationUtcNow
            durationMs = $timer.ElapsedMilliseconds
            stdout     = [string]$process.stdout
            stderr     = [string]$process.stderr
            stdoutLog  = Get-PipelineLogRelativePath -RunPaths $RunPaths -Path $stdoutPath
            stderrLog  = Get-PipelineLogRelativePath -RunPaths $RunPaths -Path $stderrPath
        }
    }
    catch {
        try { [IO.File]::WriteAllText($stderrPath, $_.Exception.Message, (New-Object Text.UTF8Encoding($false))) } catch { }
        throw
    }
    finally { $timer.Stop() }
}

function Start-PipelineOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.activeOperation) {
        Throw-PipelineError -Code 'active_operation_present' -Message 'Another migration operation is already active.' -Status blocked -Details $state.activeOperation
    }
    $state.activeOperation = [ordered]@{
        id                     = $Id
        stage                  = $Stage
        startedAt              = Get-MigrationUtcNow
        checkpointCommit       = [string]$state.checkpointCommit
        expectedManifestSha256 = $state.manifestSha256
        preexistingFiles       = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    }
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'operation-started' -Stage $Stage -Data $state.activeOperation
    return $state
}

function Finish-PipelineOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$Stage
    )
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $payload = [ordered]@{
        operationId        = if ($state.activeOperation) { [string]$state.activeOperation.id } else { $null }
        operationStartedAt = if ($state.activeOperation) { [string]$state.activeOperation.startedAt } else { $null }
    }
    if ($Data -is [Collections.IDictionary]) {
        foreach ($key in $Data.Keys) { $payload[[string]$key] = $Data[$key] }
    }
    else {
        foreach ($property in $Data.PSObject.Properties) { $payload[$property.Name] = $property.Value }
    }
    Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'operation-finished' -Stage $Stage -Data ([PSCustomObject]$payload)
}

function Complete-PipelineOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$CheckpointCommit
    )

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($Id -notin @($state.completedOperations)) { $state.completedOperations = @($state.completedOperations) + $Id }
    if ($CheckpointCommit) { $state.checkpointCommit = $CheckpointCommit }
    $state.activeOperation = $null
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'operation-confirmed' -Stage $Stage -Data ([PSCustomObject]@{ id = $Id; checkpointCommit = $state.checkpointCommit })
    return $state
}

function Clear-PipelineOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.activeOperation) {
        $state.activeOperation = $null
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    }
    return $state
}

function Get-PipelineOperationPreexistingItems {
    param([Parameter(Mandatory = $true)]$Operation)

    $items = @()
    foreach ($item in @($Operation.preexistingFiles)) {
        if ($item -is [string]) {
            $items += [PSCustomObject]@{ status = ''; path = [string]$item; untracked = $false }
        }
        elseif ($item -and $item.PSObject.Properties['path']) {
            $items += $item
        }
    }
    return @($items)
}

function Get-PipelineOperationFinish {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Operation
    )

    $eventsPath = (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId).events
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) { return $null }
    $finished = @()
    foreach ($line in @(Get-Content -LiteralPath $eventsPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.type -eq 'operation-finished' -and $event.stage -eq $Operation.stage -and $event.data -and
            $event.data.operationId -eq $Operation.id -and $event.data.operationStartedAt -eq $Operation.startedAt -and
            $event.data.status -eq 'passed') {
            $finished += $event
        }
    }
    if ($finished.Count -eq 0) { return $null }
    return $finished[-1].data
}

function Assert-PipelineCommitExists {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    if ([string]::IsNullOrWhiteSpace($Commit) -or $Commit -notmatch '^[a-fA-F0-9]{40}$') {
        Throw-PipelineError -Code 'checkpoint_missing' -Message 'The migration checkpoint is missing or invalid.' -Status failed
    }
    $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('cat-file', '-e', ('{0}^{{commit}}' -f $Commit))
    if ($result.exitCode -ne 0) {
        Throw-PipelineError -Code 'checkpoint_missing' -Message "Migration checkpoint does not exist: $Commit" -Status failed
    }
}

function Get-PipelineMigrationBranchName {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$RunId)

    if ($RunId.Length -lt 8) { Throw-PipelineError -Code 'invalid_run_id' -Message 'Run id is too short to form a migration branch.' -Status blocked }
    $suffix = $RunId.Substring($RunId.Length - 8)
    if ($suffix -notmatch '^[a-f0-9]{8}$') { Throw-PipelineError -Code 'invalid_run_id' -Message 'Run id suffix cannot form a migration branch.' -Status blocked }
    return "migration/angular-$($State.sourceMajor)-to-$($State.targetMajor)-$suffix"
}

function Set-PipelineRecoveryOutcome {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        $Details = $null
    )

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $stage = [string]$state.stage
    if ($state.activeOperation) { Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null }
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $diagnostic = [PSCustomObject]@{ code = $Code; message = $Message; details = $Details }
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus $state.status -ExpectedStage $stage -NewStatus $Status -NewStage $stage -ExpectedRevision $state.stageRevision -Diagnostic $diagnostic | Out-Null
    if ($Status -in @('blocked', 'failed')) { Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $RunId }
}

function Invoke-PipelineActiveOperationRecovery {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)

    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if (-not $state.activeOperation) { return $state }
    $operation = $state.activeOperation
    $operationId = [string]$operation.id
    $mutating = $operationId -in @('create-branch', 'update-angular', 'update-dependencies', 'install')
    $finish = Get-PipelineOperationFinish -ProjectRoot $ProjectRoot -RunId $RunId -Operation $operation

    if ($finish) {
        if ($mutating -and $operationId -ne 'install') {
            $confirmedCommit = [string]$finish.newCommit
            Assert-PipelineCommitExists -ProjectRoot $ProjectRoot -Commit $confirmedCommit
            $head = Get-PipelineGitHead -ProjectRoot $ProjectRoot
            if ($head -cne $confirmedCommit) {
                Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'blocked' -Code 'git_head_changed' -Message 'Git HEAD differs from the confirmed operation checkpoint.' -Details ([PSCustomObject]@{ expected = $confirmedCommit; actual = $head })
                return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
            }
            if ($operationId -eq 'create-branch') {
                $branchResult = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
                if ($branchResult.exitCode -ne 0 -or [string]$branchResult.stdout.Trim() -ne (Get-PipelineMigrationBranchName -State $state -RunId $RunId)) {
                    Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'blocked' -Code 'git_head_changed' -Message 'The confirmed migration branch is not checked out.' -Details $branchResult.stderr
                    return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
                }
                $state.migrationBranch = [string]$branchResult.stdout.Trim()
                Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
            }
            $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id $operationId -Stage $operation.stage -CheckpointCommit $confirmedCommit
            return $state
        }
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id $operationId -Stage $operation.stage
        return $state
    }

    if (-not $mutating) {
        Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'operation-recovered' -Stage $operation.stage -Data ([PSCustomObject]@{ id = $operationId; action = 'rerun' })
        return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    }

    try {
        Assert-PipelineCommitExists -ProjectRoot $ProjectRoot -Commit ([string]$operation.checkpointCommit)
        $head = Get-PipelineGitHead -ProjectRoot $ProjectRoot
        if ($head -cne [string]$operation.checkpointCommit) {
            Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'blocked' -Code 'git_head_changed' -Message 'Git HEAD changed while a migration operation was interrupted.' -Details ([PSCustomObject]@{ expected = $operation.checkpointCommit; actual = $head })
            return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        }
        $before = @(Get-PipelineOperationPreexistingItems -Operation $operation)
        $after = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
        $beforePaths = @($before | ForEach-Object { $_.path })
        $dirty = @($after | Where-Object { $_.path -notin $beforePaths }).Count -gt 0
        if ($dirty) {
            Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit ([string]$operation.checkpointCommit) -BeforeItems $before
        }
        Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'blocked' -Code 'interrupted_operation_rolled_back' -Message 'An interrupted mutating operation was restored to its checkpoint and requires explicit review.' -Details ([PSCustomObject]@{ operation = $operationId; rolledBack = $dirty; checkpointCommit = $operation.checkpointCommit })
    }
    catch {
        $errorInfo = Get-PipelineRunError -ErrorRecord $_
        try { Set-PipelineRecoveryOutcome -ProjectRoot $ProjectRoot -RunId $RunId -Status 'failed' -Code ([string]$errorInfo.code) -Message ([string]$errorInfo.message) -Details $errorInfo.details } catch { }
    }
    return Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
}

function Assert-PipelineRunGitContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$State,
        [switch]$AllowDirty
    )

    Assert-PipelineCommitExists -ProjectRoot $ProjectRoot -Commit ([string]$State.checkpointCommit)
    $head = Get-PipelineGitHead -ProjectRoot $ProjectRoot
    if ($State.migrationBranch) {
        $branch = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
        if ($branch.exitCode -ne 0 -or [string]$branch.stdout.Trim() -cne [string]$State.migrationBranch) {
            Throw-PipelineError -Code 'git_head_changed' -Message 'The migration branch is not checked out.' -Status blocked -Details ([PSCustomObject]@{ expectedBranch = $State.migrationBranch; actualBranch = $branch.stdout.Trim() })
        }
    }
    elseif ($State.initialBranch) {
        $branch = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
        if ($branch.exitCode -ne 0 -or [string]$branch.stdout.Trim() -cne [string]$State.initialBranch) {
            Throw-PipelineError -Code 'git_head_changed' -Message 'The initial project branch is not checked out.' -Status blocked -Details ([PSCustomObject]@{ expectedBranch = $State.initialBranch; actualBranch = $branch.stdout.Trim() })
        }
    }
    if ($head -cne [string]$State.checkpointCommit) {
        Throw-PipelineError -Code 'git_head_changed' -Message 'Git HEAD differs from the migration checkpoint.' -Status blocked -Details ([PSCustomObject]@{ expected = $State.checkpointCommit; actual = $head })
    }
    $status = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    Assert-PipelineNoProtectedChanges -StatusItems $status
    if (-not $AllowDirty -and $status.Count -gt 0) {
        Throw-PipelineError -Code 'git_dirty' -Message 'The migration working tree must be clean before resuming.' -Status blocked -Details ([PSCustomObject]@{ paths = @($status.path) })
    }
}

function New-PipelineCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $status = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    Assert-PipelineNoProtectedChanges -StatusItems $status
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $preexisting = @{}
    if ($state.activeOperation -and $state.activeOperation.preexistingFiles) {
        foreach ($item in @(Get-PipelineOperationPreexistingItems -Operation $state.activeOperation)) { $preexisting[[string]$item.path] = $true }
    }
    $paths = @($status | Where-Object { -not $preexisting.ContainsKey($_.path) } | Select-Object -ExpandProperty path -Unique)
    if ($paths.Count -eq 0) { return Get-PipelineGitHead -ProjectRoot $ProjectRoot }
    $add = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments (@('add', '--') + $paths)
    if ($add.exitCode -ne 0) { Throw-PipelineError -Code 'checkpoint_add_failed' -Message 'Could not stage the exact migration paths.' -Status failed -Details $add.stderr }
    $commit = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('commit', '-m', $Message)
    if ($commit.exitCode -ne 0) { Throw-PipelineError -Code 'checkpoint_commit_failed' -Message 'Could not create the migration checkpoint.' -Status failed -Details $commit.stderr }
    return Get-PipelineGitHead -ProjectRoot $ProjectRoot
}

function Invoke-PipelineRollback {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$CheckpointCommit,
        [Parameter(Mandatory = $true)]$BeforeItems
    )

    $after = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $beforePaths = @($BeforeItems | Select-Object -ExpandProperty path -Unique)
    $beforeUntracked = @($BeforeItems | Where-Object untracked | Select-Object -ExpandProperty path -Unique)
    $beforePathMap = @{}
    foreach ($path in $beforePaths) { $beforePathMap[[string]$path] = $true }
    $trackedPaths = @($after | Where-Object { -not $_.untracked -and -not $beforePathMap.ContainsKey($_.path) } | Select-Object -ExpandProperty path -Unique)
    foreach ($path in $trackedPaths) {
        $restore = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('restore', '--source', $CheckpointCommit, '--staged', '--worktree', '--', $path)
        if ($restore.exitCode -ne 0) { Throw-PipelineError -Code 'rollback_failed' -Message "Could not restore tracked path: $path" -Status failed -Details $restore.stderr }
    }
    $beforeUntrackedMap = @{}
    foreach ($path in $beforeUntracked) { $beforeUntrackedMap[$path] = $true }
    foreach ($item in @($after | Where-Object untracked)) {
        if (-not $beforeUntrackedMap.ContainsKey($item.path)) {
            $fullPath = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path $item.path
            if (Test-Path -LiteralPath $fullPath -PathType Container) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
            elseif (Test-Path -LiteralPath $fullPath -PathType Leaf) { Remove-Item -LiteralPath $fullPath -Force }
        }
    }
    $remaining = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $remainingPaths = @($remaining | Select-Object -ExpandProperty path -Unique | Sort-Object)
    $expectedPaths = @($BeforeItems | Select-Object -ExpandProperty path -Unique | Sort-Object)
    if (($remainingPaths -join '|') -cne ($expectedPaths -join '|')) {
        Throw-PipelineError -Code 'rollback_failed' -Message 'Rollback did not restore the previous working tree inventory.' -Status failed -Details ([PSCustomObject]@{ expected = $expectedPaths; actual = $remainingPaths })
    }
}

function Get-PipelineLocalNg {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $path = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'node_modules/.bin/ng.cmd'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Throw-PipelineError -Code 'local_angular_cli_missing' -Message 'The project local Angular CLI was not found at node_modules/.bin/ng.cmd.' -Status blocked
    }
    return $path
}

function Get-PipelineResolvedDependencies {
    param([Parameter(Mandatory = $true)]$Manifest)
    return @($Manifest.dependencies | Sort-Object name)
}

function Get-PipelineAngularUpdateCommands {
    param([Parameter(Mandatory = $true)]$Manifest)

    $dependencies = @(Get-PipelineResolvedDependencies -Manifest $Manifest | Where-Object { $_.change -ne 'unchanged' })
    $core = @($dependencies | Where-Object name -eq '@angular/core' | Select-Object -First 1)
    $cli = @($dependencies | Where-Object name -eq '@angular/cli' | Select-Object -First 1)
    if ($core.Count -ne 1 -or $cli.Count -ne 1) {
        Throw-PipelineError -Code 'angular_cli_missing' -Message 'Resolved manifest must contain exact @angular/core and @angular/cli entries.' -Status blocked
    }
    $commands = @([PSCustomObject]@{ id = 'angular-core-cli'; arguments = @('update', "@angular/core@$($core[0].targetVersion)", "@angular/cli@$($cli[0].targetVersion)") })
    $official = @($dependencies | Where-Object { $_.name -like '@angular/*' -and $_.name -notin @('@angular/core', '@angular/cli') -and $null -ne $_.metadata.ngUpdate } | Sort-Object name)
    foreach ($dependency in $official) {
        $commands += [PSCustomObject]@{ id = $dependency.name; arguments = @('update', "$($dependency.name)@$($dependency.targetVersion)") }
    }
    $external = @($dependencies | Where-Object { $_.role -eq 'angular-aware-external' -and $null -ne $_.metadata.ngUpdate } | Sort-Object name)
    foreach ($dependency in $external) {
        $commands += [PSCustomObject]@{ id = $dependency.name; arguments = @('update', "$($dependency.name)@$($dependency.targetVersion)") }
    }
    return @($commands)
}

function Assert-PipelineManifestTargets {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$Manifest
    )

    try { $package = Get-ProjectPackage -ProjectRoot $ProjectRoot } catch { Throw-PipelineError -Code 'package_invalid' -Message 'package.json is invalid after migration.' -Status blocked }
    $angularNames = @($Manifest.dependencies | Where-Object { $_.name -like '@angular/*' } | Select-Object -ExpandProperty name)
    foreach ($name in $angularNames) {
        $entry = $Manifest.dependencies | Where-Object name -eq $name | Select-Object -First 1
        $section = Get-ProjectProperty -Object $package -Name $entry.section
        if ($null -eq $section -or -not $section.PSObject.Properties[$name]) { continue }
        $major = Get-VersionMajor -Spec ([string]$section.$name)
        if ($null -ne $major -and $major -gt [int]$Manifest.targetMajor) {
            Throw-PipelineError -Code 'angular_target_exceeded' -Message "Angular package exceeds target major: $name" -Status blocked
        }
    }
    try { Get-ProjectLockfile -ProjectRoot $ProjectRoot | Out-Null } catch { Throw-PipelineError -Code 'lockfile_invalid' -Message 'package-lock.json is invalid after Angular update.' -Status blocked }
    Assert-PipelineNoProtectedChanges -StatusItems @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
}

function Invoke-PipelineRenderer {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)][ValidateSet('exact', 'declared')][string]$Mode,
        [Parameter(Mandatory = $true)]$Dependencies
    )

    $node = Find-MigrationExecutable -Names @('node.exe', 'node')
    if (-not $node) { Throw-PipelineError -Code 'node_toolchain_missing' -Message 'node is required for package rendering.' -Status blocked }
    $helper = $script:PackageRendererPath
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        Throw-PipelineError -Code 'package_manifest_writer_missing' -Message 'The package manifest renderer is missing from the plugin.' -Status failed
    }
    $packagePath = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json' -MustExist
    $packageText = [IO.File]::ReadAllText($packagePath)
    $payload = [ordered]@{ mode = $Mode; packageText = $packageText; dependencies = @($Dependencies) }
    $inputText = $payload | ConvertTo-Json -Depth 50 -Compress
    $result = Invoke-PipelineLoggedProcess -RunPaths $RunPaths -Stage 'update-dependencies' -Prefix ('01-render-' + $Mode) -FilePath $node -Arguments @($helper) -WorkingDirectory $ProjectRoot -TimeoutSeconds 30 -StandardInput $inputText
    if ($result.exitCode -ne 0 -or $result.timedOut) {
        Throw-PipelineError -Code 'package_manifest_write_failed' -Message "package.json renderer failed in $Mode mode." -Status blocked -Details ([PSCustomObject]@{ stderrLog = $result.stderrLog; stdoutLog = $result.stdoutLog })
    }
    return [PSCustomObject]@{ text = $result.stdout; logs = $result }
}

function Get-PipelineVersionTuple {
    param([Parameter(Mandatory = $true)][string]$Version)

    $match = [regex]::Match($Version, '^([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if (-not $match.Success) { return @() }
    return @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Compare-PipelineVersionTuple {
    param(
        [Parameter(Mandatory = $true)][int[]]$Left,
        [Parameter(Mandatory = $true)][int[]]$Right
    )

    for ($index = 0; $index -lt 3; $index++) {
        if ($Left[$index] -lt $Right[$index]) { return -1 }
        if ($Left[$index] -gt $Right[$index]) { return 1 }
    }
    return 0
}

function Test-PipelineVersionSpec {
    param([Parameter(Mandatory = $true)][string]$Spec, [Parameter(Mandatory = $true)][string]$Version)

    $versionTuple = @(Get-PipelineVersionTuple -Version $Version)
    if ($versionTuple.Count -ne 3) { return $false }
    if ($Spec -eq $Version) { return $true }

    $match = [regex]::Match($Spec, '^\^([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if ($match.Success) {
        $baseTuple = @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
        $upperTuple = if ($baseTuple[0] -gt 0) {
            @(($baseTuple[0] + 1), 0, 0)
        }
        elseif ($baseTuple[1] -gt 0) {
            @(0, ($baseTuple[1] + 1), 0)
        }
        else {
            @(0, 0, ($baseTuple[2] + 1))
        }
        return (Compare-PipelineVersionTuple -Left $versionTuple -Right $baseTuple) -ge 0 -and
        (Compare-PipelineVersionTuple -Left $versionTuple -Right $upperTuple) -lt 0
    }

    $match = [regex]::Match($Spec, '^~([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if ($match.Success) {
        $baseTuple = @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
        $upperTuple = @($baseTuple[0], ($baseTuple[1] + 1), 0)
        return (Compare-PipelineVersionTuple -Left $versionTuple -Right $baseTuple) -ge 0 -and
        (Compare-PipelineVersionTuple -Left $versionTuple -Right $upperTuple) -lt 0
    }

    $match = [regex]::Match($Spec, '^>=([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if ($match.Success) {
        $baseTuple = @([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
        return (Compare-PipelineVersionTuple -Left $versionTuple -Right $baseTuple) -ge 0
    }

    $match = [regex]::Match($Spec, '^([0-9]+)\.(x|X|\*)$')
    if ($match.Success) { return $versionTuple[0] -eq [int]$match.Groups[1].Value }

    $match = [regex]::Match($Spec, '^([0-9]+)\.([0-9]+)\.(x|X|\*)$')
    if ($match.Success) {
        return $versionTuple[0] -eq [int]$match.Groups[1].Value -and $versionTuple[1] -eq [int]$match.Groups[2].Value
    }

    return $false
}

function Assert-PipelineDirectDependencyLock {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)]$Manifest)
    $lock = Get-ProjectLockfile -ProjectRoot $ProjectRoot
    foreach ($dependency in @($Manifest.dependencies)) {
        $locked = [string]$lock.versions[$dependency.name]
        if ($locked -cne [string]$dependency.targetVersion) {
            Throw-PipelineError -Code 'lockfile_resolution_mismatch' -Message "Lockfile version differs from manifest: $($dependency.name)" -Status blocked -Details ([PSCustomObject]@{ expected = $dependency.targetVersion; actual = $locked })
        }
    }
    return $lock
}

function Assert-PipelineDeclaredDependencies {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)]$Manifest)
    $package = Get-ProjectPackage -ProjectRoot $ProjectRoot
    $expected = @{}
    foreach ($dependency in @($Manifest.dependencies)) {
        $section = Get-ProjectProperty -Object $package -Name $dependency.section
        if ($dependency.change -eq 'added-required-tooling' -and $dependency.section -eq 'devDependencies') {
            if ($null -eq $section -or -not $section.PSObject.Properties[$dependency.name]) {
                Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Required tooling was not added to package.json: $($dependency.name)" -Status blocked
            }
            $expected[$dependency.name] = $dependency.section
            if (-not (Test-PipelineVersionSpec -Spec ([string]$section.$($dependency.name)) -Version ([string]$dependency.targetVersion))) {
                Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Declared spec does not admit locked version: $($dependency.name)" -Status blocked
            }
            continue
        }
        if ($null -eq $section -or -not $section.PSObject.Properties[$dependency.name]) {
            Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Manifest dependency is missing after rendering: $($dependency.name)" -Status blocked
        }
        $expected[$dependency.name] = $dependency.section
        if (-not (Test-PipelineVersionSpec -Spec ([string]$section.$($dependency.name)) -Version ([string]$dependency.targetVersion))) {
            Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Declared spec does not admit locked version: $($dependency.name)" -Status blocked
        }
    }
    foreach ($sectionName in $script:DependencySections) {
        $section = Get-ProjectProperty -Object $package -Name $sectionName
        if ($null -eq $section) { continue }
        foreach ($property in $section.PSObject.Properties) {
            if (-not $expected.ContainsKey($property.Name) -or $expected[$property.Name] -cne $sectionName) {
                Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Direct dependency was added or moved without a manifest decision: $($property.Name)" -Status blocked
            }
        }
    }
}

function Get-PipelineRepairPaths {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$CheckId,
        [string]$Output,
        [switch]$ConfigRepairAllowed
    )

    $paths = @()
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    foreach ($match in [regex]::Matches([string]$Output, '(?:^|[\s(])(src[\\/][a-zA-Z0-9_./\\-]+)(?::\d+(?::\d+)?)?')) {
        $candidate = $match.Groups[1].Value.TrimEnd('.', ',', ';')
        if ($candidate -notmatch '(^|[\\/])\.\.([\\/]|$)') {
            try { $paths += ConvertTo-PipelineRelativePath -ProjectRoot $root -Path $candidate } catch { }
        }
    }
    $configFiles = @('angular.json', 'tsconfig.json', 'tsconfig.app.json', 'tsconfig.spec.json', 'tsconfig.base.json', '.eslintrc.json', '.eslintrc.js', 'eslint.config.js', 'tslint.json', 'karma.conf.js', 'jest.config.js', 'browserslist', 'polyfills.ts')
    if ($Stage -eq 'update-angular' -and $ConfigRepairAllowed -and $Output -cmatch '(?<![\w/\\.-])angular\.json(?=[:\s(]|$)') { $paths += 'angular.json' }
    if ($Stage -ne 'update-angular') {
        if ($CheckId -notin @('typecheck', 'lint', 'test', 'unit-test', 'build', 'e2e')) { return @() }
        $paths += 'src/**/*'
        foreach ($file in $configFiles) {
            if ($Output -cmatch ('(?<![\w/\\.-])' + [regex]::Escape($file) + '(?=[:\s(]|$)')) { $paths += $file }
        }
    }
    $paths = @($paths | Where-Object { $_ -and $_ -notmatch '^(?:\.git|\.github|\.angular-migration|docs)(?:/|$)' -and $_ -notin @('package.json', 'package-lock.json', 'plugin.json') } | Sort-Object -Unique)
    return $paths
}

function New-PipelineFailureContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$RunPaths,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$CheckId,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Output,
        [int]$ExitCode = 1,
        [string[]]$LogFiles = @()
    )
    $runId = Split-Path -Leaf $RunPaths.root
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $runId
    $paths = @(Get-PipelineRepairPaths -ProjectRoot $ProjectRoot -Stage $Stage -CheckId $CheckId -Output $Output -ConfigRepairAllowed:$state.configRepairAllowed)
    $safeOutput = Protect-RepairText -Text $Output -Root $ProjectRoot
    $normalized = [regex]::Replace($safeOutput, '\b\d{4}[-/]\d{1,2}[-/]\d{1,2}[T\s][^\s]+|\b\d+(?:\.\d+)?\s*(?:ms|seconds)\b', '<time>')
    $normalized = [regex]::Replace($normalized, '\s+', ' ').Trim()
    $identity = [PSCustomObject]@{ stage = $Stage; check = $CheckId; exitCode = $ExitCode; diagnostic = $normalized; manifest = $state.manifestSha256 }
    $diagnosticHash = Get-PipelineObjectHash -Value $identity
    $fingerprint = 'sha256:' + (Get-PipelineObjectHash -Value ([PSCustomObject]@{ diagnostic = $identity; checkpoint = $state.checkpointCommit }))
    $attempt = 1
    if ($state.repair -and $state.repair.diagnosticHash -ceq $diagnosticHash) { $attempt = [int]$state.repair.context.attempt + 1 }
    if ($attempt -gt 3 -or $state.repairTotal -ge 5) {
        Throw-PipelineError -Code 'repair_attempts_exhausted' -Message 'Repair attempts are exhausted.' -Status blocked
    }
    $forbidden = @('.git/**', '.github/**', '.angular-migration/**', 'package.json', 'package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml', 'scripts/**', 'hooks.json', 'agents/**', 'docs/**', 'plugin.json', '**/.npmrc', '**/.env*', '**/*.pem', '**/*.key', '**/*.pfx', '**/*.p12')
    if ($paths -cnotcontains 'angular.json') { $forbidden += 'angular.json' }
    $logs = @()
    foreach ($log in $LogFiles) {
        if (-not $log) { continue }
        $relative = '.angular-migration/runs/' + $runId + '/' + $log.Replace('\', '/')
        $full = Resolve-RepairPath $ProjectRoot $relative
        $safeLog = Protect-RepairText -Text ([IO.File]::ReadAllText($full)) -Root $ProjectRoot
        Write-MigrationTextAtomic -Text $safeLog -Path $full
        $logs += $relative
    }
    $context = [PSCustomObject][ordered]@{
        schemaVersion = 1; runId = $runId; sourceMajor = $state.sourceMajor; targetMajor = $state.targetMajor
        status = 'needs-repair'; stage = $Stage; failedCheck = $CheckId; fingerprint = $fingerprint
        attempt = $attempt; maxAttempts = 3; checkpointCommit = $state.checkpointCommit; manifestSha256 = $state.manifestSha256
        allowedPaths = @($paths); forbiddenPaths = $forbidden
        diagnostic = [PSCustomObject]@{
            summary = Protect-RepairText -Text $Message -Root $ProjectRoot
            exitCode = $ExitCode; logFiles = $logs
            relatedFiles = @($paths | Where-Object { $_ -notmatch '\*' }); warnings = @()
        }
        submissionPath = '.angular-migration/runs/' + $runId + '/inbox/repair.json'
    }
    $before = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $tracked = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('ls-files', '-z')
    if ($tracked.exitCode -ne 0) { Throw-PipelineError -Code 'git_status_failed' -Message 'Cannot inventory repair files.' }
    $protected = @()
    foreach ($path in @($tracked.stdout -split [char]0 | Where-Object { $_ })) {
        $full = Resolve-RepairPath $ProjectRoot $path
        if (-not (Test-RepairAllowedPath $path $context) -or $path -in @($before | ForEach-Object { $_.path })) {
            $hash = if (Test-Path -LiteralPath $full -PathType Leaf) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash } else { $null }
            $protected += [PSCustomObject]@{ path = $path; hash = $hash }
        }
    }
    foreach ($item in $before | Where-Object untracked) {
        $full = Resolve-RepairPath $ProjectRoot $item.path
        $protected += [PSCustomObject]@{ path = $item.path; hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
    }
    $inbox = Resolve-RepairPath $ProjectRoot ('.angular-migration/runs/' + $runId + '/inbox')
    New-Item -ItemType Directory -Path $inbox -Force | Out-Null
    Write-MigrationJsonAtomic -Value @() -Path (Join-Path $inbox 'edit-inventory.json')
    $state.repair = [PSCustomObject]@{
        context = $context; diagnosticHash = $diagnosticHash; before = $before; protected = $protected
        accepted = $null; facadePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../angular-migration.ps1'))
    }
    $state.attempt = $attempt
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $runId -State $state
    Write-MigrationJsonAtomic -Value $context -Path (Join-Path $RunPaths.root 'failure-context.json')
    return $context
}

function Assert-RepairSchema {
    param($Value, $Schema)
    if ($null -eq $Value) { throw 'Invalid repair contract.' }
    switch ([string]$Schema.type) {
        'object' {
            if ($Value -isnot [PSCustomObject]) { throw 'Invalid repair object.' }
            $names = @($Value.PSObject.Properties.Name)
            if (@($names | Where-Object { $_ -cnotin @($Schema.properties.PSObject.Properties.Name) }).Count -gt 0) { throw 'Unknown repair property.' }
            foreach ($name in $Schema.required) { if ($names -cnotcontains $name) { throw 'Missing repair property.' } }
            foreach ($name in $names) { Assert-RepairSchema $Value.$name $Schema.properties.$name }
        }
        'array' {
            if ($Value -isnot [array]) { throw 'Invalid repair array.' }
            if ($Schema.PSObject.Properties['minItems'] -and $Value.Count -lt $Schema.minItems) { throw 'Empty repair array.' }
            foreach ($item in $Value) { Assert-RepairSchema $item $Schema.items }
        }
        'string' {
            if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw 'Empty repair string.' }
            if ($Schema.PSObject.Properties['pattern'] -and $Value -cnotmatch $Schema.pattern) { throw 'Invalid repair string.' }
        }
        'integer' {
            if ($Value -isnot [int] -and $Value -isnot [long]) { throw 'Invalid repair integer.' }
            if ($Schema.PSObject.Properties['minimum'] -and $Value -lt $Schema.minimum) { throw 'Invalid repair minimum.' }
            if ($Schema.PSObject.Properties['maximum'] -and $Value -gt $Schema.maximum) { throw 'Invalid repair maximum.' }
        }
        default { throw 'Unsupported repair schema.' }
    }
    if ($Schema.PSObject.Properties['const'] -and $Value -cne $Schema.const) { throw 'Invalid repair constant.' }
    if ($Schema.PSObject.Properties['enum'] -and $Value -cnotin $Schema.enum) { throw 'Invalid repair enum.' }
}

function Get-ValidatedRepairContext {
    param([string]$ProjectRoot, [string]$RunId)
    Assert-ActiveRunOwnership -ProjectRoot $ProjectRoot -RunId $RunId
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($state.status -cne 'needs-repair' -or -not $state.repair -or $state.repair.context.stage -cne $state.stage) {
        Throw-PipelineError -Code 'invalid_repair_stage' -Message 'Repair requires needs-repair and a controller context.' -Status blocked
    }
    if ($state.repair.context.runId -cne $RunId -or $state.repair.context.checkpointCommit -cne $state.checkpointCommit -or
        $state.repair.context.manifestSha256 -cne $state.manifestSha256 -or $state.repair.context.attempt -ne $state.attempt) {
        Throw-PipelineError -Code 'invalid_repair_context' -Message 'Repair context does not match current state.'
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path (Resolve-RepairPath $ProjectRoot $paths.manifest) -Required
    if (-not $state.manifestSha256 -or (Get-ResolvedManifestHash $manifest) -cne $state.manifestSha256 -or $manifest.manifestSha256 -cne $state.manifestSha256) {
        Throw-PipelineError -Code 'manifest_integrity_failed' -Message 'Repair manifest integrity failed.'
    }
    Assert-RepairSchema $state.repair.context (Read-MigrationJson -Path (Join-Path $PSScriptRoot '../../schemas/repair-context.schema.json') -Required)
    return $state.repair.context
}

function Invoke-MigrationRepairContext {
    param([string]$ProjectRoot, [string]$RunId)
    $context = Get-ValidatedRepairContext $ProjectRoot $RunId
    return [PSCustomObject]@{ ok = $true; status = 'needs-repair'; data = $context; error = $null }
}

function Undo-MigrationRepair {
    param([string]$ProjectRoot, $State)
    $context = $State.repair.context
    $beforePaths = @($State.repair.before | ForEach-Object { $_.path })
    $changes = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    foreach ($item in $changes | Where-Object { -not $_.untracked -and $_.path -notin $beforePaths }) {
        try { $null = Resolve-RepairPath $ProjectRoot $item.path } catch { continue }
        $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('restore', '--source', $context.checkpointCommit, '--staged', '--worktree', '--', $item.path)
        if ($result.exitCode -ne 0) { Throw-PipelineError -Code 'repair_rollback_failed' -Message 'Repair rollback requires manual review.' }
    }
    $inventoryPath = Resolve-RepairPath $ProjectRoot ('.angular-migration/runs/' + $State.runId + '/inbox/edit-inventory.json')
    $inventory = @(Read-MigrationJson -Path $inventoryPath)
    foreach ($item in $changes | Where-Object { $_.untracked -and $_.path -notin $beforePaths -and $_.path -cin $inventory }) {
        try { $full = Resolve-RepairPath $ProjectRoot $item.path } catch { continue }
        if (Test-RepairAllowedPath $item.path $context) { Remove-Item -LiteralPath $full -Force }
    }
}

function Invoke-MigrationRecordRepair {
    param([string]$ProjectRoot, [string]$RunId, [string]$InputFile)
    Assert-ActiveRunOwnership -ProjectRoot $ProjectRoot -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $leasePath = Resolve-RepairPath $ProjectRoot ('.angular-migration/runs/' + $RunId + '/record-repair.lock')
    $lease = $null
    try { $lease = [IO.File]::Open($leasePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { Throw-PipelineError -Code 'repair_process_not_owner' -Message 'Another process owns repair registration.' -Status blocked }
    $state = $null
    $scopeViolation = $false
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$PID)
        $lease.Write($bytes, 0, $bytes.Length)
        $lease.Flush($true)
        $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        if ($state.status -cne 'needs-repair' -or -not $state.repair) { Throw-PipelineError -Code 'invalid_repair_stage' -Message 'No active repair contract.' -Status blocked }
        $context = $state.repair.context
        if ($context.runId -cne $RunId -or $context.stage -cne $state.stage -or $context.attempt -ne $state.attempt) { throw 'Stale repair context.' }
        try {
            $expected = Resolve-RepairPath $ProjectRoot $context.submissionPath
            $inputPath = Resolve-RepairPath $ProjectRoot $InputFile
            if ($inputPath -cne $expected) { throw 'Invalid submission path.' }
        }
        catch { $scopeViolation = $true; throw }
        $report = Read-MigrationJson -Path $inputPath -Required
        if ($report.runId -cne $RunId -or $report.fingerprint -cne $context.fingerprint -or $report.attempt -ne $context.attempt) { throw 'Stale repair submission.' }
        $schema = Read-MigrationJson -Path (Join-Path $PSScriptRoot '../../schemas/repair-input.schema.json') -Required
        Assert-RepairSchema $report $schema
        try { $null = Get-ValidatedRepairContext $ProjectRoot $RunId } catch { $scopeViolation = $true; throw }
        if ((Get-PipelineGitHead $ProjectRoot) -cne $context.checkpointCommit) { $scopeViolation = $true; throw 'Repair HEAD changed.' }
        $changes = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
        $before = @($state.repair.before | ForEach-Object { $_.path })
        $actual = @($changes | Where-Object { $_.path -notin $before } | ForEach-Object { $_.path } | Sort-Object -Unique)
        foreach ($path in $actual) {
            try { $null = Resolve-RepairPath $ProjectRoot $path } catch { $scopeViolation = $true; throw }
            if (-not (Test-RepairAllowedPath $path $context)) { $scopeViolation = $true; throw 'Repair scope violation.' }
        }
        $declared = @($report.changes | ForEach-Object { $_.path } | Sort-Object -Unique)
        foreach ($path in $declared) {
            try { $null = Resolve-RepairPath $ProjectRoot $path } catch { $scopeViolation = $true; throw }
        }
        if ($actual.Count -eq 0 -or ($actual -join "`n") -cne ($declared -join "`n") -or $declared.Count -ne @($report.changes).Count) { throw 'Repair diff does not match report.' }
        $raw = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('diff', '--raw', '--no-abbrev', '--no-renames', 'HEAD')
        if ($raw.exitCode -ne 0) { throw 'Repair diff unavailable.' }
        foreach ($line in $raw.stdout -split "`n") {
            if ($line -match '^:(\d{6}) (\d{6}) ') {
                if ($Matches[1] -in @('120000', '160000') -or $Matches[2] -in @('120000', '160000') -or
                    ($Matches[1] -ne '000000' -and $Matches[2] -ne '000000' -and $Matches[1] -ne $Matches[2])) { $scopeViolation = $true; throw 'Repair mode or link changed.' }
            }
        }
        foreach ($protected in $state.repair.protected) {
            try { $full = Resolve-RepairPath $ProjectRoot $protected.path } catch { $scopeViolation = $true; throw }
            $hash = if (Test-Path -LiteralPath $full -PathType Leaf) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash } else { $null }
            if ($hash -cne $protected.hash) { $scopeViolation = $true; throw 'Protected repair file changed.' }
        }
        $runtime = Resolve-RepairPath $ProjectRoot '.angular-migration/runtime/copilot-policy.ps1'
        if ((Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant() -cne $state.runtimeSha256) { $scopeViolation = $true; throw 'Repair runtime changed.' }
        foreach ($evidence in $report.evidence) {
            if ($evidence.reference -cnotin $context.diagnostic.logFiles) { throw 'Unknown repair evidence.' }
        }
        if ($context.attempt -gt 3 -or $state.repairTotal -ge 5) { throw 'Repair attempts exhausted.' }
        $reportText = [IO.File]::ReadAllText($inputPath)
        if ((Protect-RepairText -Text $reportText -Root $ProjectRoot) -cne $reportText) { throw 'Repair submission contains sensitive data.' }
        $archiveName = $context.fingerprint.Substring(7) + '-attempt-' + $context.attempt + '.json'
        $archive = Resolve-RepairPath $ProjectRoot ('.angular-migration/runs/' + $RunId + '/repairs/' + $archiveName)
        New-Item -ItemType Directory -Path (Split-Path -Parent $archive) -Force | Out-Null
        $archiveFilePath = if ($archive.Length -ge 248 -and $archive -match '^[A-Za-z]:\\') { '\\?\' + $archive } else { $archive }
        Move-Item -LiteralPath $inputPath -Destination $archiveFilePath -ErrorAction Stop
        $add = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments (@('add', '--') + $actual)
        if ($add.exitCode -ne 0) { throw 'Cannot stage repair.' }
        $commit = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments (@('-c', 'core.hooksPath=NUL', 'commit', '--only', '-m', "chore(angular-migration): repair $($context.failedCheck) attempt $($context.attempt)", '--') + $actual)
        if ($commit.exitCode -ne 0) { throw 'Cannot commit repair.' }
        $accepted = [PSCustomObject]@{
            fingerprint = $context.fingerprint; attempt = $context.attempt; commit = Get-PipelineGitHead $ProjectRoot
            report = '.angular-migration/runs/' + $RunId + '/repairs/' + $archiveName
            reportSha256 = (Get-FileHash -LiteralPath $archiveFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $state.repair.accepted = $accepted
        $state.repairTotal = [int]$state.repairTotal + 1
        $state.repairs = @($state.repairs) + $accepted
        $state.checkpointCommit = $accepted.commit
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'repair-accepted' -Stage $state.stage -Data $accepted
        $null = Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'needs-repair' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus running -NewStage $state.stage
        return [PSCustomObject]@{ ok = $true; status = 'running'; data = [PSCustomObject]@{ runId = $RunId; nextAction = 'rerun-failed-check'; repair = $accepted }; error = $null }
    }
    catch {
        if ($state -and $state.status -eq 'needs-repair' -and $state.repair) {
            $rollbackFailed = $false
            try { Undo-MigrationRepair $ProjectRoot $state } catch { $rollbackFailed = $true }
            Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'repair-rejected' -Stage $state.stage -Data ([PSCustomObject]@{ fingerprint = $state.repair.context.fingerprint; attempt = $state.repair.context.attempt; scopeViolation = $scopeViolation; rollbackFailed = $rollbackFailed })
            $state.repairTotal = [int]$state.repairTotal + 1
            $status = 'needs-repair'
            $code = 'repair_rejected'
            if ($scopeViolation -or $rollbackFailed) { $status = 'failed'; $code = if ($scopeViolation) { 'repair_scope_violation' } else { 'repair_rollback_failed' } }
            elseif ($state.attempt -ge 3 -or $state.repairTotal -ge 5) { $status = 'blocked'; $code = 'repair_attempts_exhausted' }
            else { $state.attempt++; $state.repair.context.attempt = $state.attempt }
            Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
            $diagnostic = [PSCustomObject]@{ code = $code; message = 'Repair was rejected by the controller.'; details = $null }
            if ($status -ne 'needs-repair') {
                $null = Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'needs-repair' -ExpectedStage $state.stage -ExpectedRevision $state.stageRevision -NewStatus $status -NewStage $state.stage -Diagnostic $diagnostic
                Remove-ActiveRunLock -ProjectRoot $ProjectRoot -RunId $RunId
            }
            return [PSCustomObject]@{ ok = $false; status = $status; data = @{}; error = $diagnostic }
        }
        throw
    }
    finally {
        if ($lease) { $lease.Dispose(); Remove-Item -LiteralPath $leasePath -Force }
    }
}

function ConvertTo-PipelineCanonicalValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('o') }
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) { $ordered[$key] = ConvertTo-PipelineCanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) { return @($Value | ForEach-Object { ConvertTo-PipelineCanonicalValue $_ }) }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -gt 0 -and $Value -isnot [ValueType] -and $Value -isnot [string]) {
        $ordered = [ordered]@{}
        foreach ($property in @($properties | Sort-Object Name)) { $ordered[$property.Name] = ConvertTo-PipelineCanonicalValue $property.Value }
        return $ordered
    }
    return $Value
}

function Get-PipelineObjectHash {
    param([Parameter(Mandatory = $true)]$Value, [string]$ExcludedProperty)
    $canonical = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Where-Object { $_.Name -cne $ExcludedProperty } | Sort-Object Name)) {
        $canonical[$property.Name] = ConvertTo-PipelineCanonicalValue $property.Value
    }
    $json = $canonical | ConvertTo-Json -Depth 100 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($json)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Get-PipelineChangedFiles {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$InitialCommit)
    $result = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('diff', '--name-only', "$InitialCommit..HEAD")
    if ($result.exitCode -ne 0) { Throw-PipelineError -Code 'git_status_failed' -Message 'Could not calculate changed migration files.' -Status failed }
    return @($result.stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { ConvertTo-PipelineRelativePath -ProjectRoot $ProjectRoot -Path $_ } | Sort-Object -Unique)
}

function Assert-PipelineTechnicalResult {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$RunPaths
    )

    $result = Read-MigrationJson -Path $RunPaths.result -Required
    if ($result.schemaVersion -ne (Get-MigrationSchemaVersion) -or $result.runId -cne $RunId -or $result.status -cne 'verified') {
        Throw-PipelineError -Code 'result_integrity_failed' -Message 'Technical result contract is invalid.' -Status failed
    }
    if ($result.resultSha256 -notmatch '^[0-9a-f]{64}$' -or $result.resultSha256 -cne (Get-PipelineObjectHash -Value $result -ExcludedProperty 'resultSha256')) {
        Throw-PipelineError -Code 'result_integrity_failed' -Message 'Technical result has been altered.' -Status failed
    }
    return $result
}

function Write-PipelineTechnicalResult {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$CheckResults,
        [Parameter(Mandatory = $true)]$RunPaths
    )
    $existing = Read-MigrationJson -Path $RunPaths.result
    if ($existing) {
        return Assert-PipelineTechnicalResult -ProjectRoot $ProjectRoot -RunId $RunId -RunPaths $RunPaths
    }
    $dependencyChanges = @($Manifest.dependencies | Where-Object { $_.change -ne 'unchanged' } | ForEach-Object {
            [PSCustomObject]@{ name = $_.name; section = $_.section; from = $_.currentVersion; to = $_.targetVersion; change = $_.change; writeSpec = $_.writeSpec }
        })
    $result = [ordered]@{
        schemaVersion        = Get-MigrationSchemaVersion
        runId                = $RunId
        sourceMajor          = $Manifest.sourceMajor
        targetMajor          = $Manifest.targetMajor
        status               = 'verified'
        migrationStatus      = 'verified'
        documentationStatus  = 'pending'
        manifestSha256       = $Manifest.manifestSha256
        initialCommit        = (Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId).initialCommit
        finalTechnicalCommit = Get-PipelineGitHead -ProjectRoot $ProjectRoot
        changedFiles         = @(Get-PipelineChangedFiles -ProjectRoot $ProjectRoot -InitialCommit ((Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId).initialCommit))
        dependencyChanges    = $dependencyChanges
        checks               = @($CheckResults)
        repairs              = @((Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId).repairs)
        warnings             = @($Manifest.warnings)
        verifiedAt           = Get-MigrationUtcNow
    }
    $resultObject = [PSCustomObject]$result
    $result.resultSha256 = Get-PipelineObjectHash -Value $resultObject -ExcludedProperty 'resultSha256'
    Write-MigrationJsonAtomic -Value ([PSCustomObject]$result) -Path $RunPaths.result
    $published = Read-MigrationJson -Path $RunPaths.result -Required
    if ($published.resultSha256 -ne (Get-PipelineObjectHash -Value $published -ExcludedProperty 'resultSha256')) {
        Throw-PipelineError -Code 'result_integrity_failed' -Message 'Technical result failed its integrity check.' -Status failed
    }
    return $published
}

function Invoke-PipelineBaselineStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('baseline' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'baseline' -NewStatus 'running' -NewStage 'resolve' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'baseline' -Stage 'baseline'
    $baseline = Invoke-MigrationBaseline -ProjectRoot $ProjectRoot -RunId $RunId
    if ($baseline.status -ne 'passed') {
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'baseline' -Data ([PSCustomObject]@{ status = $baseline.status; diagnostic = $baseline.diagnostic; logs = @($baseline.checks | ForEach-Object { $_.stdoutLog; $_.stderrLog }) })
        Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
        $status = if ($baseline.status -eq 'failed') { 'failed' } else { 'blocked' }
        Throw-PipelineError -Code ([string]$baseline.diagnostic.code) -Message 'Baseline checks did not pass.' -Status $status -Details $baseline.diagnostic
    }
    Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'baseline' -Data ([PSCustomObject]@{ status = 'passed'; logs = @($baseline.checks | ForEach-Object { $_.stdoutLog; $_.stderrLog }) })
    $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'baseline' -Stage 'baseline'
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'baseline' -NewStatus 'running' -NewStage 'resolve' -ExpectedRevision $state.stageRevision | Out-Null
}

function Invoke-PipelineResolveStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    if ('resolve-manifest' -notin @($state.completedOperations)) {
        $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'resolve-manifest' -Stage 'resolve'
        $resolution = Invoke-MigrationResolution -ProjectRoot $ProjectRoot -RunId $RunId
        if ($resolution.status -ne 'resolved') {
            Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'resolve' -Data ([PSCustomObject]@{ status = $resolution.status; diagnostic = $resolution.diagnostic; logs = @($resolution.queryEvents | ForEach-Object { $_.stdoutLog; $_.stderrLog }) })
            Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
            $status = if ($resolution.status -eq 'failed') { 'failed' } else { 'blocked' }
            Throw-PipelineError -Code ([string]$resolution.diagnostic.code) -Message 'Dependency resolution did not complete.' -Status $status -Details $resolution.diagnostic
        }
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'resolve' -Data ([PSCustomObject]@{ status = 'resolved'; logs = @($resolution.queryEvents | ForEach-Object { $_.stdoutLog; $_.stderrLog }) })
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'resolve-manifest' -Stage 'resolve'
    }
    else { $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId }
    if ('create-branch' -notin @($state.completedOperations)) {
        $suffix = $RunId.Substring($RunId.Length - 8)
        if ($suffix -notmatch '^[a-f0-9]{8}$') { Throw-PipelineError -Code 'invalid_run_id' -Message 'Run id suffix cannot form a migration branch.' -Status blocked }
        $branch = "migration/angular-$($state.sourceMajor)-to-$($state.targetMajor)-$suffix"
        if ($branch -notmatch '^migration/angular-[0-9]+-to-[0-9]+-[a-f0-9]{8}$') { Throw-PipelineError -Code 'invalid_migration_branch' -Message 'Migration branch name is invalid.' -Status blocked }
        $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'create-branch' -Stage 'resolve'
        $exists = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch")
        if ($exists.exitCode -eq 0) {
            Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
            Throw-PipelineError -Code 'migration_branch_exists' -Message "Migration branch already exists: $branch" -Status blocked
        }
        $switch = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('switch', '-c', $branch, $state.initialCommit)
        if ($switch.exitCode -ne 0 -and $switch.stderr -match '(?i)(unknown|not a git command|not available|unsupported).*switch') {
            $switch = Invoke-PipelineGit -ProjectRoot $ProjectRoot -Arguments @('checkout', '-b', $branch, $state.initialCommit)
        }
        if ($switch.exitCode -ne 0) {
            Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
            Throw-PipelineError -Code 'migration_branch_create_failed' -Message 'Could not create the migration branch.' -Status failed -Details $switch.stderr
        }
        $head = Get-PipelineGitHead -ProjectRoot $ProjectRoot
        if ($head -cne $state.initialCommit) { Throw-PipelineError -Code 'git_head_changed' -Message 'Migration branch does not point to the initial commit.' -Status blocked }
        $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        $state.migrationBranch = $branch
        $state.checkpointCommit = $head
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'resolve' -Data ([PSCustomObject]@{ status = 'passed'; exitCode = $switch.exitCode; timedOut = $false; durationMs = 0; migrationBranch = $branch; newCommit = $head })
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'create-branch' -Stage 'resolve' -CheckpointCommit $head
    }
    else { $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId }
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'resolve' -NewStatus 'running' -NewStage 'update-angular' -ExpectedRevision $state.stageRevision | Out-Null
}

function Invoke-PipelineAngularStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('update-angular' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'update-angular' -NewStatus 'running' -NewStage 'update-dependencies' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    $expectedHash = Get-ResolvedManifestHash -Manifest $manifest
    if ($manifest.manifestSha256 -ne $state.manifestSha256 -or $expectedHash -ne $state.manifestSha256) { Throw-PipelineError -Code 'manifest_integrity_failed' -Message 'Resolved manifest integrity failed before Angular update.' -Status failed }
    $ng = Get-PipelineLocalNg -ProjectRoot $ProjectRoot
    $before = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'update-angular' -Stage 'update-angular'
    $commandResults = @()
    try {
        $commands = Get-PipelineAngularUpdateCommands -Manifest $manifest
        $index = 0
        foreach ($command in $commands) {
            $index++
            if ($index -le $state.angularCommandIndex) { continue }
            $commandResults += Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'update-angular' -Prefix ('{0:D2}-{1}' -f $index, ($command.id -replace '[^a-zA-Z0-9._-]', '_')) -FilePath $ng -Arguments $command.arguments -WorkingDirectory $ProjectRoot -TimeoutSeconds 1800
            $last = $commandResults[-1]
            if ($last.timedOut -or $last.exitCode -ne 0) {
                Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
                Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'update-angular' -Data ([PSCustomObject]@{ status = 'failed'; exitCode = $last.exitCode; timedOut = $last.timedOut; durationMs = $last.durationMs; stdoutLog = $last.stdoutLog; stderrLog = $last.stderrLog })
                Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
                $blocked = [string]$last.stderr + "`n" + [string]$last.stdout
                if ($blocked -match '(?i)(ERESOLVE|peer depend|conflict|integrity|version)') { Throw-PipelineError -Code 'angular_update_conflict' -Message 'Angular update encountered a dependency or version conflict.' -Status blocked -Details $last }
                $context = New-PipelineFailureContext -ProjectRoot $ProjectRoot -RunPaths $paths -Stage 'update-angular' -CheckId $command.id -Code 'angular_update_failed' -Message 'Angular update failed.' -Output $blocked -ExitCode $last.exitCode -LogFiles @($last.stdoutLog, $last.stderrLog)
                if (@($context.allowedPaths).Count -eq 0) { Throw-PipelineError -Code 'repair_scope_unknown' -Message 'Angular update failure has no safe repair scope.' -Status blocked -Details $context }
                Throw-PipelineError -Code 'angular_update_failed' -Message 'Angular update requires a scoped repair.' -Status needs-repair -Details $context
            }
            Assert-PipelineManifestTargets -ProjectRoot $ProjectRoot -Manifest $manifest
            $checkpoint = New-PipelineCheckpoint -ProjectRoot $ProjectRoot -RunId $RunId -Message "chore(migration): Angular $($state.sourceMajor) to $($state.targetMajor) schematics [$RunId]"
            $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
            $state.checkpointCommit = $checkpoint
            $state.angularCommandIndex = $index
            $state.activeOperation.checkpointCommit = $checkpoint
            Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
        }
        Assert-PipelineManifestTargets -ProjectRoot $ProjectRoot -Manifest $manifest
        $checkpoint = New-PipelineCheckpoint -ProjectRoot $ProjectRoot -RunId $RunId -Message "chore(migration): Angular $($state.sourceMajor) to $($state.targetMajor) schematics [$RunId]"
        $summary = [PSCustomObject]@{ status = 'passed'; exitCode = 0; timedOut = $false; durationMs = ($commandResults | Measure-Object -Property durationMs -Sum).Sum; logs = @($commandResults | ForEach-Object { $_.stdoutLog; $_.stderrLog }); newCommit = $checkpoint }
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'update-angular' -Data $summary
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'update-angular' -Stage 'update-angular' -CheckpointCommit $checkpoint
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'update-angular' -NewStatus 'running' -NewStage 'update-dependencies' -ExpectedRevision $state.stageRevision | Out-Null
    }
    catch {
        $failure = $_
        $current = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        if ($current.activeOperation) {
            Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        }
        throw $failure
    }
}

function Invoke-PipelineDependencyStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('update-dependencies' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'update-dependencies' -NewStatus 'running' -NewStage 'install' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    if ($manifest.manifestSha256 -ne $state.manifestSha256 -or (Get-ResolvedManifestHash -Manifest $manifest) -ne $state.manifestSha256) { Throw-PipelineError -Code 'manifest_integrity_failed' -Message 'Resolved manifest integrity failed before dependency update.' -Status failed }
    $dependencies = @(Get-PipelineResolvedDependencies -Manifest $manifest)
    $package = Get-ProjectPackage -ProjectRoot $ProjectRoot
    foreach ($dependency in $dependencies) {
        $section = Get-ProjectProperty -Object $package -Name $dependency.section
        if ($dependency.change -eq 'added-required-tooling' -and $dependency.section -eq 'devDependencies') { continue }
        if ($null -eq $section -or -not $section.PSObject.Properties[$dependency.name]) { Throw-PipelineError -Code 'dependency_manifest_mismatch' -Message "Dependency is absent from package.json: $($dependency.name)" -Status blocked }
    }
    $before = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'update-dependencies' -Stage 'update-dependencies'
    try {
        $exact = Invoke-PipelineRenderer -ProjectRoot $ProjectRoot -RunPaths $paths -Mode 'exact' -Dependencies $dependencies
        Write-MigrationTextAtomic -Text $exact.text -Path (Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json')
        $nodeInfo = Get-ProjectNode -ProjectRoot $ProjectRoot
        if (-not $nodeInfo.npm.available) { Throw-PipelineError -Code 'node_toolchain_missing' -Message 'npm is unavailable for dependency update.' -Status blocked }
        $install = Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'update-dependencies' -Prefix '02-npm-install-lockfile' -FilePath $nodeInfo.npm.executable -Arguments @('install', '--package-lock-only') -WorkingDirectory $ProjectRoot -TimeoutSeconds 900
        if ($install.timedOut -or $install.exitCode -ne 0) {
            Throw-PipelineError -Code 'dependency_install_failed' -Message 'npm install --package-lock-only failed.' -Status blocked -Details $install
        }
        $null = Assert-PipelineDirectDependencyLock -ProjectRoot $ProjectRoot -Manifest $manifest
        $declared = Invoke-PipelineRenderer -ProjectRoot $ProjectRoot -RunPaths $paths -Mode 'declared' -Dependencies $dependencies
        Write-MigrationTextAtomic -Text $declared.text -Path (Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json')
        Assert-PipelineDirectDependencyLock -ProjectRoot $ProjectRoot -Manifest $manifest | Out-Null
        Assert-PipelineDeclaredDependencies -ProjectRoot $ProjectRoot -Manifest $manifest
        $checkpoint = New-PipelineCheckpoint -ProjectRoot $ProjectRoot -RunId $RunId -Message "chore(migration): align dependencies for Angular $($state.targetMajor) [$RunId]"
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'update-dependencies' -Data ([PSCustomObject]@{ status = 'passed'; exitCode = $install.exitCode; timedOut = $install.timedOut; durationMs = $install.durationMs; stdoutLog = $install.stdoutLog; stderrLog = $install.stderrLog; newCommit = $checkpoint })
        $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'update-dependencies' -Stage 'update-dependencies' -CheckpointCommit $checkpoint
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'update-dependencies' -NewStatus 'running' -NewStage 'install' -ExpectedRevision $state.stageRevision | Out-Null
    }
    catch {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        throw
    }
}

function Invoke-PipelineInstallStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('install' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'install' -NewStatus 'running' -NewStage 'validate' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $packagePath = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json' -MustExist
    $lockPath = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package-lock.json' -MustExist
    $packageHash = (Get-FileHash $packagePath).Hash
    $lockHash = (Get-FileHash $lockPath).Hash
    $nodeInfo = Get-ProjectNode -ProjectRoot $ProjectRoot
    if (-not $nodeInfo.npm.available) { Throw-PipelineError -Code 'node_toolchain_missing' -Message 'npm is unavailable for install.' -Status blocked }
    $before = @(Get-PipelineGitStatus -ProjectRoot $ProjectRoot)
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'install' -Stage 'install'
    try {
        $ci = Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'install' -Prefix '01-npm-ci' -FilePath $nodeInfo.npm.executable -Arguments @('ci') -WorkingDirectory $ProjectRoot -TimeoutSeconds 900
    }
    catch {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        throw
    }
    if ($ci.timedOut -or $ci.exitCode -ne 0) {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'install' -Data ([PSCustomObject]@{ status = 'blocked'; exitCode = $ci.exitCode; timedOut = $ci.timedOut; durationMs = $ci.durationMs; stdoutLog = $ci.stdoutLog; stderrLog = $ci.stderrLog })
        Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
        Throw-PipelineError -Code 'dependency_install_failed' -Message 'npm ci failed.' -Status blocked -Details $ci
    }
    if ((Get-FileHash $packagePath).Hash -ne $packageHash -or (Get-FileHash $lockPath).Hash -ne $lockHash) {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        Throw-PipelineError -Code 'dependency_install_failed' -Message 'npm ci modified package metadata.' -Status blocked
    }
    try {
        $ls = Invoke-PipelineLoggedProcess -RunPaths $paths -Stage 'install' -Prefix '02-npm-ls-all' -FilePath $nodeInfo.npm.executable -Arguments @('ls', '--all') -WorkingDirectory $ProjectRoot -TimeoutSeconds 300
    }
    catch {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        throw
    }
    if ($ls.timedOut -or $ls.exitCode -ne 0 -or ([string]$ls.stdout + "`n" + [string]$ls.stderr) -match '(?i)\b(invalid|extraneous|missing)\b') {
        Invoke-PipelineRollback -ProjectRoot $ProjectRoot -CheckpointCommit $state.checkpointCommit -BeforeItems $before
        Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'install' -Data ([PSCustomObject]@{ status = 'blocked'; exitCode = $ls.exitCode; timedOut = $ls.timedOut; durationMs = $ls.durationMs; stdoutLog = $ls.stdoutLog; stderrLog = $ls.stderrLog })
        Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
        Throw-PipelineError -Code 'dependency_install_failed' -Message 'npm ls --all reported an invalid dependency tree.' -Status blocked -Details $ls
    }
    Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'install' -Data ([PSCustomObject]@{ status = 'passed'; exitCode = $ls.exitCode; timedOut = $ls.timedOut; durationMs = $ls.durationMs; stdoutLog = $ls.stdoutLog; stderrLog = $ls.stderrLog })
    $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'install' -Stage 'install'
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'install' -NewStatus 'running' -NewStage 'validate' -ExpectedRevision $state.stageRevision | Out-Null
}

function Invoke-PipelineValidationStage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ('validate' -in @($state.completedOperations) -and 'technical-result' -in @($state.completedOperations)) {
        Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'validate' -NewStatus 'verified' -NewStage 'document' -ExpectedRevision $state.stageRevision | Out-Null
        return
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId
    $manifest = Read-MigrationJson -Path $paths.manifest -Required
    $null = Start-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'validate' -Stage 'validate'
    $results = @($state.validationResults)
    foreach ($check in @($manifest.checks | Where-Object { $_.id -in $script:TechnicalCheckIds })) {
        if ($check.id -in @($results | ForEach-Object { $_.id })) { continue }
        if ($check.status -eq 'not-configured') {
            $results += [PSCustomObject]@{
                id = $check.id; status = 'not-configured'; exitCode = $null; timedOut = $false
                startedAt = $null; finishedAt = $null; durationMs = 0
                stdoutLog = $null; stderrLog = $null; diagnosticSummary = $check.reason
                executable = $null
            }
            continue
        }
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'check-started' -Stage 'validate' -Data ([PSCustomObject]@{ checkId = $check.id })
        $result = Invoke-ProjectCheck -Check $check -LogDirectory (Join-Path $paths.logs 'validate')
        $results += $result
        Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'check-finished' -Stage 'validate' -Data $result
        if ($result.status -notin @('passed', 'not-configured')) {
            $output = ''
            if ($result.stdoutLog) { $output += [IO.File]::ReadAllText((Join-Path $paths.root $result.stdoutLog)) }
            if ($result.stderrLog) { $output += "`n" + [IO.File]::ReadAllText((Join-Path $paths.root $result.stderrLog)) }
            Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'validate' -Data ([PSCustomObject]@{ status = $result.status; exitCode = $result.exitCode; timedOut = $result.timedOut; stdoutLog = $result.stdoutLog; stderrLog = $result.stderrLog })
            Clear-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId | Out-Null
            $context = New-PipelineFailureContext -ProjectRoot $ProjectRoot -RunPaths $paths -Stage 'validate' -CheckId $result.id -Code 'validation_failed' -Message $result.diagnosticSummary -Output $output -ExitCode $result.exitCode -LogFiles @($result.stdoutLog, $result.stderrLog)
            if (@($context.allowedPaths).Count -eq 0) { Throw-PipelineError -Code 'repair_scope_unknown' -Message 'Validation failure has no safe repair scope.' -Status blocked -Details $context }
            Throw-PipelineError -Code 'validation_failed' -Message "Validation check failed: $($result.id)" -Status needs-repair -Details ([PSCustomObject]@{ context = $context; check = $result })
        }
        $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
        $state.validationResults = @($results)
        Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    }
    Finish-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Stage 'validate' -Data ([PSCustomObject]@{ status = 'passed'; checks = @($results) })
    $state = Complete-PipelineOperation -ProjectRoot $ProjectRoot -RunId $RunId -Id 'validate' -Stage 'validate'
    $state.migrationStatus = 'verified'
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    $result = Write-PipelineTechnicalResult -ProjectRoot $ProjectRoot -RunId $RunId -Manifest $manifest -CheckResults $results -RunPaths $paths
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $state.completedOperations = @($state.completedOperations) + @('technical-result')
    Write-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId -State $state
    Add-MigrationEvent -ProjectRoot $ProjectRoot -RunId $RunId -Type 'technical-result-written' -Stage 'validate' -Data ([PSCustomObject]@{ resultSha256 = $result.resultSha256 })
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    Move-MigrationState -ProjectRoot $ProjectRoot -RunId $RunId -ExpectedStatus 'running' -ExpectedStage 'validate' -NewStatus 'verified' -NewStage 'document' -ExpectedRevision $state.stageRevision | Out-Null
}

function ConvertTo-PipelineRunEnvelope {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $state = Read-MigrationRunState -ProjectRoot $ProjectRoot -RunId $RunId
    $data = [ordered]@{
        runId                       = $state.runId
        status                      = $state.status
        stage                       = $state.stage
        stageRevision               = $state.stageRevision
        attempt                     = $state.attempt
        migrationStatus             = $state.migrationStatus
        documentationStatus         = $state.documentationStatus
        completedOperations         = @($state.completedOperations)
        documentationReady          = $state.status -eq 'verified'
        documentationContextCommand = if ($state.status -eq 'verified') { 'documentation-context' } else { $null }
        manifest                    = '.angular-migration/runs/' + $RunId + '/manifest.json'
        state                       = '.angular-migration/runs/' + $RunId + '/state.json'
        result                      = if (Test-Path -LiteralPath (Get-MigrationRunPaths -ProjectRoot $ProjectRoot -RunId $RunId).result -PathType Leaf) { '.angular-migration/runs/' + $RunId + '/result.json' } else { $null }
    }
    return [PSCustomObject]@{ ok = $state.status -eq 'verified'; status = $state.status; data = [PSCustomObject]$data; error = if ($state.lastDiagnostic) { $state.lastDiagnostic } else { $null } }
}

function Invoke-MigrationRun {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$RunId = ''
    )

    try {
        if ([string]::IsNullOrWhiteSpace($RunId)) { Throw-MigrationError -Code 'run_id_required' -Message '-RunId is required for run.' -Status blocked }
        Assert-MigrationRunId -RunId $RunId
        $root = Resolve-MigrationRoot -Path $ProjectRoot
        Assert-ActiveRunOwnership -ProjectRoot $root -RunId $RunId
        $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId
        $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
        $manifest = Read-MigrationJson -Path $paths.manifest -Required
        if ($manifest.runId -cne $RunId -or $manifest.project.root -cne $root -or $manifest.sourceMajor -ne $state.sourceMajor -or $manifest.targetMajor -ne $state.targetMajor) {
            Throw-PipelineError -Code 'invalid_run_manifest' -Message 'Manifest and state do not describe the same run.' -Status failed
        }
        if ($state.manifestSha256) {
            if ($manifest.manifestSha256 -ne $state.manifestSha256 -or (Get-ResolvedManifestHash -Manifest $manifest) -ne $state.manifestSha256) {
                Throw-PipelineError -Code 'manifest_integrity_failed' -Message 'Resolved migration manifest has been altered.' -Status failed
            }
        }
        if ($state.status -in @('verified', 'completed')) {
            Assert-PipelineTechnicalResult -ProjectRoot $root -RunId $RunId -RunPaths $paths | Out-Null
            return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId
        }
        if ($state.status -in @('needs-repair', 'blocked', 'failed')) { return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId }
        $state = Invoke-PipelineActiveOperationRecovery -ProjectRoot $root -RunId $RunId
        if ($state.status -in @('blocked', 'failed')) { return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId }
        Assert-PipelineRunGitContext -ProjectRoot $root -State $state
        while ($true) {
            $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
            if ($state.status -ne 'running') { break }
            Assert-PipelineRunGitContext -ProjectRoot $root -State $state
            switch ($state.stage) {
                'baseline' { Invoke-PipelineBaselineStage -ProjectRoot $root -RunId $RunId }
                'resolve' { Invoke-PipelineResolveStage -ProjectRoot $root -RunId $RunId }
                'update-angular' { Invoke-PipelineAngularStage -ProjectRoot $root -RunId $RunId }
                'update-dependencies' { Invoke-PipelineDependencyStage -ProjectRoot $root -RunId $RunId }
                'install' { Invoke-PipelineInstallStage -ProjectRoot $root -RunId $RunId }
                'validate' { Invoke-PipelineValidationStage -ProjectRoot $root -RunId $RunId }
                default { Throw-PipelineError -Code 'invalid_stage' -Message "Unknown migration stage: $($state.stage)" -Status failed }
            }
        }
        return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId
    }
    catch {
        $errorRecord = $_
        $exception = $errorRecord.Exception
        $errorInfo = Get-PipelineRunError -ErrorRecord $errorRecord
        $status = if ($exception.Data['status']) { [string]$exception.Data['status'] } else { 'failed' }
        $root = $null
        try { $root = Resolve-MigrationRoot -Path $ProjectRoot } catch { }
        $hasRunId = -not [string]::IsNullOrWhiteSpace($RunId)
        if ($hasRunId -and $root -and (Test-Path -LiteralPath (Get-MigrationRunPaths -ProjectRoot $root -RunId $RunId).state -PathType Leaf)) {
            try {
                $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
                if ($state.activeOperation) {
                    Finish-PipelineOperation -ProjectRoot $root -RunId $RunId -Stage $state.activeOperation.stage -Data ([PSCustomObject]@{ status = $status; diagnostic = $errorInfo })
                    Clear-PipelineOperation -ProjectRoot $root -RunId $RunId | Out-Null
                }
                if ($state.status -in @('running', 'needs-repair')) {
                    $targetStatus = if ($status -in @('needs-repair', 'blocked', 'failed')) { $status } else { 'failed' }
                    $diagnostic = [PSCustomObject]@{ code = $errorInfo.code; message = $errorInfo.message; details = $errorInfo.details }
                    $state = Read-MigrationRunState -ProjectRoot $root -RunId $RunId
                    Move-MigrationState -ProjectRoot $root -RunId $RunId -ExpectedStatus $state.status -ExpectedStage $state.stage -NewStatus $targetStatus -NewStage $state.stage -ExpectedRevision $state.stageRevision -Diagnostic $diagnostic | Out-Null
                    if ($targetStatus -in @('blocked', 'failed')) { Remove-ActiveRunLock -ProjectRoot $root -RunId $RunId }
                }
                if ($state.status -in @('verified', 'completed')) {
                    return [PSCustomObject]@{
                        ok     = $false
                        status = 'failed'
                        data   = [PSCustomObject]@{ runId = $RunId; result = '.angular-migration/runs/' + $RunId + '/result.json' }
                        error  = $errorInfo
                    }
                }
                return ConvertTo-PipelineRunEnvelope -ProjectRoot $root -RunId $RunId
            }
            catch {
                $errorInfo = Get-PipelineRunError -ErrorRecord $_
            }
        }
        return [PSCustomObject]@{ ok = $false; status = $status; data = [PSCustomObject]@{}; error = $errorInfo }
    }
}

Export-ModuleMember -Function @(
    'Invoke-MigrationBaseline',
    'Invoke-MigrationResolution',
    'Invoke-InspectMigration',
    'Invoke-StartMigration',
    'Invoke-MigrationStatus',
    'Invoke-MigrationRepairContext',
    'Invoke-MigrationRecordRepair',
    'Invoke-MigrationRun'
)
