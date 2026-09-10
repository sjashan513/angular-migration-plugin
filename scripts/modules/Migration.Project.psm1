Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -DisableNameChecking

function Get-ProjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-ProjectPackage {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $path = Resolve-MigrationPath -ProjectRoot $ProjectRoot -Path 'package.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return Read-MigrationJson -Path $path
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
        dependencies = 'runtime'
        devDependencies = 'dev'
        optionalDependencies = 'optional'
        peerDependencies = 'peer'
    }
    $items = @()
    foreach ($section in $sectionRoles.Keys) {
        $values = Get-ProjectProperty -Object $Package -Name $section
        if ($null -eq $values) { continue }
        foreach ($name in @($values.PSObject.Properties.Name | Sort-Object)) {
            $spec = [string]$values.$name
            $items += [PSCustomObject]@{
                name = $name
                section = $section
                role = $sectionRoles[$section]
                spec = $spec
                kind = Get-DependencyKind -Spec $spec
            }
        }
    }

    $policies = [ordered]@{}
    foreach ($policyName in @('peerDependenciesMeta', 'overrides')) {
        $policy = Get-ProjectProperty -Object $Package -Name $policyName
        if ($null -ne $policy) { $policies[$policyName] = $policy }
    }

    return [PSCustomObject]@{
        items = @($items)
        policies = $policies
    }
}

function Get-NpmScripts {
    param([Parameter(Mandatory = $true)]$Package)

    $scripts = Get-ProjectProperty -Object $Package -Name 'scripts'
    if ($null -eq $scripts) { return @{} }
    $result = @{}
    foreach ($name in @($scripts.PSObject.Properties.Name)) {
        $result[$name] = [string]$scripts.$name
    }
    return $result
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
    $installArguments = if ($HasLockfile) { @('ci') } else { @('install') }
    $checks += [PSCustomObject]@{
        id = 'install'
        status = if ($HasLockfile) { 'configured' } else { 'blocked' }
        executable = 'npm'
        arguments = @($installArguments)
        command = if ($HasLockfile) { 'npm ci' } else { 'npm install' }
        cwd = $ProjectRoot
        reason = if ($HasLockfile) { $null } else { 'package-lock.json is required for the supported npm workflow' }
    }
    $checks += [PSCustomObject]@{
        id = 'dependency-tree'
        status = if ($HasLockfile) { 'configured' } else { 'blocked' }
        executable = 'npm'
        arguments = @('ls', '--all')
        command = 'npm ls --all'
        cwd = $ProjectRoot
        reason = if ($HasLockfile) { $null } else { 'package-lock.json is required for the supported npm workflow' }
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
            id = $definition.id
            status = if ($scriptName) { 'configured' } else { 'not-configured' }
            executable = if ($scriptName) { 'npm' } else { $null }
            arguments = @($scriptArguments)
            command = if ($scriptName) { "npm run $scriptName" } else { $null }
            cwd = $ProjectRoot
            reason = if ($scriptName) { $null } else { 'No matching npm script was found' }
        }
    }
    return @($checks)
}

