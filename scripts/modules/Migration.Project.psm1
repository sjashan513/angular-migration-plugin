Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -DisableNameChecking

$script:CheckTimeouts = [ordered]@{ install = 900; 'dependency-tree' = 300; typecheck = 600; lint = 600; 'unit-test' = 900; build = 1200; e2e = 1800 }
$script:CheckInactivityTimeoutSeconds = 300

function Get-ProjectProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary] -and @($Object.Keys) -contains $Name) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-ProjectObjectEntries {
    param([AllowNull()]$Object)

    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = [string]$_.Key; Value = $_.Value } })
    }
    return @($Object.PSObject.Properties)
}

function Read-ProjectLockfileJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    try { return Read-MigrationJson -Path $Path -Required }
    catch {
        try {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            return $serializer.DeserializeObject([IO.File]::ReadAllText($Path))
        }
        catch { throw $_ }
    }
}

function Get-ProjectPackage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $path = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return Read-MigrationJson -Path $path
}

function Get-ProjectLockfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$FnmPath = '',
        [string]$NodeVersion = '',
        [switch]$DisallowAmbientNode
    )

    $lockPath = Join-Path $ProjectRoot 'package-lock.json'
    try {
            $lock = Read-ProjectLockfileJson -Path $lockPath
        $version = Get-ProjectProperty -Object $lock -Name 'lockfileVersion'
        if ($version -notin @(1, 2, 3)) { throw 'Unsupported lockfile version' }
        $section = if ($version -eq 1) { 'dependencies' } else { 'packages' }
        $entries = Get-ProjectProperty -Object $lock -Name $section
        if ($null -eq $entries -or ($entries -isnot [PSCustomObject] -and $entries -isnot [System.Collections.IDictionary])) { throw 'Invalid lockfile layout' }
        $versions = @{}
            foreach ($entry in (Get-ProjectObjectEntries -Object $entries)) {
            $name = $entry.Name
            if ($version -ne 1) {
                if ($name -notmatch '^node_modules/((?:@[^/]+/)?[^/]+)$') { continue }
                $name = $Matches[1]
            }
            $versions[$name] = Get-ProjectProperty -Object $entry.Value -Name 'version'
        }
        if ($versions['@angular/core'] -and $versions['@angular/core'] -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
            throw 'Locked Angular core version is not exact'
        }
        return [PSCustomObject]@{ lockfileVersion = $version; versions = $versions }
    }
    catch {
        if ($DisallowAmbientNode) {
            Throw-MigrationError -Code 'lockfile_invalid' -Message 'package-lock.json cannot be read without an explicit Node runtime.' -Status blocked
        }
        try {
            $helper = Join-Path $PSScriptRoot '../js/inspect-lockfile.js'
            if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'Lockfile inspector unavailable' }
            if ($FnmPath -and $NodeVersion) {
                $process = Invoke-MigrationNodeProcess -FnmPath $FnmPath -NodeVersion $NodeVersion -Executable 'node' -Arguments @($helper, $lockPath) -WorkingDirectory $ProjectRoot -TimeoutSeconds 30
            }
            else {
                $node = Find-MigrationExecutable -Names @('node.exe', 'node')
                if (-not $node) { throw 'Lockfile inspector unavailable' }
                $process = Invoke-MigrationProcess -FilePath $node -Arguments @($helper, $lockPath) -WorkingDirectory $ProjectRoot -TimeoutSeconds 30
            }
            if ($process.timedOut -or $process.exitCode -ne 0) { throw 'Lockfile inspector rejected the lockfile' }
            $normalized = $process.stdout | ConvertFrom-Json
            $version = [int](Get-ProjectProperty -Object $normalized -Name 'lockfileVersion')
            if ($version -notin @(1, 2, 3)) { throw 'Unsupported lockfile version' }
            $entries = Get-ProjectProperty -Object $normalized -Name 'versions'
            if ($null -eq $entries -or $entries -isnot [PSCustomObject]) { throw 'Invalid lockfile layout' }
            $versions = @{}
            foreach ($entry in $entries.PSObject.Properties) { $versions[$entry.Name] = [string]$entry.Value }
            if ($versions['@angular/core'] -and $versions['@angular/core'] -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
                throw 'Locked Angular core version is not exact'
            }
            return [PSCustomObject]@{ lockfileVersion = $version; versions = $versions }
        }
        catch {
            Throw-MigrationError -Code 'lockfile_invalid' -Message 'package-lock.json cannot be read or has an unsupported layout.' -Status blocked
        }
    }
}

function Get-ProjectAngularConfig {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $path = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'angular.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return Read-MigrationJson -Path $path
}

function Get-VersionMajor {
    param([string]$Spec)

    if ([string]::IsNullOrWhiteSpace($Spec)) { return $null }
    $match = [regex]::Match($Spec, '^\s*(?:~|\^|>=?)?\s*(\d+)(?:\.(?:\d+|x|\*)){0,2}(?:-[0-9A-Za-z.-]+)?\s*$')
    if (-not $match.Success) { return $null }
    return [int]$match.Groups[1].Value
}

function Get-DependencyKind {
    param([string]$Spec)

    if ([string]::IsNullOrWhiteSpace($Spec)) { return 'invalid' }
    if ($Spec -match '^npm:') { return 'alias' }
    if ($Spec -match '^(git\+|git@|git://|github:|bitbucket:|gitlab:)') { return 'git' }
    if ($Spec -match '^https?://') { return 'url' }
    if ($Spec -match '^(file:|link:|workspace:|patch:|\.{1,2}[\\/]|[a-zA-Z]:[\\/])') { return 'local' }
    return 'registry'
}

function Get-DependencyInventory {
    param([Parameter(Mandatory = $true)]$Package)

    $sectionRoles = [ordered]@{
        dependencies         = 'runtime'
        devDependencies      = 'dev'
        optionalDependencies = 'optional'
        peerDependencies     = 'peer'
    }
    $items = @()
    foreach ($section in $sectionRoles.Keys) {
        $values = Get-ProjectProperty -Object $Package -Name $section
        if ($null -eq $values) { continue }
        foreach ($name in @($values.PSObject.Properties | Select-Object -ExpandProperty Name | Sort-Object)) {
            $spec = [string]$values.$name
            $items += [PSCustomObject]@{
                name    = $name
                section = $section
                role    = $sectionRoles[$section]
                spec    = $spec
                kind    = Get-DependencyKind -Spec $spec
            }
        }
    }

    $policies = [ordered]@{}
    foreach ($policyName in @('peerDependenciesMeta', 'overrides')) {
        $policy = Get-ProjectProperty -Object $Package -Name $policyName
        if ($null -ne $policy) { $policies[$policyName] = $policy }
    }
    $migrationPolicy = Get-ProjectProperty -Object $Package -Name 'angularMigration'
    if ($migrationPolicy) {
        foreach ($policyName in @('peerExceptions', 'transitivePeerPromotions')) {
            $policy = Get-ProjectProperty -Object $migrationPolicy -Name $policyName
            if ($null -ne $policy) { $policies[$policyName] = $policy }
        }
    }

    return [PSCustomObject]@{
        items    = @($items)
        policies = $policies
    }
}

