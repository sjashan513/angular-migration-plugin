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
  "dependencies": { "@angular/core": "^7.2.0", "@ionic/angular": "^4.0.0", "rxjs": "~6.3.3", "zone.js": "~0.8.26" },
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
    Check 'dependency_count = 6' ($anOut.data.dependency_count -eq 6)
    Check 'typescript marcada como dev' ($anOut.data.dependencies.'typescript'.type -eq 'dev')

    Write-Host '4. comandos v2 existen en ValidateSet' -ForegroundColor Cyan
    $src = Get-Content $SCRIPT -Raw
    foreach ($cmd in @('analyze-project', 'write-snapshot', 'ng-update', 'diff', 'ensure-node')) {
        Check "ValidateSet contiene '$cmd'" ($src -match "'$cmd'")
    }
    Write-Host '5. resolver de script contempla la instalacion por marketplace' -ForegroundColor Cyan
    foreach ($agent in @('Hermes', 'Prometeo', 'Hefesto')) {
        $agentSrc = Get-Content (Join-Path $PSScriptRoot "..\agents\$agent.agent.md") -Raw
        Check "$agent contempla copilot\marketplaces" ($agentSrc -match 'copilot\\marketplaces\\sjashan513-angular-migration-plugin')
    }

    Write-Host '6. ensure-node (gestión de Node)' -ForegroundColor Cyan
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
