#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\scripts\angular-migration.ps1'
$coreModulePath = Join-Path $PSScriptRoot '..\scripts\modules\Migration.Core.psm1'
$projectModulePath = Join-Path $PSScriptRoot '..\scripts\modules\Migration.Project.psm1'
$stateModulePath = Join-Path $PSScriptRoot '..\scripts\modules\Migration.State.psm1'
$script:failed = 0
$originalPath = $env:PATH

function Assert-Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        Write-Host "PASS $Name" -ForegroundColor Green
    }
    else {
        Write-Host "FAIL $Name" -ForegroundColor Red
        $script:failed++
    }
}

function Invoke-Facade {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$ExpectedExitCode = 0
    )

    Push-Location $ProjectRoot
    try {
        $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ("angular-migration-smoke-" + [guid]::NewGuid().ToString('N') + '.err')
        try {
            $stdout = & powershell -NoProfile -File $scriptPath @Arguments 2> $stderrPath
            $exitCode = $LASTEXITCODE
            $raw = ($stdout -join "`n")
            Assert-Check "exit code $ExpectedExitCode" ($exitCode -eq $ExpectedExitCode)
            Assert-Check 'stdout contiene un JSON' (-not [string]::IsNullOrWhiteSpace($raw))
            $json = $raw | ConvertFrom-Json
            Assert-Check 'stdout contiene exactamente un envelope' ($json.schemaVersion -eq 5 -and $json.command)
            return $json
        }
        finally {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        Pop-Location
    }
}

function Assert-MarkdownLinks {
    param([Parameter(Mandatory = $true)][string]$Path)

    $base = Split-Path -Parent $Path
    $text = Get-Content -LiteralPath $Path -Raw
    foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)')) {
        $target = $match.Groups[1].Value
        if ($target -match '^(?i:https?://|mailto:)') { continue }
        Assert-Check ("markdown link exists: {0} -> {1}" -f (Split-Path -Leaf $Path), $target) (Test-Path -LiteralPath (Join-Path $base $target))
    }
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginPath = Join-Path $repositoryRoot 'plugin.json'
$marketplacePath = Join-Path $repositoryRoot 'marketplace.json'
$plugin = Get-Content -LiteralPath $pluginPath -Raw | ConvertFrom-Json
$marketplace = Get-Content -LiteralPath $marketplacePath -Raw | ConvertFrom-Json
$marketplacePlugin = @($marketplace.plugins | Where-Object name -ceq $plugin.name | Select-Object -First 1)
Assert-Check 'plugin and marketplace metadata parse' ($plugin.name -and $marketplace.name -and $marketplacePlugin.Count -eq 1)
Assert-Check 'plugin and marketplace identity matches' ($marketplacePlugin[0].name -ceq $plugin.name -and $marketplacePlugin[0].version -ceq $plugin.version -and $marketplace.metadata.version -ceq $plugin.version -and $marketplacePlugin[0].description -ceq $plugin.description)
Assert-Check 'marketplace author and license match plugin' ($marketplacePlugin[0].author.name -ceq $plugin.author.name -and $marketplacePlugin[0].author.url -ceq $plugin.author.url -and $marketplacePlugin[0].license -ceq $plugin.license -and $marketplacePlugin[0].source -ceq '.')

