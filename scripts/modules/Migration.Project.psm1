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
    $match = [regex]::Match($Spec, '(?<!\d)(\d+)(?:\.\d+)?')
    if (-not $match.Success) { return $null }
    return [int]$match.Groups[1].Value
}

function Get-DependencyKind {
    param([string]$Spec)

    if ([string]::IsNullOrWhiteSpace($Spec)) { return 'invalid' }
    if ($Spec -match '^npm:') { return 'alias' }
    if ($Spec -match '^(git\+|git@|git://|github:|bitbucket:|gitlab:)') { return 'git' }
    if ($Spec -match '^https?://') { return 'url' }
    if ($Spec -match '^(file:|workspace:)') { return 'local' }
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
    $installCommand = if ($HasLockfile) { 'npm ci' } else { 'npm install' }
    $checks += [PSCustomObject]@{
        id = 'install'
        status = if ($HasLockfile) { 'configured' } else { 'blocked' }
        command = $installCommand
        cwd = $ProjectRoot
        reason = if ($HasLockfile) { $null } else { 'package-lock.json is required for the supported npm workflow' }
    }
    $checks += [PSCustomObject]@{
        id = 'dependency-tree'
        status = if ($HasLockfile) { 'configured' } else { 'blocked' }
        command = 'npm ls --all --depth=0'
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
        $checks += [PSCustomObject]@{
            id = $definition.id
            status = if ($scriptName) { 'configured' } else { 'not-configured' }
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
            clean = $false
            branch = $null
            head = $null
            repositoryRoot = $null
            dirtyFiles = @()
            error = 'git is not available'
        }
    }

    $rootResult = Invoke-MigrationProcess -FilePath $git -Arguments @('rev-parse', '--show-toplevel') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    if ($rootResult.exitCode -ne 0) {
        return [PSCustomObject]@{
            available = $true
            clean = $false
            branch = $null
            head = $null
            repositoryRoot = $null
            dirtyFiles = @()
            error = 'project is not inside a Git repository'
        }
    }

    $repositoryRoot = $rootResult.stdout.Trim()
    $statusResult = Invoke-MigrationProcess -FilePath $git -Arguments @('status', '--porcelain') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $branchResult = Invoke-MigrationProcess -FilePath $git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $headResult = Invoke-MigrationProcess -FilePath $git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $ProjectRoot -TimeoutSeconds 15
    $dirtyFiles = @($statusResult.stdout -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
    $sameRepository = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\').Equals(
        [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )

    return [PSCustomObject]@{
        available = $true
        clean = $statusResult.exitCode -eq 0 -and $dirtyFiles.Count -eq 0 -and $sameRepository
        branch = $branchResult.stdout.Trim()
        head = if ($headResult.exitCode -eq 0) { $headResult.stdout.Trim() } else { $null }
        repositoryRoot = $repositoryRoot
        dirtyFiles = $dirtyFiles
        error = if (-not $sameRepository) { 'Git repository root does not match the project root' } elseif ($statusResult.exitCode -ne 0) { $statusResult.stderr.Trim() } else { $null }
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
        node = [PSCustomObject]@{ available = [bool]$node; version = $nodeVersion }
        npm = [PSCustomObject]@{ available = [bool]$npm; version = $npmVersion }
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
    $package = $null
    $angular = $null

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
    $currentMajor = Get-VersionMajor -Spec $coreSpec
    if ($null -eq $currentMajor) {
        $errors += [PSCustomObject]@{ code = 'angular_core_missing'; message = '@angular/core with a numeric major is required' }
    }

    $git = Get-ProjectGit -ProjectRoot $root
    if (-not $git.available) { $errors += [PSCustomObject]@{ code = 'git_missing'; message = $git.error } }
    elseif (-not $git.clean) { $errors += [PSCustomObject]@{ code = 'git_dirty'; message = 'The Git working tree must be clean'; files = $git.dirtyFiles } }
    $node = Get-ProjectNode -ProjectRoot $root
    if (-not $node.node.available -or -not $node.npm.available) {
        $errors += [PSCustomObject]@{ code = 'node_toolchain_missing'; message = 'node and npm are required' }
    }
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        $errors += [PSCustomObject]@{ code = 'lockfile_missing'; message = 'package-lock.json is required for the npm workflow' }
    }

    $unsupported = @($inventory.items | Where-Object { $_.kind -ne 'registry' })
    foreach ($dependency in $unsupported) {
        $errors += [PSCustomObject]@{ code = 'unsupported_dependency_spec'; message = "Dependency requires an explicit policy: $($dependency.name)"; dependency = $dependency }
    }

    $projectConfig = [PSCustomObject]@{
        present = $null -ne $angular
        projects = if ($angular) { @((Get-ProjectProperty -Object $angular -Name 'projects').PSObject.Properties.Name | Sort-Object) } else { @() }
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
            projects = $projectConfig.projects
        }
        packageManager = 'npm'
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
