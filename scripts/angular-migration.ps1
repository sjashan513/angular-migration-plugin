#Requires -Version 5.1
<#
  angular-migration.ps1 — optimizado para velocidad
  Principios:
   - Cada comando hace SOLO su trabajo. Nada de side-effects globales.
   - State lazy: solo se lee/escribe cuando el comando lo necesita.
   - Output JSON comprimido (-Compress): menos tokens para el agente.
   - El state completo SOLO se devuelve en read-state. El resto devuelve data mínima.
   - npm registry: metadata abreviada (corgi) + HttpClient async = 1 ronda paralela real.
   - Documentación humana: docs/migration/ (commiteada). Aquí solo state de máquina.
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'init', 'read-state',
        'resolve-versions',
        'install-angular', 'install-devdeps', 'install-ionic',
        'build', 'commit', 'complete-step',
        'git-status', 'node-version', 'create-branch'
    )]
    [string]$Command,

    [string]$AngularMajor,
    [string]$AngularVersion,
    [string]$CliVersion,
    [string]$BuildVersion,
    [string]$IonicVersion,
    [string]$ZoneVersion,
    [string]$TypescriptVersion,
    [string]$RxjsVersion,
    [string]$CommitMessage
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$env:GIT_TERMINAL_PROMPT = '0'

# ── Paths (solo strings, cero IO en arranque) ────────────────────
$MIGRATION_DIR  = Join-Path $PSScriptRoot '.angular-migration'
$CONFIG_FILE    = Join-Path $MIGRATION_DIR 'config.json'
$STATE_FILE     = Join-Path $MIGRATION_DIR 'state.json'
$GITIGNORE_FILE = Join-Path $PSScriptRoot '.gitignore'

# ── Tablas de compatibilidad (constantes, sin coste) ─────────────
$IONIC_COMPAT = @{ '8'='4';'9'='5';'10'='5';'11'='5';'12'='6';'13'='6';'14'='6';'15'='7';'16'='7';'17'='7' }
$RXJS_MIN     = @{ '8'='6.4';'9'='6.5';'10'='6.5';'11'='6.6';'12'='6.6';'13'='7.4';'14'='7.5';'15'='7.5';'16'='7.8';'17'='7.8' }
$NODE_MIN     = @{ '8'='10';'9'='10';'10'='10';'11'='10';'12'='12';'13'='12';'14'='14';'15'='14';'16'='16';'17'='18' }

# ================================================================
# HELPERS — todos lazy, ninguno se ejecuta si el comando no lo pide
# ================================================================

function Read-Config {
    if (Test-Path $CONFIG_FILE) { return Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json }
    return $null
}

function Save-Config($c) {
    $c | ConvertTo-Json -Depth 10 | Set-Content $CONFIG_FILE -Encoding UTF8
}

function New-DefaultState {
    return [PSCustomObject]@{
        angular_current = 0
        last_build      = $null
        completed_steps = @()
        commits         = @()
        errors_history  = @()
    }
}

function Read-MigState {
    if (Test-Path $STATE_FILE) { return Get-Content $STATE_FILE -Raw | ConvertFrom-Json }
    return New-DefaultState
}

function Save-MigState($s) {
    $s | ConvertTo-Json -Depth 10 | Set-Content $STATE_FILE -Encoding UTF8
}

function Get-AngularMajorLocal {
    $pkg = Get-Content 'package.json' -Raw | ConvertFrom-Json
    $ver = $pkg.dependencies.'@angular/core' -replace '[~^]',''
    return [int]($ver.Split('.')[0])
}

# Output: JSON comprimido, SIN echo del state (solo read-state lo devuelve)
function Emit($exitCode, $data) {
    [PSCustomObject]@{
        command   = $Command
        exit_code = $exitCode
        data      = $data
    } | ConvertTo-Json -Depth 10 -Compress
    if ($exitCode -ne 0) { exit $exitCode }
}

function Invoke-Slow {
    param([string]$exe, [string[]]$argList)
    $outFile = "$env:TEMP\mig-out-$PID.txt"
    $errFile = "$env:TEMP\mig-err-$PID.txt"
    $proc = Start-Process $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
    $stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    return @($proc.ExitCode, $stdout, $stderr)
}

# Filtra npm WARN pero conserva ERR — el agente necesita los errores reales
function Clean-NpmStderr($stderr) {
    if (-not $stderr) { return '' }
    return (($stderr -split "`n") | Where-Object { $_ -and $_ -notmatch 'npm WARN' }) -join "`n"
}

