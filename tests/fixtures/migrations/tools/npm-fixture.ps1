$ErrorActionPreference = 'Stop'
$arguments = @($args)
$root = (Get-Location).Path
$tracePath = Join-Path $root '.fixture-trace'
function Write-Trace {
    param([string]$Value)
    [IO.File]::AppendAllText($tracePath, $Value + [Environment]::NewLine)
}
function Get-JsonFile {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}
function Get-VersionFromSpec {
    param([string]$Spec)
    $match = [regex]::Match($Spec, '(\d+\.\d+\.\d+)')
    if (-not $match.Success) { throw "Fixture cannot resolve spec: $Spec" }
    return $match.Groups[1].Value
}

if ($arguments.Count -eq 0) { exit 1 }
if ($arguments[0] -eq '--version') {
    [Console]::Out.WriteLine('10.2.4')
    exit 0
}
if ($arguments[0] -eq 'view') {
    $key = [string]$arguments[1]
    $responsePath = if ($env:MIGRATION_REGISTRY_FIXTURE) { $env:MIGRATION_REGISTRY_FIXTURE } else { Join-Path $env:MIGRATION_FIXTURE_ROOT 'registry/responses.json' }
    $responses = Get-JsonFile -Path $responsePath
    $response = $responses.PSObject.Properties[$key]
    if (-not $response) {
        [Console]::Error.WriteLine("No fixture metadata for $key")
        exit 1
    }
    if ($env:MIGRATION_REGISTRY_TRACE) {
        [IO.File]::AppendAllText($env:MIGRATION_REGISTRY_TRACE, (($arguments -join ' ') + [Environment]::NewLine))
    }
    [Console]::Out.Write(($response.Value | ConvertTo-Json -Depth 50 -Compress))
    exit 0
}
if ($arguments[0] -eq 'install' -and $arguments -contains '--package-lock-only') {
    Write-Trace 'npm-install-lockfile'
    if (Test-Path -LiteralPath (Join-Path $root '.fixture-fail-install')) {
        [Console]::Error.WriteLine('fixture npm install failure')
        exit 1
    }
    $package = Get-JsonFile -Path (Join-Path $root 'package.json')
    $lockPath = Join-Path $root 'package-lock.json'
    $lock = Get-JsonFile -Path $lockPath
    foreach ($sectionName in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')) {
        $section = $package.PSObject.Properties[$sectionName]
        if (-not $section) { continue }
        foreach ($dependency in $section.Value.PSObject.Properties) {
            $entry = $lock.dependencies.PSObject.Properties[$dependency.Name]
            if (-not $entry) {
                $lock.dependencies | Add-Member -NotePropertyName $dependency.Name -NotePropertyValue ([PSCustomObject]@{ version = (Get-VersionFromSpec -Spec ([string]$dependency.Value)) })
            }
            else {
                $entry.Value.version = Get-VersionFromSpec -Spec ([string]$dependency.Value)
            }
        }
    }
    $lock | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $lockPath -Encoding UTF8
    exit 0
}
if ($arguments[0] -eq 'ci') {
    Write-Trace 'npm-ci'
    $failure = Join-Path $root '.fixture-fail-ci'
    if (Test-Path -LiteralPath (Join-Path $root '.fixture-fail-second-ci')) {
        $countPath = Join-Path $root '.angular-migration/fixture-ci-count'
        $count = 0
        if (Test-Path -LiteralPath $countPath) { $count = [int](Get-Content -LiteralPath $countPath -Raw) }
        $count++
        [IO.File]::WriteAllText($countPath, [string]$count)
        if ($count -gt 1) { $failure = $countPath }
    }
    if (Test-Path -LiteralPath $failure) {
        [Console]::Error.WriteLine('fixture npm ci failure')
        exit 1
    }
    exit 0
}
if ($arguments[0] -eq 'ls') {
    Write-Trace 'npm-ls-all'
    if (Test-Path -LiteralPath (Join-Path $root '.fixture-fail-ls')) {
        [Console]::Error.WriteLine('missing fixture dependency')
        exit 1
    }
    [Console]::Out.WriteLine('pipeline-migration-fixture@0.0.0')
    exit 0
}
if ($arguments[0] -eq 'run') {
    $scriptName = [string]$arguments[1]
    Write-Trace ('npm-run:' + $scriptName)
    $failure = Join-Path $root ('.fixture-fail-' + $scriptName)
    if ($scriptName -eq 'build' -and (Test-Path -LiteralPath (Join-Path $root '.fixture-fail-second-build'))) {
        $countPath = Join-Path $root '.fixture-build-count'
        $count = 0
        if (Test-Path -LiteralPath $countPath) { $count = [int](Get-Content -LiteralPath $countPath -Raw) }
        $count++
        [IO.File]::WriteAllText($countPath, [string]$count)
        if ($count -gt 1) { $failure = $countPath }
    }
    if (Test-Path -LiteralPath $failure) {
        [Console]::Error.WriteLine("src/app.component.ts:1:1 fixture $scriptName failure")
        exit 1
    }
    [Console]::Out.WriteLine("fixture $scriptName passed")
    exit 0
}
[Console]::Error.WriteLine('unsupported fixture npm command')
exit 1
