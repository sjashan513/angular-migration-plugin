#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../../scripts/modules'
foreach ($name in @('Core', 'State', 'Dependencies', 'Pipeline')) {
    Import-Module (Join-Path $modules "Migration.$name.psm1") -Force -DisableNameChecking
}
$pipeline = Get-Module Migration.Pipeline
$fixtureTemplate = Join-Path $PSScriptRoot '../fixtures/documentation/research.template.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('documentation-contract-' + [guid]::NewGuid().ToString('N'))

function Assert-DocumentationTest {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name"
}

function Get-PipelineHashForTest {
    param($Value)
    return (& $pipeline { param($InputObject) Get-PipelineObjectHash -Value $InputObject -ExcludedProperty 'resultSha256' } $Value)
}

function New-DocumentationManifestForTest {
    param([string]$Root, [string]$RunId)
    $manifest = [PSCustomObject][ordered]@{
        schemaVersion = 5
        manifestType = 'migration'
        runId = $RunId
        sourceMajor = 7
        targetMajor = 8
        resolverVersion = 1
        resolutionStatus = 'resolved'
        resolvedAt = '2026-09-10T10:00:00.0000000Z'
        project = [PSCustomObject][ordered]@{ root = $Root; packageManager = 'npm'; lockfileVersion = 1 }
        angular = [PSCustomObject][ordered]@{ declaredCoreSpec = '^7.2.0'; resolvedCoreVersion = '7.2.16'; current = 7; target = [PSCustomObject][ordered]@{ major = 8; resolved = $true; resolutionStatus = 'resolved'; coreVersion = '8.2.14' } }
        node = [PSCustomObject][ordered]@{ activeVersion = '20.11.0'; requiredRange = '>=12.0.0'; compatible = $true }
        dependencies = @(
            [PSCustomObject][ordered]@{ name = '@angular/core'; section = 'dependencies'; role = 'angular-framework'; kind = 'registry'; declaredSpec = '^7.2.0'; currentVersion = '7.2.16'; targetVersion = '8.2.14'; writeSpec = '^8.2.14'; change = 'major-required'; reason = 'Angular framework packages align to target major 8' },
            [PSCustomObject][ordered]@{ name = 'typescript'; section = 'devDependencies'; role = 'toolchain-related'; kind = 'registry'; declaredSpec = '~3.2.2'; currentVersion = '3.2.2'; targetVersion = '3.5.3'; writeSpec = '~3.5.3'; change = 'toolchain-alignment'; reason = 'Angular compiler compatibility' }
        )
        checks = @()
        warnings = @()
        manifestSha256 = $null
    }
    $manifest.manifestSha256 = Get-ResolvedManifestHash -Manifest $manifest
    return $manifest
}

function New-DocumentationResultForTest {
    param([string]$RunId, [string]$ManifestHash, [string]$Commit)
    $result = [PSCustomObject][ordered]@{
        schemaVersion = 5
        runId = $RunId
        sourceMajor = 7
        targetMajor = 8
        status = 'verified'
        migrationStatus = 'verified'
        documentationStatus = 'pending'
        manifestSha256 = $ManifestHash
        initialCommit = $Commit
        finalTechnicalCommit = $Commit
        changedFiles = @()
        dependencyChanges = @()
        checks = @([PSCustomObject][ordered]@{ id = 'build'; status = 'passed'; exitCode = 0; timedOut = $false; durationMs = 10; stdoutLog = 'logs/validate/build.stdout.log'; stderrLog = 'logs/validate/build.stderr.log'; diagnosticSummary = $null; executable = 'npm.cmd' })
        repairs = @()
        warnings = @()
        verifiedAt = '2026-09-10T10:10:00.0000000Z'
        resultSha256 = $null
    }
    $result.resultSha256 = Get-PipelineHashForTest -Value $result
    return $result
}

