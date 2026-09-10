$ErrorActionPreference = 'Stop'
$arguments = @($args)
$root = (Get-Location).Path
$tracePath = Join-Path $root '.fixture-trace'
[IO.File]::AppendAllText($tracePath, ('ng ' + ($arguments -join ' ') + [Environment]::NewLine))
if (Test-Path -LiteralPath (Join-Path $root '.fixture-fail-ng')) {
    [Console]::Error.WriteLine('src/app.component.ts:1:1 fixture Angular update failure')
    exit 1
}
if ($env:MIGRATION_FIXTURE_PROTECTED_PROJECT -and
    [IO.Path]::GetFullPath($env:MIGRATION_FIXTURE_PROTECTED_PROJECT) -eq [IO.Path]::GetFullPath($root)) {
    $protectedDirectory = Join-Path $root 'docs'
    New-Item -ItemType Directory -Path $protectedDirectory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $protectedDirectory 'unexpected.md'), 'unexpected')
}
$sourcePath = Join-Path $root 'src/migrated-by-ng.ts'
[IO.File]::WriteAllText($sourcePath, "export const migratedByFixture = true;`n")
[Console]::Out.WriteLine('fixture ng update passed')
exit 0
