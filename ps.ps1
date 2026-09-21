Write-Host "`n=== PWSH EN PATH ==="
Get-Command pwsh -All -ErrorAction SilentlyContinue |
    Select-Object Name, CommandType, Source, Path |
    Format-Table -AutoSize

Write-Host "`n=== WHERE PWSH ==="
where.exe pwsh

Write-Host "`n=== POWERSHELL 7 INSTALADO ==="
$pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"

if (Test-Path $pwsh) {
    Get-Item $pwsh |
        Select-Object FullName, Length, CreationTime, LastWriteTime

    Write-Host "`n=== INTENTO DIRECTO ==="
    try {
        & $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion'
    }
    catch {
        Write-Host $_.Exception.Message
    }
}
else {
    Write-Host "No existe: $pwsh"
}

Write-Host "`n=== OH MY POSH ==="
Get-Command oh-my-posh -ErrorAction SilentlyContinue |
    Select-Object Name, Source, Path

Write-Host "`n=== APPLOCKER RECIENTE ==="
Get-WinEvent -FilterHashtable @{
    LogName   = 'Microsoft-Windows-AppLocker/EXE and DLL'
    StartTime = (Get-Date).AddMinutes(-15)
} -ErrorAction SilentlyContinue |
    Select-Object -First 10 TimeCreated, Id, Message |
    Format-List

Write-Host "`n=== CODE INTEGRITY RECIENTE ==="
Get-WinEvent -FilterHashtable @{
    LogName   = 'Microsoft-Windows-CodeIntegrity/Operational'
    StartTime = (Get-Date).AddMinutes(-15)
} -ErrorAction SilentlyContinue |
    Select-Object -First 10 TimeCreated, Id, Message |
    Format-List