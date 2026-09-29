#Requires -Version 5.1

[CmdletBinding()]
param([ValidateSet('preToolUse', 'subagentStop')][string]$Event)

$ErrorActionPreference = 'Stop'
$payloadText = [Console]::In.ReadToEnd()
$payload = $null
try { $payload = $payloadText | ConvertFrom-Json } catch { }
if (-not $payload -or $payload.agentName -notin @('migration-implementer', 'migration-documenter')) {
    [Console]::Out.Write('{}')
    exit 0
}

$deny = if ($Event -eq 'subagentStop') {
    '{"decision":"block","reason":"TypeScript hook runtime is unavailable; the operation was denied."}'
}
else {
    '{"permissionDecision":"deny","permissionDecisionReason":"TypeScript hook runtime is unavailable; the operation was denied."}'
}
$projectRoot = (Get-Location).Path
$runRecord = Join-Path $projectRoot '.angular-migration/run.json'
$policy = Join-Path $PSScriptRoot 'copilot-policy.mjs'
$fnm = Get-Command fnm -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not (Test-Path -LiteralPath $runRecord -PathType Leaf) -or
    -not (Test-Path -LiteralPath $policy -PathType Leaf) -or -not $fnm) {
    [Console]::Out.Write($deny)
    exit 0
}

$previousEncoding = $OutputEncoding
try {
    $OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $payloadText | & $fnm.Source exec --using 22.19.0 -- node $policy $Event
    if ($LASTEXITCODE -ne 0) { [Console]::Out.Write($deny) }
}
catch {
    [Console]::Out.Write($deny)
}
finally {
    $OutputEncoding = $previousEncoding
}
exit 0