function Get-NpmScripts {
    param([Parameter(Mandatory = $true)]$Package)

    $scripts = Get-ProjectProperty -Object $Package -Name 'scripts'
    if ($null -eq $scripts) { return @{} }
    $result = @{}
    foreach ($name in @($scripts.PSObject.Properties | Select-Object -ExpandProperty Name)) {
        $result[$name] = [string]$scripts.$name
    }
    return $result
}

function Get-ProjectRegistryUri {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\r\n]') { return $null }
    try { $uri = [Uri]$Value } catch { return $null }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { return $null }
    return $uri
}

function Find-NpmScript {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Scripts,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Scripts.ContainsKey($name)) { return $name }
    }
    return $null
}

function Get-ProjectChecks {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][bool]$HasLockfile
    )

    $scripts = Get-NpmScripts -Package $Package
    $checks = @()
    $installArguments = @('ci') + @(Get-MigrationNpmRegistryArguments)
    $checks += [PSCustomObject]@{
        id             = 'install'
        status         = if ($HasLockfile) { 'configured' } else { 'blocked' }
        executable     = 'npm'
        arguments      = @($installArguments)
        displayCommand = 'npm ci --registry https://registry.npmjs.org/'
        cwd            = $ProjectRoot
        reason         = if ($HasLockfile) { $null } else { 'package-lock.json is required for the supported npm workflow' }
    }
    $checks += [PSCustomObject]@{
        id             = 'dependency-tree'
        status         = if ($HasLockfile) { 'configured' } else { 'blocked' }
        executable     = 'npm'
        arguments      = @('ls', '--all') + @(Get-MigrationNpmRegistryArguments)
        displayCommand = 'npm ls --all --registry https://registry.npmjs.org/'
        cwd            = $ProjectRoot
        reason         = if ($HasLockfile) { $null } else { 'package-lock.json is required for the supported npm workflow' }
    }

    $definitions = @(
        @{ id = 'typecheck'; names = @('typecheck', 'type-check', 'check:types', 'tsc') },
        @{ id = 'lint'; names = @('lint') },
        @{ id = 'unit-test'; names = @('test:unit', 'unit-test', 'test') },
        @{ id = 'build'; names = @('build') },
        @{ id = 'e2e'; names = @('e2e', 'test:e2e', 'cy:run') }
    )
    foreach ($definition in $definitions) {
        $scriptName = Find-NpmScript -Scripts $scripts -Names $definition.names
        $scriptArguments = if ($scriptName) { @('run', $scriptName) } else { @() }
        $checks += [PSCustomObject]@{
            id             = $definition.id
            status         = if ($scriptName) { 'configured' } else { 'not-configured' }
            executable     = if ($scriptName) { 'npm' } else { $null }
            arguments      = @($scriptArguments)
            displayCommand = if ($scriptName) { "npm run $scriptName" } else { $null }
            cwd            = $ProjectRoot
            reason         = if ($scriptName) { $null } else { 'No matching npm script was found' }
        }
    }
    $angular = $null
    try { $angular = Get-ProjectAngularConfig -ProjectRoot $ProjectRoot } catch { }
    $projects = if ($angular) { Get-ProjectProperty -Object $angular -Name 'projects' } else { $null }
    $hasApplication = $false
    if ($projects) {
        foreach ($project in $projects.PSObject.Properties) {
            if ((Get-ProjectProperty -Object $project.Value -Name 'projectType') -eq 'application') { $hasApplication = $true }
        }
    }
    foreach ($check in $checks) {
        $check | Add-Member -NotePropertyName phase -NotePropertyValue 'baseline'
        $check | Add-Member -NotePropertyName blocking -NotePropertyValue $true
        $check | Add-Member -NotePropertyName canSkip -NotePropertyValue ($check.id -in @('typecheck', 'lint', 'unit-test', 'e2e'))
        $check | Add-Member -NotePropertyName runtimeProfile -NotePropertyValue ('baseline:' + $check.id)
        $check | Add-Member -NotePropertyName timeoutSeconds -NotePropertyValue $script:CheckTimeouts[$check.id]
        if ($check.id -eq 'build' -and $hasApplication -and $check.status -eq 'not-configured') {
            $check.status = 'blocked'
            $check.reason = 'Application project does not define an npm build script'
        }
    }
    return @($checks)
}