function New-DocumentationFixture {
    param([string]$Name, [switch]$Verified)
    $root = Join-Path $temporaryRoot $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.gitignore'), '.angular-migration/' + [Environment]::NewLine)
    [IO.File]::WriteAllText((Join-Path $root 'package.json'), '{"name":"documentation-fixture"}')
    [IO.File]::WriteAllText((Join-Path $root 'package-lock.json'), '{"lockfileVersion":1}')
    & git -C $root init --quiet
    & git -C $root config user.name 'Documentation Fixture'
    & git -C $root config user.email 'documentation@example.invalid'
    & git -C $root add .
    & git -C $root commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Documentation fixture Git setup failed.' }
    $head = (& git -C $root rev-parse HEAD).Trim()
    $runId = 'angular-7-to-8-20260910T100000Z-' + $Name
    New-ActiveRunLock -ProjectRoot $root -RunId $runId
    $state = New-MigrationRunState -ProjectRoot $root -RunId $runId -SourceMajor 7 -TargetMajor 8 -InitialCommit $head -InitialBranch ((& git -C $root branch --show-current).Trim())
    $state.baselineStatus = 'passed'
    $state.resolutionStatus = 'resolved'
    $state.completedOperations = @('baseline', 'resolve-manifest', 'create-branch', 'update-angular', 'update-dependencies', 'install', 'validate', 'technical-result')
    $state.checkpointCommit = $head
    $manifest = New-DocumentationManifestForTest -Root $root -RunId $runId
    $state.manifestSha256 = $manifest.manifestSha256
    $state.migrationBranch = ((& git -C $root branch --show-current).Trim())
    if ($Verified) {
        $state.status = 'verified'
        $state.stage = 'document'
        $state.migrationStatus = 'verified'
    }
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $runId
    Write-MigrationRunState -ProjectRoot $root -RunId $runId -State $state
    Write-MigrationJsonAtomic -Value $manifest -Path $paths.manifest
    if ($Verified) {
        $result = New-DocumentationResultForTest -RunId $runId -ManifestHash $manifest.manifestSha256 -Commit $head
        Write-MigrationJsonAtomic -Value $result -Path $paths.result
    }
    return [PSCustomObject]@{ root = $root; runId = $runId; head = $head; paths = $paths; manifest = $manifest }
}

function New-ResearchInputForTest {
    param($Fixture)
    $research = Get-Content -LiteralPath $fixtureTemplate -Raw -Encoding UTF8 | ConvertFrom-Json
    $research.runId = $Fixture.runId
    $research.manifestSha256 = $Fixture.manifest.manifestSha256
    return $research
}

function Write-ResearchInputForTest {
    param($Fixture, $Research)
    $path = Join-Path $Fixture.root ('.angular-migration/runs/' + $Fixture.runId + '/inbox/research.json')
    Write-MigrationJsonAtomic -Value $Research -Path $path
    return $path
}

