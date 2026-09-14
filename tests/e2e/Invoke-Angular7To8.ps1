#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$facadePath = Join-Path $repositoryRoot 'scripts/angular-migration.ps1'
$fixtureRoot = Join-Path $repositoryRoot 'tests/fixtures/migrations'
$projectFixture = Join-Path $fixtureRoot 'project'
$sourceTools = Join-Path $fixtureRoot 'tools'
$registryFixture = Join-Path $fixtureRoot 'registry/responses.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('angular-migration-e2e-' + [guid]::NewGuid().ToString('N'))
$toolDirectory = Join-Path $temporaryRoot 'tools'
$projectRoot = Join-Path $temporaryRoot 'angular7-to-8'

$originalPath = $env:PATH
$originalFixtureRoot = $env:MIGRATION_FIXTURE_ROOT
$originalFixtureTools = $env:MIGRATION_FIXTURE_TOOLS
$originalRegistryFixture = $env:MIGRATION_REGISTRY_FIXTURE
$originalNodeScript = $env:MIGRATION_FIXTURE_NODE_SCRIPT

function Assert-E2E {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][bool]$Condition)

    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name" -ForegroundColor Green
}

function Write-E2EJson {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$Path)

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $json = $Value | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Read-E2EJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Invoke-Facade {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$ExpectedExitCode = 0
    )

    $commandArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $facadePath) + @($Arguments) + @('-ProjectRoot', $ProjectRoot)
    $stderrPath = Join-Path $temporaryRoot ([guid]::NewGuid().ToString('N') + '.stderr.log')
    try {
        $stdout = & powershell.exe @commandArguments 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $raw = [string]::Join("`n", @($stdout))
        if ($exitCode -ne $ExpectedExitCode) {
            $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
            throw "Facade exit code $exitCode, expected $ExpectedExitCode. stdout=$raw stderr=$stderr"
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Facade returned empty stdout.' }
        return ($raw | ConvertFrom-Json)
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function New-NodeFixtureExecutable {
    $source = @'
using System;
using System.Diagnostics;

public class MigrationNodeFixture {
    private static string Quote(string value) {
        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    public static int Main(string[] args) {
        var script = Environment.GetEnvironmentVariable("MIGRATION_FIXTURE_NODE_SCRIPT");
        var info = new ProcessStartInfo("powershell.exe");
        info.Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(script);
        foreach (var arg in args) { info.Arguments += " " + Quote(arg); }
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardInput = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        using (var process = new Process()) {
            process.StartInfo = info;
            process.Start();
            process.StandardInput.Write(Console.In.ReadToEnd());
            process.StandardInput.Close();
            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();
            Console.Out.Write(stdout);
            Console.Error.Write(stderr);
            return process.ExitCode;
        }
    }
}
'@
    Add-Type -TypeDefinition $source -OutputAssembly (Join-Path $toolDirectory 'node.exe') -OutputType ConsoleApplication
}

function New-E2EProject {
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $projectFixture -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $projectRoot $item.Name) -Recurse -Force
    }
    $ngDirectory = Join-Path $projectRoot 'node_modules/.bin'
    New-Item -ItemType Directory -Path $ngDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceTools 'ng.cmd') -Destination (Join-Path $ngDirectory 'ng.cmd') -Force
    New-Item -ItemType File -Path (Join-Path $projectRoot '.fixture-fail-second-build') -Force | Out-Null
    & git -C $projectRoot init --quiet
    & git -C $projectRoot config user.name 'Angular Migration E2E'
    & git -C $projectRoot config user.email 'angular-migration-e2e@example.invalid'
    & git -C $projectRoot add .
    & git -C $projectRoot commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the E2E Git fixture.' }
}

