#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Install
)

$ErrorActionPreference = 'Stop'

function Find-Executable {
    param([Parameter(Mandatory = $true)][string]$Name)
    return Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Refresh-ProcessPath {
    $pathParts = @($env:Path) +
        @([Environment]::GetEnvironmentVariable('Path', 'User')) +
        @([Environment]::GetEnvironmentVariable('Path', 'Machine')) |
        ForEach-Object { $_ -split ';' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    $env:Path = $pathParts -join ';'
}

function Get-ExecutableVersion {
    param(
        [Parameter(Mandatory = $true)]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    try {
        $output = & $Command.Source @Arguments 2>$null | Select-Object -First 1
        if ($output) { return ([string]$output).Trim() }
    }
    catch { }
    return $null
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)]$Winget,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $output = & $Winget.Source install --id $Id --exact --source winget --accept-source-agreements --accept-package-agreements 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $Id with exit code $LASTEXITCODE."
    }
    return [PSCustomObject]@{ package = $Id; status = 'installed' }
}

$winget = Find-Executable -Name 'winget.exe'
$actions = @()
$failure = $null
Refresh-ProcessPath
$winget = Find-Executable -Name 'winget.exe'

if ($Install) {
    if (-not $winget) {
        $failure = 'winget.exe is required for installation but was not found.'
    }
    else {
        try {
            if (-not (Find-Executable -Name 'pwsh.exe')) {
                $actions += Install-WingetPackage -Winget $winget -Id 'Microsoft.PowerShell'
            }
            if (-not (Find-Executable -Name 'copilot.exe')) {
                $actions += Install-WingetPackage -Winget $winget -Id 'GitHub.Copilot'
            }
        }
        catch {
            $failure = $_.Exception.Message
        }
    }
}

Refresh-ProcessPath
$pwsh = Find-Executable -Name 'pwsh.exe'
$copilot = Find-Executable -Name 'copilot.exe'
$missing = @()
if (-not $pwsh) { $missing += 'pwsh.exe' }
if (-not $copilot) { $missing += 'copilot.exe' }
$status = if ($failure) { 'failed' } elseif ($missing.Count -gt 0) { 'blocked' } else { 'ready' }

$report = [ordered]@{
    schemaVersion = 1
    status = $status
    installRequested = [bool]$Install
    hostPowerShell = $PSVersionTable.PSVersion.ToString()
    winget = [ordered]@{
        available = [bool]$winget
        version = if ($winget) { Get-ExecutableVersion -Command $winget -Arguments @('--version') } else { $null }
    }
    tools = [ordered]@{
        pwsh = [ordered]@{
            executable = 'pwsh.exe'
            available = [bool]$pwsh
            path = if ($pwsh) { $pwsh.Source } else { $null }
            version = if ($pwsh) { Get-ExecutableVersion -Command $pwsh -Arguments @('-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()') } else { $null }
        }
        copilot = [ordered]@{
            executable = 'copilot.exe'
            available = [bool]$copilot
            path = if ($copilot) { $copilot.Source } else { $null }
            version = if ($copilot) { Get-ExecutableVersion -Command $copilot -Arguments @('--version') } else { $null }
        }
    }
    actions = @($actions)
    missing = @($missing)
    failure = $failure
    note = if ($status -eq 'ready') { 'Restart the terminal before running the installation smoke and real pilot.' } elseif ($Install) { 'Restart the terminal and run this script again so the refreshed PATH is observed.' } else { 'Run with -Install to use the official Windows package identifiers through winget.' }
}

$report | ConvertTo-Json -Depth 8
if ($status -eq 'failed') { exit 1 }
if ($status -eq 'blocked') { exit 2 }
exit 0