$declaredDirectories = @($plugin.agents) + @($plugin.skills)
foreach ($declaredPath in $declaredDirectories) {
    Assert-Check "declared directory exists: $declaredPath" (Test-Path -LiteralPath (Join-Path $repositoryRoot $declaredPath) -PathType Container)
}
Assert-Check "declared path exists: $($plugin.hooks)" (Test-Path -LiteralPath (Join-Path $repositoryRoot $plugin.hooks) -PathType Leaf)
$agentFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot $plugin.agents) -Filter '*.agent.md' -File | Sort-Object Name)
Assert-Check 'plugin declares exactly two agents' ($agentFiles.Count -eq 2 -and (@($agentFiles.Name | Sort-Object) -join '|') -ceq 'migration-documenter.agent.md|migration-implementer.agent.md')
$agentTexts = @{}
foreach ($agentFile in $agentFiles) { $agentTexts[$agentFile.Name] = Get-Content -LiteralPath $agentFile.FullName -Raw }
$implementerText = $agentTexts['migration-implementer.agent.md']
$documenterText = $agentTexts['migration-documenter.agent.md']
$skillFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot $plugin.skills) -Filter 'SKILL.md' -File -Recurse)
foreach ($frontMatterFile in @($agentFiles + $skillFiles)) {
    $frontMatterText = Get-Content -LiteralPath $frontMatterFile.FullName -Raw
    $frontMatter = [regex]::Match($frontMatterText, '(?s)^---\r?\n(.*?)\r?\n---(?:\r?\n|$)')
    Assert-Check "valid frontmatter: $($frontMatterFile.FullName.Substring($repositoryRoot.Length + 1))" ($frontMatter.Success -and $frontMatter.Groups[1].Value -match '(?im)^name:\s*\S' -and $frontMatter.Groups[1].Value -match '(?im)^description:\s*\S')
}
Assert-Check 'implementer has only the four permitted tools' ($implementerText -match '(?im)^tools:\s*\[read, search, edit, execute\]\s*$')
Assert-Check 'documenter has no execute tool' ($documenterText -match '(?im)^tools:\s*\[read, search, web, edit\]\s*$' -and $documenterText -notmatch '(?im)^tools:.*execute')

$hooks = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks.json') -Raw | ConvertFrom-Json
$hookNames = @($hooks.hooks.PSObject.Properties.Name | Sort-Object)
Assert-Check 'hooks use version one and expected events' ($hooks.version -eq 1 -and ($hookNames -join '|') -ceq 'preToolUse|subagentStop')
foreach ($hookName in $hookNames) { Assert-Check "hook has one PowerShell command: $hookName" (@($hooks.hooks.$hookName).Count -eq 1 -and $hooks.hooks.$hookName[0].type -ceq 'command' -and $hooks.hooks.$hookName[0].powershell) }

$expectedSchemas = @('state.schema.json', 'manifest.schema.json', 'result.schema.json', 'change-set.schema.json', 'check-result.schema.json', 'repair-context.schema.json', 'repair-input.schema.json', 'documentation-context.schema.json', 'documentation-research.schema.json', 'documentation-input.schema.json')
$schemaDirectory = Join-Path $repositoryRoot 'schemas'
$actualSchemas = @(Get-ChildItem -LiteralPath $schemaDirectory -File -Filter '*.json' | Select-Object -ExpandProperty Name | Sort-Object)
Assert-Check 'schema inventory is complete' ((($actualSchemas -join '|') -ceq (($expectedSchemas | Sort-Object) -join '|')))
foreach ($schemaName in $expectedSchemas) {
    $schema = Get-Content -LiteralPath (Join-Path $schemaDirectory $schemaName) -Raw | ConvertFrom-Json
    $closedSchema = $schema.type -eq 'object' -and $schema.additionalProperties -eq $false
    if ($null -ne $schema.oneOf -and @($schema.oneOf).Count -gt 0) {
        $closedSchema = @($schema.oneOf | Where-Object { $_.type -eq 'object' -and $_.additionalProperties -eq $false }).Count -eq @($schema.oneOf).Count
    }
    Assert-Check "schema parses and closes: $schemaName" $closedSchema
}