function Assert-ResearchRejected {
    param($Fixture, $Research, [string]$Code, [string]$Name)
    $null = Invoke-DocumentationContext -ProjectRoot $Fixture.root -RunId $Fixture.runId -Mode research
    $path = Write-ResearchInputForTest -Fixture $Fixture -Research $Research
    $rejected = $false
    try { Invoke-RecordDocumentation -ProjectRoot $Fixture.root -RunId $Fixture.runId -Mode research -InputFile $path | Out-Null }
    catch { $rejected = $_.Exception.Data['code'] -ceq $Code }
    Assert-DocumentationTest $Name $rejected
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $fixture = New-DocumentationFixture -Name 'parallel-running'
    $context = Invoke-DocumentationContext -ProjectRoot $fixture.root -RunId $fixture.runId -Mode research
    Assert-DocumentationTest 'research context is available while migration is running' ($context.ok -and $context.status -eq 'researching' -and $context.data.dependencies.Count -eq 2)
    $questionStart = [string][char]0x00bf + 'Qu' + [char]0x00e9
    Assert-DocumentationTest 'research context uses exact contractual questions' ($context.data.questions[0] -ceq ($questionStart + ' breaking changes oficiales aplican de Angular 7 a 8?') -and $context.data.allowedWritePath -like '*.json')
    $research = New-ResearchInputForTest -Fixture $fixture
    $researchPath = Write-ResearchInputForTest -Fixture $fixture -Research $research
    $recorded = Invoke-RecordDocumentation -ProjectRoot $fixture.root -RunId $fixture.runId -Mode research -InputFile $researchPath
    Assert-DocumentationTest 'valid research is registered and hashed' ($recorded.ok -and $recorded.status -eq 'researched' -and $recorded.data.researchSha256 -match '^[0-9a-f]{64}$' -and (Test-Path -LiteralPath $fixture.paths.researchArtifact))
    Assert-DocumentationTest 'research does not create final documentation' (-not (Test-Path -LiteralPath (Join-Path $fixture.root 'docs')))
    $storedResearch = Read-MigrationJson -Path $fixture.paths.researchArtifact -Required
    Assert-DocumentationTest 'unresolved array is conserved' (@($storedResearch.unresolved).Count -eq @($research.unresolved).Count)

    Assert-ResearchRejected -Fixture (New-DocumentationFixture -Name 'wrong-manifest') -Research ($research | ForEach-Object { $_.manifestSha256 = ('0' * 64); $_ }) -Code 'documentation_identity_mismatch' -Name 'wrong manifest hash is rejected'
    $invalidUrlFixture = New-DocumentationFixture -Name 'invalid-url'
    $invalidUrlResearch = New-ResearchInputForTest -Fixture $invalidUrlFixture
    $invalidUrlResearch.sources[0].url = 'http://angular.dev/update-guide'
    Assert-ResearchRejected -Fixture $invalidUrlFixture -Research $invalidUrlResearch -Code 'documentation_source_url_invalid' -Name 'non HTTPS source is rejected'
    $unknownSourceFixture = New-DocumentationFixture -Name 'unknown-source'
    $unknownSourceResearch = New-ResearchInputForTest -Fixture $unknownSourceFixture
    $unknownSourceResearch.findings[0].sourceIds = @('S-999')
    Assert-ResearchRejected -Fixture $unknownSourceFixture -Research $unknownSourceResearch -Code 'documentation_source_unknown' -Name 'unknown source id is rejected'
    $noPrimaryFixture = New-DocumentationFixture -Name 'no-primary'
    $noPrimaryResearch = New-ResearchInputForTest -Fixture $noPrimaryFixture
    $noPrimaryResearch.sources[0].primary = $false
    Assert-ResearchRejected -Fixture $noPrimaryFixture -Research $noPrimaryResearch -Code 'documentation_primary_source_required' -Name 'official finding without primary source is rejected'
    $foreignPackageFixture = New-DocumentationFixture -Name 'foreign-package'
    $foreignPackageResearch = New-ResearchInputForTest -Fixture $foreignPackageFixture
    $foreignPackageResearch.findings[0].affectedPackages = @('not-in-manifest')
    Assert-ResearchRejected -Fixture $foreignPackageFixture -Research $foreignPackageResearch -Code 'documentation_package_not_in_manifest' -Name 'package outside manifest is rejected'
    $versionFixture = New-DocumentationFixture -Name 'new-version'
    $versionResearch = New-ResearchInputForTest -Fixture $versionFixture
    $versionResearch.findings[0].summary = 'This applies to package version 99.99.99.'
    Assert-ResearchRejected -Fixture $versionFixture -Research $versionResearch -Code 'documentation_version_not_in_manifest' -Name 'version absent from manifest is rejected'
    $criticalFixture = New-DocumentationFixture -Name 'critical-unresolved'
    $criticalResearch = New-ResearchInputForTest -Fixture $criticalFixture
    $criticalResearch.unresolved = @([PSCustomObject]@{ id = 'U-001'; question = 'Could this affect a custom build?'; critical = $true; sourceIds = @('S-001') })
    $null = Invoke-DocumentationContext -ProjectRoot $criticalFixture.root -RunId $criticalFixture.runId -Mode research
    $criticalPath = Write-ResearchInputForTest -Fixture $criticalFixture -Research $criticalResearch
    $criticalRecorded = Invoke-RecordDocumentation -ProjectRoot $criticalFixture.root -RunId $criticalFixture.runId -Mode research -InputFile $criticalPath
    Assert-DocumentationTest 'critical unresolved research is preserved for publish review' ($criticalRecorded.status -eq 'researched' -and (Read-MigrationJson -Path $criticalFixture.paths.researchArtifact -Required).unresolved[0].id -eq 'U-001')

    $schema = Read-MigrationJson -Path (Join-Path $PSScriptRoot '../../schemas/documentation-research.schema.json') -Required
    Assert-DocumentationTest 'research schema is closed and requires evidence collections' ($schema.additionalProperties -eq $false -and @($schema.required) -contains 'sources' -and @($schema.required) -contains 'unresolved')
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
