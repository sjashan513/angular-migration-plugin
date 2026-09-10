$ErrorActionPreference = 'Stop'
$arguments = @($args)
if ($arguments.Count -eq 1 -and $arguments[0] -eq '--version') {
    [Console]::Out.WriteLine('v20.11.1')
    exit 0
}
if ($arguments.Count -lt 1) { exit 1 }
$payloadText = [Console]::In.ReadToEnd()
try { $payload = $payloadText | ConvertFrom-Json } catch { [Console]::Error.WriteLine('invalid renderer input'); exit 1 }
if ($payload.mode -notin @('exact', 'declared')) { [Console]::Error.WriteLine('invalid renderer mode'); exit 1 }
try { $package = $payload.packageText | ConvertFrom-Json } catch { [Console]::Error.WriteLine('invalid package input'); exit 1 }
foreach ($dependency in @($payload.dependencies)) {
    $section = $package.PSObject.Properties[$dependency.section]
    if (-not $section) {
        if ($dependency.change -eq 'added-required-tooling' -and $dependency.section -eq 'devDependencies') {
            $package | Add-Member -NotePropertyName devDependencies -NotePropertyValue ([PSCustomObject]@{})
            $section = $package.PSObject.Properties['devDependencies']
        }
        else { [Console]::Error.WriteLine("missing section $($dependency.section)"); exit 1 }
    }
    $value = if ($payload.mode -eq 'exact') { [string]$dependency.targetVersion } else { [string]$dependency.writeSpec }
    $property = $section.Value.PSObject.Properties[$dependency.name]
    if (-not $property) {
        if ($dependency.change -eq 'added-required-tooling' -and $dependency.section -eq 'devDependencies') {
            $section.Value | Add-Member -NotePropertyName $dependency.name -NotePropertyValue $value
        }
        else { [Console]::Error.WriteLine("missing dependency $($dependency.name)"); exit 1 }
    }
    else { $property.Value = $value }
}
[Console]::Out.Write(($package | ConvertTo-Json -Depth 50))
