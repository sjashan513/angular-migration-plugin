$ErrorActionPreference = 'Stop'
$arguments = @($args)
function Get-FixtureStatePath {
    if ($env:FNM_FIXTURE_STATE_PATH) { return $env:FNM_FIXTURE_STATE_PATH }
    return Join-Path (Get-Location).Path '.fixture-fnm-installed'
}
function Get-FixtureVersions {
    param([string]$EnvironmentName, [string[]]$Default)
    $configured = [Environment]::GetEnvironmentVariable($EnvironmentName)
    $values = if ($configured) { @($configured -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @($Default) }
    if ($EnvironmentName -eq 'FNM_FIXTURE_INSTALLED') {
        $statePath = Get-FixtureStatePath
        if (Test-Path -LiteralPath $statePath -PathType Leaf) { $values = @($values) + @([IO.File]::ReadAllLines($statePath) | Where-Object { $_.Trim() }) }
    }
    return @($values | Sort-Object -Unique)
}
if ($arguments.Count -eq 1 -and $arguments[0] -eq '--version') {
    [Console]::Out.WriteLine('1.38.1')
    exit 0
}
if ($arguments.Count -ge 1 -and $arguments[0] -eq 'list') {
    Get-FixtureVersions -EnvironmentName 'FNM_FIXTURE_INSTALLED' -Default @('20.11.1') | ConvertTo-Json -Compress
    exit 0
}
if ($arguments.Count -ge 1 -and $arguments[0] -eq 'list-remote') {
    Get-FixtureVersions -EnvironmentName 'FNM_FIXTURE_REMOTE' -Default @('20.11.1', '16.20.2') | ConvertTo-Json -Compress
    exit 0
}
if ($arguments.Count -ge 2 -and $arguments[0] -eq 'install') {
    $statePath = Get-FixtureStatePath
    Add-Content -LiteralPath $statePath -Value ([string]$arguments[1])
    [Console]::Out.WriteLine("installed $($arguments[1])")
    exit 0
}
if ($arguments.Count -ge 5 -and $arguments[0] -eq 'exec' -and $arguments[1] -eq '--using' -and $arguments[3] -eq '--') {
    $usingVersion = [string]$arguments[2]
    $executable = [string]$arguments[4]
    $childArguments = @($arguments | Select-Object -Skip 5)
    if ($executable -eq 'node' -and $childArguments.Count -eq 1 -and $childArguments[0] -eq '--version') {
        [Console]::Out.WriteLine('v' + $usingVersion)
        exit 0
    }
    if (@('npm', 'npm.cmd') -contains $executable -and $childArguments.Count -eq 1 -and $childArguments[0] -eq '--version') {
        $npmVersion = if ($env:FNM_FIXTURE_NPM_VERSION) { $env:FNM_FIXTURE_NPM_VERSION } else { '10.2.4' }
        [Console]::Out.WriteLine($npmVersion)
        exit 0
    }
    if (@('npm', 'npm.cmd') -contains $executable -and $childArguments.Count -ge 2 -and $childArguments[0] -eq 'view') {
        $selector = [string]$childArguments[1]
        $separator = $selector.LastIndexOf('@')
        $packageName = if ($separator -gt 0) { $selector.Substring(0, $separator) } else { $selector }
        $requested = if ($separator -gt 0) { $selector.Substring($separator + 1) } else { '' }
        $responsePath = $env:MIGRATION_REGISTRY_FIXTURE
        if ($responsePath -and (Test-Path -LiteralPath $responsePath -PathType Leaf)) {
            $responses = Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json
            $response = $responses.PSObject.Properties[$selector]
            if ($response) {
                [Console]::Out.Write(($response.Value | ConvertTo-Json -Depth 50 -Compress))
                exit 0
            }
            if ($requested -match '^\d+$') {
                [Console]::Error.WriteLine("No fixture metadata for $selector")
                exit 1
            }
        }
        $versions = @{
            '@angular/core' = '8.2.14'; '@angular/common' = '8.2.14'; '@angular/compiler' = '8.2.14'
            '@angular/cli' = '8.3.29'; '@angular/compiler-cli' = '8.2.14'
            'rxjs' = '6.5.5'; 'zone.js' = '0.9.1'; 'typescript' = '3.5.3'
        }
        $metadata = [ordered]@{
            version              = if ($versions.ContainsKey($packageName) -and $requested -match '^\d+$') { $versions[$packageName] } elseif ($requested -match '^\d+\.\d+\.\d+$') { $requested } else { '8.2.14' }
            peerDependencies     = [ordered]@{}
            peerDependenciesMeta = [ordered]@{}
            engines              = [ordered]@{ node = '>=10.9.0' }
            deprecated           = $false
            'dist-tags'          = [ordered]@{}
        }
        if ($packageName -eq '@angular/core') {
            $metadata.peerDependencies = [ordered]@{ rxjs = '^6.4.0'; 'zone.js' = '~0.9.0' }
        }
        if ($packageName -eq '@angular/common' -or $packageName -eq '@angular/compiler') {
            $metadata.peerDependencies = [ordered]@{ '@angular/core' = '^8.0.0' }
        }
        if ($packageName -eq '@angular/compiler-cli') {
            $metadata.peerDependencies = [ordered]@{ typescript = '>=3.4.0 <3.6.0' }
        }
        [Console]::Out.Write(($metadata | ConvertTo-Json -Depth 20 -Compress))
        exit 0
    }
    $target = if (Test-Path -LiteralPath $executable -PathType Leaf) { (Resolve-Path -LiteralPath $executable).Path } else { Join-Path $PSScriptRoot (([IO.Path]::GetFileName($executable)) + $(if ([IO.Path]::GetExtension($executable) -eq '.cmd') { '' } else { '.cmd' })) }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        [Console]::Error.WriteLine("fixture executable not found: $executable")
        exit 1
    }
    & $target @childArguments
    exit $LASTEXITCODE
}
[Console]::Error.WriteLine('unsupported fixture fnm command')
exit 1
