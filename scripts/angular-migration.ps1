#Requires -Version 5.1
<#
  angular-migration.ps1 — v2
  Principios:
   - API determinista para los agentes: el LLM nunca construye comandos npm/ng.
   - La raíz del proyecto es el cwd de ejecución, NUNCA la carpeta del plugin.
   - Cada comando hace SOLO su trabajo. Nada de side-effects globales.
   - State lazy: solo se lee/escribe cuando el comando lo necesita.
   - Output JSON comprimido (-Compress): menos tokens para el agente.
    - Logs y handoff agrupados por salto en .angular-migration/v{from}-v{to}.log/.
   - Documentación humana: docs/migration/ (commiteada). Aquí solo state de máquina.
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'init', 'read-state',
        'analyze-project', 'resolve-versions', 'write-snapshot',
        'ng-update',
        'ensure-node',
        'install-angular', 'install-devdeps', 'install-ionic',
        'build', 'commit', 'complete-step',
        'git-status', 'node-version', 'create-branch', 'diff'
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
    [string]$CommitMessage,
    [string]$BaseRef
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$env:GIT_TERMINAL_PROMPT = '0'

# ── Paths ───────────────────────────────────────────────────────
# La raíz del proyecto es el cwd de ejecución. El script vive instalado en
# el plugin, pero TODOS los artefactos (.angular-migration/, .gitignore)
# pertenecen al repo del usuario. Usar $PSScriptRoot aquí era el bug de v1.
$PROJECT_ROOT = (Get-Location).Path
$MIGRATION_DIR = Join-Path $PROJECT_ROOT '.angular-migration'
$CONFIG_FILE = Join-Path $MIGRATION_DIR 'config.json'
$STATE_FILE = Join-Path $MIGRATION_DIR 'state.json'
$GITIGNORE_FILE = Join-Path $PROJECT_ROOT '.gitignore'

# ── Tablas de compatibilidad (constantes, sin coste) ─────────────
$IONIC_COMPAT = @{ '8' = '4'; '9' = '5'; '10' = '5'; '11' = '5'; '12' = '6'; '13' = '6'; '14' = '6'; '15' = '7'; '16' = '7'; '17' = '7' }
$RXJS_MIN = @{ '8' = '6.4'; '9' = '6.5'; '10' = '6.5'; '11' = '6.6'; '12' = '6.6'; '13' = '7.4'; '14' = '7.5'; '15' = '7.5'; '16' = '7.8'; '17' = '7.8' }
$NODE_MIN = @{ '8' = '10'; '9' = '10'; '10' = '10'; '11' = '10'; '12' = '12'; '13' = '12'; '14' = '14'; '15' = '14'; '16' = '16'; '17' = '18' }

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
    $ver = $pkg.dependencies.'@angular/core' -replace '[~^]', ''
    return [int]($ver.Split('.')[0])
}

