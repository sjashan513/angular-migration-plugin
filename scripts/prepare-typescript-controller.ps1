#Requires -Version 5.1

[CmdletBinding()]
param([switch]$Prepare)

$ErrorActionPreference = 'Stop'
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
$nodeVersion = '22.19.0'
$failure = $null
$nodePath = $null
$npmCli = $null
$fnm = Get-Command fnm -ErrorAction SilentlyContinue | Select-Object -First 1

function Invoke-ControllerNode {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = & $fnm.Source exec --using $nodeVersion -- node @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Node 22.19.0 command failed with exit code $LASTEXITCODE."
    }
    return @($output)
}

if (-not $fnm) {
    $failure = 'fnm is required; install Node 22.19.0 with fnm before preparing the controller.'
}
else {
    try {
        $version = (Invoke-ControllerNode -Arguments @('--version') | Select-Object -First 1).Trim()
        if ($version -cne "v$nodeVersion") {
            throw "fnm selected $version instead of v$nodeVersion."
        }
        $nodePath = (Invoke-ControllerNode -Arguments @('-p', 'process.execPath') | Select-Object -First 1).Trim()
        if (-not [IO.Path]::IsPathRooted($nodePath) -or -not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
            throw 'The selected Node executable could not be verified.'
        }
        $npmCli = Join-Path (Split-Path -Parent $nodePath) 'node_modules/npm/bin/npm-cli.js'
        if (-not (Test-Path -LiteralPath $npmCli -PathType Leaf)) {
            throw 'The npm CLI bundled with Node 22.19.0 was not found.'
        }
        if ($Prepare) {
            Push-Location $packageRoot
            try {
                [void](Invoke-ControllerNode -Arguments @($npmCli, 'ci', '--ignore-scripts'))
                [void](Invoke-ControllerNode -Arguments @($npmCli, 'run', 'build'))
            }
            finally {
                Pop-Location
            }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'dist/entrypoints/main.mjs') -PathType Leaf)) {
            throw 'The bundled controller CLI is missing; rerun with -Prepare.'
        }
    }
    catch {
        $failure = $_.Exception.Message
    }
}

$status = if ($failure) { 'blocked' } else { 'ready' }
$report = [ordered]@{
    schemaVersion    = 1
    status           = $status
    prepareRequested = [bool]$Prepare
    nodeVersion      = if ($failure -and -not $nodePath) { $null } else { $nodeVersion }
    nodeExecutable   = $nodePath
    packageRoot      = $packageRoot
    cli              = 'dist/entrypoints/main.mjs'
    failure          = $failure
}
[Console]::Out.WriteLine(($report | ConvertTo-Json -Compress))
if ($failure) { exit 2 }
exit 0