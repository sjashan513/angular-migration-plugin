#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/modules/Migration.Project.psm1') -Force -DisableNameChecking
$root = Join-Path ([IO.Path]::GetTempPath()) ('migration-project-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    foreach ($version in @(1, 2, 3)) {
        $lock = if ($version -eq 1) {
            @{ lockfileVersion = 1; dependencies = @{ '@angular/core' = @{ version = '7.2.16' } } }
        }
        else {
            @{ lockfileVersion = $version; packages = @{ 'node_modules/@angular/core' = @{ version = '7.2.16' } } }
        }
        $lock | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root 'package-lock.json') -Encoding UTF8
        $result = Get-ProjectLockfile -ProjectRoot $root
        if ($result.versions.'@angular/core' -ne '7.2.16') { throw "Lockfile v$version did not return the resolved core version" }
    }
    Write-Host 'PASS lockfile v1/v2/v3 resolved versions'
    $module = Get-Module Migration.Project
    & $module {
        function script:Get-ProjectGit { return [PSCustomObject]@{ available = $true; valid = $true; clean = $true; detached = $false; identityConfigured = $true; stateDirectoryIgnored = $true; error = $null; errorCode = $null } }
        function script:Get-ProjectNode { return [PSCustomObject]@{ node = @{ available = $true }; npm = @{ available = $true }; errors = @() } }
    }
    '{"dependencies":{"@angular/core":"^7.2.0"},"scripts":{"build":"echo build","type-check":"echo types","typecheck":"echo preferred","test":"echo test","test:unit":"echo preferred","test:e2e":"echo e2e","cy:run":"echo other"}}' | Set-Content (Join-Path $root 'package.json')
    '{"projects":{"app":{"projectType":"application"}}}' | Set-Content (Join-Path $root 'angular.json')
    $inspection = Get-ProjectInspection -ProjectRoot $root
    if ($inspection.angular.resolvedCoreVersion -ne '7.2.16' -or $inspection.angular.declaredCoreSpec -ne '^7.2.0' -or -not $inspection.ready) { throw 'Inspection must preserve declared and resolved versions' }
    $checks = $inspection.checks
    if (($checks.id -join ',') -ne 'install,dependency-tree,typecheck,lint,unit-test,build,e2e') { throw 'Invalid check order' }
    if (($checks.timeoutSeconds -join ',') -ne '900,300,600,600,900,1200,1800') { throw 'Invalid check timeouts' }
    if ($checks[2].arguments[1] -ne 'typecheck' -or $checks[4].arguments[1] -ne 'test:unit' -or $checks[6].arguments[1] -ne 'test:e2e') { throw 'Script priority mismatch' }
    if ($checks[3].status -ne 'not-configured' -or $checks[5].displayCommand -ne 'npm run build' -or $checks[5].phase -ne 'baseline' -or -not $checks[5].blocking) { throw 'Invalid structured check contract' }
    '{"dependencies":{"@angular/core":"^8.0.0"}}' | Set-Content (Join-Path $root 'package.json')
    $inspection = Get-ProjectInspection -ProjectRoot $root
    if ($inspection.blockers.code -notcontains 'angular_core_major_mismatch') { throw 'Major mismatch was not blocked' }
    if ($inspection.checks[5].status -ne 'blocked' -or $inspection.checks[6].status -ne 'not-configured') { throw 'Application build must be mandatory; e2e optional' }
    '{"projects":{"lib":{"projectType":"library"}}}' | Set-Content (Join-Path $root 'angular.json')
    if ((Get-ProjectInspection -ProjectRoot $root).checks[5].status -ne 'not-configured') { throw 'Library build should be optional' }
    'invalid' | Set-Content (Join-Path $root 'package-lock.json')
    if ((Get-ProjectInspection -ProjectRoot $root).blockers.code -notcontains 'lockfile_invalid') { throw 'Invalid lockfile was not blocked' }
    Write-Host 'PASS inspection and check discovery contracts'
    '{"lockfileVersion":1,"dependencies":{}}' | Set-Content (Join-Path $root 'package-lock.json')
    if ((Get-ProjectInspection -ProjectRoot $root).blockers.code -notcontains 'angular_core_not_locked') { throw 'Unlocked core must block' }
    '{"dependencies":{},"scripts":{}}' | Set-Content (Join-Path $root 'package.json')
    if ((Get-ProjectInspection -ProjectRoot $root).blockers.code -notcontains 'angular_core_missing') { throw 'Missing core must block' }
    '{"dependencies":{"@angular/core":"^7.2.0","@angular/common":"^8.0.0","@angular/material":"^6.0.0"}}' | Set-Content (Join-Path $root 'package.json')
    '{"lockfileVersion":1,"dependencies":{"@angular/core":{"version":"7.2.16"},"@angular/common":{"version":"8.0.0"}}}' | Set-Content (Join-Path $root 'package-lock.json')
    $inspection = Get-ProjectInspection -ProjectRoot $root
    if (@($inspection.blockers | Where-Object code -eq 'angular_package_major_mismatch').Count -ne 1) { throw 'Framework mismatch must block; Material is not a framework package' }
    '{"dependencies":{"@angular/core":"^7.2.0"}}' | Set-Content (Join-Path $root 'package.json')
    '{"lockfileVersion":1,"dependencies":{"@angular/core":{"version":"7.2.16"},"@angular/compiler":{"version":"8.0.0"}}}' | Set-Content (Join-Path $root 'package-lock.json')
    if ((Get-ProjectInspection -ProjectRoot $root).blockers.code -notcontains 'angular_package_major_mismatch') { throw 'Locked transitive framework mismatch must block' }
    foreach ($invalidVersion in @('^7.2.16', '7', 'invalid')) {
        @{ lockfileVersion = 1; dependencies = @{ '@angular/core' = @{ version = $invalidVersion } } } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root 'package-lock.json')
        if ((Get-ProjectInspection -ProjectRoot $root).blockers.code -notcontains 'lockfile_invalid') { throw 'Locked core version must be exact' }
    }
    '{invalid' | Set-Content (Join-Path $root 'angular.json')
    if ((Get-ProjectInspection -ProjectRoot $root).blockers.code -notcontains 'angular_config_invalid') { throw 'Invalid Angular config must block inspection' }
    Write-Host 'PASS missing core, framework mismatch and invalid configuration'
    Import-Module (Join-Path $PSScriptRoot '../../scripts/modules/Migration.Project.psm1') -Force -DisableNameChecking
    $module = Get-Module Migration.Project
    & $module {
        $script:scenario = 'ready'
        function script:Find-MigrationExecutable { param($Names) if ($script:scenario -ne 'git_missing') { return $Names[0] } }
        function script:Invoke-MigrationProcess {
            param($FilePath, $Arguments, $WorkingDirectory, $TimeoutSeconds)
            $output = ''; $exitCode = 0
            switch ($Arguments -join ' ') {
                'rev-parse --show-toplevel' { $output = if ($script:scenario -eq 'git_root_mismatch') { Split-Path $WorkingDirectory } else { $WorkingDirectory }; if ($script:scenario -eq 'git_repository_missing') { $exitCode = 128 } }
                'rev-parse HEAD' { $output = 'a' * 40 }
                'symbolic-ref --quiet --short HEAD' { $output = 'main'; if ($script:scenario -eq 'git_detached_head') { $exitCode = 1; $output = '' } }
                'status --porcelain=v1 --untracked-files=all' { if ($script:scenario -eq 'git_dirty') { $output = '?? untracked.txt' } }
                'check-ignore --quiet -- .angular-migration/.probe' { if ($script:scenario -eq 'migration_state_not_ignored') { $exitCode = 1 } }
                'config user.name' { $output = 'Fixture'; if ($script:scenario -eq 'git_identity_missing') { $exitCode = 1; $output = '' } }
                'config user.email' { $output = 'fixture@example.invalid' }
                '--version' { $output = if ($FilePath -like 'node*') { 'v20.11.1' } else { '10.2.4' }; if ($script:scenario -eq 'tool_failure') { $exitCode = 1; $output = 'full failure stdout' } }
                default { throw "Unexpected process arguments: $Arguments" }
            }
            return [PSCustomObject]@{ stdout = $output; stderr = ''; exitCode = $exitCode; timedOut = $false }
        }
    }
    $git = Get-ProjectGit -ProjectRoot $root
    if (-not $git.valid -or $git.detached -or -not $git.identityConfigured -or $git.branch -ne 'main' -or $git.head -ne ('a' * 40)) { throw 'Ready Git context is invalid' }
    foreach ($scenario in @('git_missing', 'git_repository_missing', 'git_root_mismatch', 'git_detached_head', 'git_dirty', 'git_identity_missing', 'migration_state_not_ignored')) {
        & $module { param($value) $script:scenario = $value } $scenario
        if ((Get-ProjectGit -ProjectRoot $root).errorCode -ne $scenario) { throw "Missing Git diagnosis: $scenario" }
    }
    & $module { $script:scenario = 'ready' }
    $tools = Get-ProjectNode -ProjectRoot $root
    if ($tools.node.version -ne '20.11.1' -or $tools.node.executable -ne 'node.exe' -or $tools.npm.executable -ne 'npm.cmd') { throw 'Tool version or executable normalization failed' }
    & $module { $script:scenario = 'tool_failure' }
    $tools = Get-ProjectNode -ProjectRoot $root
    if ($tools.node.available -or $tools.npm.available -or $tools.node.stdout -ne 'full failure stdout') { throw 'Failed tools must be unusable and retain stdout' }
    Write-Host 'PASS Git blockers and tool detection'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}