function Assert-ProjectCheck {
    param($Check, [string]$LogDirectory)

    $directory = [IO.Path]::GetFullPath($LogDirectory).TrimEnd([char[]]@('\', '/'))
    $logs = Split-Path -Parent $directory
    $runRoot = Split-Path -Parent $logs
    $runs = Split-Path -Parent $runRoot
    $migration = Split-Path -Parent $runs
    $root = Resolve-MigrationRoot -Path (Split-Path -Parent $migration)
    if ((Split-Path -Leaf $directory) -notin @('baseline', 'validate') -or
        (Split-Path -Leaf $logs) -cne 'logs' -or (Split-Path -Leaf $runs) -cne 'runs' -or
        (Split-Path -Leaf $migration) -cne '.angular-migration' -or
        (Split-Path -Leaf $runRoot) -notmatch '^[a-z0-9TZ]+(?:-[a-z0-9TZ]+)*$' -or
        $Check.cwd -cne $root) {
        Throw-MigrationError -Code 'invalid_check_contract' -Message 'Check and log directory must belong to the normalized project root.' -Status blocked
    }
    $ancestor = $directory
    while ($ancestor -and $ancestor.Length -ge $root.Length) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Throw-MigrationError -Code 'invalid_check_contract' -Message 'Check paths cannot traverse reparse points.' -Status blocked
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    $checks = @(Get-ProjectChecks -Package (Get-ProjectPackage -ProjectRoot $root) -ProjectRoot $root -HasLockfile (Test-Path -LiteralPath (Join-Path $root 'package-lock.json') -PathType Leaf))
    $expected = @($checks | Where-Object { $_.id -ceq $Check.id })
    if ($expected.Count -ne 1) {
        Throw-MigrationError -Code 'invalid_check_contract' -Message 'Unknown check id.' -Status blocked
    }
    foreach ($field in @('phase', 'status', 'blocking', 'executable', 'arguments', 'cwd', 'timeoutSeconds', 'reason')) {
        $actualJson = ConvertTo-Json -InputObject $Check.$field -Compress
        $expectedJson = ConvertTo-Json -InputObject $expected[0].$field -Compress
        if ($actualJson -cne $expectedJson) {
            Throw-MigrationError -Code 'invalid_check_contract' -Message "Check contract differs from discovery: $field" -Status blocked
        }
    }
    return [PSCustomObject]@{ projectRoot = $root; runRoot = $runRoot; logDirectory = $directory }
}

function Invoke-ProjectCheck {
    param(
        [Parameter(Mandatory = $true)]$Check,
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [string]$FnmPath = '',
        [string]$NodeVersion = ''
    )

    $context = Assert-ProjectCheck -Check $Check -LogDirectory $LogDirectory
    $result = [PSCustomObject]@{
        id = $Check.id; status = $Check.status; exitCode = $null; timedOut = $false; processStalled = $false; terminationReason = $null
        startedAt = $null; finishedAt = $null; durationMs = 0
        stdoutLog = $null; stderrLog = $null; diagnosticSummary = $Check.reason
        executable = $null
    }
    if ($Check.status -in @('not-configured', 'blocked')) { return $result }
    $npm = if ($FnmPath -and $NodeVersion) { 'npm' } else { Find-MigrationExecutable -Names @('npm.cmd', 'npm.exe', 'npm') }
    if (-not $npm) {
        Throw-MigrationError -Code 'process_failed' -Message 'npm could not be resolved for the check.' -Status failed
    }
    $result.executable = $npm
    New-Item -ItemType Directory -Path $context.logDirectory -Force -ErrorAction Stop | Out-Null
    $order = @($script:CheckTimeouts.Keys).IndexOf($Check.id) + 1
    $prefix = '{0:D2}-{1}' -f $order, $Check.id
    $relativeDirectory = 'logs/' + (Split-Path -Leaf $context.logDirectory) + '/'
    $result.stdoutLog = $relativeDirectory + $prefix + '.stdout.log'
    $result.stderrLog = $relativeDirectory + $prefix + '.stderr.log'
    $result.startedAt = Get-MigrationUtcNow
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($FnmPath -and $NodeVersion) {
            $process = Invoke-MigrationNodeProcess -FnmPath $FnmPath -NodeVersion $NodeVersion -Executable 'npm' -Arguments $Check.arguments -WorkingDirectory $context.projectRoot -TimeoutSeconds $Check.timeoutSeconds -InactivityTimeoutSeconds $script:CheckInactivityTimeoutSeconds
        }
        else {
            $process = Invoke-MigrationProcess -FilePath $npm -Arguments $Check.arguments -WorkingDirectory $context.projectRoot -TimeoutSeconds $Check.timeoutSeconds -InactivityTimeoutSeconds $script:CheckInactivityTimeoutSeconds
        }
        [IO.File]::WriteAllText((Join-Path $context.runRoot $result.stdoutLog), (ConvertTo-MigrationRedactedText $process.stdout), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $context.runRoot $result.stderrLog), (ConvertTo-MigrationRedactedText $process.stderr), (New-Object Text.UTF8Encoding($false)))
        $result.exitCode = $process.exitCode
        $result.timedOut = [bool]$process.timedOut
        $result.processStalled = if ($process.PSObject.Properties['processStalled']) { [bool]$process.processStalled } else { $false }
        $result.terminationReason = if ($process.PSObject.Properties['terminationReason']) { [string]$process.terminationReason } else { if ($result.timedOut) { 'timeout' } else { 'completed' } }
        $result.status = if ($process.timedOut) { 'timed-out' } elseif ($process.exitCode -eq 0) { 'passed' } else { 'failed' }
        if ($result.processStalled) { $result.diagnosticSummary = "Check $($Check.id) stalled due to inactivity; see the check logs." }
        elseif ($result.status -ne 'passed') { $result.diagnosticSummary = "Check $($Check.id) ended with status $($result.status); see the check logs." }
    }
    finally {
        $timer.Stop()
        $result.finishedAt = Get-MigrationUtcNow
        $result.durationMs = $timer.ElapsedMilliseconds
    }
    return $result
}

function Invoke-ProjectCheckSet {
    param(
        [Parameter(Mandatory = $true)][object[]]$Checks,
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [ValidateSet('baseline', 'final')][string]$Mode = 'baseline'
    )

    if (($Checks.id -join ',') -cne ($script:CheckTimeouts.Keys -join ',')) {
        Throw-MigrationError -Code 'invalid_check_contract' -Message 'Checks must contain the complete fixed sequence.' -Status blocked
    }
    foreach ($check in $Checks) { $null = Assert-ProjectCheck -Check $check -LogDirectory $LogDirectory }
    $results = @()
    $notStarted = @()
    foreach ($check in $Checks) {
        if ($notStarted.Count -gt 0 -or ($results.Count -gt 0 -and $results[-1].status -notin @('passed', 'not-configured'))) {
            $notStarted += $check
            continue
        }
        $results += Invoke-ProjectCheck -Check $check -LogDirectory $LogDirectory
    }
    $failed = @($results | Where-Object { $_.status -notin @('passed', 'not-configured') })
    return [PSCustomObject]@{ status = if ($failed.Count -eq 0) { 'passed' } elseif ($Mode -eq 'baseline') { 'blocked' } else { 'failed' }; checks = $results; notStarted = $notStarted }
}

