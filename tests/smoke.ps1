#Requires -Version 5.1
<#
  smoke.ps1 — smoke test del script angular-migration.ps1 (v2)
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

    Write-Host '4. comandos v2 existen en ValidateSet' -ForegroundColor Cyan
    $src = Get-Content $SCRIPT -Raw
    foreach ($cmd in @('analyze-project', 'write-snapshot', 'ng-update', 'diff', 'ensure-node')) {
        Check "ValidateSet contiene '$cmd'" ($src -match "'$cmd'")
    }
    Check 'snapshot consulta todas las dependencias directas' ($src -match 'Get-DirectDependencyMetadata \$dependencies')
    Check 'snapshot guarda inventario completo' ($src -match 'direct_dependencies =')
    Check 'snapshot guarda metadata npm' ($src -match 'dependency_metadata =')
    Check 'snapshot marca metadata completa' ($src -match 'dependency_metadata_complete =')
    Check 'snapshot se escribe dentro del salto' ($src -match '\$snapFile = Join-Path \$stepDir "snapshot-v\$AngularMajor\.json"')
    Check 'usa npm view para registry privado' ($src -match "Invoke-Slow 'npm\.cmd'.*'view'.*\$name.*'--json'")
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
    Check 'Hermes exige rama antes del resto' ($hermesSrc -match 'primer paso obligatorio del salto')
    Check 'Hermes verifica el why fisico' ($hermesSrc -match 'El `why` debe existir y no estar vacío')
    Check 'Hermes exige metadata completa' ($hermesSrc -match 'direct_dependencies.*dependency_metadata')
    Check 'Cronos relee el why antes de responder' ($cronosSrc -match 'vuelve a leer `docs/migration/v\{to\}/v\{to\}-why\.md`')
    Check 'Prometeo audita todas las dependencias' ($prometeoSrc -match 'Auditoría de dependencias')
    Check 'Hefesto usa el modelo de implementacion' ($hefestoSrc -match 'model: claude-sonnet-5 \(copilot\)')

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