function Get-InstalledPackageVersion([string]$PackageName) {
    $packagePath = Join-Path 'node_modules' (($PackageName -replace '/', '\') + '\package.json')
    if (-not (Test-Path $packagePath)) { return $null }
    return (Get-Content $packagePath -Raw | ConvertFrom-Json).version
}

function Get-DirectDependencies($pkg) {
    $dependencies = [ordered]@{}
    foreach ($section in @(@('dependencies', 'runtime'), @('devDependencies', 'dev'))) {
        $property = $section[0]
        $type = $section[1]
        if ($pkg.$property) {
            foreach ($name in ($pkg.$property.PSObject.Properties.Name | Sort-Object)) {
                $dependencies[$name] = [PSCustomObject]@{
                    version = $pkg.$property.$name
                    type    = $type
                }
            }
        }
    }
    return $dependencies
}

function Get-MigrationStepDirectory([string]$To) {
    if (-not $To) { return $null }

    $packageMajor = $null
    if (Test-Path 'package.json') {
        try { $packageMajor = Get-AngularMajorLocal } catch { }
    }
    $stateMajor = $null
    if (Test-Path $STATE_FILE) {
        try {
            $state = Read-MigState
            if ($state.angular_current -gt 0) { $stateMajor = [int]$state.angular_current }
        }
        catch { }
    }
    $from = if ($stateMajor -and $packageMajor -eq [int]$To) { $stateMajor } else { $packageMajor }
    if (-not $from) { $from = $stateMajor }
    if (-not $from) { return $null }

    $stepDir = Join-Path $MIGRATION_DIR "v$from-v$To.log"
    if (-not (Test-Path $stepDir)) { New-Item -ItemType Directory -Path $stepDir -Force | Out-Null }
    return $stepDir
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
    param([string]$exe, [string[]]$argList, [int]$TimeoutSeconds = 0, [string]$ProgressLabel = '')
    $runId = [guid]::NewGuid().ToString('N')
    $outFile = "$env:TEMP\mig-out-$runId.txt"
    $errFile = "$env:TEMP\mig-err-$runId.txt"
    try {
        $proc = Start-Process $exe -ArgumentList $argList -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # PowerShell 5.1 only populates ExitCode reliably if the handle is materialized before waiting.
        $processHandle = $proc.Handle
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $nextNotice = 15
        while (-not $proc.HasExited) {
            if ($ProgressLabel -and $watch.Elapsed.TotalSeconds -ge $nextNotice) {
                [Console]::Error.WriteLine("[$ProgressLabel] proceso en curso: $([int]$watch.Elapsed.TotalSeconds)s")
                $nextNotice += 15
            }
            if ($TimeoutSeconds -gt 0 -and $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
                if (-not $proc.WaitForExit(5000)) {
                    try { $proc.Kill() } catch { }
                    [void]$proc.WaitForExit(5000)
                }
                $proc.Refresh()
                $stdout = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
                $stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
                return @(124, $stdout, ($stderr + "`nTimeout tras $TimeoutSeconds segundos; proceso terminado."))
            }
            [void]$proc.WaitForExit(500)
        }
        [void]$proc.WaitForExit()
        $proc.Refresh()
        $stdout = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
        $stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
        return @($proc.ExitCode, $stdout, $stderr)
    }
    finally {
        Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    }
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

function Get-ActiveNodeMajor {
    $v = (& node --version 2>$null)
    if (-not $v) { return $null }
    return [int]($v -replace 'v(\d+)\..*', '$1')
}

# Detecta el gestor de Node instalado: fnm > nvm > ninguno.
function Get-NodeManager {
    if (Get-Command fnm -ErrorAction SilentlyContinue) { return 'fnm' }
    if (Get-Command nvm -ErrorAction SilentlyContinue) { return 'nvm' }
    return $null
}

# Majors de Node instalados según el gestor (fnm list / nvm list).
# NOTA: fnm escribe stderr informativo incluso en éxito — con EAP=Stop eso
# lanza NativeCommandError. Estas llamadas van con EAP=Continue.
function Get-InstalledNodeMajors([string]$Manager) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = if ($Manager -eq 'fnm') { (& fnm list 2>$null | Out-String) } else { (& nvm list 2>$null | Out-String) }
    }
    finally { $ErrorActionPreference = $prev }
    if (-not $raw) { return @() }
    $majors = foreach ($line in ($raw -split "`n")) {
        if ($line -match 'v?(\d+)\.\d+\.\d+') { [int]$Matches[1] }
    }
    return @($majors | Sort-Object -Unique)
}

# Activa un major en el proceso actual.
# fnm: `fnm use N` imprime exports; `fnm env --shell powershell` fuerza el
# formato `$env:VAR = "..."`. Ojo: fnm escribe stderr informativo incluso en
# éxito — el criterio es el exit code, no el texto. Y con EAP=Stop el stderr
# informativo lanza NativeCommandError — por eso EAP=Continue aquí.
# nvm: `nvm use N` modifica el symlink global (visible en este proceso).
function Invoke-NodeUse {
    param([string]$Manager, [string]$Major)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Manager -eq 'fnm') {
            $out = (& fnm use $Major 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { return @($false, $out) }

            # Parser por líneas: `$env:PATH = "...;...;..."` tiene comas, punto
            # y coma y comillas — un regex flojo se corta mal.
            $envLines = (& fnm env --shell powershell 2>$null)
            foreach ($line in $envLines) {
                if ($line -match '^\$env:([A-Z_]+)\s*=\s*"(.*)"\s*$') {
                    Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
                }
            }
            Write-MigLog 'hermes' "Invoke-NodeUse: PATH head = $(($env:PATH -split ';')[0])"
            return @($true, $out)
        }
        if ($Manager -eq 'nvm') {
            $out = (& nvm use $Major 2>&1 | Out-String)
            return @(($LASTEXITCODE -eq 0), $out)
        }
        return @($false, 'sin gestor de node')
    }
    finally { $ErrorActionPreference = $prev }
}

