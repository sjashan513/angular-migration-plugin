#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '../../scripts/modules/Migration.Core.psm1'
Import-Module $modulePath -Force -DisableNameChecking
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

$timer = [Diagnostics.Stopwatch]::StartNew()
$stalled = Invoke-MigrationProcess -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -WorkingDirectory $root -TimeoutSeconds 10 -InactivityTimeoutSeconds 1
$timer.Stop()
if (-not $stalled.processStalled -or $stalled.timedOut -or $stalled.terminationReason -ne 'process_stalled' -or $stalled.exitCode -ne 125) { throw 'Silent process was not classified as process_stalled.' }
if ($timer.Elapsed.TotalSeconds -ge 4) { throw 'Inactivity watchdog did not terminate the silent process promptly.' }
Write-Host 'PASS inactivity watchdog stops silent processes before total timeout'

$timedOut = Invoke-MigrationProcess -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -WorkingDirectory $root -TimeoutSeconds 1 -InactivityTimeoutSeconds 10
if ($timedOut.processStalled -or -not $timedOut.timedOut -or $timedOut.terminationReason -ne 'timeout' -or $timedOut.exitCode -ne 124) { throw 'Total timeout did not retain precedence over inactivity.' }
Write-Host 'PASS total timeout remains distinct from inactivity'

$completed = Invoke-MigrationProcess -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-Command', 'Write-Output heartbeat') -WorkingDirectory $root -TimeoutSeconds 10 -InactivityTimeoutSeconds 1
if ($completed.processStalled -or $completed.timedOut -or $completed.terminationReason -ne 'completed' -or $completed.exitCode -ne 0 -or $completed.stdout -notmatch 'heartbeat') { throw 'Active process was incorrectly classified as stalled.' }
Write-Host 'PASS active process completes with output'

Write-Host 'Migration core process tests OK'
