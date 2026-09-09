#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\scripts\angular-migration.ps1'
$coreModulePath = Join-Path $PSScriptRoot '..\scripts\modules\Migration.Core.psm1'
$script:failed = 0

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
        $stderrPath = Join-Path $env:TEMP ("angular-migration-smoke-" + [guid]::NewGuid().ToString('N') + '.err')
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

$tmp = Join-Path $env:TEMP ("angular-migration-v5-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
  Import-Module (Resolve-Path $coreModulePath) -DisableNameChecking -Force
  $atomicPath = Join-Path $tmp 'atomic.json'
  Write-MigrationJsonAtomic -Value ([ordered]@{ version = 1 }) -Path $atomicPath
  Write-MigrationJsonAtomic -Value ([ordered]@{ version = 2 }) -Path $atomicPath
  $atomicValue = Get-Content -LiteralPath $atomicPath -Raw | ConvertFrom-Json
  $temporaryFiles = @(Get-ChildItem -LiteralPath $tmp -Filter 'atomic.json.*.tmp' -File -ErrorAction SilentlyContinue)
  Assert-Check 'atomic write leaves valid latest JSON' ($atomicValue.version -eq 2 -and $temporaryFiles.Count -eq 0)

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
  "dependencies": {}
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
        Assert-Check 'discovers lint and build' (($inspection.data.checks | Where-Object id -eq 'lint').status -eq 'configured' -and ($inspection.data.checks | Where-Object id -eq 'build').status -eq 'configured')
        Assert-Check 'marks e2e as not-configured' (($inspection.data.checks | Where-Object id -eq 'e2e').status -eq 'not-configured')

        Write-Host '2. sequential target and run creation' -ForegroundColor Cyan
        $jump = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'start', '-TargetMajor', '9') -ExpectedExitCode 2
        Assert-Check 'rejects N to N+2 before creating a run' ($jump.status -eq 'blocked' -and $jump.error.code -eq 'non_sequential_target' -and -not (Test-Path (Join-Path $tmp '.angular-migration')))

        $start = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'start', '-TargetMajor', '8')
        Assert-Check 'start creates a running run' ($start.ok -eq $true -and $start.status -eq 'running' -and $start.data.runId)
        $runId = $start.data.runId
        $runRoot = Join-Path $tmp (".angular-migration\runs\$runId")
        Assert-Check 'manifest exists' (Test-Path (Join-Path $runRoot 'manifest.json'))
        Assert-Check 'state exists' (Test-Path (Join-Path $runRoot 'state.json'))
        Assert-Check 'events exist' (Test-Path (Join-Path $runRoot 'events.jsonl'))
        Assert-Check 'ownership lock exists' (Test-Path (Join-Path $tmp '.angular-migration\active.lock'))

        Write-Host '3. status and ownership' -ForegroundColor Cyan
        $status = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'status', '-RunId', $runId)
        Assert-Check 'status reads the same run' ($status.ok -eq $true -and $status.data.runId -eq $runId -and $status.data.stage -eq 'baseline')
        $second = Invoke-Facade -ProjectRoot $tmp -Arguments @('-Command', 'start', '-TargetMajor', '8') -ExpectedExitCode 2
        Assert-Check 'second run is blocked by ownership' ($second.status -eq 'blocked' -and $second.error.code -eq 'active_run')
    }
    finally {
        Pop-Location
    }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host "$($script:failed) smoke checks failed" -ForegroundColor Red
    exit 1
}
Write-Host 'Smoke test OK' -ForegroundColor Green