function New-ResearchInput {
    param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$RunId)

    return [PSCustomObject][ordered]@{
        schemaVersion = 1
        runId = $RunId
        sourceMajor = 7
        targetMajor = 8
        manifestSha256 = [string]$Manifest.manifestSha256
        researchedAt = [DateTime]::UtcNow.ToString('o')
        sources = @([PSCustomObject][ordered]@{
            id = 'S-001'
            title = 'Angular update guide'
            url = 'https://angular.dev/update-guide'
            publisher = 'Angular'
            primary = $true
            accessedAt = [DateTime]::UtcNow.ToString('o')
        })
        findings = @([PSCustomObject][ordered]@{
            id = 'F-001'
            kind = 'official-change'
            area = 'framework'
            title = 'Angular 7 to 8 migration guidance'
            summary = 'The official guide describes the supported migration path.'
            affectedPackages = @('@angular/core')
            sourceIds = @('S-001')
            applicability = 'applicable'
        })
        concepts = @([PSCustomObject][ordered]@{
            id = 'C-001'
            name = 'Migration schematics'
            whyItMatters = 'Automated transformations still require review of the committed diff.'
            sourceIds = @('S-001')
        })
        unresolved = @()
    }
}

function New-DocumentationFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Result
    )

    $directory = Join-Path $ProjectRoot 'docs/migration/v8'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $dependencyRows = @($Manifest.dependencies | ForEach-Object {
            $before = if ($_.currentVersion) { [string]$_.currentVersion } else { '-' }
            "| $($_.name) | $($_.section) | $before | $($_.targetVersion) | $($_.change) | $($_.reason) |"
        }) -join [Environment]::NewLine
    $repairText = @($Result.repairs | ForEach-Object { [string]$_.fingerprint }) -join ', '
    $warningText = if (@($Result.warnings).Count -eq 0) { 'No quedaron warnings registrados por la pipeline.' } else { 'Warnings aceptados y documentados para seguimiento.' }
    $content = [ordered]@{
        'README.md' = @"
# Migracion Angular 7 a 8

## Resultado
La migracion tecnica quedo verified y la documentacion usa evidencia del run.

## Navegacion
[Changes](changes.md) | [Dependencies](dependencies.md) | [Errors](errors-and-repairs.md) | [New concepts](new-concepts.md) | [Sources](sources.md) | [Validation](validation.md) | [Warnings](warnings.md)
"@
        'changes.md' = @"
# Cambios aplicados

La guia oficial se registro en [S-001](sources.md#S-001). Las transformaciones observadas se conservaron en commits del run.
"@
        'dependencies.md' = @"
# Dependencias

| Paquete | Seccion | Antes | Despues | Cambio | Motivo |
| --- | --- | --- | --- | --- | --- |
$dependencyRows
"@
        'errors-and-repairs.md' = @"
# Errores y reparaciones

La reparacion registrada fue: $repairText.
"@
        'warnings.md' = @"
# Warnings

$warningText
"@
        'new-concepts.md' = @"
# Nuevos conceptos

## Migration schematics

Las schematics automatizan transformaciones conocidas; el equipo debe revisar el diff.

Fuente: [S-001](sources.md#S-001).
"@
        'validation.md' = @"
# Validacion

El resultado tecnico verified se apoyo en el check build y en result:$($Result.resultSha256).
"@
        'sources.md' = @"
# Fuentes

## Fuentes primarias

S-001. Angular. Angular update guide. https://angular.dev/update-guide.
"@
    }
    foreach ($name in $content.Keys) { [IO.File]::WriteAllText((Join-Path $directory $name), [string]$content[$name], (New-Object Text.UTF8Encoding($false))) }
    return $directory
}

function New-DocumentationInput {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$ResearchHash,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $directory = 'docs/migration/v8'
    $order = @('README.md', 'changes.md', 'dependencies.md', 'errors-and-repairs.md', 'new-concepts.md', 'sources.md', 'validation.md', 'warnings.md')
    $files = @($order | ForEach-Object {
            $path = Join-Path $ProjectRoot (Join-Path $directory $_)
            [PSCustomObject][ordered]@{ path = ($directory + '/' + $_); sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
    return [PSCustomObject][ordered]@{
        schemaVersion = 1
        runId = $RunId
        mode = 'publish'
        manifestSha256 = [string]$Manifest.manifestSha256
        researchSha256 = [string]$ResearchHash
        technicalVerifiedCommit = [string]$Result.finalTechnicalCommit
        outputDirectory = $directory
        files = $files
        claims = @(
            [PSCustomObject][ordered]@{ id = 'D-001'; kind = 'official-change'; document = 'changes.md'; evidence = @('source:S-001') },
            [PSCustomObject][ordered]@{ id = 'D-002'; kind = 'observed-change'; document = 'validation.md'; evidence = @('check:build', 'result:verified') },
            [PSCustomObject][ordered]@{ id = 'D-003'; kind = 'inference'; document = 'new-concepts.md'; evidence = @('source:F-001') }
        )
        remainingWarnings = @()
    }
}

try {
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceTools 'npm.cmd') -Destination (Join-Path $toolDirectory 'npm.cmd') -Force
    Copy-Item -LiteralPath (Join-Path $sourceTools 'npm-fixture.ps1') -Destination (Join-Path $toolDirectory 'npm-fixture.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $sourceTools 'ng.cmd') -Destination (Join-Path $toolDirectory 'ng.cmd') -Force
    Copy-Item -LiteralPath (Join-Path $sourceTools 'ng-fixture.ps1') -Destination (Join-Path $toolDirectory 'ng-fixture.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $sourceTools 'node-fixture.ps1') -Destination (Join-Path $toolDirectory 'node-fixture.ps1') -Force
    $env:MIGRATION_FIXTURE_NODE_SCRIPT = Join-Path $toolDirectory 'node-fixture.ps1'
    New-NodeFixtureExecutable
    $env:PATH = $toolDirectory + [IO.Path]::PathSeparator + $originalPath
    $env:MIGRATION_FIXTURE_ROOT = $fixtureRoot
    $env:MIGRATION_FIXTURE_TOOLS = $toolDirectory
    $env:MIGRATION_REGISTRY_FIXTURE = $registryFixture
    New-E2EProject

    $inspection = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'inspect')
    Assert-E2E 'inspect reports Angular 7 fixture ready' ($inspection.ok -and $inspection.status -eq 'ready' -and $inspection.data.angular.currentMajor -eq 7)
    Assert-E2E 'inspect uses the controlled Node and npm tools' ($inspection.data.node.node.executable -eq (Join-Path $toolDirectory 'node.exe') -and $inspection.data.node.npm.executable -eq (Join-Path $toolDirectory 'npm.cmd'))

    $start = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'start', '-TargetMajor', '8')
    Assert-E2E 'start creates one Angular 7 to 8 run' ($start.ok -and $start.status -eq 'running' -and $start.data.runId)
    $runId = [string]$start.data.runId
    $runRoot = Join-Path $projectRoot ('.angular-migration/runs/' + $runId)

    $firstRun = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'run', '-RunId', $runId) -ExpectedExitCode 2
    Assert-E2E 'run reaches scoped needs-repair' ($firstRun.status -eq 'needs-repair' -and $firstRun.error.code -eq 'validation_failed')
    $repairContextEnvelope = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'repair-context', '-RunId', $runId) -ExpectedExitCode 2
    $repairContext = $repairContextEnvelope.data
    Assert-E2E 'repair context contains only source scope' (@($repairContext.allowedPaths) -contains 'src/**/*' -and @($repairContext.forbiddenPaths) -contains 'package.json')
    Add-Content -LiteralPath (Join-Path $projectRoot 'src/app.component.ts') -Value "`nexport const repairedByFixture = true;"
    Remove-Item -LiteralPath (Join-Path $projectRoot '.fixture-fail-second-build') -Force
    $repairInput = [PSCustomObject][ordered]@{
        schemaVersion = 1
        runId = $repairContext.runId
        fingerprint = $repairContext.fingerprint
        attempt = $repairContext.attempt
        rootCause = 'The final fixture build reports a source diagnostic.'
        changes = @([PSCustomObject][ordered]@{ path = 'src/app.component.ts'; summary = 'Adapt the fixture source.'; reason = 'The validation diagnostic points to the component source.' })
        evidence = @([PSCustomObject][ordered]@{ kind = 'diagnostic'; reference = $repairContext.diagnostic.logFiles[0]; claim = 'The original validation log identifies the source diagnostic.' })
        unresolvedWarnings = @()
    }
    $repairPath = Join-Path $projectRoot $repairContext.submissionPath
    Write-E2EJson -Value $repairInput -Path $repairPath
    $recordedRepair = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'record-repair', '-RunId', $runId, '-InputFile', $repairContext.submissionPath)
    Assert-E2E 'record-repair accepts the scoped fixture change' ($recordedRepair.ok -and $recordedRepair.status -eq 'running')

    $verified = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'run', '-RunId', $runId)
    Assert-E2E 'resumed run reaches verified' ($verified.ok -and $verified.status -eq 'verified' -and $verified.data.migrationStatus -eq 'verified')
    $manifest = Read-E2EJson -Path (Join-Path $runRoot 'manifest.json')
    $result = Read-E2EJson -Path (Join-Path $runRoot 'result.json')
    Assert-E2E 'technical result and repair evidence are present' ($result.status -eq 'verified' -and @($result.repairs).Count -eq 1 -and $result.manifestSha256 -eq $manifest.manifestSha256)

    $researchContext = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'documentation-context', '-RunId', $runId, '-Mode', 'research')
    $research = New-ResearchInput -Manifest $manifest -RunId $runId
    $researchPath = Join-Path $projectRoot $researchContext.data.allowedWritePath
    Write-E2EJson -Value $research -Path $researchPath
    $recordedResearch = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'record-documentation', '-RunId', $runId, '-Mode', 'research', '-InputFile', $researchContext.data.allowedWritePath)
    Assert-E2E 'research is recorded before publication' ($recordedResearch.ok -and $recordedResearch.status -eq 'researched')
    $stateAfterResearch = Read-E2EJson -Path (Join-Path $runRoot 'state.json')
    $publishContext = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'documentation-context', '-RunId', $runId, '-Mode', 'publish')
    Assert-E2E 'publish context is issued only after verified research' ($publishContext.status -eq 'publishing' -and $stateAfterResearch.documentationStatus -eq 'researched')
    $outputDirectory = New-DocumentationFiles -ProjectRoot $projectRoot -Manifest $manifest -Result $result
    $documentationInput = New-DocumentationInput -ProjectRoot $projectRoot -Manifest $manifest -Result $result -ResearchHash $stateAfterResearch.documentation.researchSha256 -RunId $runId
    $documentationPath = Join-Path $projectRoot $publishContext.data.submissionPath
    Write-E2EJson -Value $documentationInput -Path $documentationPath
    $recordedDocumentation = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'record-documentation', '-RunId', $runId, '-Mode', 'publish', '-InputFile', $publishContext.data.submissionPath)
    $finalStatus = Invoke-Facade -ProjectRoot $projectRoot -Arguments @('-Command', 'status', '-RunId', $runId)
    $finalState = Read-E2EJson -Path (Join-Path $runRoot 'state.json')
    $trackedChanges = @(& git -C $projectRoot status --porcelain)
    Assert-E2E 'documentation publish completes the run' ($recordedDocumentation.ok -and $recordedDocumentation.status -eq 'completed' -and $finalStatus.status -eq 'completed' -and $finalState.status -eq 'completed' -and $finalState.documentation.status -eq 'completed')
    Assert-E2E 'completion releases ownership and leaves a clean tree' (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.angular-migration/active.lock')) -and $trackedChanges.Count -eq 0)
    Assert-E2E 'final documentation contains exactly eight files' (@(& git -C $projectRoot show --pretty= --name-only HEAD | Where-Object { $_ }).Count -eq 8)
    Write-Host 'Angular 7 to 8 E2E OK' -ForegroundColor Green
}
finally {
    $env:PATH = $originalPath
    if ($null -eq $originalFixtureRoot) { Remove-Item Env:MIGRATION_FIXTURE_ROOT -ErrorAction SilentlyContinue } else { $env:MIGRATION_FIXTURE_ROOT = $originalFixtureRoot }
    if ($null -eq $originalFixtureTools) { Remove-Item Env:MIGRATION_FIXTURE_TOOLS -ErrorAction SilentlyContinue } else { $env:MIGRATION_FIXTURE_TOOLS = $originalFixtureTools }
    if ($null -eq $originalRegistryFixture) { Remove-Item Env:MIGRATION_REGISTRY_FIXTURE -ErrorAction SilentlyContinue } else { $env:MIGRATION_REGISTRY_FIXTURE = $originalRegistryFixture }
    if ($null -eq $originalNodeScript) { Remove-Item Env:MIGRATION_FIXTURE_NODE_SCRIPT -ErrorAction SilentlyContinue } else { $env:MIGRATION_FIXTURE_NODE_SCRIPT = $originalNodeScript }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}