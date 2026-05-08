# LucidPC - Patch existing servers with RustDesk auto-recovery
#
# For servers that were installed BEFORE auto-recovery was added to the install script.
# Adds two layers:
#   1. Windows Service Recovery: restart RustDesk service on crash (3 attempts, 5s apart)
#   2. Watchdog: scheduled task as SYSTEM, runs every 5 minutes, restarts service if stopped
#
# Run as Administrator on each existing server. Safe to re-run -- replaces existing watchdog.
# Usage:
#   iex (irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-PatchAutoRecovery.ps1)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Must run as Administrator. Right-click PowerShell -> Run as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}

Clear-Host
Write-Host ""
Write-Host "  LucidPC RustDesk Auto-Recovery Patch" -ForegroundColor White
Write-Host "  ====================================" -ForegroundColor White
Write-Host ""

try {
    # Confirm RustDesk service exists
    $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "  Error: RustDesk service not found. Run LucidPC-ServerInstall first." -ForegroundColor Red
        Read-Host "Press Enter to exit"; exit 1
    }

    Write-Host -NoNewline "  [1/3] Setting service to Automatic startup..."
    Set-Service -Name 'RustDesk' -StartupType Automatic -ErrorAction SilentlyContinue
    if ((Get-Service -Name 'RustDesk').Status -ne 'Running') { Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue }
    Write-Host " done" -ForegroundColor Green

    Write-Host -NoNewline "  [2/3] Configuring crash recovery (auto-restart on failure)..."
    & sc.exe failure RustDesk reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Write-Host " done" -ForegroundColor Green

    Write-Host -NoNewline "  [3/3] Installing watchdog (checks service every 5 min)..."
    $watchdogName = 'LucidPC-RustDesk-Watchdog'
    Unregister-ScheduledTask -TaskName $watchdogName -Confirm:$false -ErrorAction SilentlyContinue
    $wdAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NoProfile -WindowStyle Hidden -Command "if ((Get-Service -Name RustDesk -ErrorAction SilentlyContinue).Status -ne ''Running'') { Start-Service -Name RustDesk -ErrorAction SilentlyContinue }"'
    $wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 5)
    $wdPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    $wdSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $watchdogName -Action $wdAction -Trigger $wdTrigger `
        -Principal $wdPrincipal -Settings $wdSettings `
        -Description 'LucidPC: ensures the RustDesk service is running every 5 minutes (recovery if stopped/crashed)' `
        -Force | Out-Null
    Write-Host " done" -ForegroundColor Green

    Write-Host ""
    Write-Host "  Auto-recovery is now active on this server." -ForegroundColor Green
    Write-Host ""
    Write-Host "  - RustDesk service starts on every Windows boot (Automatic)"
    Write-Host "  - On a crash, Windows restarts it within 5 seconds (up to 3 times)"
    Write-Host "  - Every 5 minutes, a SYSTEM watchdog checks and restarts if stopped"
    Write-Host ""
    Write-Host "  Practically: even if you (or anything else) clicks Stop Service,"
    Write-Host "  it'll be back within 5 minutes max." -ForegroundColor DarkGray
    Write-Host ""

} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}

Read-Host "  Press Enter to close"