function Get-ProjectGit {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $context = [PSCustomObject]@{
        available = $false; valid = $false; clean = $false; branch = $null
        detached = $false; head = $null; repositoryRoot = $null
        stateDirectoryIgnored = $false; identityConfigured = $false
        dirtyFiles = @(); error = $null; errorCode = $null
    }
    $git = Find-MigrationExecutable -Names @('git.exe', 'git')
    if (-not $git) {
        $context.errorCode = 'git_missing'
        $context.error = 'git is not available'
        return $context
    }
    $context.available = $true
    $rootResult = Invoke-MigrationProcess -FilePath $git -Arguments @('rev-parse', '--show-toplevel') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    if ($rootResult.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($rootResult.stdout)) {
        $context.errorCode = 'git_repository_missing'
        $context.error = 'project is not inside a Git repository'
        return $context
    }
    $context.repositoryRoot = Resolve-MigrationRoot -Path $rootResult.stdout.Trim()
    if (-not $context.repositoryRoot.Equals((Resolve-MigrationRoot -Path $ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) {
        $context.errorCode = 'git_root_mismatch'
        $context.error = 'Git repository root does not match the project root'
        return $context
    }
    $statusResult = Invoke-MigrationProcess -FilePath $git -Arguments @('status', '--porcelain=v1', '--untracked-files=all') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $branchResult = Invoke-MigrationProcess -FilePath $git -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $headResult = Invoke-MigrationProcess -FilePath $git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $ignoreResult = Invoke-MigrationProcess -FilePath $git -Arguments @('check-ignore', '--quiet', '--', '.angular-migration/.probe') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $nameResult = Invoke-MigrationProcess -FilePath $git -Arguments @('config', 'user.name') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $emailResult = Invoke-MigrationProcess -FilePath $git -Arguments @('config', 'user.email') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $context.head = $headResult.stdout.Trim()
    $context.branch = if ($branchResult.exitCode -eq 0) { $branchResult.stdout.Trim() } else { $null }
    $context.detached = $branchResult.exitCode -eq 1
    $context.dirtyFiles = @($statusResult.stdout -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
    $context.stateDirectoryIgnored = $ignoreResult.exitCode -eq 0
    $context.identityConfigured = $nameResult.exitCode -eq 0 -and $emailResult.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($nameResult.stdout) -and -not [string]::IsNullOrWhiteSpace($emailResult.stdout)
    $context.valid = $headResult.exitCode -eq 0 -and $context.head -match '^[a-fA-F0-9]{40}$' -and $statusResult.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($context.branch)
    $context.clean = $context.valid -and $context.dirtyFiles.Count -eq 0
    if ($context.detached) {
        $context.errorCode = 'git_detached_head'; $context.error = 'A named Git branch is required'
    }
    elseif (-not $context.valid) {
        $context.errorCode = 'git_repository_missing'; $context.error = 'Git HEAD or repository context is invalid'
    }
    elseif (-not $context.clean) {
        $context.errorCode = 'git_dirty'; $context.error = 'The Git working tree must be clean'
    }
    elseif (-not $context.stateDirectoryIgnored) {
        $context.errorCode = 'migration_state_not_ignored'; $context.error = '.angular-migration/ must be ignored by Git'
    }
    elseif (-not $context.identityConfigured) {
        $context.errorCode = 'git_identity_missing'; $context.error = 'Git user.name and user.email are required'
    }
    return $context
}

function Get-ProjectNode {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $node = Find-MigrationExecutable -Names @('node.exe', 'node')
    $npm = Find-MigrationExecutable -Names @('npm.cmd', 'npm.exe', 'npm')
    $nodeVersion = $null
    $npmVersion = $null
    $nodeResult = $null
    $npmResult = $null
    $errors = @()
    if ($node) {
        $nodeResult = Invoke-MigrationProcess -FilePath $node -Arguments @('--version') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
        if ($nodeResult.exitCode -eq 0) { $nodeVersion = $nodeResult.stdout.Trim() -replace '^v', '' } else { $errors += $nodeResult.stderr.Trim() }
    }
    else { $errors += 'node is not available' }
    if ($npm) {
        $npmResult = Invoke-MigrationProcess -FilePath $npm -Arguments @('--version') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
        if ($npmResult.exitCode -eq 0) { $npmVersion = $npmResult.stdout.Trim() } else { $errors += $npmResult.stderr.Trim() }
    }
    else { $errors += 'npm is not available' }

    return [PSCustomObject]@{
        node   = [PSCustomObject]@{ available = [bool]($node -and $nodeVersion); executable = $node; version = $nodeVersion; stdout = if ($nodeResult -and -not $nodeVersion) { [string]$nodeResult.stdout } else { $null } }
        npm    = [PSCustomObject]@{ available = [bool]($npm -and $npmVersion); executable = $npm; version = $npmVersion; stdout = if ($npmResult -and -not $npmVersion) { [string]$npmResult.stdout } else { $null } }
        errors = @($errors | Where-Object { $_ })
    }
}

function Get-ProjectNodeDeclarations {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $declarations = @()
    $nodeRanges = @()
    $npmRanges = @()
    $sources = @('.nvmrc', '.node-version', '.tool-versions')
    foreach ($relative in $sources) {
        $path = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $text = ([IO.File]::ReadAllText($path)).Trim()
        if ($relative -eq '.tool-versions') {
            $line = @($text -split "`r?`n" | Where-Object { $_ -match '^\s*nodejs\s+\S+' } | Select-Object -First 1)
            if ($line.Count -eq 0) { continue }
            $text = ([regex]::Match([string]$line[0], '^\s*nodejs\s+(\S+)').Groups[1].Value).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $declarations += [PSCustomObject][ordered]@{ source = $relative; value = $text; kind = 'node' }
        $nodeRanges += [PSCustomObject]@{ source = $relative; value = $text }
    }
    $package = Get-ProjectPackage -ProjectRoot $root
    if ($package) {
        $engines = Get-ProjectProperty -Object $package -Name 'engines'
        $nodeEngine = [string](Get-ProjectProperty -Object $engines -Name 'node')
        $npmEngine = [string](Get-ProjectProperty -Object $engines -Name 'npm')
        if ($nodeEngine) {
            $declarations += [PSCustomObject][ordered]@{ source = 'package.json#engines.node'; value = $nodeEngine; kind = 'node' }
            $nodeRanges += [PSCustomObject]@{ source = 'package.json#engines.node'; value = $nodeEngine }
        }
        if ($npmEngine) {
            $declarations += [PSCustomObject][ordered]@{ source = 'package.json#engines.npm'; value = $npmEngine; kind = 'npm' }
            $npmRanges += [PSCustomObject]@{ source = 'package.json#engines.npm'; value = $npmEngine }
        }
        $packageManager = [string](Get-ProjectProperty -Object $package -Name 'packageManager')
        if ($packageManager -match '^npm@(.+)$') {
            $declarations += [PSCustomObject][ordered]@{ source = 'package.json#packageManager'; value = $Matches[1]; kind = 'npm' }
            $npmRanges += [PSCustomObject]@{ source = 'package.json#packageManager'; value = $Matches[1] }
        }
        $volta = Get-ProjectProperty -Object $package -Name 'volta'
        $voltaNode = [string](Get-ProjectProperty -Object $volta -Name 'node')
        $voltaNpm = [string](Get-ProjectProperty -Object $volta -Name 'npm')
        if ($voltaNode) {
            $declarations += [PSCustomObject][ordered]@{ source = 'package.json#volta.node'; value = $voltaNode; kind = 'node' }
            $nodeRanges += [PSCustomObject]@{ source = 'package.json#volta.node'; value = $voltaNode }
        }
        if ($voltaNpm) {
            $declarations += [PSCustomObject][ordered]@{ source = 'package.json#volta.npm'; value = $voltaNpm; kind = 'npm' }
            $npmRanges += [PSCustomObject]@{ source = 'package.json#volta.npm'; value = $voltaNpm }
        }
    }
    $conflicts = @()
    $exactNodes = @($nodeRanges | Where-Object { $_.value -match '^v?\d+\.\d+\.\d+$' })
    foreach ($left in $exactNodes) {
        foreach ($right in @($nodeRanges | Where-Object { $_.source -cne $left.source })) {
            $value = ([string]$left.value) -replace '^v', ''
            if (-not (Test-MigrationVersionRange -Version $value -Range ([string]$right.value))) {
                $conflicts += [PSCustomObject][ordered]@{ code = 'node_declarations_conflict'; source = $left.source; value = $left.value; conflictsWith = $right.source; conflictingValue = $right.value }
            }
        }
    }
    $exactNpm = @($npmRanges | Where-Object { $_.value -match '^v?\d+\.\d+\.\d+$' })
    foreach ($left in $exactNpm) {
        foreach ($right in @($npmRanges | Where-Object { $_.source -cne $left.source })) {
            $value = ([string]$left.value) -replace '^v', ''
            if (-not (Test-MigrationVersionRange -Version $value -Range ([string]$right.value))) {
                $conflicts += [PSCustomObject][ordered]@{ code = 'npm_declarations_conflict'; source = $left.source; value = $left.value; conflictsWith = $right.source; conflictingValue = $right.value }
            }
        }
    }
    return [PSCustomObject][ordered]@{
        declarations = @($declarations)
        nodeRanges   = @($nodeRanges)
        npmRanges    = @($npmRanges)
        conflicts    = @($conflicts | Sort-Object source, conflictsWith -Unique)
    }
}

function Get-ProjectFnmVersionsFromText {
    param([AllowEmptyString()][string]$Text)

    $versions = @()
    foreach ($match in [regex]::Matches($Text, '(?<![0-9A-Za-z.-])v?(\d+\.\d+\.\d+)(?![-0-9A-Za-z])')) {
        $version = $match.Groups[1].Value
        if ($version -notin $versions) { $versions += $version }
    }
    return @($versions | Sort-Object { [version]$_ })
}

function Get-ProjectFnmInventory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [switch]$IncludeRemote
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $fnm = Find-MigrationExecutable -Names @('fnm.exe', 'fnm')
    if (-not $fnm) {
        return [PSCustomObject][ordered]@{
            available = $false; executable = $null; version = $null; installedVersions = @(); identities = @(); remoteVersions = @(); errors = @('fnm is not available')
        }
    }
    $versionResult = Invoke-MigrationProcess -FilePath $fnm -Arguments @('--version') -WorkingDirectory $root -TimeoutSeconds 15
    $fnmVersion = if ($versionResult.exitCode -eq 0) { ([string]$versionResult.stdout).Trim() } else { $null }
    $list = Invoke-MigrationProcess -FilePath $fnm -Arguments @('list', '--json') -WorkingDirectory $root -TimeoutSeconds 30
    $installed = @(Get-ProjectFnmVersionsFromText -Text $list.stdout)
    if ($list.exitCode -ne 0 -or $installed.Count -eq 0) {
        $list = Invoke-MigrationProcess -FilePath $fnm -Arguments @('list') -WorkingDirectory $root -TimeoutSeconds 30
        $installed = @(Get-ProjectFnmVersionsFromText -Text $list.stdout)
    }
    $identities = @()
    foreach ($version in $installed) {
        try { $identities += Get-MigrationNodeIdentity -FnmPath $fnm -NodeVersion $version -WorkingDirectory $root -TimeoutSeconds 30 }
        catch {
            $identities += [PSCustomObject][ordered]@{ nodeVersion = $version; npmVersion = $null; observedNodeVersion = $null; status = 'unusable'; reason = $_.Exception.Message }
        }
    }
    $remote = @()
    if ($IncludeRemote) {
        $remoteResult = Invoke-MigrationProcess -FilePath $fnm -Arguments @('list-remote', '--json') -WorkingDirectory $root -TimeoutSeconds 60
        $remote = @(Get-ProjectFnmVersionsFromText -Text $remoteResult.stdout)
        if ($remoteResult.exitCode -ne 0 -or $remote.Count -eq 0) {
            $remoteResult = Invoke-MigrationProcess -FilePath $fnm -Arguments @('list-remote') -WorkingDirectory $root -TimeoutSeconds 60
            $remote = @(Get-ProjectFnmVersionsFromText -Text $remoteResult.stdout)
        }
    }
    $errors = @()
    if ($versionResult.exitCode -ne 0) { $errors += 'fnm --version failed' }
    if ($list.exitCode -ne 0) { $errors += 'fnm list failed' }
    return [PSCustomObject][ordered]@{
        available = $true; executable = $fnm; version = $fnmVersion; installedVersions = @($installed); identities = @($identities); remoteVersions = @($remote); errors = @($errors)
    }
}

function Get-ProjectInputFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$Inspection
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $relativePaths = @('package.json', 'package-lock.json', 'angular.json', '.nvmrc', '.node-version', '.tool-versions') + @($Inspection.files.configurations)
    $records = @()
    foreach ($relative in @($relativePaths | ForEach-Object { [string]$_ } | Sort-Object -Unique)) {
        $full = Join-Path $root ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        $present = Test-Path -LiteralPath $full -PathType Leaf
        $records += [ordered]@{
            path = $relative.Replace('\', '/')
            present = $present
            sha256 = if ($present) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        }
    }
    $json = [PSCustomObject][ordered]@{ files = @($records) } | ConvertTo-Json -Depth 20 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
        return 'sha256:' + (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-ProjectLockfileNpmMinimumRange {
    param([Parameter(Mandatory = $true)][int]$LockfileVersion)
    if ($LockfileVersion -eq 1) { return '>=5' }
    return '>=7'
}

function Get-ProjectLockedTooling {
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)]$Package
    )
    $names = @('webpack', '@angular-devkit/build-angular', '@angular/cli', 'typescript', 'karma', 'jest', 'cypress', '@angular/compiler-cli')
    $items = @()
    foreach ($name in $names) {
        $declared = $null
        foreach ($sectionName in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')) {
            $section = Get-ProjectProperty -Object $Package -Name $sectionName
            if ($section -and $section.PSObject.Properties[$name]) { $declared = [string]$section.$name; break }
        }
        $locked = if ($Lock.versions.ContainsKey($name)) { [string]$Lock.versions[$name] } else { $null }
        if ($declared -or $locked) { $items += [PSCustomObject][ordered]@{ name = $name; declaredSpec = $declared; lockedVersion = $locked } }
    }
    return @($items)
}

function Get-AngularPackageVersions {
    param([Parameter(Mandatory = $true)]$Inventory)

    $angularPackages = @{}
    foreach ($item in @($Inventory.items | Where-Object { $_.name -like '@angular/*' })) {
        $angularPackages[$item.name] = $item.spec
    }
    return $angularPackages
}

function Test-ProjectRelativeFile {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $normalized = $RelativePath -replace '\\', '/'
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -match '^(?:[A-Za-z]:/|/)' -or $normalized -match '(^|/)\.\.(?:/|$)') { return $false }
    return Test-Path -LiteralPath (Join-Path $ProjectRoot ($normalized -replace '/', [IO.Path]::DirectorySeparatorChar)) -PathType Leaf
}

function Get-ProjectAngularTsConfigPaths {
    param([AllowNull()]$AngularProjects)

    $paths = New-Object 'System.Collections.Generic.List[string]'
    $walk = $null
    $walk = {
        param($Value)
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
        if ($Value -is [Collections.IEnumerable] -and $Value -isnot [Collections.IDictionary]) {
            foreach ($item in @($Value)) { & $walk $item }
            return
        }
        foreach ($entry in @(Get-ProjectObjectEntries -Object $Value)) {
            if ([string]$entry.Name -ieq 'tsConfig') {
                $values = if ($entry.Value -is [Collections.IEnumerable] -and $entry.Value -isnot [string]) { @($entry.Value) } else { @($entry.Value) }
                foreach ($candidate in $values) {
                    if ($candidate -isnot [string]) { continue }
                    $path = ([string]$candidate).Replace('\', '/')
                    while ($path.StartsWith('./')) { $path = $path.Substring(2) }
                    if (-not [string]::IsNullOrWhiteSpace($path) -and $path -notmatch '^(?:[A-Za-z]:/|/)' -and $path -notmatch '(^|/)\.\.(?:/|$)' -and -not $paths.Contains($path)) {
                        [void]$paths.Add($path)
                    }
                }
            }
            & $walk $entry.Value
        }
    }
    & $walk $AngularProjects
    return @($paths | Sort-Object)
}

function Get-ProjectTsConfigChain {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Paths
    )

    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $seen = @{}
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($relative in @($Paths)) {
        if (-not [string]::IsNullOrWhiteSpace($relative)) { $queue.Enqueue(([string]$relative).Replace('\', '/')) }
    }
    while ($queue.Count -gt 0) {
        $relative = $queue.Dequeue()
        if ($seen.ContainsKey($relative)) { continue }
        $seen[$relative] = $true
        [void]$result.Add($relative)
        $path = Join-Path $root ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try { $config = Read-MigrationJson -Path $path -Required } catch { continue }
        $extends = Get-ProjectProperty -Object $config -Name 'extends'
        if ($extends -isnot [string]) { continue }
        $base = [string]$extends
        if (-not $base.StartsWith('.')) { continue }
        $basePath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $path) ($base -replace '/', [IO.Path]::DirectorySeparatorChar)))
        if ([IO.Path]::GetExtension($basePath) -eq '') { $basePath += '.json' }
        $rootPrefix = $root.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
        if (-not $basePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $baseRelative = $basePath.Substring($rootPrefix.Length).Replace('\', '/')
        if (-not $seen.ContainsKey($baseRelative)) { $queue.Enqueue($baseRelative) }
    }
    return @($result | Sort-Object)
}

function New-ProjectPreflightFileFinding {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Purpose,
        [Parameter(Mandatory = $true)][string[]]$Candidates,
        [Parameter(Mandatory = $true)][bool]$Required,
        [string]$CheckId
    )

    $detected = @($Candidates | Where-Object { Test-ProjectRelativeFile -ProjectRoot $ProjectRoot -RelativePath $_ })
    return [PSCustomObject][ordered]@{
        id         = $Id
        purpose    = $Purpose
        checkId    = if ($CheckId) { $CheckId } else { $null }
        candidates = @($Candidates)
        detected   = @($detected)
        required   = $Required
        present    = $detected.Count -gt 0
        status     = if ($detected.Count -gt 0) { 'present' } elseif ($Required) { 'missing' } else { 'not-found' }
    }
}

function Get-ProjectPreflightFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$AngularProjects,
        [Parameter(Mandatory = $true)]$Checks,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Configurations
    )

    $checkById = @{}
    foreach ($check in @($Checks)) { $checkById[[string]$check.id] = $check }
    $findings = @()
    $findings += New-ProjectPreflightFileFinding -ProjectRoot $ProjectRoot -Id 'package-json' -Purpose 'Project manifest' -Candidates @('package.json') -Required $true
    $findings += New-ProjectPreflightFileFinding -ProjectRoot $ProjectRoot -Id 'angular-json' -Purpose 'Angular workspace configuration' -Candidates @('angular.json') -Required $true
    $findings += New-ProjectPreflightFileFinding -ProjectRoot $ProjectRoot -Id 'package-lock' -Purpose 'npm lockfile' -Candidates @('package-lock.json') -Required $true

    $typecheckConfigured = $checkById.ContainsKey('typecheck') -and $checkById['typecheck'].status -eq 'configured'
    $findings += New-ProjectPreflightFileFinding -ProjectRoot $ProjectRoot -Id 'typescript-config' -Purpose 'TypeScript checking' -Candidates @('tsconfig.json') -Required $typecheckConfigured -CheckId 'typecheck'

    $hasApplication = $false
    foreach ($project in @($AngularProjects.PSObject.Properties)) {
        if ((Get-ProjectProperty -Object $project.Value -Name 'projectType') -eq 'application') { $hasApplication = $true }
    }
    $buildConfigured = $checkById.ContainsKey('build') -and $checkById['build'].status -eq 'configured'
    if ($hasApplication) {
        $findings += New-ProjectPreflightFileFinding -ProjectRoot $ProjectRoot -Id 'application-typescript-config' -Purpose 'Angular application build configuration' -Candidates @('src/tsconfig.app.json', 'tsconfig.app.json') -Required $buildConfigured -CheckId 'build'
    }

    $unitConfigured = $checkById.ContainsKey('unit-test') -and $checkById['unit-test'].status -eq 'configured'
    $findings += New-ProjectPreflightFileFinding -ProjectRoot $ProjectRoot -Id 'unit-test-typescript-config' -Purpose 'Unit-test TypeScript configuration' -Candidates @('src/tsconfig.spec.json', 'tsconfig.spec.json') -Required $unitConfigured -CheckId 'unit-test'

    $configurationGroups = @(
        @{ id = 'lint-configuration'; purpose = 'Lint configuration'; checkId = 'lint'; candidates = @('.eslintrc', '.eslintrc.json', '.eslintrc.js', '.eslintrc.yml', '.eslintrc.yaml', 'eslint.config.js', 'eslint.config.mjs', 'eslint.config.cjs', 'tslint.json') },
        @{ id = 'unit-test-runner'; purpose = 'Unit-test runner configuration'; checkId = 'unit-test'; candidates = @('karma.conf.js', 'karma.conf.ts', 'jest.config.js', 'jest.config.ts', 'jest.config.json') },
        @{ id = 'e2e-runner'; purpose = 'End-to-end test runner configuration'; checkId = 'e2e'; candidates = @('cypress.config.js', 'cypress.config.ts', 'cypress.json') }
    )
    foreach ($group in $configurationGroups) {
        $configured = $checkById.ContainsKey($group.checkId) -and $checkById[$group.checkId].status -eq 'configured'
        $detected = @($Configurations | Where-Object { $_ -in $group.candidates })
        $findings += [PSCustomObject][ordered]@{
            id         = $group.id
            purpose    = $group.purpose
            checkId    = $group.checkId
            candidates = @($group.candidates)
            detected   = @($detected)
            required   = $configured
            present    = $detected.Count -gt 0
            status     = if ($detected.Count -gt 0) { 'present' } elseif ($configured) { 'missing' } else { 'not-found' }
        }
    }
    $angularTsConfigs = @(Get-ProjectAngularTsConfigPaths -AngularProjects $AngularProjects)
    $referencedTsConfigs = @(Get-ProjectTsConfigChain -ProjectRoot $ProjectRoot -Paths $angularTsConfigs)
    $knownPaths = @($findings | ForEach-Object { $_.candidates } | ForEach-Object { [string]$_ })
    foreach ($relative in @($referencedTsConfigs | Where-Object { $_ -notin $knownPaths })) {
        $findings += New-ProjectPreflightFileFinding -ProjectRoot $ProjectRoot -Id $(if ($relative -in $angularTsConfigs) { 'angular-referenced-tsconfig' } else { 'typescript-extends-config' }) -Purpose $(if ($relative -in $angularTsConfigs) { 'Angular workspace TypeScript configuration' } else { 'TypeScript extends configuration' }) -Candidates @([string]$relative) -Required $true
    }
    return @($findings)
}

