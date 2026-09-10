#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../../scripts/modules'
Import-Module (Join-Path $modules 'Migration.Pipeline.psm1') -Force -DisableNameChecking
$pipeline = Get-Module Migration.Pipeline
& $pipeline {
    $source = ${function:Invoke-MigrationRun}.ToString()
    if ($source -notmatch "status -in @\('needs-repair', 'blocked', 'failed'\)") {
        throw 'run must not bypass record-repair'
    }
    $root = (Get-Location).Path
    $timestamp = '2026-09-10T10:00:00.1234567Z'
    $original = [PSCustomObject]@{ timestamp = $timestamp }
    $parsed = [PSCustomObject]@{ timestamp = [datetime]::Parse($timestamp).ToUniversalTime() }
    if ((Get-PipelineObjectHash $original) -cne (Get-PipelineObjectHash $parsed)) { throw 'JSON date parsing must not change canonical hashes' }
    $scope = @(Get-PipelineRepairPaths -ProjectRoot $root -Stage validate -CheckId build -Output 'src/app.ts:1 TS2554')
    if ($scope -notcontains 'src/**/*' -or $scope -contains 'angular.json') { throw 'Configuration must be diagnostic-driven' }
    $scope = @(Get-PipelineRepairPaths -ProjectRoot $root -Stage validate -CheckId build -Output 'tsconfig.json: invalid option')
    if ($scope -notcontains 'tsconfig.json') { throw 'Explicit configuration must be repairable' }
    $scope = @(Get-PipelineRepairPaths -ProjectRoot $root -Stage update-angular -CheckId ng-update -Output 'src/../package.json src/app.ts:1')
    if ($scope.Count -ne 1 -or $scope[0] -cne 'src/app.ts') { throw 'ng-update scope must be exact and reject traversal' }
    $scope = @(Get-PipelineRepairPaths -ProjectRoot $root -Stage update-angular -CheckId ng-update -Output 'angular.json: configuration')
    if ($scope -contains 'angular.json') { throw 'ng-update requires controller config authorization' }
    $scope = @(Get-PipelineRepairPaths -ProjectRoot $root -Stage update-angular -CheckId ng-update -Output 'angular.json: configuration' -ConfigRepairAllowed)
    if ($scope -notcontains 'angular.json') { throw 'Controller-authorized config repair should be available' }
    foreach ($gate in @('npm-install', 'integrity', 'git', 'node', 'manifest')) {
        if (@(Get-PipelineRepairPaths -ProjectRoot $root -Stage validate -CheckId $gate -Output 'src/app.ts:1').Count -ne 0) { throw 'Deterministic blockers must not have a repair scope' }
    }
    $secretRoot = Join-Path ([IO.Path]::GetTempPath()) ('repair-redaction-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $secretRoot | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $secretRoot '.npmrc'), 'custom=private-fixture-value')
        $datePath = Join-Path $secretRoot 'date.json'
        Write-MigrationJsonAtomic -Value $original -Path $datePath
        $dateValue = Read-MigrationJson -Path $datePath -Required
        if ($dateValue.timestamp -isnot [string] -or $dateValue.timestamp -cne $timestamp) { throw 'JSON reader must preserve timestamp text' }
        $redacted = Protect-RepairText -Root $secretRoot -Text "Authorization: Bearer fixture-secret`nhttps://user:password@registry.invalid/path`nprivate-fixture-value`nghp_exampletoken`nsrc/app.ts:1 TS2554"
        if ($redacted -match 'fixture-secret|password|private-fixture-value|ghp_exampletoken' -or $redacted -notmatch 'TS2554') { throw 'Diagnostic redaction failed' }
    }
    finally { Remove-Item -LiteralPath $secretRoot -Recurse -Force }
    if (-not (Test-RepairGlob 'src/app.ts' 'src/**/*') -or -not (Test-RepairGlob 'src/app/a.ts' 'src/**/*')) { throw 'Recursive glob must include direct children' }
    if (Test-RepairAllowedPath 'package.json' ([PSCustomObject]@{ allowedPaths = @('**'); forbiddenPaths = @('package.json') })) { throw 'Forbidden must prevail' }
    foreach ($invalid in @('src/../package.json', 'src/file.ts:stream', 'src/file.ts.', 'src/CON')) {
        $rejected = $false
        try { Resolve-RepairPath $root $invalid | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Unsafe path accepted: $invalid" }
    }
}
Write-Host 'PASS run cannot resume an unregistered repair'