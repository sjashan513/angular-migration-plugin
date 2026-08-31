#Requires -Version 5.1
<#
  smoke.ps1 — smoke test del script angular-migration.ps1 (v3)
  Sin red ni npm: valida sintaxis, rutas (bug $PSScriptRoot de v1), init y
  analyze-project contra un proyecto Angular fake en %TEMP%.
  Uso: powershell -File tests\smoke.ps1
#>

$ErrorActionPreference = 'Stop'
$SCRIPT = Join-Path $PSScriptRoot '..\scripts\angular-migration.ps1'
$script:failed = 0

function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL $Name" -ForegroundColor Red; $script:failed++ }
}

Write-Host '1. Sintaxis' -ForegroundColor Cyan
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($SCRIPT, [ref]$null, [ref]$parseErrors)
Check 'script parsea sin errores' ($parseErrors.Count -eq 0)

Write-Host '2. init en proyecto fake (bug de rutas v1)' -ForegroundColor Cyan
$tmp = Join-Path $env:TEMP ("am-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
@'
{
  "name": "fake-app",
    "dependencies": { "@angular/core": "^7.2.0", "@ionic/angular": "^4.0.0", "rxjs": "~6.3.3", "zone.js": "~0.8.26", "lodash": "^4.17.0" },
  "devDependencies": { "@angular/cli": "~7.3.0", "typescript": "~3.2.2" }
}
'@ | Set-Content (Join-Path $tmp 'package.json') -Encoding UTF8

Push-Location $tmp
try {
    $initOut = (& powershell -NoProfile -File $SCRIPT -Command init) | ConvertFrom-Json
    Check 'init exit_code 0' ($initOut.exit_code -eq 0)
    Check 'config.json creado en el PROYECTO' (Test-Path (Join-Path $tmp '.angular-migration\config.json'))
    Check 'state.json creado en el PROYECTO' (Test-Path (Join-Path $tmp '.angular-migration\state.json'))
    Check 'nada escrito en la carpeta del plugin' (-not (Test-Path (Join-Path $PSScriptRoot '..\.angular-migration')))
    Check '.gitignore del proyecto incluye .angular-migration/' ((Get-Content (Join-Path $tmp '.gitignore') -Raw) -match '\.angular-migration/')
    Check 'detecta angular_current = 7' ($initOut.data.detected.angular_current -eq 7)
    Check 'detecta ionic = true' ($initOut.data.detected.features.ionic -eq $true)

    Write-Host '3. analyze-project' -ForegroundColor Cyan
    $anOut = (& powershell -NoProfile -File $SCRIPT -Command analyze-project) | ConvertFrom-Json
    Check 'analyze-project exit_code 0' ($anOut.exit_code -eq 0)
    Check 'dependency_count = 7' ($anOut.data.dependency_count -eq 7)
    Check 'typescript marcada como dev' ($anOut.data.dependencies.'typescript'.type -eq 'dev')
    Check 'dependencia externa incluida' ($anOut.data.dependencies.'lodash'.version -eq '^4.17.0')

    Write-Host '3b. runtime-check Playwright' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path (Join-Path $tmp 'node_modules\.bin') -Force | Out-Null
    @('@echo off', 'echo Executed 0 tests', 'exit /b 0') | Set-Content (Join-Path $tmp 'node_modules\.bin\ng.cmd') -Encoding ASCII
    $runtimeDir = Join-Path $tmp 'playwright-runtime'
    $runtimeOut = (& powershell -NoProfile -File $SCRIPT -Command runtime-check -AngularMajor 8 -RuntimeDir $runtimeDir) | ConvertFrom-Json
    Check 'runtime-check usa Playwright' ($runtimeOut.exit_code -eq 2 -and $runtimeOut.data.status -eq 'unverified' -and @('playwright_missing', 'runtime_node_missing') -contains $runtimeOut.data.reason)

    Write-Host '4. comandos v3 existen en ValidateSet' -ForegroundColor Cyan
    $src = Get-Content $SCRIPT -Raw
    $playwrightSrc = Get-Content (Join-Path $PSScriptRoot '..\scripts\playwright-runtime-check.js') -Raw
    foreach ($cmd in @('analyze-project', 'write-snapshot', 'ng-update', 'build', 'runtime-install', 'runtime-check', 'diff', 'ensure-node')) {
        Check "ValidateSet contiene '$cmd'" ($src -match "'$cmd'")
    }
    foreach ($cmd in @('changes-init', 'changes-record', 'changes-close', 'changes-read', 'vision-run')) {
        Check "ValidateSet contiene '$cmd'" ($src -match "'$cmd'")
    }
    Check 'snapshot consulta todas las dependencias directas' ($src -match 'Get-DirectDependencyMetadata \$dependencies')
    Check 'snapshot guarda inventario completo' ($src -match 'direct_dependencies\s*=')
    Check 'snapshot guarda metadata npm' ($src -match 'dependency_metadata\s*=')
    Check 'snapshot marca metadata completa' ($src -match 'dependency_metadata_complete =')
    Check 'snapshot conserva fallos de metadata' ($src -match 'dependency_metadata_failures =')
    Check 'snapshot pide confirmacion para metadata parcial' ($src -match 'requires_user_confirmation')
    Check 'snapshot se escribe dentro del salto' ($src -match '\$snapFile = Join-Path \$stepDir "snapshot-v\$AngularMajor\.json"')
    Check 'usa npm view para registry privado' ($src -match "Invoke-Slow 'npm\.cmd'.*'view'.*\$name.*'--json'")
    Check 'ValidateSet contiene progreso' ($src -match "'progress'")
    $progressErr = Join-Path $tmp 'progress.stderr'
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $progressOut = (& powershell -NoProfile -File $SCRIPT -Command progress -ProgressCurrent 2 -ProgressTotal 5 -ProgressLabel 'snapshot' 2> $progressErr) | ConvertFrom-Json
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    $progressFile = Get-Content (Join-Path $tmp '.angular-migration\progress.json') -Raw | ConvertFrom-Json
    Check 'progress devuelve JSON y persiste estado' ($progressOut.exit_code -eq 0 -and $progressOut.data.current -eq 2 -and $progressFile.total -eq 5)
    Check 'progress escribe barra en stderr' ((Get-Content $progressErr -Raw) -match '\[progreso\].*2/5.*snapshot')
    Write-Host '5. resolver de script contempla la instalacion por marketplace' -ForegroundColor Cyan
    foreach ($agent in @('Hermes', 'Prometeo', 'Hefesto')) {
        $agentSrc = Get-Content (Join-Path $PSScriptRoot "..\agents\$agent.agent.md") -Raw
        Check "$agent contempla copilot\marketplaces" ($agentSrc -match 'copilot\\marketplaces\\sjashan513-angular-migration-plugin')
    }

    Write-Host '6. guards de orquestacion y procesos' -ForegroundColor Cyan
    $hermesSrc = Get-Content (Join-Path $PSScriptRoot '..\agents\Hermes.agent.md') -Raw
    $cronosSrc = Get-Content (Join-Path $PSScriptRoot '..\agents\Cronos.agent.md') -Raw
    $prometeoSrc = Get-Content (Join-Path $PSScriptRoot '..\agents\Prometeo.agent.md') -Raw
    $hefestoSrc = Get-Content (Join-Path $PSScriptRoot '..\agents\Hefesto.agent.md') -Raw
    Check 'build tiene timeout y mata el arbol' ($src -match 'TimeoutSeconds 900' -and $src -match 'taskkill\.exe /PID')
    Check 'build desactiva progreso del CLI' ($src -match "'--progress=false'")
    Check 'runtime-check arranca y limpia ng serve' ($src -match "'serve'" -and $src -match 'taskkill\.exe /PID')
    Check 'runtime-check espera a ng serve' ($src -match 'Wait-ForRuntimeServer' -and $src -match 'server_not_ready')
    Check 'runner captura consola y errores de pagina' ($playwrightSrc -match 'page\.on\(["'']console["'']' -and $playwrightSrc -match 'page\.on\(["'']pageerror["'']' -and $playwrightSrc -match 'chromium\.launch')
    Check 'Hermes exige rama antes del resto' ($hermesSrc -match 'primer paso obligatorio del salto')
    Check 'Hermes verifica el why fisico' ($hermesSrc -match 'El `why` debe existir y no estar vacío')
    Check 'Hermes pide confirmacion para metadata parcial' ($hermesSrc -match 'requires_user_confirmation' -and $hermesSrc -match 'metadata_failures' -and $hermesSrc -match 'metadata parcial')
    Check 'Hermes bloquea si falta el why' ($hermesSrc -match 'detén el salto antes de invocar a Hefesto')
    Check 'Hermes reintenta Cronos antes de bloquear' ($hermesSrc -match 'invoca \*\*una vez\*\* a Cronos' -and $hermesSrc -match 'vuelve a leer')
    Check 'Cronos relee el why antes de responder' ($cronosSrc -match 'vuelve a leer `docs/migration/v\{to\}/v\{to\}-why\.md`')
    Check 'Cronos tolera metadata parcial sin inventar' ($cronosSrc -match 'dependency_metadata_failures' -and $cronosSrc -match 'no inventes')
    Check 'Prometeo audita todas las dependencias' ($prometeoSrc -match 'Auditoría de dependencias')
    Check 'Prometeo acepta metadata parcial autorizada' ($prometeoSrc -match 'metadata parcial' -and $prometeoSrc -match 'missing_metadata')
    Check 'Hefesto declara un modelo de implementacion' ($hefestoSrc -match '(?m)^model:\s+\S+')

    Write-Host '6b. ledger de cambios agrupados' -ForegroundColor Cyan
    $ledgerPath = '.angular-migration\ledger-test.json'
    $payloadPath = '.angular-migration\change-input.json'
    $closePath = '.angular-migration\change-close.json'
    $ledgerInit = (& powershell -NoProfile -File $SCRIPT -Command changes-init -LedgerPath $ledgerPath -RunKind diagnostic -AgentName Asclepio) | ConvertFrom-Json
    Check 'changes-init crea el ledger' ($ledgerInit.exit_code -eq 0 -and (Test-Path $ledgerPath))
    $changedFiles = @(1..40 | ForEach-Object { "src/app/file-$_.ts" })
    $recordsOk = $true
    foreach ($file in $changedFiles) {
        [PSCustomObject]@{
            id = 'same-fix'; category = 'typescript'; source = 'linter'; summary = 'Mismo fix'
            reason = 'Regla instalada'; transformation = @{ before = 'old'; after = 'new' }
            occurrence = @{ file = $file; location = '1:1'; status = 'applied' }
            validation = @{ command = 'lint'; status = 'passed' }
        } | ConvertTo-Json -Depth 5 | Set-Content $payloadPath -Encoding UTF8
        $recordOut = (& powershell -NoProfile -File $SCRIPT -Command changes-record -LedgerPath $ledgerPath -InputFile $payloadPath) | ConvertFrom-Json
        if ($recordOut.exit_code -ne 0) { $recordsOk = $false }
    }
    Check 'changes-record acepta 40 ocurrencias' $recordsOk
    @{ changed_files = $changedFiles; ignored_files = @() } | ConvertTo-Json | Set-Content $closePath -Encoding UTF8
    $closeOut = (& powershell -NoProfile -File $SCRIPT -Command changes-close -LedgerPath $ledgerPath -InputFile $closePath) | ConvertFrom-Json
    $ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json
    Check 'changes-close agrupa 40 fixes en una entrada' ($closeOut.exit_code -eq 0 -and $ledger.groups.Count -eq 1 -and $ledger.groups[0].count -eq 40)
    Check 'changes-close calcula resumen' ($ledger.closed -eq $true -and $ledger.summary.groups -eq 1 -and $ledger.summary.occurrences -eq 40 -and $ledger.summary.files -eq 40)
    $readOut = (& powershell -NoProfile -File $SCRIPT -Command changes-read -LedgerPath $ledgerPath) | ConvertFrom-Json
    Check 'changes-read devuelve el ledger cerrado' ($readOut.exit_code -eq 0 -and $readOut.data.closed -eq $true -and $readOut.data.summary.occurrences -eq 40)

    $uncoveredLedgerPath = '.angular-migration\ledger-uncovered.json'
    $uncoveredInit = (& powershell -NoProfile -File $SCRIPT -Command changes-init -LedgerPath $uncoveredLedgerPath -RunKind diagnostic -AgentName Asclepio) | ConvertFrom-Json
    $uncoveredRecord = (& powershell -NoProfile -File $SCRIPT -Command changes-record -LedgerPath $uncoveredLedgerPath -InputFile $payloadPath) | ConvertFrom-Json
    @{ changed_files = @('src/app/file-40.ts', 'src/app/unexplained.ts'); ignored_files = @() } | ConvertTo-Json | Set-Content $closePath -Encoding UTF8
    $uncoveredClose = (& powershell -NoProfile -File $SCRIPT -Command changes-close -LedgerPath $uncoveredLedgerPath -InputFile $closePath) | ConvertFrom-Json
    Check 'changes-close rechaza ficheros sin explicar' ($uncoveredInit.exit_code -eq 0 -and $uncoveredRecord.exit_code -eq 0 -and $uncoveredClose.exit_code -eq 1 -and $uncoveredClose.data.error -match 'unexplained.ts')

    Write-Host '6c. contratos v3' -ForegroundColor Cyan
    $asclepioSrc = Get-Content (Join-Path $PSScriptRoot '..\agents\Asclepio.agent.md') -Raw
    $heliosSrc = Get-Content (Join-Path $PSScriptRoot '..\agents\Helios.agent.md') -Raw
    $visionSrc = Get-Content (Join-Path $PSScriptRoot '..\scripts\playwright-vision.js') -Raw
    Check 'Asclepio es invocable y limita safe-fix' ($asclepioSrc -match 'user-invocable:\s+true' -and $asclepioSrc -match 'safe-fix' -and $asclepioSrc -match 'Nunca cambies dependencias')
    Check 'Helios usa cinco fases secuenciales' ($heliosSrc -match 'Fase 1/5' -and $heliosSrc -match 'Fase 3/5' -and $heliosSrc -match 'Fase 5')
    Check 'Helios usa auth local separada' ($heliosSrc -match 'base-auth-file' -and $heliosSrc -match 'candidate-auth-file' -and $heliosSrc -match 'No pegues contraseñas')
    Check 'runner acepta archivo de autenticacion' ($src -match '\[string\]\$AuthFile' -and $visionSrc -match '--auth-file')
    Check 'agentes nuevos no pertenecen a Hermes' ($hermesSrc -match 'agents: \["Prometeo", "Hefesto", "Cronos", "Clio"\]' -and $hermesSrc -notmatch 'agents: \[[^\r\n]*(Asclepio|Helios)')
    Check 'runner conserva capturas y publica diferencias' ($visionSrc -match 'baselineDir = path\.join\(outputDir, "baseline"\)' -and $visionSrc -match 'candidateDir = path\.join\(outputDir, "candidate"\)' -and $visionSrc -match 'difference_ratio')
    Check 'schemas v3 son JSON valido' ((Get-Content (Join-Path $PSScriptRoot '..\schemas\changes.schema.json') -Raw | ConvertFrom-Json) -and (Get-Content (Join-Path $PSScriptRoot '..\schemas\vision.schema.json') -Raw | ConvertFrom-Json))
    Check 'catalogo Asclepio es JSON valido' ((Get-Content (Join-Path $PSScriptRoot '..\rules\angular-patterns.json') -Raw | ConvertFrom-Json).rules.Count -gt 0)

    & git init --quiet
    & git config user.email 'smoke@example.invalid'
    & git config user.name 'Migration Smoke'
    & git add .
    & git commit --quiet -m 'initial'
    $branchOut = (& powershell -NoProfile -File $SCRIPT -Command create-branch -AngularMajor 8) | ConvertFrom-Json
    if ($branchOut.exit_code -ne 0 -or $branchOut.data.active_branch -ne 'migration/v8') { Write-Host ($branchOut | ConvertTo-Json -Depth 5) }
    Check 'create-branch crea y activa migration/v8' ($branchOut.exit_code -eq 0 -and $branchOut.data.active_branch -eq 'migration/v8')
    $branchAgainOut = (& powershell -NoProfile -File $SCRIPT -Command create-branch -AngularMajor 8) | ConvertFrom-Json
    if ($branchAgainOut.exit_code -ne 0 -or $branchAgainOut.data.active_branch -ne 'migration/v8') { Write-Host ($branchAgainOut | ConvertTo-Json -Depth 5) }
    Check 'create-branch existente sigue siendo idempotente' ($branchAgainOut.exit_code -eq 0 -and $branchAgainOut.data.active_branch -eq 'migration/v8')
    $stepDir = Join-Path $tmp '.angular-migration\v7-v8.log'
    Check 'crea directorio fisico por salto' (Test-Path $stepDir -PathType Container)
    Check 'log de Hermes queda dentro del salto' (Test-Path (Join-Path $stepDir 'logs\hermes.log'))
    $rootMigrationFiles = @(Get-ChildItem (Join-Path $tmp '.angular-migration') -File | Select-Object -ExpandProperty Name)
    Check 'config y state siguen en la raiz de migracion' ($rootMigrationFiles -contains 'config.json' -and $rootMigrationFiles -contains 'state.json')
    Check 'no crea handoff en la raiz de migracion' ($rootMigrationFiles -notcontains 'snapshot-v8.json' -and $rootMigrationFiles -notcontains 'plan-v8.json' -and $rootMigrationFiles -notcontains 'report-v8.json')
    $hermesPaths = Get-Content (Join-Path $PSScriptRoot '..\agents\Hermes.agent.md') -Raw
    Check 'Hermes usa handoff por salto' ($hermesPaths -match 'v\{from\}-v\{to\}\.log/snapshot-v\{to\}\.json')

    Write-Host '7. ensure-node (gestión de Node)' -ForegroundColor Cyan
    $nodeMajor = [int]((& node --version) -replace 'v(\d+)\..*', '$1')
    $nodeOut = (& powershell -NoProfile -File $SCRIPT -Command ensure-node -AngularMajor $nodeMajor) | ConvertFrom-Json
    Check 'ensure-node no-op con el major activo' ($nodeOut.exit_code -eq 0 -and $nodeOut.data.ok -eq $true -and $nodeOut.data.action -eq 'none')

    $missingMajor = @(8, 10, 12, 14, 16, 18 | Where-Object { $_ -ne $nodeMajor })[0]
    $missingOut = (& powershell -NoProfile -File $SCRIPT -Command ensure-node -AngularMajor $missingMajor) | ConvertFrom-Json
    $validResult = ($missingOut.data.ok -eq $true) -or ($missingOut.data.needs_user -eq $true)
    Check "ensure-node con major ${missingMajor}: switch o needs_user" $validResult
}
finally {
    Pop-Location
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failed -gt 0) { Write-Host "$($script:failed) checks fallaron" -ForegroundColor Red; exit 1 }
Write-Host 'Smoke test OK' -ForegroundColor Green
