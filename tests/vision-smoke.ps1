#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\angular-migration.ps1')).Path
$serverPath = (Resolve-Path (Join-Path $PSScriptRoot 'vision-fixture\server.js')).Path
$tempRoot = Join-Path $env:TEMP ("am-vision-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$port = Get-Random -Minimum 43000 -Maximum 49000
$server = $null

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS $Message" -ForegroundColor Green
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
@{
    routes = @(
        @{ path = '/'; status = 'visitable' },
        @{ path = '/same/'; status = 'visitable' }
    )
    viewports = @(@{ name = 'test'; width = 800; height = 600 })
    masks = @()
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $tempRoot 'routes.json') -Encoding UTF8

Push-Location $tempRoot
try {
    $server = Start-Process node -ArgumentList @($serverPath, $port) -PassThru -WindowStyle Hidden
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $response = Invoke-WebRequest "http://127.0.0.1:$port/baseline/" -UseBasicParsing -TimeoutSec 1
            if ($response.StatusCode -eq 200) { $ready = $true; break }
        }
        catch { [Threading.Thread]::Sleep(100) }
    }
    Assert $ready 'servidor fixture disponible'

    $install = (& powershell -NoProfile -File $scriptPath -Command runtime-install) | ConvertFrom-Json
    Assert ($install.exit_code -eq 0) 'runtime visual preparado'

    $baseline = (& powershell -NoProfile -File $scriptPath -Command vision-run -VisionMode baseline -ManifestPath 'routes.json' -RuntimeUrl "http://127.0.0.1:$port/baseline/" -OutputDir '.angular-migration\vision\test') | ConvertFrom-Json
    if ($baseline.exit_code -ne 0 -or $baseline.data.summary.captured -ne 2) { Write-Host ($baseline | ConvertTo-Json -Depth 8) }
    Assert ($baseline.exit_code -eq 0 -and $baseline.data.summary.captured -eq 2) 'baseline captura ambas rutas'

    $comparison = (& powershell -NoProfile -File $scriptPath -Command vision-run -VisionMode compare -ManifestPath 'routes.json' -RuntimeUrl "http://127.0.0.1:$port/candidate/" -OutputDir '.angular-migration\vision\test' -PublishDir 'published') | ConvertFrom-Json
    Assert ($comparison.exit_code -eq 0) 'comparación visual termina correctamente'
    Assert ($comparison.data.summary.different -eq 1 -and $comparison.data.summary.unchanged -eq 1) 'distingue vista cambiada e idéntica'
    Assert ((Get-ChildItem 'published' -Recurse -Filter 'baseline.png').Count -eq 1) 'publica solo una baseline diferente'
    Assert ((Get-ChildItem 'published' -Recurse -Filter 'candidate.png').Count -eq 1) 'publica solo una candidata diferente'
    Assert ((Get-ChildItem 'published' -Recurse -Filter 'diff.png').Count -eq 1) 'publica solo un mapa diff'
    Assert (-not (Test-Path '.angular-migration\vision\test\temp')) 'elimina capturas temporales e iguales'
}
finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Pop-Location
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Vision smoke OK' -ForegroundColor Green