function Get-ProjectInspection {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [switch]$SkipNodeToolchain
    )

    $errors = @()
    $root = Resolve-MigrationRoot -Path $ProjectRoot
    $packagePath = Join-Path $root 'package.json'
    $angularPath = Join-Path $root 'angular.json'
    $lockPath = Join-Path $root 'package-lock.json'
    $yarnLockPath = Join-Path $root 'yarn.lock'
    $pnpmLockPath = Join-Path $root 'pnpm-lock.yaml'
    $nxPath = Join-Path $root 'nx.json'
    $package = $null
    $angular = $null
    $packageManager = $null

    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        $errors += [PSCustomObject]@{ code = 'package_missing'; message = 'package.json is required at the project root' }
    }
    else {
        try { $package = Get-ProjectPackage -ProjectRoot $root }
        catch { $errors += [PSCustomObject]@{ code = 'package_invalid'; message = $_.Exception.Message } }
    }
    if (-not (Test-Path -LiteralPath $angularPath -PathType Leaf)) {
        $errors += [PSCustomObject]@{ code = 'angular_config_missing'; message = 'angular.json is required at the project root' }
    }
    else {
        try { $angular = Get-ProjectAngularConfig -ProjectRoot $root }
        catch { $errors += [PSCustomObject]@{ code = 'angular_config_invalid'; message = $_.Exception.Message } }
    }

    $inventory = if ($package) { Get-DependencyInventory -Package $package } else { [PSCustomObject]@{ items = @(); policies = @{} } }
    if ($package) {
        $packageManager = [string](Get-ProjectProperty -Object $package -Name 'packageManager')
        if ($packageManager -and $packageManager -notmatch '^npm(?:@|$)') {
            $errors += [PSCustomObject]@{ code = 'unsupported_package_manager'; message = "Only npm is supported, but package.json declares: $packageManager" }
        }
        if ($null -ne (Get-ProjectProperty -Object $package -Name 'workspaces')) {
            $errors += [PSCustomObject]@{ code = 'workspaces_not_supported'; message = 'npm workspaces are not supported by this migration controller' }
        }
    }
    $privateDependencies = @($inventory.items | Where-Object { [string]$_.name -match '^@ips(?:/|$)' })
    $npmrcPath = Join-Path $root '.npmrc'
    $npmrcLines = if (Test-Path -LiteralPath $npmrcPath -PathType Leaf) { [IO.File]::ReadAllLines($npmrcPath) } else { @() }
    $ipsRegistry = $null
    foreach ($line in @($npmrcLines)) {
        if ([string]$line -match '^\s*@ips:registry\s*=\s*(\S+)\s*$') { $ipsRegistry = [string]$Matches[1]; break }
    }
    $credentialLine = @($npmrcLines | Where-Object {
            $_ -match '(?i)(?:_authToken|_auth|password)\s*=' -and
            $_ -notmatch '\$\{[A-Za-z_][A-Za-z0-9_]*\}'
        })
    if ($credentialLine.Count -gt 0) {
        $errors += [PSCustomObject]@{ code = 'npmrc_credentials_present'; message = 'Project .npmrc contains a credential; use an environment-backed token in user/CI configuration.' }
    }
    if ($privateDependencies.Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($ipsRegistry)) {
            $errors += [PSCustomObject]@{ code = 'private_registry_scope_missing'; message = 'Dependencies in the @ips scope require an explicit @ips:registry entry in .npmrc.' }
        }
        else {
            $projectRegistry = Get-ProjectRegistryUri -Value $ipsRegistry
            $trustedRegistryValue = [Environment]::GetEnvironmentVariable('MIGRATION_IPS_REGISTRY')
            $trustedRegistry = Get-ProjectRegistryUri -Value $trustedRegistryValue
            if ($null -eq $projectRegistry -or $ipsRegistry -match '(?i)registry\.npmjs\.org') {
                $errors += [PSCustomObject]@{ code = 'private_registry_scope_invalid'; message = 'The @ips:registry entry must be an HTTPS private registry without embedded credentials.' }
            }
            elseif ($null -eq $trustedRegistry) {
                $errors += [PSCustomObject]@{ code = 'private_registry_trust_missing'; message = 'MIGRATION_IPS_REGISTRY must identify the trusted @ips registry before private dependencies can run.' }
            }
            elseif ($projectRegistry.AbsoluteUri.TrimEnd('/') -cne $trustedRegistry.AbsoluteUri.TrimEnd('/')) {
                $errors += [PSCustomObject]@{ code = 'private_registry_scope_untrusted'; message = 'The project @ips:registry does not match the trusted MIGRATION_IPS_REGISTRY value.' }
            }
        }
    }
    $coreSpec = $null
    if ($package) {
        foreach ($section in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')) {
            $values = Get-ProjectProperty -Object $package -Name $section
            if ($values -and $values.PSObject.Properties['@angular/core']) {
                $coreSpec = [string]$values.'@angular/core'
                break
            }
        }
    }
    $coreDependency = @($inventory.items | Where-Object { $_.name -eq '@angular/core' } | Select-Object -First 1)
    $declaredMajor = Get-VersionMajor -Spec $coreSpec
    $lock = $null
    try { $lock = Get-ProjectLockfile -ProjectRoot $root -DisallowAmbientNode:$SkipNodeToolchain }
    catch { $errors += [PSCustomObject]@{ code = 'lockfile_invalid'; message = $_.Exception.Message } }
    $resolvedCoreVersion = if ($lock) { [string]$lock.versions['@angular/core'] } else { $null }
    $currentMajor = Get-VersionMajor -Spec $resolvedCoreVersion
    if ($coreDependency.Count -eq 0) {
        $errors += [PSCustomObject]@{ code = 'angular_core_missing'; message = '@angular/core is required in a direct dependency section' }
    }
    elseif ($coreDependency[0].kind -ne 'registry' -or $null -eq $declaredMajor) {
        $errors += [PSCustomObject]@{ code = 'unsupported_angular_core_spec'; message = '@angular/core must use an npm registry version spec'; dependency = $coreDependency[0] }
    }
    elseif ($lock -and $null -eq $currentMajor) {
        $errors += [PSCustomObject]@{ code = 'angular_core_not_locked'; message = '@angular/core has no resolved version in package-lock.json' }
    }
    elseif ($null -ne $currentMajor -and $declaredMajor -ne $currentMajor) {
        $errors += [PSCustomObject]@{ code = 'angular_core_major_mismatch'; message = 'Declared and resolved Angular core majors differ' }
    }
    if ($lock -and $null -ne $currentMajor) {
        $frameworkPackages = @('animations', 'common', 'compiler', 'compiler-cli', 'core', 'elements', 'forms', 'language-service', 'localize', 'platform-browser', 'platform-browser-dynamic', 'platform-server', 'platform-webworker', 'platform-webworker-dynamic', 'router', 'service-worker', 'upgrade')
        $frameworkNames = @(@($inventory.items | Select-Object -ExpandProperty name) + @($lock.versions.Keys) | Where-Object {
                $_ -like '@angular/*' -and $frameworkPackages -contains ($_ -replace '^@angular/', '')
            } | Sort-Object -Unique)
        foreach ($name in $frameworkNames) {
            $resolved = Get-VersionMajor -Spec $lock.versions[$name]
            $mismatch = $null -ne $resolved -and $resolved -ne $currentMajor
            foreach ($dependency in @($inventory.items | Where-Object name -eq $name)) {
                $declared = Get-VersionMajor -Spec $dependency.spec
                if ($null -eq $declared -or $declared -ne $currentMajor) { $mismatch = $true }
            }
            if ($mismatch) {
                $errors += [PSCustomObject]@{ code = 'angular_package_major_mismatch'; message = "Angular framework major mismatch: $name" }
            }
        }
    }

    $git = Get-ProjectGit -ProjectRoot $root
    if ($git.errorCode) { $errors += [PSCustomObject]@{ code = $git.errorCode; message = $git.error } }
    $node = if ($SkipNodeToolchain) {
        [PSCustomObject]@{
            node   = [PSCustomObject]@{ available = $false; executable = $null; version = $null; stdout = $null }
            npm    = [PSCustomObject]@{ available = $false; executable = $null; version = $null; stdout = $null }
            errors = @('active Node toolchain inspection skipped; fnm discovery is authoritative')
        }
    }
    else { Get-ProjectNode -ProjectRoot $root }
    if (-not $SkipNodeToolchain -and (-not $node.node.available -or -not $node.npm.available)) {
        $errors += [PSCustomObject]@{ code = 'node_toolchain_missing'; message = 'node and npm must be available and executable'; details = $node.errors }
    }
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        $errors += [PSCustomObject]@{ code = 'lockfile_missing'; message = 'package-lock.json is required for the npm workflow' }
    }
    if (Test-Path -LiteralPath $yarnLockPath -PathType Leaf) {
        $errors += [PSCustomObject]@{ code = 'unsupported_lockfile'; message = 'yarn.lock is not supported by the npm-only workflow' }
    }
    if (Test-Path -LiteralPath $pnpmLockPath -PathType Leaf) {
        $errors += [PSCustomObject]@{ code = 'unsupported_lockfile'; message = 'pnpm-lock.yaml is not supported by the npm-only workflow' }
    }
    if (Test-Path -LiteralPath $nxPath -PathType Leaf) {
        $errors += [PSCustomObject]@{ code = 'nx_not_supported'; message = 'Nx workspaces are outside the current migration scope' }
    }

    $unsupported = @($inventory.items | Where-Object { $_.kind -ne 'registry' })
    foreach ($dependency in $unsupported) {
        $errors += [PSCustomObject]@{ code = 'unsupported_dependency_spec'; message = "Dependency requires an explicit policy: $($dependency.name)"; dependency = $dependency }
    }

    $angularProjects = if ($angular) { Get-ProjectProperty -Object $angular -Name 'projects' } else { $null }
    if ($angular -and $null -eq $angularProjects) {
        $errors += [PSCustomObject]@{ code = 'angular_projects_missing'; message = 'angular.json must contain a projects object' }
    }
    $projectNames = if ($angularProjects) { @($angularProjects.PSObject.Properties | Select-Object -ExpandProperty Name | Sort-Object) } else { @() }
    $projectConfig = [PSCustomObject]@{
        present  = $null -ne $angular
        projects = @($projectNames)
    }
    $checks = Get-ProjectChecks -Package $(if ($package) { $package } else { [PSCustomObject]@{} }) -ProjectRoot $root -HasLockfile (Test-Path -LiteralPath $lockPath -PathType Leaf)
    foreach ($check in @($checks | Where-Object status -eq 'blocked')) {
        $errors += [PSCustomObject]@{ code = 'check_blocked'; checkId = $check.id; message = $check.reason }
    }
    $configurations = @(Get-ChildItem -LiteralPath $root -File | Where-Object {
            $_.Name -match '^(?:\.eslintrc(?:\..+)?|eslint\.config\..+|tslint\.json|karma\.conf\..+|jest\.config\..+|cypress\.config\..+|cypress\.json)$'
        } | Select-Object -ExpandProperty Name)
    $referencedTsConfigs = @(Get-ProjectTsConfigChain -ProjectRoot $root -Paths @(Get-ProjectAngularTsConfigPaths -AngularProjects $angularProjects))
    $configurations = @($configurations + $referencedTsConfigs | Sort-Object -Unique)
    $builders = @()
    if ($angularProjects) {
        foreach ($project in $angularProjects.PSObject.Properties) {
            foreach ($section in @('architect', 'targets')) {
                $targets = Get-ProjectProperty -Object $project.Value -Name $section
                if ($targets) {
                    foreach ($target in $targets.PSObject.Properties) {
                        $builder = Get-ProjectProperty -Object $target.Value -Name 'builder'
                        if ($builder) { $builders += [PSCustomObject]@{ project = $project.Name; target = $target.Name; builder = $builder } }
                    }
                }
            }
        }
    }
    $projectName = if ($package -and (Get-ProjectProperty -Object $package -Name 'name')) { [string](Get-ProjectProperty -Object $package -Name 'name') } else { Split-Path -Leaf $root }
    $preflightFiles = Get-ProjectPreflightFiles -ProjectRoot $root -AngularProjects $(if ($angularProjects) { $angularProjects } else { [PSCustomObject]@{} }) -Checks $checks -Configurations $configurations
    $preflight = [PSCustomObject]@{
        requiredFiles = @($preflightFiles)
        criticalChecks = @($checks | Where-Object { $_.id -in @('install', 'dependency-tree', 'build') } | ForEach-Object { [PSCustomObject]@{ id = $_.id; status = $_.status; blocking = $true; canSkip = $false } })
        optionalChecks = @($checks | Where-Object { $_.id -in @('typecheck', 'lint', 'unit-test', 'e2e') } | ForEach-Object { [PSCustomObject]@{ id = $_.id; status = $_.status; blocking = $true; canSkip = $true; reason = $_.reason } })
    }

    return [PSCustomObject]@{
        schemaVersion   = Get-MigrationSchemaVersion
        projectRoot     = $root
        projectName     = $projectName
        ready           = $errors.Count -eq 0
        status          = if ($errors.Count -eq 0) { 'ready' } else { 'blocked' }
        blockers        = @($errors)
        files           = [PSCustomObject]@{
            packageJson    = Test-Path -LiteralPath $packagePath -PathType Leaf
            angularJson    = Test-Path -LiteralPath $angularPath -PathType Leaf
            packageLock    = Test-Path -LiteralPath $lockPath -PathType Leaf
            tsconfig       = Test-Path -LiteralPath (Join-Path $root 'tsconfig.json') -PathType Leaf
            configurations = $configurations
        }
        angular         = [PSCustomObject]@{
            currentMajor        = $currentMajor
            coreSpec            = $coreSpec
            declaredCoreSpec    = $coreSpec
            resolvedCoreVersion = $resolvedCoreVersion
            packages            = Get-AngularPackageVersions -Inventory $inventory
            projects            = @($projectConfig.projects)
        }
        packageManager  = if ($packageManager) { $packageManager } else { 'npm' }
        lockfileVersion = if ($lock) { $lock.lockfileVersion } else { $null }
        scripts         = if ($package) { Get-NpmScripts -Package $package } else { @{} }
        builders        = $builders
        dependencies    = $inventory.items
        policies        = $inventory.policies
        git             = $git
        node            = $node
        checks          = $checks
        preflight       = $preflight
    }
}

Export-ModuleMember -Function @(
    'Invoke-ProjectCheck',
    'Invoke-ProjectCheckSet',
    'Get-ProjectLockfile',
    'Get-ProjectProperty',
    'Get-ProjectPackage',
    'Get-ProjectAngularConfig',
    'Get-VersionMajor',
    'Get-DependencyKind',
    'Get-DependencyInventory',
    'Get-ProjectChecks',
    'Get-ProjectGit',
    'Get-ProjectNode',
    'Get-ProjectNodeDeclarations',
    'Get-ProjectFnmInventory',
    'Get-ProjectInputFingerprint',
    'Get-ProjectLockfileNpmMinimumRange',
    'Get-ProjectLockedTooling',
    'Get-ProjectInspection'
)