function Get-ProjectGit {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $git = Find-MigrationExecutable -Names @('git.exe', 'git')
    if (-not $git) {
        return [PSCustomObject]@{
            available = $false
            valid = $false
            clean = $false
            branch = $null
            head = $null
            repositoryRoot = $null
            dirtyFiles = @()
            stateDirectoryIgnored = $false
            error = 'git is not available'
        }
    }

    $rootResult = Invoke-MigrationProcess -FilePath $git -Arguments @('rev-parse', '--show-toplevel') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    if ($rootResult.exitCode -ne 0) {
        return [PSCustomObject]@{
            available = $true
            valid = $false
            clean = $false
            branch = $null
            head = $null
            repositoryRoot = $null
            dirtyFiles = @()
            stateDirectoryIgnored = $false
            error = 'project is not inside a Git repository'
        }
    }

    $repositoryRoot = $rootResult.stdout.Trim()
    $statusResult = Invoke-MigrationProcess -FilePath $git -Arguments @('status', '--porcelain') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $branchResult = Invoke-MigrationProcess -FilePath $git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $headResult = Invoke-MigrationProcess -FilePath $git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $ignoreResult = Invoke-MigrationProcess -FilePath $git -Arguments @('check-ignore', '--quiet', '--', '.angular-migration/.probe') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $dirtyFiles = @($statusResult.stdout -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
    $sameRepository = (Resolve-MigrationRoot -Path $repositoryRoot).Equals(
        (Resolve-MigrationRoot -Path $ProjectRoot),
        [StringComparison]::OrdinalIgnoreCase
    )

    $gitContextValid = $statusResult.exitCode -eq 0 -and $branchResult.exitCode -eq 0 -and $headResult.exitCode -eq 0
    $gitError = if (-not $sameRepository) {
        'Git repository root does not match the project root'
    }
    elseif (-not $gitContextValid) {
        $diagnostic = (@($statusResult.stderr, $branchResult.stderr, $headResult.stderr) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join [Environment]::NewLine
        if ($diagnostic) { $diagnostic } else { 'Git context commands failed' }
    }
    else {
        $null
    }

    return [PSCustomObject]@{
        available = $true
        valid = $gitContextValid -and $sameRepository
        clean = $gitContextValid -and $dirtyFiles.Count -eq 0 -and $sameRepository
        branch = if ($branchResult.exitCode -eq 0) { $branchResult.stdout.Trim() } else { $null }
        head = if ($headResult.exitCode -eq 0) { $headResult.stdout.Trim() } else { $null }
        repositoryRoot = $repositoryRoot
        dirtyFiles = $dirtyFiles
        stateDirectoryIgnored = $ignoreResult.exitCode -eq 0
        error = $gitError
    }
}

function Get-ProjectNode {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $node = Find-MigrationExecutable -Names @('node.exe', 'node')
    $npm = Find-MigrationExecutable -Names @('npm.cmd', 'npm.exe', 'npm')
    $nodeVersion = $null
    $npmVersion = $null
    $errors = @()
    if ($node) {
        $nodeResult = Invoke-MigrationProcess -FilePath $node -Arguments @('--version') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
        if ($nodeResult.exitCode -eq 0) { $nodeVersion = $nodeResult.stdout.Trim() } else { $errors += $nodeResult.stderr.Trim() }
    }
    else { $errors += 'node is not available' }
    if ($npm) {
        $npmResult = Invoke-MigrationProcess -FilePath $npm -Arguments @('--version') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
        if ($npmResult.exitCode -eq 0) { $npmVersion = $npmResult.stdout.Trim() } else { $errors += $npmResult.stderr.Trim() }
    }
    else { $errors += 'npm is not available' }

    return [PSCustomObject]@{
        node = [PSCustomObject]@{ available = [bool]($node -and $nodeVersion); version = $nodeVersion }
        npm = [PSCustomObject]@{ available = [bool]($npm -and $npmVersion); version = $npmVersion }
        errors = @($errors | Where-Object { $_ })
    }
}

function Get-AngularPackageVersions {
    param([Parameter(Mandatory = $true)]$Inventory)

    $angularPackages = @{}
    foreach ($item in @($Inventory.items | Where-Object { $_.name -like '@angular/*' })) {
        $angularPackages[$item.name] = $item.spec
    }
    return $angularPackages
}

function Get-ProjectInspection {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

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
    $currentMajor = Get-VersionMajor -Spec $coreSpec
    if ($null -eq $currentMajor -or $coreDependency.Count -eq 0) {
        $errors += [PSCustomObject]@{ code = 'angular_core_missing'; message = '@angular/core with a numeric major is required' }
    }
    elseif ($coreDependency[0].kind -ne 'registry') {
        $errors += [PSCustomObject]@{ code = 'unsupported_angular_core_spec'; message = '@angular/core must use an npm registry version spec'; dependency = $coreDependency[0] }
    }

    $git = Get-ProjectGit -ProjectRoot $root
    if (-not $git.available) { $errors += [PSCustomObject]@{ code = 'git_missing'; message = $git.error } }
    elseif (-not $git.valid) { $errors += [PSCustomObject]@{ code = 'git_context_invalid'; message = $git.error } }
    elseif (-not $git.clean) { $errors += [PSCustomObject]@{ code = 'git_dirty'; message = 'The Git working tree must be clean'; files = $git.dirtyFiles } }
    if ($git.valid -and -not $git.stateDirectoryIgnored) {
        $errors += [PSCustomObject]@{ code = 'migration_state_not_ignored'; message = '.angular-migration/ must be ignored by Git before starting a run' }
    }
    $node = Get-ProjectNode -ProjectRoot $root
    if (-not $node.node.available -or -not $node.npm.available) {
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
    $projectNames = if ($angularProjects) { @($angularProjects.PSObject.Properties.Name | Sort-Object) } else { @() }
    $projectConfig = [PSCustomObject]@{
        present = $null -ne $angular
        projects = @($projectNames)
    }
    $checks = Get-ProjectChecks -Package $(if ($package) { $package } else { [PSCustomObject]@{} }) -ProjectRoot $root -HasLockfile (Test-Path -LiteralPath $lockPath -PathType Leaf)
    $projectName = if ($package -and (Get-ProjectProperty -Object $package -Name 'name')) { [string](Get-ProjectProperty -Object $package -Name 'name') } else { Split-Path -Leaf $root }

    return [PSCustomObject]@{
        schemaVersion = Get-MigrationSchemaVersion
        projectRoot = $root
        projectName = $projectName
        ready = $errors.Count -eq 0
        status = if ($errors.Count -eq 0) { 'ready' } else { 'blocked' }
        blockers = @($errors)
        files = [PSCustomObject]@{
            packageJson = Test-Path -LiteralPath $packagePath -PathType Leaf
            angularJson = Test-Path -LiteralPath $angularPath -PathType Leaf
            packageLock = Test-Path -LiteralPath $lockPath -PathType Leaf
        }
        angular = [PSCustomObject]@{
            currentMajor = $currentMajor
            coreSpec = $coreSpec
            packages = Get-AngularPackageVersions -Inventory $inventory
            projects = @($projectConfig.projects)
        }
        packageManager = if ($packageManager) { $packageManager } else { 'npm' }
        dependencies = $inventory.items
        policies = $inventory.policies
        git = $git
        node = $node
        checks = $checks
    }
}

Export-ModuleMember -Function @(
    'Get-ProjectProperty',
    'Get-ProjectPackage',
    'Get-ProjectAngularConfig',
    'Get-VersionMajor',
    'Get-DependencyKind',
    'Get-DependencyInventory',
    'Get-ProjectChecks',
    'Get-ProjectGit',
    'Get-ProjectNode',
    'Get-ProjectInspection'
)