$facadeText = Get-Content -LiteralPath $scriptPath -Raw
$pipelineText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'scripts/modules/Migration.Pipeline.psm1') -Raw
$moduleNames = @('Migration.Core', 'Migration.State', 'Migration.Project', 'Migration.Dependencies', 'Migration.Pipeline')
foreach ($moduleName in $moduleNames) { Assert-Check "module exists: $moduleName" (Test-Path -LiteralPath (Join-Path $repositoryRoot ('scripts/modules/' + $moduleName + '.psm1')) -PathType Leaf) }
Assert-Check 'facade loads the five module graph' (@($moduleNames | Where-Object { ($facadeText + $pipelineText) -match [regex]::Escape($_) }).Count -eq 5)
$publicCommands = @('inspect', 'start', 'run', 'status', 'baseline-dependency-context', 'approve-baseline-dependencies', 'skip-check', 'repair-context', 'record-repair', 'documentation-context', 'record-documentation')
foreach ($publicCommand in $publicCommands) { Assert-Check "facade exposes command: $publicCommand" ($facadeText -match ("'" + [regex]::Escape($publicCommand) + "'\s*\{")) }
Assert-Check 'JavaScript inventory is under scripts/js' ((Test-Path -LiteralPath (Join-Path $repositoryRoot 'scripts/js/inspect-lockfile.js') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $repositoryRoot 'scripts/js/render-package-json.js') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'scripts/helpers/render-package-json.js')))
$legacyVisualFixtureFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests/vision-fixture') -File -Recurse -ErrorAction SilentlyContinue)
Assert-Check 'legacy visual and marketplace files are absent' (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'scripts/playwright-runtime-check.js')) -and -not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'scripts/playwright-vision.js')) -and $legacyVisualFixtureFiles.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $repositoryRoot '.github/plugin/marketplace.json')) -and -not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'skills/update-angular/SKILL.md')))

$functionalFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts') -File -Recurse) + @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'agents') -File -Recurse) + @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'skills') -File -Recurse)
$functionalText = (($functionalFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n")
Assert-Check 'functional files contain no visual runtime references' ($functionalText -notmatch '(?i)\bplaywright\b|\bscreenshot\b|\bvision\b|(?<![\w-])browser(?![\w-])')
Assert-Check 'functional files contain no bypass flags' ($functionalText -notmatch '(?i)npx\s+--force|npm\s+(?:install|ci)\s+--force|npm\s+install\s+--legacy-peer-deps|ng\s+update\s+--force|--allow-dirty|--ignore-scripts')
Assert-Check 'skill requires confirmation for baseline dependencies' ($functionalText -match 'baseline-dependency-context' -and $functionalText -match 'approve-baseline-dependencies' -and $functionalText -match 'proposalHash' -and $functionalText -match 'confirmacion')
Assert-Check 'skill documents audited skips and critical gates' ($functionalText -match 'skip-check' -and $functionalText -match 'dependency-tree' -and $functionalText -match 'build' -and $functionalText -match 'status=skipped')
Assert-Check 'skill announces autonomous execution' ($functionalText -match 'trabajare\s+autonomamente')
Assert-MarkdownLinks -Path (Join-Path $repositoryRoot 'README.md')
Assert-MarkdownLinks -Path (Join-Path $repositoryRoot 'docs/README.md')

$temporaryRoot = [IO.Path]::GetTempPath()
$tmp = Join-Path $temporaryRoot ("angular-migration-v5-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$toolDirectory = Join-Path $temporaryRoot ("angular-migration-v5-tools-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
try {
    $nodeFixtureSource = 'public class NodeFixture { public static void Main() { System.Console.WriteLine("v20.11.0"); } }'
    Add-Type -TypeDefinition $nodeFixtureSource -OutputAssembly (Join-Path $toolDirectory 'node.exe') -OutputType ConsoleApplication
    "@echo off`r`necho 10.2.4" | Set-Content -LiteralPath (Join-Path $toolDirectory 'npm.cmd') -Encoding ASCII
    $env:PATH = $toolDirectory + [IO.Path]::PathSeparator + $originalPath

    Import-Module (Resolve-Path $coreModulePath) -DisableNameChecking -Force
    Import-Module (Resolve-Path $projectModulePath) -DisableNameChecking -Force
    Import-Module (Resolve-Path $stateModulePath) -DisableNameChecking -Force
    $facadeText = Get-Content -LiteralPath $scriptPath -Raw
    foreach ($commandName in @('documentation-context', 'record-documentation')) {
        Assert-Check "facade exposes $commandName" ($facadeText -match [regex]::Escape("'$commandName'"))
    }
    $agentText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../agents/migration-documenter.agent.md') -Raw
    Assert-Check 'documenter tools are read search web edit only' ($agentText -match 'tools: \[read, search, web, edit\]' -and $agentText -notmatch '(?im)^tools:.*execute')
    $researchSchema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/documentation-research.schema.json') -Raw | ConvertFrom-Json
    $inputSchema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/documentation-input.schema.json') -Raw | ConvertFrom-Json
    $contextSchema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/documentation-context.schema.json') -Raw | ConvertFrom-Json
    Assert-Check 'documentation schemas are closed' ($researchSchema.additionalProperties -eq $false -and $inputSchema.additionalProperties -eq $false -and @($contextSchema.oneOf).Count -eq 2)
    Assert-Check 'documentation input requires exactly eight files' ($inputSchema.properties.files.minItems -eq 8 -and $inputSchema.properties.files.maxItems -eq 8)
    $hookText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/hooks/copilot-policy.ps1') -Raw
    Assert-Check 'documenter hook policy is present' ($hookText -match 'migration-documenter' -and $hookText -match 'documentation')
    Assert-MigrationRunId -RunId 'angular-7-to-8-20260910T100000Z-a1b2c3d4'
    Assert-Check 'run ids accept UTC timestamp markers' $true
    $volumeRoot = [IO.Path]::GetPathRoot($tmp)
    Assert-Check 'volume root is preserved' ((Resolve-MigrationRoot -Path $volumeRoot) -eq $volumeRoot)
    Assert-Check 'valid Angular range exposes its major' ((Get-VersionMajor -Spec '^7.2.0') -eq 7)
    Assert-Check 'ambiguous version text is rejected' ($null -eq (Get-VersionMajor -Spec 'beta7'))

    $argumentScript = Join-Path $toolDirectory 'argument-echo.ps1'
    '[Console]::Write($args[0])' | Set-Content -LiteralPath $argumentScript -Encoding ASCII
    $powershellPath = (Get-Command powershell.exe).Source
    $argumentResult = Invoke-MigrationProcess -FilePath $powershellPath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $argumentScript, 'value with spaces') -WorkingDirectory $tmp -TimeoutSeconds 10
    Assert-Check 'process arguments preserve boundaries' ($argumentResult.exitCode -eq 0 -and $argumentResult.stdout -eq 'value with spaces')

    $atomicPath = Join-Path $tmp 'atomic.json'
    Write-MigrationJsonAtomic -Value ([ordered]@{ version = 1 }) -Path $atomicPath
    Write-MigrationJsonAtomic -Value ([ordered]@{ version = 2 }) -Path $atomicPath
    $atomicValue = Get-Content -LiteralPath $atomicPath -Raw | ConvertFrom-Json
    $temporaryFiles = @(Get-ChildItem -LiteralPath $tmp -Filter 'atomic.json.*.tmp' -File -ErrorAction SilentlyContinue)
    $backupFiles = @(Get-ChildItem -LiteralPath $tmp -Filter 'atomic.json.*.bak' -File -ErrorAction SilentlyContinue)
    Assert-Check 'atomic write leaves valid latest JSON' ($atomicValue.version -eq 2 -and $temporaryFiles.Count -eq 0 -and $backupFiles.Count -eq 0)

    Push-Location $tmp
    try {
        @'
{
  "name": "fake-angular-app",
  "dependencies": {
    "@angular/core": "^7.2.0",
    "@angular/common": "^7.2.0",
    "rxjs": "~6.3.3",
    "zone.js": "~0.8.26"
  },
  "devDependencies": {
    "@angular/cli": "~7.3.0",
    "typescript": "~3.2.2"
  },
  "scripts": {
    "lint": "echo lint",
    "test": "echo test",
    "build": "echo build"
  }
}
'@ | Set-Content -LiteralPath (Join-Path $tmp 'package.json') -Encoding UTF8
        @'
{
  "version": 1,
  "projects": {
    "fake-angular-app": {
      "projectType": "application"
    }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $tmp 'angular.json') -Encoding UTF8
        @'
{
  "name": "fake-angular-app",
  "lockfileVersion": 1,
  "requires": true,
  "dependencies": {
    "@angular/core": { "version": "7.2.16" },
    "@angular/common": { "version": "7.2.16" }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $tmp 'package-lock.json') -Encoding UTF8
        '.angular-migration/' | Set-Content -LiteralPath (Join-Path $tmp '.gitignore') -Encoding ASCII

        & git init --quiet
        & git config user.email 'smoke@example.invalid'
        & git config user.name 'Migration Smoke'
        & git add .
        & git commit --quiet -m 'fixture'

        Write-Host '1. inspect ready fixture' -ForegroundColor Cyan
        $inspection = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'inspect')
        Assert-Check 'inspect is ready' ($inspection.ok -eq $true -and $inspection.status -eq 'ready')
        Assert-Check 'detects Angular major 7' ($inspection.data.angular.currentMajor -eq 7)
        Assert-Check 'inspect does not create migration state' (-not (Test-Path (Join-Path $tmp '.angular-migration')))
        Assert-Check 'toolchain uses fixtures' ($inspection.data.node.node.executable -eq (Join-Path $toolDirectory 'node.exe') -and $inspection.data.node.npm.executable -eq (Join-Path $toolDirectory 'npm.cmd'))
        $missingRunId = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'run') -ExpectedExitCode 2
        Assert-Check 'run requires an explicit run id' ($missingRunId.error.code -eq 'run_id_required')
        Assert-Check 'discovers lint and build' (($inspection.data.checks | Where-Object id -eq 'lint').status -eq 'configured' -and ($inspection.data.checks | Where-Object id -eq 'build').status -eq 'configured')
        Assert-Check 'checks use structured process arguments' ((@(($inspection.data.checks | Where-Object id -eq 'build').arguments) -join ' ') -eq 'run build')
        Assert-Check 'marks e2e as not-configured' (($inspection.data.checks | Where-Object id -eq 'e2e').status -eq 'not-configured')

        Write-Host '2. sequential target and run creation' -ForegroundColor Cyan
        $jump = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'start', '-TargetMajor', '9') -ExpectedExitCode 2
        Assert-Check 'rejects N to N+2 before creating a run' ($jump.status -eq 'blocked' -and $jump.error.code -eq 'non_sequential_target' -and -not (Test-Path (Join-Path $tmp '.angular-migration')))

        $concurrentOutputs = @(
            (Join-Path $temporaryRoot ("angular-migration-start-" + [guid]::NewGuid().ToString('N') + '-1.json'))
            (Join-Path $temporaryRoot ("angular-migration-start-" + [guid]::NewGuid().ToString('N') + '-2.json'))
        )
        $concurrentErrors = @($concurrentOutputs | ForEach-Object { $_ + '.err' })
        try {
            $startProcesses = @()
            for ($index = 0; $index -lt 2; $index++) {
                $startProcesses += Start-Process powershell.exe -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
                    '-Command', 'start', '-TargetMajor', '8'
                ) -WorkingDirectory $tmp -RedirectStandardOutput $concurrentOutputs[$index] -RedirectStandardError $concurrentErrors[$index] -PassThru
            }
            $startProcesses | ForEach-Object { $_.WaitForExit() }
            $startResults = @($concurrentOutputs | ForEach-Object { Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json })
            $start = $startResults | Where-Object { $_.status -eq 'running' } | Select-Object -First 1
            $blockedStart = $startResults | Where-Object { $_.status -eq 'blocked' -and $_.error.code -eq 'active_run' } | Select-Object -First 1
            Assert-Check 'concurrent starts have one owner' (@($start).Count -eq 1 -and @($blockedStart).Count -eq 1)
        }
        finally {
            @($concurrentOutputs + $concurrentErrors) | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }
        }

        Assert-Check 'start creates a running run' ($start.ok -eq $true -and $start.status -eq 'running' -and $start.data.runId)
        $runId = $start.data.runId
        $runRoot = Join-Path $tmp (".angular-migration\runs\$runId")
        Assert-Check 'only the owner created a run directory' (@(Get-ChildItem -LiteralPath (Join-Path $tmp '.angular-migration\runs') -Directory).Count -eq 1)
        Assert-Check 'manifest exists' (Test-Path (Join-Path $runRoot 'manifest.json'))
        Assert-Check 'state exists' (Test-Path (Join-Path $runRoot 'state.json'))
        Assert-Check 'events exist' (Test-Path (Join-Path $runRoot 'events.jsonl'))
        Assert-Check 'ownership lock exists' (Test-Path (Join-Path $tmp '.angular-migration\active.lock'))
        $startManifest = Get-Content -LiteralPath (Join-Path $runRoot 'manifest.json') -Raw | ConvertFrom-Json
        $startState = Get-Content -LiteralPath (Join-Path $runRoot 'state.json') -Raw | ConvertFrom-Json
        Assert-Check 'manifest starts pending' ($startManifest.resolutionStatus -eq 'pending' -and $startManifest.resolverVersion -eq 1)
        Assert-Check 'state starts with resolution contract' ($startState.baselineStatus -eq 'pending' -and $startState.resolutionStatus -eq 'pending' -and $null -eq $startState.manifestSha256)
        $runtimePath = Join-Path $tmp '.angular-migration/runtime/copilot-policy.ps1'
        Assert-Check 'start copies the pinned hook runtime' ((Test-Path -LiteralPath $runtimePath) -and $startState.runtimeSha256 -ceq (Get-FileHash -LiteralPath $runtimePath).Hash.ToLowerInvariant())
        $noRepair = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'repair-context', '-RunId', $runId) -ExpectedExitCode 2
        Assert-Check 'repair-context refuses running baseline' ($noRepair.error.code -eq 'invalid_repair_stage')
        $noRecord = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'record-repair', '-RunId', $runId, '-InputFile', ".angular-migration/runs/$runId/inbox/repair.json") -ExpectedExitCode 2
        Assert-Check 'record-repair refuses running baseline' ($noRecord.error.code -eq 'invalid_repair_stage')

        Write-Host '3. status and ownership' -ForegroundColor Cyan
        $status = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'status', '-RunId', $runId)
        Assert-Check 'status reads the same run' ($status.ok -eq $true -and $status.data.runId -eq $runId -and $status.data.stage -eq 'baseline')

        $statePath = Join-Path $runRoot 'state.json'
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $state.status = 'needs-repair'
        Write-MigrationJsonAtomic -Value $state -Path $statePath
        $repairStatus = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'status', '-RunId', $runId) -ExpectedExitCode 2
        Assert-Check 'needs-repair is actionable, not successful' ($repairStatus.ok -eq $false -and $repairStatus.status -eq 'needs-repair')

        $state.runId = 'different-run'
        Write-MigrationJsonAtomic -Value $state -Path $statePath
        $invalidState = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'status', '-RunId', $runId) -ExpectedExitCode 1
        Assert-Check 'status rejects state from another run' ($invalidState.status -eq 'failed' -and $invalidState.error.code -eq 'invalid_run_state')

        $second = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'start', '-TargetMajor', '8') -ExpectedExitCode 2
        Assert-Check 'second run is blocked by ownership' ($second.status -eq 'blocked' -and $second.error.code -eq 'active_run')
    }
    finally {
        Pop-Location
    }
}
finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $toolDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host "$($script:failed) smoke checks failed" -ForegroundColor Red
    exit 1
}
Write-Host 'Smoke test OK' -ForegroundColor Green
