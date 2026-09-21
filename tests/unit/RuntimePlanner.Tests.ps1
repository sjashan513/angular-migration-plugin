#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot '../../scripts/modules'
Import-Module (Join-Path $modules 'Migration.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.State.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Project.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Dependencies.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Migration.Pipeline.psm1') -Force -DisableNameChecking

function Assert-Planner {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name" -ForegroundColor Green
}

$pipelineModule = Get-Module Migration.Pipeline
Assert-Planner 'lockfile v1 requires npm 5' ((Get-ProjectLockfileNpmMinimumRange -LockfileVersion 1) -ceq '>=5')
Assert-Planner 'lockfile v2 requires npm 7' ((Get-ProjectLockfileNpmMinimumRange -LockfileVersion 2) -ceq '>=7')
Assert-Planner 'lockfile v3 requires npm 7' ((Get-ProjectLockfileNpmMinimumRange -LockfileVersion 3) -ceq '>=7')
Assert-Planner 'core accepts a spaced minimum range' (Test-MigrationVersionRange -Version '10.13.0' -Range '>= 10.13.0')
Assert-Planner 'core accepts a spaced compound range' (Test-MigrationVersionRange -Version '10.13.0' -Range '>= 10.13.0 < 11.0.0')
Assert-Planner 'core accepts partial hyphen ranges' ((Test-MigrationVersionRange -Version '2.4.0' -Range '1.9.1 - 3') -and (Test-MigrationVersionRange -Version '3.8.0' -Range '1.9.1 - 3') -and -not (Test-MigrationVersionRange -Version '4.0.0' -Range '1.9.1 - 3'))
Assert-Planner 'core accepts prerelease comparator ranges' ((Test-MigrationVersionRange -Version '10.0.0-next.1' -Range '>=10.0.0-next.0') -and (Test-MigrationVersionRange -Version '10.0.0' -Range '>=10.0.0-next.0'))
Assert-Planner 'core accepts wildcard alternatives' ((Test-MigrationVersionRange -Version '1.9.4' -Range '1.8.x || 1.9.x') -and -not (Test-MigrationVersionRange -Version '2.0.0' -Range '1.8.x || 1.9.x'))
Assert-Planner 'core rejects unsupported alternative syntax' (-not (Test-MigrationVersionRange -Version '1.9.4' -Range '1.9.x || workspace:*'))
$devkitPolicy = Get-MigrationAngularToolingVersionPolicy -AngularMajor 10 -PackageName '@angular-devkit/build-angular'
Assert-Planner 'Angular 10 DevKit uses the published 0.1000-0.1002 family' ($devkitPolicy.selector -ceq '>=0.1000.0 <0.1003.0' -and $devkitPolicy.requiredRange -ceq $devkitPolicy.selector -and $devkitPolicy.major -eq -1)
$cliPolicy = Get-MigrationAngularToolingVersionPolicy -AngularMajor 10 -PackageName '@angular/cli'
Assert-Planner 'Angular CLI keeps the Angular major selector' ($cliPolicy.selector -ceq '10' -and $cliPolicy.major -eq 10 -and $null -eq $cliPolicy.requiredRange)
$discoveryMinimum = & $pipelineModule { param($Range) Test-DiscoveryRangeSupported -Range $Range } '>= 10.13.0'
$discoveryCompound = & $pipelineModule { param($Range) Test-DiscoveryRangeSupported -Range $Range } '>= 10.13.0 < 11.0.0'
Assert-Planner 'discovery accepts a spaced minimum range' $discoveryMinimum
Assert-Planner 'discovery accepts a spaced compound range' $discoveryCompound

$candidates = @(
    [PSCustomObject]@{ nodeVersion = '22.19.0'; npmVersion = '10.9.0'; status = 'installed' }
    [PSCustomObject]@{ nodeVersion = '16.20.2'; npmVersion = '8.19.4'; status = 'installed' }
    [PSCustomObject]@{ nodeVersion = '10.24.1'; npmVersion = '6.14.18'; status = 'installed' }
    [PSCustomObject]@{ nodeVersion = '14.21.3'; npmVersion = $null; status = 'missing' }
)
$buildCandidate = & $pipelineModule { param($Items) Select-DiscoveryRuntimeCandidate -Candidates $Items -NodeRanges @('<17') -NpmRange '>=7' -Selected @() } $candidates
Assert-Planner 'build constraints prefer installed Node 16' ($buildCandidate.nodeVersion -ceq '16.20.2' -and $buildCandidate.status -ceq 'installed')
$lockCandidate = & $pipelineModule { param($Items) Select-DiscoveryRuntimeCandidate -Candidates $Items -NodeRanges @('10') -NpmRange '>=7' -Selected @() } $candidates
Assert-Planner 'incompatible installed npm is not selected for lockfile v3' ($null -eq $lockCandidate)
$metadataCandidate = & $pipelineModule { param($Items) Select-DiscoveryRuntimeCandidate -Candidates $Items -NodeRanges @() -NpmRange '>=7' -Selected @() } $candidates
Assert-Planner 'metadata selection prefers the highest compatible installed runtime' ($metadataCandidate.nodeVersion -ceq '22.19.0')
$compoundCandidate = & $pipelineModule { param($Items) Select-DiscoveryRuntimeCandidate -Candidates $Items -NodeRanges @('>= 10.13.0 < 21.0.0') -NpmRange '>=7' -Selected @() } $candidates
Assert-Planner 'planner evaluates spaced compound ranges' ($compoundCandidate.nodeVersion -ceq '16.20.2')
Write-Host 'Runtime planner contracts OK' -ForegroundColor Green