# Lee el último log de npm debug y extrae las líneas de error
# Se llama automáticamente cuando un install falla — Hefesto no tiene que pedirlo
function Get-NpmErrorDetail {
    $logDir = Join-Path $env:APPDATA 'npm-cache\_logs'
    if (-not (Test-Path $logDir)) { return 'Log dir not found' }
    $lastLog = Get-ChildItem $logDir -Filter '*debug.log' |
        Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $lastLog) { return 'No npm log found' }
    $lines = Get-Content $lastLog.FullName -Encoding UTF8 |
        Where-Object { $_ -match 'npm ERR!|error ' } |
        Select-Object -Last 30
    return ($lines -join "`n")
}

# ================================================================
# COMMANDS
# ================================================================

switch ($Command) {

    # ── init ─────────────────────────────────────────────────────
    'init' {
        if (-not (Test-Path 'package.json')) {
            Emit 1 @{ error = 'No package.json. Ejecuta init desde la raiz del repo Angular.' }
        }

        $existing = Read-Config
        $pkg = Get-Content 'package.json' -Raw | ConvertFrom-Json
        $allDeps = @()
        if ($pkg.dependencies)    { $allDeps += $pkg.dependencies.PSObject.Properties.Name }
        if ($pkg.devDependencies) { $allDeps += $pkg.devDependencies.PSObject.Properties.Name }

        $detected = [PSCustomObject]@{
            project_name    = $pkg.name
            angular_current = [int](($pkg.dependencies.'@angular/core' -replace '[~^]','').Split('.')[0])
            features        = [PSCustomObject]@{
                ionic     = $allDeps -contains '@ionic/angular'
                capacitor = $allDeps -contains '@capacitor/core'
                pwa       = $allDeps -contains '@angular/pwa'
                ngrx      = $allDeps -contains '@ngrx/store'
                material  = $allDeps -contains '@angular/material'
            }
        }

        if ($existing) {
            Emit 0 ([PSCustomObject]@{ already_inited = $true; config = $existing; detected = $detected })
        }

        if (-not (Test-Path $MIGRATION_DIR)) { New-Item -ItemType Directory -Path $MIGRATION_DIR | Out-Null }

        $config = [PSCustomObject]@{
            project_name   = $detected.project_name
            features       = $detected.features
            node_manager   = if (Get-Command fnm -ErrorAction SilentlyContinue) { 'fnm' } else { 'nvm' }
            created_at     = (Get-Date -Format 'yyyy-MM-dd')
            schema_version = '2'
        }
        Save-Config $config

        $state = New-DefaultState
        $state.angular_current = $detected.angular_current
        Save-MigState $state

        # gitignore: una sola lectura, un solo append si falta
        $gitignorePatched = $false
        $lines = if (Test-Path $GITIGNORE_FILE) { Get-Content $GITIGNORE_FILE } else { @() }
        if ($lines -notcontains '.angular-migration/') {
            Add-Content $GITIGNORE_FILE "`n# Angular migration local state (never commit)`n.angular-migration/"
            $gitignorePatched = $true
        }

        Emit 0 ([PSCustomObject]@{
            already_inited    = $false
            migration_dir     = $MIGRATION_DIR
            gitignore_patched = $gitignorePatched
            detected          = $detected
            node_manager      = $config.node_manager
        })
    }

    # ── read-state ───────────────────────────────────────────────
    # El ÚNICO comando que devuelve config + state completos + git.
    # Una llamada = todo lo que Hermes necesita para la Fase 0/1.
    'read-state' {
        $config = Read-Config
        $state  = Read-MigState
        $state.angular_current = Get-AngularMajorLocal
        Save-MigState $state

        # 1 solo spawn de git: porcelain v1 + branch en la misma llamada
        $gitOut = (& git status --porcelain=v1 --branch 2>$null) -split "`n"
        $branchLine = $gitOut | Select-Object -First 1        # "## main...origin/main"
        $dirtyLines = @($gitOut | Select-Object -Skip 1 | Where-Object { $_ })

        Emit 0 ([PSCustomObject]@{
            inited      = ($null -ne $config)
            config      = $config
            state       = $state
            node_active = (& node --version 2>$null)
            git         = [PSCustomObject]@{
                branch      = ($branchLine -replace '^## ','') -replace '\.\.\..*',''
                clean       = ($dirtyLines.Count -eq 0)
                dirty_files = $dirtyLines
            }
        })
    }

    # ── git-status ───────────────────────────────────────────────
    # 2 spawns de git (antes 4). Sin tocar state ni package.json.
    'git-status' {
        $gitOut = (& git status --porcelain=v1 --branch 2>$null) -split "`n"
        $branchLine = $gitOut | Select-Object -First 1
        $dirtyLines = @($gitOut | Select-Object -Skip 1 | Where-Object { $_ })
        $lastCommit = (& git log -1 --pretty='%h %s' 2>$null)

        Emit 0 ([PSCustomObject]@{
            branch      = ($branchLine -replace '^## ','') -replace '\.\.\..*',''
            clean       = ($dirtyLines.Count -eq 0)
            dirty_files = $dirtyLines
            last_commit = $lastCommit
        })
    }

    # ── node-version ─────────────────────────────────────────────
    # 1 spawn de node. Lee config solo para el hint del gestor.
    'node-version' {
        $nodeVer   = (& node --version 2>$null)
        $nodeMajor = [int]($nodeVer -replace 'v(\d+)\..*','$1')
        $required  = if ($AngularMajor) { $NODE_MIN[$AngularMajor] } else { $null }
        $compatible = if ($required) { $nodeMajor -eq [int]$required } else { $true }

        $hint = $null
        if (-not $compatible) {
            $config = Read-Config
            $mgr = if ($config -and $config.node_manager) { $config.node_manager } else { 'fnm' }
            $hint = "$mgr use $required"
        }

        Emit 0 ([PSCustomObject]@{
            node_version = $nodeVer
            node_major   = $nodeMajor
            required     = $required
            compatible   = $compatible
            switch_hint  = $hint
        })
    }

    # ── resolve-versions ─────────────────────────────────────────
    # OPTIMIZACIÓN CLAVE:
    #  - Metadata ABREVIADA de npm (Accept: install-v1+json): ~100x menos
    #    bytes que el doc completo (el de @angular/core pesa decenas de MB).
    #  - HttpClient async: 5 fetches en paralelo real, sin Start-Job
    #    (cada Job arranca un proceso PowerShell entero, ~1s de overhead cada uno).
    #  - compiler-cli se pide en la MISMA ronda (antes era una llamada extra serial).
    'resolve-versions' {
        if (-not $AngularMajor) { Emit 1 @{ error = '-AngularMajor requerido' } }

        Add-Type -AssemblyName System.Net.Http
        $client = [System.Net.Http.HttpClient]::new()
        $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.npm.install-v1+json')
        $client.Timeout = [TimeSpan]::FromSeconds(30)

        $pkgNames = @('@angular/core','@angular/cli','@angular-devkit/build-angular','@ionic/angular','@angular/compiler-cli')
        $tasks = [ordered]@{}
        foreach ($p in $pkgNames) {
            $tasks[$p] = $client.GetStringAsync("https://registry.npmjs.org/$($p -replace '/','%2F')")
        }
        [System.Threading.Tasks.Task]::WaitAll(@($tasks.Values))

        $docs = @{}
        foreach ($p in $pkgNames) { $docs[$p] = $tasks[$p].Result | ConvertFrom-Json }
        $client.Dispose()

        function Latest-Stable($doc, $prefix) {
            $names = $doc.versions.PSObject.Properties.Name |
                Where-Object { $_ -match "^$prefix\." -and $_ -notmatch '-' }
            if (-not $names) { return $null }
            return $names | Sort-Object {
                $p = $_.Split('.'); [int]$p[0]*1000000 + [int]$p[1]*1000 + [int]$p[2]
            } | Select-Object -Last 1
        }

        $angVer   = Latest-Stable $docs['@angular/core'] $AngularMajor
        $cliVer   = Latest-Stable $docs['@angular/cli']  $AngularMajor
        $ionMajor = $IONIC_COMPAT[$AngularMajor]
        $ionVer   = Latest-Stable $docs['@ionic/angular'] $ionMajor

        # build-angular: versionado especial pre-12 (0.NNxx.x)
        $buildDoc = $docs['@angular-devkit/build-angular']
        $int = [int]$AngularMajor
        $buildVer = if ($int -ge 12) {
            Latest-Stable $buildDoc $AngularMajor
        } else {
            $names = $buildDoc.versions.PSObject.Properties.Name | Where-Object { $_ -notmatch '-' }
            $r = $names | Where-Object { $_ -match "^0\.$($int)00" }
            if (-not $r) { $r = $names | Where-Object { $_ -match "^0\.$AngularMajor\." } }
            if ($r) {
                $r | Sort-Object { $p = $_.Split('.'); [int]$p[0]*1000000 + [int]$p[1]*1000 + [int]$p[2] } | Select-Object -Last 1
            } else { $null }
        }

        # peer deps: ya están en los docs abreviados — CERO llamadas extra
        $zoneRaw = $docs['@angular/core'].versions.$angVer.peerDependencies.'zone.js'
        $tsRaw   = $docs['@angular/compiler-cli'].versions.$angVer.peerDependencies.typescript

        $zoneVer = if ($zoneRaw) { $zoneRaw } else { "~0.$([int]$AngularMajor - 1).x" }
        $tsVer = if (-not $tsRaw) { '~4.0.0' }
                 elseif ($tsRaw -match '^[~^]') { $tsRaw }
                 elseif ($tsRaw -match '>=\s*(\d+\.\d+)') { "~$($Matches[1]).0" }
                 else { '~4.0.0' }

        Emit 0 ([PSCustomObject]@{
            angular_major = $AngularMajor
            angular_core  = $angVer
            angular_cli   = $cliVer
            build_angular = $buildVer
            ionic         = $ionVer
            zone_js       = $zoneVer
            typescript    = $tsVer
            rxjs          = "^$($RXJS_MIN[$AngularMajor])"
            node_required = $NODE_MIN[$AngularMajor]
            ionic_major   = $ionMajor
        })
    }

    # ── install-angular ──────────────────────────────────────────
    'install-angular' {
        if (-not $AngularVersion -or -not $ZoneVersion -or -not $RxjsVersion) {
            Emit 1 @{ error = '-AngularVersion, -ZoneVersion y -RxjsVersion requeridos' }
        }

        $pkgs = @(
            "@angular/animations@$AngularVersion", "@angular/common@$AngularVersion",
            "@angular/compiler@$AngularVersion",   "@angular/core@$AngularVersion",
            "@angular/forms@$AngularVersion",      "@angular/platform-browser@$AngularVersion",
            "@angular/platform-browser-dynamic@$AngularVersion", "@angular/router@$AngularVersion",
            "zone.js@$ZoneVersion", "rxjs@$RxjsVersion",
            '--legacy-peer-deps'
        )
        $exit, $stdout, $stderr = Invoke-Slow 'npm.cmd' (@('install') + $pkgs)

        if ($exit -eq 0) {
            $state = Read-MigState
            $state.angular_current = Get-AngularMajorLocal
            Save-MigState $state
            $summary = ($stdout -split "`n" | Where-Object { $_ } | Select-Object -Last 2) -join ' | '
            Emit 0 ([PSCustomObject]@{ summary = $summary })
        } else {
            # Fallo: leer el log de npm automáticamente para que Hefesto tenga el error real
            $errDetail = Get-NpmErrorDetail
            $stderrClean = Clean-NpmStderr $stderr
            Emit 1 ([PSCustomObject]@{
                error      = 'install-angular fallo'
                npm_errors = $errDetail
                stderr     = $stderrClean
                hint       = 'Revisa npm_errors para el fix. Intenta con --force si es conflicto de peer deps irresolvible.'
            })
        }
    }

    # ── install-devdeps ──────────────────────────────────────────
    'install-devdeps' {
        if (-not $AngularVersion -or -not $CliVersion -or -not $BuildVersion -or -not $TypescriptVersion) {
            Emit 1 @{ error = '-AngularVersion, -CliVersion, -BuildVersion y -TypescriptVersion requeridos' }
        }

        $pkgs = @(
            "@angular/cli@$CliVersion", "@angular/compiler-cli@$AngularVersion",
            "@angular-devkit/build-angular@$BuildVersion", "typescript@$TypescriptVersion",
            '--legacy-peer-deps'
        )
        $exit, $stdout, $stderr = Invoke-Slow 'npm.cmd' (@('install', '--save-dev') + $pkgs)
        if ($exit -eq 0) {
            $summary = ($stdout -split "`n" | Where-Object { $_ } | Select-Object -Last 2) -join ' | '
            Emit 0 ([PSCustomObject]@{ summary = $summary })
        } else {
            $errDetail = Get-NpmErrorDetail
            Emit 1 ([PSCustomObject]@{
                error      = 'install-devdeps fallo'
                npm_errors = $errDetail
                stderr     = Clean-NpmStderr $stderr
                hint       = 'Revisa npm_errors para el fix.'
            })
        }
    }

    # ── install-ionic ────────────────────────────────────────────
    'install-ionic' {
        if (-not $IonicVersion) { Emit 1 @{ error = '-IonicVersion requerido' } }

        $exit, $stdout, $stderr = Invoke-Slow 'npm.cmd' @('install', "@ionic/angular@$IonicVersion", '--legacy-peer-deps')
        if ($exit -eq 0) {
            $summary = ($stdout -split "`n" | Where-Object { $_ } | Select-Object -Last 2) -join ' | '
            Emit 0 ([PSCustomObject]@{ summary = $summary })
        } else {
            $errDetail = Get-NpmErrorDetail
            Emit 1 ([PSCustomObject]@{
                error      = 'install-ionic fallo'
                npm_errors = $errDetail
                stderr     = Clean-NpmStderr $stderr
                hint       = 'Revisa npm_errors para el fix.'
            })
        }
    }

    # ── build ────────────────────────────────────────────────────
    'build' {
        $ngBin = '.\node_modules\.bin\ng.cmd'
        if (-not (Test-Path $ngBin)) { Emit 1 @{ error = "$ngBin no encontrado" } }

        $exit, $stdout, $stderr = Invoke-Slow $ngBin @('build', '--prod')

        $allLines = ($stdout + "`n" + $stderr) -split "`n"
        $errors   = @($allLines | Where-Object { $_ -match 'ERROR' })
        $warnings = @($allLines | Where-Object { $_ -match 'WARNING' })
        $chunks   = @{}
        $time     = $null
        foreach ($line in $allLines) {
            if ($line -match 'chunk \{[^\}]+\} (\S+) \(([^\)]+)\) ([\d.]+ [kMB]+)') { $chunks[$Matches[2]] = $Matches[3] }
            if ($line -match 'Time: (\d+)ms') { $time = "$($Matches[1])ms" }
        }

        $buildResult = [PSCustomObject]@{
            status   = if ($exit -eq 0) { 'ok' } else { 'failed' }
            errors   = $errors
            warnings = $warnings
            chunks   = $chunks
            time     = $time
        }

        # State: una lectura + una escritura, solo aquí porque build sí es checkpoint
        $state = Read-MigState
        $state.last_build = $buildResult
        if ($errors.Count -gt 0) { $state.errors_history += $errors }
        Save-MigState $state

        Emit $exit $buildResult
    }

    # ── commit ───────────────────────────────────────────────────
    'commit' {
        if (-not $CommitMessage) { Emit 1 @{ error = '-CommitMessage requerido' } }

        & git add -A 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Emit $LASTEXITCODE @{ error = 'git add fallo' } }

        $commitOut  = (& git commit -m $CommitMessage --allow-empty 2>&1) -join "`n"
        $commitExit = $LASTEXITCODE

        if ($commitExit -eq 0) {
            $hash = (& git rev-parse --short HEAD 2>$null)
            $state = Read-MigState
            $state.commits += "$hash $CommitMessage"
            Save-MigState $state
            Emit 0 ([PSCustomObject]@{ hash = $hash; message = $CommitMessage })
        } else {
            Emit $commitExit ([PSCustomObject]@{ output = $commitOut })
        }
    }

    # ── complete-step ────────────────────────────────────────────
    'complete-step' {
        if (-not $AngularMajor) { Emit 1 @{ error = '-AngularMajor (major destino) requerido' } }

        $state = Read-MigState
        $hash  = (& git rev-parse --short HEAD 2>$null)

        $record = [PSCustomObject]@{
            from        = $state.angular_current
            to          = [int]$AngularMajor
            date        = (Get-Date -Format 'yyyy-MM-dd')
            commits     = @($state.commits | Select-Object -Last 4)
            bundle_main = if ($state.last_build) { $state.last_build.chunks.main } else { $null }
            head_commit = $hash
        }

        if (-not $state.completed_steps) { $state.completed_steps = @() }
        $state.completed_steps += $record
        $state.angular_current = [int]$AngularMajor
        Save-MigState $state

        Emit 0 ([PSCustomObject]@{ step_recorded = $record; total_completed = $state.completed_steps.Count })
    }

    # ── create-branch ────────────────────────────────────────────
    'create-branch' {
        if (-not $AngularMajor) { Emit 1 @{ error = '-AngularMajor requerido' } }

        $branch = "migration/v$AngularMajor"
        $out    = (& git checkout -b $branch 2>&1) -join "`n"
        Emit $LASTEXITCODE ([PSCustomObject]@{ branch = $branch; output = $out })
    }
}