# Log legible por salto. Fichero: v{from}-v{to}.log/logs/<source>.log.
# Nunca rompe el comando: un fallo de logging no puede tumbar una migración.
function Write-MigLog {
    param([string]$Source, [string]$Message)
    try {
        $stepDir = Get-MigrationStepDirectory $AngularMajor
        if (-not $stepDir) { return }
        $logsDir = Join-Path $stepDir 'logs'
        if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content (Join-Path $logsDir "$Source.log") "$stamp $Message" -Encoding UTF8
    }
    catch { }
}

# Última versión estable de un doc de metadata npm para un prefijo de major.
function Get-LatestStable($doc, $prefix) {
    $names = $doc.versions.PSObject.Properties.Name |
    Where-Object { $_ -match "^$prefix\." -and $_ -notmatch '-' }
    if (-not $names) { return $null }
    return $names | Sort-Object {
        $p = $_.Split('.'); [int]$p[0] * 1000000 + [int]$p[1] * 1000 + [int]$p[2]
    } | Select-Object -Last 1
}

# Resolución de versiones objetivo — ÚNICA fuente de verdad.
# Usada por resolve-versions y write-snapshot. El LLM jamás inventa versiones.
# OPTIMIZACIÓN: metadata abreviada de npm (install-v1+json) + HttpClient async
# = 5 fetches en una ronda paralela real.
function Get-TargetVersions {
    param([Parameter(Mandatory)][string]$Major)

    Add-Type -AssemblyName System.Net.Http
    $client = [System.Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.npm.install-v1+json')
    $client.Timeout = [TimeSpan]::FromSeconds(30)

    $pkgNames = @('@angular/core', '@angular/cli', '@angular-devkit/build-angular', '@ionic/angular', '@angular/compiler-cli')
    $tasks = [ordered]@{}
    foreach ($p in $pkgNames) {
        $tasks[$p] = $client.GetStringAsync("https://registry.npmjs.org/$($p -replace '/','%2F')")
    }
    [System.Threading.Tasks.Task]::WaitAll(@($tasks.Values))

    $docs = @{}
    foreach ($p in $pkgNames) { $docs[$p] = $tasks[$p].Result | ConvertFrom-Json }
    $client.Dispose()

    $angVer = Get-LatestStable $docs['@angular/core'] $Major
    $cliVer = Get-LatestStable $docs['@angular/cli']  $Major
    $ionMajor = $IONIC_COMPAT[$Major]
    $ionVer = Get-LatestStable $docs['@ionic/angular'] $ionMajor

    # build-angular: versionado especial pre-12 (0.NNxx.x)
    $buildDoc = $docs['@angular-devkit/build-angular']
    $int = [int]$Major
    $buildVer = if ($int -ge 12) {
        Get-LatestStable $buildDoc $Major
    }
    else {
        $names = $buildDoc.versions.PSObject.Properties.Name | Where-Object { $_ -notmatch '-' }
        $r = $names | Where-Object { $_ -match "^0\.$($int)00" }
        if (-not $r) { $r = $names | Where-Object { $_ -match "^0\.$Major\." } }
        if ($r) {
            $r | Sort-Object { $p = $_.Split('.'); [int]$p[0] * 1000000 + [int]$p[1] * 1000 + [int]$p[2] } | Select-Object -Last 1
        }
        else { $null }
    }

    # peer deps: ya están en los docs abreviados — CERO llamadas extra
    $zoneRaw = $docs['@angular/core'].versions.$angVer.peerDependencies.'zone.js'
    $tsRaw = $docs['@angular/compiler-cli'].versions.$angVer.peerDependencies.typescript

    $zoneVer = if ($zoneRaw) { $zoneRaw } else { "~0.$([int]$Major - 1).x" }
    $tsVer = if (-not $tsRaw) { '~4.0.0' }
    elseif ($tsRaw -match '^[~^]') { $tsRaw }
    elseif ($tsRaw -match '>=\s*(\d+\.\d+)') { "~$($Matches[1]).0" }
    else { '~4.0.0' }

    return [PSCustomObject]@{
        angular_major = $Major
        angular_core  = $angVer
        angular_cli   = $cliVer
        build_angular = $buildVer
        ionic         = $ionVer
        zone_js       = $zoneVer
        typescript    = $tsVer
        rxjs          = "^$($RXJS_MIN[$Major])"
        node_required = $NODE_MIN[$Major]
        ionic_major   = $ionMajor
    }
}

# Consulta metadata de npm para TODAS las dependencias directas del proyecto.
# Solo guarda el resumen necesario para que Prometeo y Cronos evalúen compatibilidad.
function Get-DirectDependencyMetadata($dependencies) {
    Add-Type -AssemblyName System.Net.Http
    $client = [System.Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.npm.install-v1+json')
    $client.Timeout = [TimeSpan]::FromSeconds(30)

    $tasks = [ordered]@{}
    $failures = [ordered]@{}
    foreach ($name in $dependencies.Keys) {
        try {
            $urlName = $name -replace '/','%2F'
            $tasks[$name] = $client.GetStringAsync("https://registry.npmjs.org/$urlName")
        }
        catch {
            $failures[$name] = $_.Exception.Message
        }
    }

    if ($tasks.Count -gt 0) {
        try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tasks.Values)) }
        catch { }
    }

    $metadata = [ordered]@{}
    foreach ($name in $dependencies.Keys) {
        if (-not $tasks.Contains($name)) { continue }
        try {
            $doc = $null
            try { $doc = $tasks[$name].Result | ConvertFrom-Json } catch { }
            if (-not $doc) {
                $viewExit, $viewOut, $viewErr = Invoke-Slow 'npm.cmd' @('view', $name, '--json') -TimeoutSeconds 60
                if ($viewExit -ne 0 -or -not $viewOut) { throw $viewErr }
                $doc = $viewOut | ConvertFrom-Json
            }
            $requested = [string]$dependencies[$name].version
            $currentVersion = if ($requested -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { $null }
            $latestVersion = if ($doc.'dist-tags'.latest) { [string]$doc.'dist-tags'.latest } else { $null }
            $currentDoc = if ($currentVersion -and $doc.versions.PSObject.Properties[$currentVersion]) { $doc.versions.PSObject.Properties[$currentVersion].Value } else { $null }
            $latestDoc = if ($latestVersion -and $doc.versions.PSObject.Properties[$latestVersion]) { $doc.versions.PSObject.Properties[$latestVersion].Value } else { $null }
            $metadata[$name] = [PSCustomObject]@{
                requested                  = $requested
                type                       = $dependencies[$name].type
                registry_status             = 'ok'
                current_version             = $currentVersion
                current_peer_dependencies  = if ($currentDoc) { $currentDoc.peerDependencies } else { $null }
                latest                     = $latestVersion
                latest_peer_dependencies   = if ($latestDoc) { $latestDoc.peerDependencies } else { $null }
                latest_engines             = if ($latestDoc) { $latestDoc.engines } else { $null }
                latest_deprecated          = if ($latestDoc) { $latestDoc.deprecated } else { $null }
            }
        }
        catch {
            $failures[$name] = $_.Exception.Message
        }
    }
    $client.Dispose()

    return [PSCustomObject]@{
        complete = ($failures.Count -eq 0 -and $metadata.Count -eq $dependencies.Count)
        queried  = $metadata.Count
        total    = $dependencies.Count
        packages = [PSCustomObject]$metadata
        failures = [PSCustomObject]$failures
    }
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
        if ($pkg.dependencies) { $allDeps += $pkg.dependencies.PSObject.Properties.Name }
        if ($pkg.devDependencies) { $allDeps += $pkg.devDependencies.PSObject.Properties.Name }

        $detected = [PSCustomObject]@{
            project_name    = $pkg.name
            angular_current = [int](($pkg.dependencies.'@angular/core' -replace '[~^]', '').Split('.')[0])
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
        $state = Read-MigState
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
                    branch      = ($branchLine -replace '^## ', '') -replace '\.\.\..*', ''
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
                branch      = ($branchLine -replace '^## ', '') -replace '\.\.\..*', ''
                clean       = ($dirtyLines.Count -eq 0)
                dirty_files = $dirtyLines
                last_commit = $lastCommit
            })
    }

    # ── node-version ─────────────────────────────────────────────
    # 1 spawn de node. Lee config solo para el hint del gestor.
    'node-version' {
        $nodeVer = (& node --version 2>$null)
        $nodeMajor = Get-ActiveNodeMajor
        $required = if ($AngularMajor) { $NODE_MIN[$AngularMajor] } else { $null }
        $compatible = if ($required) { $nodeMajor -eq [int]$required } else { $true }

        $hint = $null
        if (-not $compatible) {
            $mgr = Get-NodeManager
            $hint = if ($mgr) { "$mgr use $required" } else { 'Instala fnm o nvm y luego la version de Node requerida' }
        }

        Emit 0 ([PSCustomObject]@{
                node_version = $nodeVer
                node_major   = $nodeMajor
                required     = $required
                compatible   = $compatible
                manager      = (Get-NodeManager)
                switch_hint  = $hint
            })
    }

    # ── ensure-node ──────────────────────────────────────────────
    # Garantiza que el major de Node del salto está activo.
    # Intenta cambiar de versión automáticamente (fnm/nvm). Solo si no puede
    # (sin gestor, major sin instalar, install fallido) devuelve needs_user: true
    # con instrucciones concretas — ese es el único stop de Node en v2.
    'ensure-node' {
        if (-not $AngularMajor) { Emit 1 @{ error = '-AngularMajor requerido' } }
        $required = $NODE_MIN[$AngularMajor]
        if (-not $required) { Emit 1 @{ error = "Major $AngularMajor no soportado por este plugin" } }

        $nodeMajor = Get-ActiveNodeMajor
        if ($nodeMajor -eq [int]$required) {
            Emit 0 ([PSCustomObject]@{
                    ok           = $true
                    action       = 'none'
                    node_version = (& node --version 2>$null)
                    required     = $required
                })
        }

        $mgr = Get-NodeManager
        if (-not $mgr) {
            Emit 0 ([PSCustomObject]@{
                    ok         = $false
                    needs_user = $true
                    required   = $required
                    action     = 'install-manager'
                    message    = "Se requiere Node $required y no hay gestor instalado. Instala fnm (recomendado) o nvm y ejecuta: fnm install $required; fnm use $required"
                })
        }

        $installed = Get-InstalledNodeMajors $mgr
        $installedAction = 'use'

        if ($installed -notcontains [int]$required) {
            Write-MigLog 'hermes' "ensure-node: Node $required no instalado, instalando con $mgr"
            # fnm escribe progreso a stderr: EAP=Continue para que no lance
            # NativeCommandError; el criterio de éxito es el exit code.
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $installOut = if ($mgr -eq 'fnm') {
                    (& fnm install $required 2>&1 | Out-String)
                }
                else {
                    (& nvm install $required 2>&1 | Out-String)
                }
                $installCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $prevEap }
            $installedAction = 'install+use'
            Write-MigLog 'hermes' "ensure-node: install exit=$installCode"
            $installed = Get-InstalledNodeMajors $mgr
            if ($installCode -ne 0 -and ($installed -notcontains [int]$required)) {
                Emit 0 ([PSCustomObject]@{
                        ok         = $false
                        needs_user = $true
                        required   = $required
                        action     = 'install-failed'
                        manager    = $mgr
                        output     = $installOut
                        message    = "No se pudo instalar Node $required con $mgr. Instálalo manualmente: $mgr install $required; $mgr use $required"
                    })
            }
        }

        $ok, $useOut = Invoke-NodeUse $mgr $required
        Start-Sleep -Milliseconds 300
        $nowMajor = Get-ActiveNodeMajor

        if ($ok -and $nowMajor -eq [int]$required) {
            Write-MigLog 'hermes' "ensure-node: Node $nodeMajor -> $required ($mgr, $installedAction)"
            Emit 0 ([PSCustomObject]@{
                    ok           = $true
                    action       = $installedAction
                    manager      = $mgr
                    previous     = $nodeMajor
                    node_version = (& node --version 2>$null)
                    required     = $required
                })
        }

        Emit 0 ([PSCustomObject]@{
                ok         = $false
                needs_user = $true
                required   = $required
                action     = 'use-failed'
                manager    = $mgr
                output     = $useOut
                message    = "No se pudo activar Node $required con $mgr en este proceso. Ejecuta manualmente: $mgr use $required"
            })
    }

    # ── resolve-versions ─────────────────────────────────────────
    'resolve-versions' {
        if (-not $AngularMajor) { Emit 1 @{ error = '-AngularMajor requerido' } }

        $target = Get-TargetVersions $AngularMajor
        if (-not $target.angular_core) {
            Emit 1 @{ error = "No existe version estable de @angular/core para major $AngularMajor" }
        }

        Write-MigLog 'hermes' "resolve-versions: @$($target.angular_core) / cli $($target.angular_cli) / ts $($target.typescript)"
        Emit 0 $target
    }

    # ── install-angular ──────────────────────────────────────────
    'install-angular' {
        if (-not $AngularVersion -or -not $ZoneVersion -or -not $RxjsVersion) {
            Emit 1 @{ error = '-AngularVersion, -ZoneVersion y -RxjsVersion requeridos' }
        }

        $pkgs = @(
            "@angular/animations@$AngularVersion", "@angular/common@$AngularVersion",
            "@angular/compiler@$AngularVersion", "@angular/core@$AngularVersion",
            "@angular/forms@$AngularVersion", "@angular/platform-browser@$AngularVersion",
            "@angular/platform-browser-dynamic@$AngularVersion", "@angular/router@$AngularVersion",
            "zone.js@$ZoneVersion", "rxjs@$RxjsVersion",
            '--legacy-peer-deps'
        )
        $exit, $stdout, $stderr = Invoke-Slow 'npm.cmd' (@('install') + $pkgs)

        if ($exit -eq 0) {
            $summary = ($stdout -split "`n" | Where-Object { $_ } | Select-Object -Last 2) -join ' | '
            Emit 0 ([PSCustomObject]@{ summary = $summary })
        }
        else {
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
        }
        else {
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
        }
        else {
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

        $installedCore = Get-InstalledPackageVersion '@angular/core'
        $installedCli = Get-InstalledPackageVersion '@angular/cli'
        $installedBuild = Get-InstalledPackageVersion '@angular-devkit/build-angular'
        $installedCoreMajor = if ($installedCore) { [int]$installedCore.Split('.')[0] } else { $null }
        $installedCliMajor = if ($installedCli) { [int]$installedCli.Split('.')[0] } else { $null }
        if ($AngularMajor -and (($installedCoreMajor -ne [int]$AngularMajor) -or ($installedCliMajor -ne [int]$AngularMajor))) {
            Emit 1 ([PSCustomObject]@{
                    error = 'Dependencias Angular instaladas no coinciden con el major solicitado'
                    requested_major = [int]$AngularMajor
                    installed = [PSCustomObject]@{
                        angular_core = $installedCore
                        angular_cli = $installedCli
                        build_angular = $installedBuild
                    }
                    hint = 'node_modules esta mezclado. Restaura las dependencias del package.json/package-lock antes de reintentar el build.'
                })
        }

        $env:CI = 'true'
        $env:NG_CLI_ANALYTICS = 'false'
        $exit, $stdout, $stderr = Invoke-Slow $ngBin @('build', '--prod', '--progress=false') -TimeoutSeconds 900 -ProgressLabel "build Angular $AngularMajor"

        $allLines = ($stdout + "`n" + $stderr) -split "`n"
        $errors = @($allLines | Where-Object { $_ -match 'ERROR' })
        $warnings = @($allLines | Where-Object { $_ -match 'WARNING' })
        $chunks = @{}
        $time = $null
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

        # Log completo del build por salto: v{from}-v{to}.log/logs/build.log
        if ($AngularMajor) {
            try {
            $stepDir = Get-MigrationStepDirectory $AngularMajor
            $logsDir = Join-Path $stepDir 'logs'
            if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
            ($stdout + "`n" + $stderr) | Set-Content (Join-Path $logsDir 'build.log') -Encoding UTF8
            }
            catch { }
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

        $commitOut = (& git commit -m $CommitMessage --allow-empty 2>&1) -join "`n"
        $commitExit = $LASTEXITCODE

        if ($commitExit -eq 0) {
            $hash = (& git rev-parse --short HEAD 2>$null)
            $state = Read-MigState
            $state.commits += "$hash $CommitMessage"
            Save-MigState $state
            Emit 0 ([PSCustomObject]@{ hash = $hash; message = $CommitMessage })
        }
        else {
            Emit $commitExit ([PSCustomObject]@{ output = $commitOut })
        }
    }

    # ── complete-step ────────────────────────────────────────────
    'complete-step' {
        if (-not $AngularMajor) { Emit 1 @{ error = '-AngularMajor (major destino) requerido' } }

        $state = Read-MigState
        $hash = (& git rev-parse --short HEAD 2>$null)

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
        $branchExistsExit, $null, $null = Invoke-Slow 'git.exe' @('show-ref', '--verify', '--quiet', "refs/heads/$branch")
        if ($branchExistsExit -eq 0) {
            $checkoutExit, $stdout, $stderr = Invoke-Slow 'git.exe' @('checkout', $branch)
        }
        else {
            $checkoutExit, $stdout, $stderr = Invoke-Slow 'git.exe' @('checkout', '-b', $branch)
        }
        $out = ($stdout + "`n" + $stderr).Trim()
        $activeBranch = if ($checkoutExit -eq 0) { (& git branch --show-current 2>$null) } else { $null }
        if ($checkoutExit -eq 0 -and $activeBranch -ne $branch) {
            Emit 1 ([PSCustomObject]@{ branch = $branch; active_branch = $activeBranch; output = $out; error = 'La rama destino no quedo activa' })
        }
        Write-MigLog 'hermes' "create-branch: $branch (active=$activeBranch)"
        Emit $checkoutExit ([PSCustomObject]@{ branch = $branch; active_branch = $activeBranch; output = $out })
    }

    # ── analyze-project ──────────────────────────────────────────
    # Mapa completo de dependencias directas del package.json.
    'analyze-project' {
        if (-not (Test-Path 'package.json')) {
            Emit 1 @{ error = 'No package.json. Ejecuta desde la raiz del repo Angular.' }
        }

        $pkg = Get-Content 'package.json' -Raw | ConvertFrom-Json
        $deps = Get-DirectDependencies $pkg

        Write-MigLog 'hermes' "analyze-project: $($deps.Count) dependencias directas"
        Emit 0 ([PSCustomObject]@{
                project_name     = $pkg.name
                angular_current  = [int](($pkg.dependencies.'@angular/core' -replace '[~^]', '').Split('.')[0])
                dependency_count = $deps.Count
                dependencies     = [PSCustomObject]$deps
            })
    }

    # ── write-snapshot ───────────────────────────────────────────
    # Persiste .angular-migration/v{from}-v{to}.log/snapshot-v{N}.json: versiones actuales vs objetivo.
    # Lo consume Cronos (documentación) y Prometeo (plan) — es su única fuente de versiones.
    'write-snapshot' {
        if (-not $AngularMajor) { Emit 1 @{ error = '-AngularMajor requerido' } }
        if (-not (Test-Path 'package.json')) { Emit 1 @{ error = 'No package.json' } }

        $pkg = Get-Content 'package.json' -Raw | ConvertFrom-Json
        $dependencies = Get-DirectDependencies $pkg
        $metadata = Get-DirectDependencyMetadata $dependencies
        if (-not $metadata.complete) {
            Emit 1 ([PSCustomObject]@{
                error    = 'No se pudo consultar npm para todas las dependencias directas'
                queried  = $metadata.queried
                total    = $metadata.total
                failures = $metadata.failures
                hint     = 'Corrige el acceso al registry o la configuracion de npm y vuelve a ejecutar write-snapshot.'
            })
        }

        $tracked = @('@angular/core', '@angular/cli', '@angular-devkit/build-angular', '@angular/compiler-cli', '@ionic/angular', 'zone.js', 'typescript', 'rxjs')
        $current = [ordered]@{}
        foreach ($name in $tracked) {
            $v = $null
            if ($pkg.dependencies -and $pkg.dependencies.$name) { $v = $pkg.dependencies.$name }
            if ($pkg.devDependencies -and $pkg.devDependencies.$name) { $v = $pkg.devDependencies.$name }
            $current[$name] = $v
        }

        $target = Get-TargetVersions $AngularMajor
        if (-not $target.angular_core) {
            Emit 1 @{ error = "No existe version estable de @angular/core para major $AngularMajor" }
        }

        $fromMajor = [int](($pkg.dependencies.'@angular/core' -replace '[~^]', '').Split('.')[0])
        $snapshot = [PSCustomObject]@{
            created_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            project    = $pkg.name
            from       = $fromMajor
            to         = [int]$AngularMajor
            current    = [PSCustomObject]$current
            direct_dependencies = [PSCustomObject]$dependencies
            dependency_metadata = $metadata.packages
            dependency_metadata_complete = $metadata.complete
            target     = $target
            node       = [PSCustomObject]@{ active = (& node --version 2>$null); required = $target.node_required }
        }

        $stepDir = Get-MigrationStepDirectory $AngularMajor
        $snapFile = Join-Path $stepDir "snapshot-v$AngularMajor.json"
        $snapshot | ConvertTo-Json -Depth 10 | Set-Content $snapFile -Encoding UTF8
        Write-MigLog 'hermes' "write-snapshot: v$fromMajor -> v$AngularMajor"

        Emit 0 ([PSCustomObject]@{ snapshot_path = $snapFile; snapshot = $snapshot })
    }

    # ── ng-update ────────────────────────────────────────────────
    # Ejecuta ng update con las versiones EXACTAS del plan. El LLM nunca
    # construye el comando ni elige flags: la politica de reintentos vive aqui.
    'ng-update' {
        if (-not $AngularVersion -or -not $CliVersion) {
            Emit 1 @{ error = '-AngularVersion y -CliVersion requeridos' }
        }

        $ngBin = '.\node_modules\.bin\ng.cmd'
        if (-not (Test-Path $ngBin)) { Emit 1 @{ error = "$ngBin no encontrado" } }

        $ngArgs = @('update', "@angular/core@$AngularVersion", "@angular/cli@$CliVersion")
        Write-MigLog 'hefesto' "ng-update: ng $($ngArgs -join ' ')"

        $exit, $stdout, $stderr = Invoke-Slow $ngBin $ngArgs
        $combined = "$stdout`n$stderr"
        $forced = $false
        $allowDirty = $false

        # Decisión v2: ERESOLVE/peer deps -> un único reintento con --force.
        if ($exit -ne 0 -and $combined -match 'ERESOLVE|peer dep|Conflicting peer dependency') {
            $forced = $true
            Write-MigLog 'hefesto' 'ng-update: conflicto de peer deps, reintento con --force'
            $exit, $stdout, $stderr = Invoke-Slow $ngBin ($ngArgs + '--force')
            $combined = "$stdout`n$stderr"
        }

        # ng exige repo limpio -> un reintento con --allow-dirty (los cambios son del propio update).
        if ($exit -ne 0 -and $combined -match 'not clean|--allow-dirty') {
            $allowDirty = $true
            Write-MigLog 'hefesto' 'ng-update: repo no limpio para ng, reintento con --allow-dirty'
            $retryArgs = @($ngArgs) + '--allow-dirty'
            if ($forced) { $retryArgs += '--force' }
            $exit, $stdout, $stderr = Invoke-Slow $ngBin $retryArgs
        }

        $changedFiles = @((& git status --porcelain 2>$null) | Where-Object { $_ })
        $tail = ((($stdout -split "`n") | Where-Object { $_ } | Select-Object -Last 10) -join "`n")
        Write-MigLog 'hefesto' "ng-update: exit=$exit, $($changedFiles.Count) ficheros modificados"

        Emit $exit ([PSCustomObject]@{
                forced        = $forced
                allow_dirty   = $allowDirty
                changed_files = $changedFiles
                output_tail   = $tail
                stderr        = Clean-NpmStderr $stderr
            })
    }

    # ── diff ─────────────────────────────────────────────────────
    # Diff real del salto contra la rama base. Lo usa Hefesto para el reporte
    # y lo lee Clío para el documento de diff.
    'diff' {
        if (-not $BaseRef) { Emit 1 @{ error = '-BaseRef requerido (ej: main)' } }

        $files = @((& git diff --name-only "$BaseRef...HEAD" 2>$null) | Where-Object { $_ })
        $numstat = @((& git diff --numstat "$BaseRef...HEAD" 2>$null) | Where-Object { $_ })
        $stat = ((& git diff --stat "$BaseRef...HEAD" 2>$null) -join "`n")

        Emit 0 ([PSCustomObject]@{
                base_ref = $BaseRef
                files    = $files
                numstat  = $numstat
                stat     = $stat
            })
    }
}