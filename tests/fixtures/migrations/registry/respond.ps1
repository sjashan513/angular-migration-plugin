param(
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$RawArguments
)
$ErrorActionPreference = 'Stop'
$responsePath = if ($env:MIGRATION_REGISTRY_FIXTURE) { $env:MIGRATION_REGISTRY_FIXTURE } else { Join-Path $PSScriptRoot 'responses.json' }
$responses = Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json
$response = $responses.PSObject.Properties[$Key]
if (-not $response) {
    [Console]::Error.WriteLine("No fixture metadata for $Key")
    exit 1
}
if ($env:MIGRATION_REGISTRY_TRACE) {
    [IO.File]::AppendAllText($env:MIGRATION_REGISTRY_TRACE, $RawArguments + [Environment]::NewLine)
}
[Console]::Out.Write(($response.Value | ConvertTo-Json -Depth 50 -Compress))
