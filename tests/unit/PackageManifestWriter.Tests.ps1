#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '../../scripts/modules/Migration.Core.psm1'
Import-Module $modulePath -Force -DisableNameChecking
$renderer = (Resolve-Path (Join-Path $PSScriptRoot '../../scripts/helpers/render-package-json.js')).Path
$node = Find-MigrationExecutable -Names @('node.exe', 'node')
if (-not $node) { throw 'node is required for the package renderer test' }

function Invoke-Renderer {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [int]$ExpectedExitCode = 0
    )
    $inputText = $InputObject | ConvertTo-Json -Depth 30 -Compress
    $result = Invoke-MigrationProcess -FilePath $node -Arguments @($renderer) -WorkingDirectory (Split-Path -Parent $renderer) -TimeoutSeconds 15 -StandardInput $inputText
    if ($result.exitCode -ne $ExpectedExitCode) {
        throw "Renderer exit code $($result.exitCode), expected ${ExpectedExitCode}: $($result.stderr)"
    }
    return $result
}

$lfText = @'
{
    "name": "fixture",
    "dependencies": {
        "@angular/core": "^7.2.0",
        "rxjs": "~6.3.3"
    },
    "scripts": {
        "build": "ng build"
    }
}
'@ -replace "`r`n", "`n"
$lfText += "`n"
$input = [ordered]@{
    mode = 'exact'
    packageText = $lfText
    dependencies = @(
        [ordered]@{ name = '@angular/core'; section = 'dependencies'; targetVersion = '8.2.14'; writeSpec = '^8.2.14' }
    )
}
$result = Invoke-Renderer -InputObject $input
if (-not $result.stdout.EndsWith("`n") -or $result.stdout.Contains("`r`n")) { throw 'LF newline or final newline was not preserved' }
$rendered = $result.stdout | ConvertFrom-Json
if ($rendered.dependencies.'@angular/core' -ne '8.2.14' -or $rendered.dependencies.rxjs -ne '~6.3.3') { throw 'Exact mode changed the wrong dependency' }
if (($result.stdout.IndexOf('"name"') -gt $result.stdout.IndexOf('"dependencies"')) -or ($result.stdout.IndexOf('"dependencies"') -gt $result.stdout.IndexOf('"scripts"'))) { throw 'Property order was not preserved' }
Write-Host 'PASS exact mode preserves LF, final newline and property order'

$crlfText = "{`r`n`t`"name`": `"fixture`",`r`n`t`"devDependencies`": {`r`n`t`t`"@angular/cli`": `"~7.3.0`"`r`n`t}`r`n}"
$declared = [ordered]@{
    mode = 'declared'
    packageText = $crlfText
    dependencies = @(
        [ordered]@{ name = '@angular/cli'; section = 'devDependencies'; targetVersion = '8.3.29'; writeSpec = '~8.3.29' }
    )
}
$result = Invoke-Renderer -InputObject $declared
if ($result.stdout.Contains("`n") -and -not $result.stdout.Contains("`r`n")) { throw 'CRLF newline was not preserved' }
if ($result.stdout.EndsWith("`r`n")) { throw 'Missing final newline was added' }
if (($result.stdout | ConvertFrom-Json).devDependencies.'@angular/cli' -ne '~8.3.29') { throw 'Declared mode did not use writeSpec' }
if ($result.stdout.IndexOf("`t`"name`"") -lt 0) { throw 'Tab indentation was not preserved' }
Write-Host 'PASS declared mode preserves CRLF, tabs and missing final newline'

$cases = @(
    @{ name = 'duplicate'; dependencies = @(
        @{ name = 'rxjs'; section = 'dependencies'; targetVersion = '6.5.5'; writeSpec = '~6.5.5' },
        @{ name = 'rxjs'; section = 'dependencies'; targetVersion = '6.5.5'; writeSpec = '~6.5.5' }
    ) },
    @{ name = 'missing'; dependencies = @(
        @{ name = 'missing'; section = 'dependencies'; targetVersion = '1.0.0'; writeSpec = '^1.0.0' }
    ) },
    @{ name = 'wrong-section'; dependencies = @(
        @{ name = '@angular/core'; section = 'devDependencies'; targetVersion = '8.2.14'; writeSpec = '^8.2.14' }
    ) }
)
foreach ($case in $cases) {
    $invalid = [ordered]@{ mode = 'exact'; packageText = $lfText; dependencies = $case.dependencies }
    $result = Invoke-Renderer -InputObject $invalid -ExpectedExitCode 1
    if ([string]::IsNullOrWhiteSpace($result.stderr)) { throw "Renderer did not diagnose $($case.name)" }
}
Write-Host 'PASS renderer rejects duplicate, missing and wrong-section dependencies'
