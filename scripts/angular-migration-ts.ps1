#Requires -Version 5.1

[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

$ErrorActionPreference = 'Stop'
$nodeVersion = '22.19.0'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$entrypoint = Join-Path $pluginRoot 'src/dist/entrypoints/main.mjs'
$fnm = Get-Command fnm -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $fnm) {
    [Console]::Out.WriteLine('{"schemaVersion":1,"ok":false,"status":"blocked","data":null,"error":{"code":"fnm_unavailable","message":"fnm is required to launch the TypeScript controller."}}')
    exit 2
}
if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
    [Console]::Out.WriteLine('{"schemaVersion":1,"ok":false,"status":"blocked","data":null,"error":{"code":"controller_bundle_missing","message":"The bundled TypeScript controller is missing from this plugin checkout."}}')
    exit 2
}

$env:ANGULAR_MIGRATION_PLUGIN_ROOT = $pluginRoot
& $fnm.Source exec --using $nodeVersion -- node $entrypoint @Arguments
$exitCode = $LASTEXITCODE
if ($null -eq $exitCode) { $exitCode = 1 }
exit $exitCode