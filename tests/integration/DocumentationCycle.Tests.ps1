#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../../scripts/modules'
foreach ($name in @('Core', 'State', 'Dependencies', 'Pipeline')) {
    Import-Module (Join-Path $modules "Migration.$name.psm1") -Force -DisableNameChecking
}
$pipeline = Get-Module Migration.Pipeline
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('documentation-cycle-' + [guid]::NewGuid().ToString('N'))

function Assert-DocumentationCycle {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name"
}

function Get-PipelineHashForCycle {
    param($Value)
    return (& $pipeline { param($InputObject) Get-PipelineObjectHash -Value $InputObject -ExcludedProperty 'resultSha256' } $Value)
}

function New-CycleManifest {
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

function New-CycleResult {
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
    $result.resultSha256 = Get-PipelineHashForCycle -Value $result
    return $result
}

function New-CycleFixture {
    param([string]$Name)
    $root = Join-Path $temporaryRoot $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.gitignore'), '.angular-migration/' + [Environment]::NewLine)
    [IO.File]::WriteAllText((Join-Path $root 'package.json'), '{"name":"documentation-cycle-fixture"}')
    [IO.File]::WriteAllText((Join-Path $root 'package-lock.json'), '{"lockfileVersion":1}')
    & git -C $root init --quiet
    & git -C $root config user.name 'Documentation Cycle'
    & git -C $root config user.email 'documentation-cycle@example.invalid'
    & git -C $root add .
    & git -C $root commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Documentation cycle fixture Git setup failed.' }
    $head = (& git -C $root rev-parse HEAD).Trim()
    $runId = 'angular-7-to-8-20260910T100000Z-' + $Name
    New-ActiveRunLock -ProjectRoot $root -RunId $runId
    $state = New-MigrationRunState -ProjectRoot $root -RunId $runId -SourceMajor 7 -TargetMajor 8 -InitialCommit $head -InitialBranch ((& git -C $root branch --show-current).Trim())
    $state.baselineStatus = 'passed'
    $state.resolutionStatus = 'resolved'
    $state.completedOperations = @('baseline', 'resolve-manifest', 'create-branch', 'update-angular', 'update-dependencies', 'install', 'validate', 'technical-result')
    $state.checkpointCommit = $head
    $state.migrationBranch = ((& git -C $root branch --show-current).Trim())
    $manifest = New-CycleManifest -Root $root -RunId $runId
    $state.manifestSha256 = $manifest.manifestSha256
    $paths = Get-MigrationRunPaths -ProjectRoot $root -RunId $runId
    Write-MigrationRunState -ProjectRoot $root -RunId $runId -State $state
    Write-MigrationJsonAtomic -Value $manifest -Path $paths.manifest
    $result = New-CycleResult -RunId $runId -ManifestHash $manifest.manifestSha256 -Commit $head
    Write-MigrationJsonAtomic -Value $result -Path $paths.result
    return [PSCustomObject]@{ root = $root; runId = $runId; head = $head; paths = $paths; manifest = $manifest }
}

function Set-CycleVerified {
    param($Fixture)
    $state = Read-MigrationRunState -ProjectRoot $Fixture.root -RunId $Fixture.runId
    $state.status = 'verified'
    $state.stage = 'document'
    $state.stageRevision = [int]$state.stageRevision + 1
    $state.migrationStatus = 'verified'
    Write-MigrationRunState -ProjectRoot $Fixture.root -RunId $Fixture.runId -State $state
}

function New-CycleResearch {
    param($Fixture)
    return [PSCustomObject][ordered]@{
        schemaVersion = 1
        runId = $Fixture.runId
        sourceMajor = 7
        targetMajor = 8
        manifestSha256 = $Fixture.manifest.manifestSha256
        researchedAt = '2026-09-10T10:30:00.0000000Z'
        sources = @([PSCustomObject][ordered]@{ id = 'S-001'; title = 'Angular Update Guide'; url = 'https://angular.dev/update-guide'; publisher = 'Angular'; primary = $true; accessedAt = '2026-09-10T10:20:00.0000000Z' })
        findings = @([PSCustomObject][ordered]@{ id = 'F-001'; kind = 'official-change'; area = 'framework'; title = 'Framework migration guidance'; summary = 'The official guide identifies the relevant framework migration path.'; affectedPackages = @('@angular/core'); sourceIds = @('S-001'); applicability = 'applicable' })
        concepts = @([PSCustomObject][ordered]@{ id = 'C-001'; name = 'Migration schematics'; whyItMatters = 'The team should review automated changes before relying on them.'; sourceIds = @('S-001') })
        unresolved = @()
    }
}

function Start-CycleResearch {
    param($Fixture)
    $null = Invoke-DocumentationContext -ProjectRoot $Fixture.root -RunId $Fixture.runId -Mode research
    $research = New-CycleResearch -Fixture $Fixture
    $path = Join-Path $Fixture.root ('.angular-migration/runs/' + $Fixture.runId + '/inbox/research.json')
    Write-MigrationJsonAtomic -Value $research -Path $path
    $recorded = Invoke-RecordDocumentation -ProjectRoot $Fixture.root -RunId $Fixture.runId -Mode research -InputFile $path
    return $recorded
}

function New-CycleDocuments {
    param($Fixture, [string]$Explanation = 'The technical gates passed for this fixture.')
    $directory = Join-Path $Fixture.root 'docs/migration/v8'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $readme = @"
# Migracion Angular 7 a 8

## Resumen
Estado tecnico verified para run $($Fixture.runId).

## Alcance
Se revisaron las dependencias directas del manifest.

## Resultado
$Explanation

## Navegacion
[Changes](changes.md) | [Dependencies](dependencies.md) | [Errors](errors-and-repairs.md) | [New concepts](new-concepts.md) | [Sources](sources.md) | [Validation](validation.md) | [Warnings](warnings.md)
"@
    $changes = @"
# Cambios aplicados

## Cambios automaticos de Angular
El cambio oficial se resume con evidencia en [sources](sources.md#S-001).

## Cambios manuales
No hubo cambios manuales.

## Cambios oficiales no aplicables
Ninguno.
"@
    $dependencyRows = ($Fixture.manifest.dependencies | ForEach-Object { "| $($_.name) | $($_.section) | $($_.currentVersion) | $($_.targetVersion) | $($_.change) | $($_.reason) |" }) -join [Environment]::NewLine
    $dependencies = @"
# Dependencias

| Paquete | Seccion | Antes | Despues | Tipo de cambio | Motivo |
| --- | --- | ---: | ---: | --- | --- |
$dependencyRows

## Node
Node activo: 20.11.0.
"@
    $errors = "# Errores y reparaciones`r`n`r`nLa ejecucion no requirio reparaciones manuales.`r`n"
    $concepts = @"
# Nuevos conceptos

## Migration schematics

### Explicacion intuitiva
Las schematics aplican transformaciones conocidas.

### Que cambio entre las versiones
La guia oficial describe el camino de migracion.

### Como aparece en este proyecto
La dependencia @angular/core participa en el salto.

### Que debe hacer el equipo a partir de ahora
Revisar el diff y los gates.

### Fuente oficial
[sources](sources.md#S-001)
"@
    $sources = @"
# Fuentes

## Fuentes primarias

1. S-001. Angular. Angular Update Guide. https://angular.dev/update-guide. Consultada 2026-09-10T10:20:00.0000000Z. Sustenta F-001.
"@
    $validation = @"
# Validacion

El gate build termino con estado passed, exit code 0 y duracion 10 ms.
Logs: logs/validate/build.stdout.log y logs/validate/build.stderr.log.
Manifest hash: $($Fixture.manifest.manifestSha256).
Resultado tecnico verified.
"@
    $warnings = "# Warnings`r`n`r`nNo quedaron warnings registrados por la pipeline.`r`n"
    $content = [ordered]@{
        'README.md' = $readme
        'changes.md' = $changes
        'errors-and-repairs.md' = $errors
        'warnings.md' = $warnings
        'new-concepts.md' = $concepts
        'dependencies.md' = $dependencies
        'validation.md' = $validation
        'sources.md' = $sources
    }
    foreach ($name in $content.Keys) { Write-MigrationTextAtomic -Text ([string]$content[$name]) -Path (Join-Path $directory $name) }
    return $content
}

function New-CycleInput {
    param($Fixture, [hashtable]$Options = @{})
    $state = Read-MigrationRunState -ProjectRoot $Fixture.root -RunId $Fixture.runId
    $directory = 'docs/migration/v8'
    $fileOrder = @('README.md', 'changes.md', 'dependencies.md', 'errors-and-repairs.md', 'new-concepts.md', 'sources.md', 'validation.md', 'warnings.md')
    $files = @($fileOrder | ForEach-Object {
            $path = Join-Path $Fixture.root (Join-Path $directory $_)
            $hash = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() } else { '0' * 64 }
            [PSCustomObject][ordered]@{ path = ($directory + '/' + $_); sha256 = $hash }
        })
    $claims = @(
        [PSCustomObject][ordered]@{ id = 'D-001'; kind = 'official-change'; document = 'changes.md'; evidence = @('source:S-001') },
        [PSCustomObject][ordered]@{ id = 'D-002'; kind = 'observed-change'; document = 'validation.md'; evidence = @('check:build', 'result:verified') },
        [PSCustomObject][ordered]@{ id = 'D-003'; kind = 'inference'; document = 'new-concepts.md'; evidence = @('source:F-001') }
    )
    $documentationInput = [PSCustomObject][ordered]@{
        schemaVersion = 1
        runId = $Fixture.runId
        mode = 'publish'
        manifestSha256 = $Fixture.manifest.manifestSha256
        researchSha256 = $state.documentation.researchSha256
        technicalVerifiedCommit = $Fixture.head
        outputDirectory = $directory
        files = $files
        claims = $claims
        remainingWarnings = @()
    }
    foreach ($name in $Options.Keys) { $documentationInput.$name = $Options[$name] }
    return $documentationInput
}

function Write-CycleInput {
    param($Fixture, $InputObject)
    $path = Join-Path $Fixture.root ('.angular-migration/runs/' + $Fixture.runId + '/inbox/documentation.json')
    Write-MigrationJsonAtomic -Value $InputObject -Path $path
    return $path
}

function Start-CyclePublish {
    param($Fixture)
    $null = Invoke-DocumentationContext -ProjectRoot $Fixture.root -RunId $Fixture.runId -Mode publish
}

function Assert-CyclePublishRejected {
    param($Fixture, $InputObject, [string]$Code, [string]$Name)
    $path = Write-CycleInput -Fixture $Fixture -InputObject $InputObject
    $rejected = $false
    try { Invoke-RecordDocumentation -ProjectRoot $Fixture.root -RunId $Fixture.runId -Mode publish -InputFile $path | Out-Null }
    catch { $rejected = $_.Exception.Data['code'] -ceq $Code }
    Assert-DocumentationCycle $Name $rejected
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null

    $running = New-CycleFixture -Name 'running-research'
    $researchResult = Start-CycleResearch -Fixture $running
    Assert-DocumentationCycle 'research runs before technical verification' ($researchResult.status -eq 'researched' -and (Read-MigrationRunState -ProjectRoot $running.root -RunId $running.runId).migrationStatus -eq 'running')
    Assert-DocumentationCycle 'research has no final documentation side effects' (-not (Test-Path -LiteralPath (Join-Path $running.root 'docs')))

    $beforeVerified = New-CycleFixture -Name 'publish-before-verified'
    Start-CycleResearch -Fixture $beforeVerified | Out-Null
    $publishBlocked = $false
    try { Invoke-DocumentationContext -ProjectRoot $beforeVerified.root -RunId $beforeVerified.runId -Mode publish | Out-Null }
    catch { $publishBlocked = $_.Exception.Data['code'] -ceq 'publish_requires_verified' }
    Assert-DocumentationCycle 'publish is denied before verified' $publishBlocked

    $badResearch = New-CycleFixture -Name 'research-hash'
    $null = Invoke-DocumentationContext -ProjectRoot $badResearch.root -RunId $badResearch.runId -Mode research
    $wrongResearch = New-CycleResearch -Fixture $badResearch
    $wrongResearch.manifestSha256 = ('0' * 64)
    $wrongResearchPath = Join-Path $badResearch.root ('.angular-migration/runs/' + $badResearch.runId + '/inbox/research.json')
    Write-MigrationJsonAtomic -Value $wrongResearch -Path $wrongResearchPath
    $researchRejected = $false
    try { Invoke-RecordDocumentation -ProjectRoot $badResearch.root -RunId $badResearch.runId -Mode research -InputFile $wrongResearchPath | Out-Null }
    catch { $researchRejected = $_.Exception.Data['code'] -ceq 'documentation_identity_mismatch' }
    Assert-DocumentationCycle 'research manifest hash mismatch is rejected' $researchRejected

    $happy = New-CycleFixture -Name 'publish-success'
    Start-CycleResearch -Fixture $happy | Out-Null
    Set-CycleVerified -Fixture $happy
    Start-CyclePublish -Fixture $happy
    New-CycleDocuments -Fixture $happy | Out-Null
    $happyInput = New-CycleInput -Fixture $happy
    $happyRecord = Invoke-RecordDocumentation -ProjectRoot $happy.root -RunId $happy.runId -Mode publish -InputFile (Write-CycleInput -Fixture $happy -InputObject $happyInput)
    $happyState = Read-MigrationRunState -ProjectRoot $happy.root -RunId $happy.runId
    Assert-DocumentationCycle 'successful publish creates fixed commit and completes run' ($happyRecord.ok -and $happyRecord.status -eq 'completed' -and $happyState.status -eq 'completed' -and $happyState.stage -eq 'done' -and $happyState.documentation.status -eq 'completed' -and -not (Test-Path -LiteralPath (Join-Path $happy.root '.angular-migration/active.lock')))
    Assert-DocumentationCycle 'successful publish contains exactly eight documents' (@(& git -C $happy.root show --pretty= --name-only HEAD | Where-Object { $_ }).Count -eq 8)
    Assert-DocumentationCycle 'successful publish uses fixed commit message' ((& git -C $happy.root log -1 --format=%s).Trim() -ceq 'docs(angular-migration): document Angular 7 to 8')

    $ninth = New-CycleFixture -Name 'ninth-file'
    Start-CycleResearch -Fixture $ninth | Out-Null
    Set-CycleVerified -Fixture $ninth
    Start-CyclePublish -Fixture $ninth
    New-CycleDocuments -Fixture $ninth | Out-Null
    Write-MigrationTextAtomic -Text '# Extra' -Path (Join-Path $ninth.root 'docs/migration/v8/extra.md')
    Assert-CyclePublishRejected -Fixture $ninth -InputObject (New-CycleInput -Fixture $ninth) -Code 'documentation_file_set_invalid' -Name 'ninth documentation file is rejected'
    Assert-DocumentationCycle 'failed publish rolls back untracked documents' (-not (Test-Path -LiteralPath (Join-Path $ninth.root 'docs/migration/v8/README.md')))

    $missing = New-CycleFixture -Name 'missing-file'
    Start-CycleResearch -Fixture $missing | Out-Null
    Set-CycleVerified -Fixture $missing
    Start-CyclePublish -Fixture $missing
    New-CycleDocuments -Fixture $missing | Out-Null
    Remove-Item -LiteralPath (Join-Path $missing.root 'docs/migration/v8/warnings.md') -Force
    Assert-CyclePublishRejected -Fixture $missing -InputObject (New-CycleInput -Fixture $missing) -Code 'documentation_file_set_invalid' -Name 'missing documentation file is rejected'

    $wrongVersion = New-CycleFixture -Name 'wrong-version'
    Start-CycleResearch -Fixture $wrongVersion | Out-Null
    Set-CycleVerified -Fixture $wrongVersion
    Start-CyclePublish -Fixture $wrongVersion
    New-CycleDocuments -Fixture $wrongVersion | Out-Null
    Add-Content -LiteralPath (Join-Path $wrongVersion.root 'docs/migration/v8/dependencies.md') -Value 'Unexpected version 99.99.99.'
    Assert-CyclePublishRejected -Fixture $wrongVersion -InputObject (New-CycleInput -Fixture $wrongVersion) -Code 'documentation_version_not_in_manifest' -Name 'version outside manifest is rejected'

    $brokenLink = New-CycleFixture -Name 'broken-link'
    Start-CycleResearch -Fixture $brokenLink | Out-Null
    Set-CycleVerified -Fixture $brokenLink
    Start-CyclePublish -Fixture $brokenLink
    New-CycleDocuments -Fixture $brokenLink | Out-Null
    Add-Content -LiteralPath (Join-Path $brokenLink.root 'docs/migration/v8/README.md') -Value '[Missing](missing.md)'
    Assert-CyclePublishRejected -Fixture $brokenLink -InputObject (New-CycleInput -Fixture $brokenLink) -Code 'documentation_link_broken' -Name 'broken internal link is rejected'

    $secret = New-CycleFixture -Name 'secret-text'
    Start-CycleResearch -Fixture $secret | Out-Null
    Set-CycleVerified -Fixture $secret
    Start-CyclePublish -Fixture $secret
    New-CycleDocuments -Fixture $secret | Out-Null
    Add-Content -LiteralPath (Join-Path $secret.root 'docs/migration/v8/README.md') -Value 'password=do-not-publish'
    Assert-CyclePublishRejected -Fixture $secret -InputObject (New-CycleInput -Fixture $secret) -Code 'documentation_sensitive_or_executable_text' -Name 'secret text is rejected'

    foreach ($claimCase in @('event', 'commit', 'repair')) {
        $evidence = New-CycleFixture -Name ('missing-' + $claimCase)
        Start-CycleResearch -Fixture $evidence | Out-Null
        Set-CycleVerified -Fixture $evidence
        Start-CyclePublish -Fixture $evidence
        New-CycleDocuments -Fixture $evidence | Out-Null
        $missingEvidence = switch ($claimCase) { event { 'event:missing-event' }; commit { 'commit:' + ('a' * 40) }; repair { 'repair:missing-fingerprint' } }
        $claim = [PSCustomObject][ordered]@{ id = 'D-004'; kind = 'observed-change'; document = 'validation.md'; evidence = @($missingEvidence, 'check:build', 'result:verified') }
        $claimInput = New-CycleInput -Fixture $evidence -Options @{ claims = @($claim) }
        $code = switch ($claimCase) { event { 'documentation_event_unknown' }; commit { 'checkpoint_missing' }; repair { 'documentation_repair_unknown' } }
        Assert-CyclePublishRejected -Fixture $evidence -InputObject $claimInput -Code $code -Name ("missing $claimCase evidence is rejected")
    }

    $wrongInputHash = New-CycleFixture -Name 'wrong-input-hash'
    Start-CycleResearch -Fixture $wrongInputHash | Out-Null
    Set-CycleVerified -Fixture $wrongInputHash
    Start-CyclePublish -Fixture $wrongInputHash
    New-CycleDocuments -Fixture $wrongInputHash | Out-Null
    $wrongInput = New-CycleInput -Fixture $wrongInputHash -Options @{ researchSha256 = ('0' * 64) }
    Assert-CyclePublishRejected -Fixture $wrongInputHash -InputObject $wrongInput -Code 'documentation_evidence_mismatch' -Name 'publish research hash mismatch is rejected'

    $retry = New-CycleFixture -Name 'retry'
    Start-CycleResearch -Fixture $retry | Out-Null
    Set-CycleVerified -Fixture $retry
    Start-CyclePublish -Fixture $retry
    New-CycleDocuments -Fixture $retry | Out-Null
    Write-MigrationTextAtomic -Text '# Extra' -Path (Join-Path $retry.root 'docs/migration/v8/extra.md')
    Assert-CyclePublishRejected -Fixture $retry -InputObject (New-CycleInput -Fixture $retry) -Code 'documentation_file_set_invalid' -Name 'documentation failure preserves verified technical status'
    $retryState = Read-MigrationRunState -ProjectRoot $retry.root -RunId $retry.runId
    Assert-DocumentationCycle 'failed publish retains verified migration and ownership' ($retryState.migrationStatus -eq 'verified' -and $retryState.status -eq 'verified' -and (Test-Path -LiteralPath (Join-Path $retry.root '.angular-migration/active.lock')))
    $retryContext = Invoke-DocumentationContext -ProjectRoot $retry.root -RunId $retry.runId -Mode publish
    New-CycleDocuments -Fixture $retry | Out-Null
    $retryState = Read-MigrationRunState -ProjectRoot $retry.root -RunId $retry.runId
    $retryInput = New-CycleInput -Fixture $retry
    $retryRecord = Invoke-RecordDocumentation -ProjectRoot $retry.root -RunId $retry.runId -Mode publish -InputFile (Write-CycleInput -Fixture $retry -InputObject $retryInput)
    Assert-DocumentationCycle 'failed documentation can be retried' ($retryContext.status -eq 'publishing' -and $retryState.documentation.publishAttempt -eq 2 -and $retryRecord.status -eq 'completed')

    $concurrent = New-CycleFixture -Name 'concurrent-head'
    Start-CycleResearch -Fixture $concurrent | Out-Null
    Set-CycleVerified -Fixture $concurrent
    Start-CyclePublish -Fixture $concurrent
    New-CycleDocuments -Fixture $concurrent | Out-Null
    [IO.File]::WriteAllText((Join-Path $concurrent.root 'concurrent.txt'), 'changed after verification')
    & git -C $concurrent.root add concurrent.txt
    & git -C $concurrent.root commit --quiet -m concurrent
    Assert-CyclePublishRejected -Fixture $concurrent -InputObject (New-CycleInput -Fixture $concurrent) -Code 'git_head_changed' -Name 'concurrent HEAD change is rejected'
    $concurrentState = Read-MigrationRunState -ProjectRoot $concurrent.root -RunId $concurrent.runId
    Assert-DocumentationCycle 'concurrent rejection retains verified migration' ($concurrentState.migrationStatus -eq 'verified' -and (Test-Path -LiteralPath (Join-Path $concurrent.root '.angular-migration/active.lock')))

    $equivalentA = New-CycleFixture -Name 'equivalent-a'
    Start-CycleResearch -Fixture $equivalentA | Out-Null
    Set-CycleVerified -Fixture $equivalentA
    Start-CyclePublish -Fixture $equivalentA
    New-CycleDocuments -Fixture $equivalentA -Explanation 'The technical gates passed for fixture A.' | Out-Null
    $inputA = New-CycleInput -Fixture $equivalentA
    Invoke-RecordDocumentation -ProjectRoot $equivalentA.root -RunId $equivalentA.runId -Mode publish -InputFile (Write-CycleInput -Fixture $equivalentA -InputObject $inputA) | Out-Null
    $equivalentB = New-CycleFixture -Name 'equivalent-b'
    Start-CycleResearch -Fixture $equivalentB | Out-Null
    Set-CycleVerified -Fixture $equivalentB
    Start-CyclePublish -Fixture $equivalentB
    New-CycleDocuments -Fixture $equivalentB -Explanation 'The technical gates passed for fixture B.' | Out-Null
    $inputB = New-CycleInput -Fixture $equivalentB
    Invoke-RecordDocumentation -ProjectRoot $equivalentB.root -RunId $equivalentB.runId -Mode publish -InputFile (Write-CycleInput -Fixture $equivalentB -InputObject $inputB) | Out-Null
    $namesA = @(& git -C $equivalentA.root show --pretty= --name-only HEAD | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf })
    $namesB = @(& git -C $equivalentB.root show --pretty= --name-only HEAD | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf })
    Assert-DocumentationCycle 'repeated publications have structurally equivalent output' (($namesA -join '|') -ceq ($namesB -join '|') -and (Get-Content -LiteralPath (Join-Path $equivalentA.root 'docs/migration/v8/dependencies.md') -Raw) -match '\| @angular/core \|')

    Write-Host 'Documentation cycle integration OK' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
