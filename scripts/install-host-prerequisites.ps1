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
$controllerNodeVersion = '22.19.0'
$controllerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
$controllerBundle = Join-Path $controllerRoot 'dist/entrypoints/main.mjs'
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
$fnm = Find-Executable -Name 'fnm.exe'
$fnmNodeVersion = $null
if ($fnm) {
    try {
        $nodeOutput = & $fnm.Source exec --using $controllerNodeVersion -- node --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            $candidateVersion = @($nodeOutput | Select-Object -Last 1)[0].Trim()
            if ($candidateVersion -ceq "v$controllerNodeVersion") { $fnmNodeVersion = $candidateVersion }
        }
    }
    catch { }
}
$bundleAvailable = Test-Path -LiteralPath $controllerBundle -PathType Leaf
$missing = @()
if (-not $pwsh) { $missing += 'pwsh.exe' }
if (-not $copilot) { $missing += 'copilot.exe' }
$missing += if (-not $fnm) { 'fnm.exe' }
$missing += if (-not $fnmNodeVersion) { "Node $controllerNodeVersion via fnm" }
$missing += if (-not $bundleAvailable) { 'bundled TypeScript controller' }
$status = if ($failure) { 'failed' } elseif ($missing.Count -gt 0) { 'blocked' } else { 'ready' }

$report = [ordered]@{
    schemaVersion    = 1
    status           = $status
    installRequested = [bool]$Install
    hostPowerShell   = $PSVersionTable.PSVersion.ToString()
    winget           = [ordered]@{
        available = [bool]$winget
        version   = if ($winget) { Get-ExecutableVersion -Command $winget -Arguments @('--version') } else { $null }
    }
    tools            = [ordered]@{
        pwsh           = [ordered]@{
            executable = 'pwsh.exe'
            available  = [bool]$pwsh
            path       = if ($pwsh) { $pwsh.Source } else { $null }
            version    = if ($pwsh) { Get-ExecutableVersion -Command $pwsh -Arguments @('-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()') } else { $null }
        }
        copilot        = [ordered]@{
            executable = 'copilot.exe'
            available  = [bool]$copilot
            path       = if ($copilot) { $copilot.Source } else { $null }
            version    = if ($copilot) { Get-ExecutableVersion -Command $copilot -Arguments @('--version') } else { $null }
        }
        fnm            = [ordered]@{
            executable = 'fnm.exe'
            available  = [bool]$fnm
            path       = if ($fnm) { $fnm.Source } else { $null }
        }
        controllerNode = [ordered]@{
            requiredVersion = $controllerNodeVersion
            available       = [bool]$fnmNodeVersion
            version         = $fnmNodeVersion
        }
    }
    controller       = [ordered]@{
        bundle    = 'src/dist/entrypoints/main.mjs'
        available = $bundleAvailable
    }
    actions          = @($actions)
    missing          = @($missing)
    failure          = $failure
    note             = if ($status -eq 'ready') { 'Host tools and bundled controller are present. Host smoke and real-project pilot remain separate validation steps.' } elseif ($Install) { 'Restart the terminal and run this script again; fnm, Node 22.19.0, and the controller bundle are not installed by -Install.' } else { 'Use -Install only for pwsh.exe and copilot.exe; prepare the controller bundle with scripts/prepare-typescript-controller.ps1 -Prepare.' }
}

$report | ConvertTo-Json -Depth 8
if ($status -eq 'failed') { exit 1 }
if ($status -eq 'blocked') { exit 2 }
exit 0
