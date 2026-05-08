# LucidPC - Patch existing servers with RustDesk auto-recovery
#
# Adds three layers of protection so you never lose remote access to a server:
#   1. Windows Service Recovery: restart RustDesk on crash (3 attempts, 5s apart)
#   2. Watchdog if service is STOPPED (exists but not running)   -> Start-Service
#   3. Watchdog if service is DELETED (RustDesk "Stop Service" button calls
#      sc delete -- the service vanishes from Windows entirely)  -> rustdesk --install-service
#
# The watchdog runs every 5 minutes as SYSTEM. So in the worst case, you lose
# access for at most 5 minutes -- after which the service is back up automatically.
#
# Run as Administrator on each existing server. Safe to re-run (replaces existing watchdog).
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
    # Find rustdesk.exe (needed for --install-service in the watchdog)
    $rdExePaths = @("$env:ProgramFiles\RustDesk\rustdesk.exe", "$env:ProgramFiles\RustDesk\RustDesk.exe")
    $rdExe = $rdExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $rdExe) {
        Write-Host "  Error: rustdesk.exe not found. Install RustDesk first using LucidPC-ServerInstall." -ForegroundColor Red
        Read-Host "Press Enter to exit"; exit 1
    }

    Write-Host -NoNewline "  [1/3] Ensuring service is registered + Automatic startup..."
    $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if (-not $svc) {
        # Service was deleted (Stop Service button) - reinstall it
        & $rdExe --install-service
        Start-Sleep -Seconds 3
    }
    Set-Service -Name 'RustDesk' -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    Write-Host " done" -ForegroundColor Green

    Write-Host -NoNewline "  [2/3] Configuring crash recovery..."
    & sc.exe failure RustDesk reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Write-Host " done" -ForegroundColor Green

    Write-Host -NoNewline "  [3/3] Installing watchdog (every 5 min, runs as SYSTEM)..."
    $watchdogName = 'LucidPC-RustDesk-Watchdog'
    Unregister-ScheduledTask -TaskName $watchdogName -Confirm:$false -ErrorAction SilentlyContinue
    $watchdogScript = @'
$rdExe = @("$env:ProgramFiles\RustDesk\rustdesk.exe", "$env:ProgramFiles\RustDesk\RustDesk.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $rdExe) { exit 0 }
$svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
if (-not $svc) {
    & $rdExe --install-service
    Start-Sleep -Seconds 3
    Set-Service -Name 'RustDesk' -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
} elseif ($svc.Status -ne 'Running') {
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
}
'@
    $watchdogB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($watchdogScript))
    $wdAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $watchdogB64"
    $wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 5)
    $wdPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    $wdSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $watchdogName -Action $wdAction -Trigger $wdTrigger `
        -Principal $wdPrincipal -Settings $wdSettings `
        -Description 'LucidPC: every 5 min, ensure RustDesk service exists and is Running. Re-installs via --install-service if Stop Service button deleted the service entry.' `
        -Force | Out-Null
    Write-Host " done" -ForegroundColor Green

    # Self-verify all three layers are actually in place
    Write-Host ""
    Write-Host "  Verifying:"
    $allOk = $true

    $svcCheck = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if ($svcCheck -and $svcCheck.StartType -eq 'Automatic') {
        Write-Host "    [OK]  Service auto-start on Windows boot" -ForegroundColor Green
    } else { Write-Host "    [!!]  Service auto-start NOT verified" -ForegroundColor Red; $allOk = $false }

    $failureOut = & sc.exe qfailure RustDesk 2>&1 | Out-String
    if ($failureOut -match 'RESTART') {
        Write-Host "    [OK]  Service Recovery (auto-restart on crash)" -ForegroundColor Green
    } else { Write-Host "    [!!]  Service Recovery NOT verified" -ForegroundColor Red; $allOk = $false }

    if (Get-ScheduledTask -TaskName $watchdogName -ErrorAction SilentlyContinue) {
        Write-Host "    [OK]  Watchdog task (every 5 min as SYSTEM)" -ForegroundColor Green
    } else { Write-Host "    [!!]  Watchdog task NOT verified" -ForegroundColor Red; $allOk = $false }

    Write-Host ""
    if ($allOk) {
        Write-Host "  Auto-recovery is fully active. Worst-case access loss = 5 minutes." -ForegroundColor Green
    } else {
        Write-Host "  Some layers did not verify. Server is still accessible right now," -ForegroundColor Yellow
        Write-Host "  but recovery may not work if the service is stopped. Re-run this script." -ForegroundColor Yellow
    }
    Write-Host ""

} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}

Read-Host "  Press Enter to close"
