# LucidPC Server Install -- one-shot RustDesk setup for unattended access
#
# Run on any Windows server/PC you want to manage remotely without an end-user present.
# After this script: you can connect from your tech machine using the device's 9-digit ID
# and the permanent password set below. No clicks, no popups, no Accept prompt.
#
# Usage (run as Administrator):
#   powershell -ExecutionPolicy Bypass -File .\LucidPC-ServerInstall.ps1 -PermanentPassword "Your-Strong-Password"
#
# Or just double-click LucidPC-ServerInstall.bat (it self-elevates and prompts for password).

[CmdletBinding()]
param(
    [string]$PermanentPassword = '',
    [switch]$GeneratePassword,        # generate a random 20-char password instead of typing one
    [int]$GeneratedLength = 20,
    [string]$RustDeskUrl = 'https://github.com/rustdesk/rustdesk/releases/latest/download/rustdesk-1.4.6-x86_64.exe'
)

function New-RandomPassword {
    param([int]$Length = 20)
    # Avoid ambiguous chars (0/O, 1/l/I) and shell-unfriendly chars (quotes, backslash, etc.)
    $charset = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%^&*-_=+'.ToCharArray()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new($Length)
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $charset[$_ % $charset.Length] })
}

$ErrorActionPreference = 'Stop'

# --- LucidPC server config ---
$idServer    = 'live.lucidpc.com'
$relayServer = 'live.lucidpc.com'
$apiServer   = 'https://live.lucidpc.com'
$publicKey   = 'hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k='
# -----------------------------

function Write-Step($msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "[!!] $msg" -ForegroundColor Red }

# Require admin for service install
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "This script must run as Administrator (RustDesk service install requires it)."
    Write-Host "Right-click PowerShell -> Run as Administrator -> re-run this script."
    Read-Host "`nPress Enter to exit"
    exit 1
}

$pwWasGenerated = $false

# Resolve the permanent password in order of priority:
#   1. -GeneratePassword switch (random password)
#   2. -PermanentPassword "..." parameter
#   3. Type/paste at masked prompt (default)
if ($GeneratePassword) {
    $PermanentPassword = New-RandomPassword -Length $GeneratedLength
    $pwWasGenerated = $true
    Write-Host "[*] Generated a random $GeneratedLength-char password (will be shown ONCE at the end)." -ForegroundColor Cyan
} elseif ([string]::IsNullOrWhiteSpace($PermanentPassword)) {
    Write-Host ""
    Write-Host "Paste your shared LucidPC RustDesk password from your password manager." -ForegroundColor Cyan
    Write-Host "Input is hidden. Use Ctrl+V or right-click to paste." -ForegroundColor DarkGray
    Write-Host ""
    $secure1 = Read-Host "Password" -AsSecureString
    if (-not $secure1 -or $secure1.Length -eq 0) { Write-Err "Password required. Aborting."; exit 1 }
    $secure2 = Read-Host "Re-paste to confirm" -AsSecureString
    $bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1)
    $bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
    try {
        $pw1 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr1)
        $pw2 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
        if ($pw1 -ne $pw2) { Write-Err "Passwords did not match. Aborting."; exit 1 }
        if ($pw1.Length -lt 8) { Write-Err "Password must be at least 8 characters. Aborting."; exit 1 }
        $PermanentPassword = $pw1
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
    }
}

Clear-Host
Write-Host "================================================================" -ForegroundColor White
Write-Host "  LucidPC Server Install -- RustDesk for unattended access" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White

try {
    # 1. Stop any running RustDesk
    Write-Step "Stopping any running RustDesk processes/service..."
    Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'rustdesk', 'RustDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # 2. Install RustDesk if needed
    $rustdeskExePaths = @(
        "$env:ProgramFiles\RustDesk\rustdesk.exe",
        "$env:ProgramFiles\RustDesk\RustDesk.exe"
    )
    $rustdeskExe = $rustdeskExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $rustdeskExe) {
        $installer = Join-Path $env:TEMP 'rustdesk-installer.exe'
        Write-Step "Downloading RustDesk... (~50 MB)"
        Invoke-WebRequest -Uri $RustDeskUrl -OutFile $installer -UseBasicParsing
        Write-Ok "Downloaded to $installer"

        Write-Step "Installing RustDesk silently (will poll for completion, ~30-60s)..."
        # Don't use -Wait: RustDesk's --silent-install often auto-launches the UI after installing,
        # and that holds the installer's parent process open indefinitely. Instead, fire-and-forget
        # the installer and poll for the binary to appear at the install location.
        $proc = Start-Process -FilePath $installer -ArgumentList '--silent-install' -PassThru
        $timeoutSec = 180
        $waited = 0
        while (-not (Test-Path "$env:ProgramFiles\RustDesk\rustdesk.exe") -and $waited -lt $timeoutSec) {
            Start-Sleep -Seconds 2
            $waited += 2
        }
        if (-not (Test-Path "$env:ProgramFiles\RustDesk\rustdesk.exe")) {
            throw "Install timed out after $timeoutSec seconds. Run the installer manually and re-run this script."
        }

        # Give the service registration a moment to finalize
        Start-Sleep -Seconds 5

        # Kill any RustDesk UI/processes that auto-launched - they can keep the installer parent alive
        # and we want a clean state before writing config and setting password.
        Get-Process -Name 'rustdesk', 'RustDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.HasExited) {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }

        $rustdeskExe = $rustdeskExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $rustdeskExe) { throw "Could not find rustdesk.exe after install." }
        Write-Ok "Installed at $rustdeskExe"
    } else {
        Write-Ok "RustDesk already installed at $rustdeskExe"
    }

    # 3. Write the RustDesk config to all three RustDesk config locations
    Write-Step "Writing config (server + connection settings + unattended mode)..."

    $configToml = @"
rendezvous_server = '${idServer}:21116'
nat_type = 1
serial = 0

[options]
relay-server = '$relayServer'
api-server = '$apiServer'
custom-rendezvous-server = '$idServer'
key = '$publicKey'
approve-mode = 'password'
verification-method = 'use-permanent-password'
"@

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    # User-mode config
    $userCfgDir = Join-Path $env:APPDATA 'RustDesk\config'
    New-Item -ItemType Directory -Force -Path $userCfgDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $userCfgDir 'RustDesk2.toml'), $configToml, $utf8NoBom)
    Write-Ok "User config: $userCfgDir\RustDesk2.toml"

    # Service-mode config (LocalService)
    $svcCfgDir = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config'
    New-Item -ItemType Directory -Force -Path $svcCfgDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $svcCfgDir 'RustDesk2.toml'), $configToml, $utf8NoBom)
    Write-Ok "Service config: $svcCfgDir\RustDesk2.toml"

    # SYSTEM profile config
    $sysCfgDir = 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config'
    if (-not (Test-Path $sysCfgDir)) { New-Item -ItemType Directory -Force -Path $sysCfgDir | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $sysCfgDir 'RustDesk2.toml'), $configToml, $utf8NoBom)
    Write-Ok "System config: $sysCfgDir\RustDesk2.toml"

    # 4. Make sure the RustDesk service is running first (CLI password command requires it)
    Write-Step "Configuring RustDesk service for boot..."
    Set-Service -Name 'RustDesk' -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4

    # 5. Set the permanent password as SYSTEM (the context the service runs in).
    #    Running rustdesk --password from Admin context silently does nothing (no error);
    #    we use a one-shot scheduled task running as NT AUTHORITY\SYSTEM to write to the
    #    service-context config. The service then sees and uses the password for incoming connections.
    Write-Step "Setting permanent password (running as SYSTEM)..."
    $taskName = "lucidpc-rustdesk-setpw-$(([guid]::NewGuid()).ToString('N').Substring(0,8))"
    try {
        $action = New-ScheduledTaskAction -Execute $rustdeskExe -Argument "--password `"$PermanentPassword`""
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -RunLevel Highest -LogonType ServiceAccount
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 30)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName

        # Wait for the task to actually run and complete
        $waited = 0
        while ((Get-ScheduledTask -TaskName $taskName).State -ne 'Ready' -and $waited -lt 15) {
            Start-Sleep -Seconds 1
            $waited++
        }
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        if ($taskInfo.LastTaskResult -eq 0) {
            Write-Ok "Permanent password set via SYSTEM context"
        } else {
            Write-Host "[!] Scheduled-task exit code: $($taskInfo.LastTaskResult) (0x$('{0:X8}' -f $taskInfo.LastTaskResult))" -ForegroundColor Yellow
            Write-Host "    Falling back to admin-context CLI as a best-effort..." -ForegroundColor Yellow
            & $rustdeskExe --password "$PermanentPassword" 2>&1
        }
    } catch {
        Write-Err "Failed to set password via SYSTEM scheduled task: $($_.Exception.Message)"
        Write-Host "Falling back to admin-context CLI..." -ForegroundColor Yellow
        & $rustdeskExe --password "$PermanentPassword" 2>&1
    } finally {
        # Clean up the temporary task
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    # 6. Restart the service so it re-reads the password from its config
    Write-Step "Restarting RustDesk service so it picks up the new password..."
    Stop-Service -Name 'RustDesk' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4

    # 7. Verify the password file was actually written in the service config dir
    $sysCfgFile = 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config\RustDesk.toml'
    if (Test-Path $sysCfgFile) {
        $tomlContent = Get-Content $sysCfgFile -Raw -ErrorAction SilentlyContinue
        if ($tomlContent -match "password\s*=\s*'[^']+'") {
            Write-Ok "Verified: password is set in service config ($sysCfgFile)"
        } else {
            Write-Host "[!] Service config exists but no password field found. The password may not be applied." -ForegroundColor Yellow
            Write-Host "    Open RustDesk on this server, check Settings -> Security -> Password for unattended access." -ForegroundColor Yellow
            Write-Host "    If blank, set it manually using the password you typed." -ForegroundColor Yellow
        }
    } else {
        Write-Host "[!] Service config file not found at $sysCfgFile yet." -ForegroundColor Yellow
        Write-Host "    The service may not have written it yet -- give it a minute, then verify in RustDesk Settings." -ForegroundColor Yellow
    }

    # 8. Verify the RustDesk service is actually Running
    Write-Step "Verifying RustDesk service is running..."
    $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Err "RustDesk service is not registered. Install may be incomplete."
        throw "Service missing"
    }
    $tries = 0
    while ($svc.Status -ne 'Running' -and $tries -lt 6) {
        Start-Sleep -Seconds 2
        $svc.Refresh()
        $tries++
    }
    if ($svc.Status -eq 'Running') {
        Write-Ok "RustDesk service is Running (auto-start enabled)"
    } else {
        Write-Err "RustDesk service did not reach Running state. Last status: $($svc.Status)"
        throw "Service not running"
    }

    # 9. Read the device's RustDesk ID with retry (service IPC needs a moment to be ready)
    Write-Step "Retrieving this device's RustDesk ID..."
    $deviceId = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        Start-Sleep -Seconds 2
        $deviceIdRaw = & $rustdeskExe --get-id 2>&1 | Out-String
        $match = [regex]::Match($deviceIdRaw, '\b\d{6,12}\b')
        if ($match.Success) { $deviceId = $match.Value; break }
    }
    if (-not $deviceId) {
        Write-Host "[!] Could not auto-retrieve Device ID via --get-id. Falling back to launching RustDesk UI." -ForegroundColor Yellow
    }

    # 10. Launch RustDesk user-mode UI so it appears in the tray and you can see the ID
    Write-Step "Launching RustDesk window so you can see the ID in the tray..."
    Start-Process -FilePath $rustdeskExe -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4

    # 11. Copy the Device ID to clipboard for your address-book paste on the tech machine
    if ($deviceId) {
        try {
            Set-Clipboard -Value $deviceId
            Write-Ok "Device ID $deviceId copied to clipboard"
        } catch {
            # Set-Clipboard may not be available on older PowerShell; still display the ID
        }
    }

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  DONE - this server is ready for unattended remote access." -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Server config:"
    Write-Host "    ID server:    $idServer"
    Write-Host "    Relay:        $relayServer"
    Write-Host "    API:          $apiServer"
    Write-Host "    Approve mode: password (no Accept prompt needed)"
    Write-Host ""
    Write-Host "  Connection details for your tech machine:"
    Write-Host ""
    if ($deviceId) {
        Write-Host "    +---------------------------+" -ForegroundColor Green
        Write-Host "    |                           |" -ForegroundColor Green
        Write-Host "    |  Device ID:  $($deviceId.PadRight(13))|" -ForegroundColor Green
        Write-Host "    |                           |" -ForegroundColor Green
        Write-Host "    +---------------------------+" -ForegroundColor Green
        Write-Host "    (already copied to clipboard - paste into your tech client's address book)" -ForegroundColor DarkGray
    } else {
        Write-Host "    Device ID:    (look at the RustDesk window that just opened - it shows at the top)" -ForegroundColor Yellow
    }
    Write-Host ""
    if ($pwWasGenerated) {
        Write-Host "    Password:     $PermanentPassword" -ForegroundColor Yellow
        Write-Host "                  ^ COPY THIS NOW. It will not be shown again or saved to disk." -ForegroundColor Yellow
    } else {
        Write-Host "    Password:     (the one you just entered -- save it to your password manager now)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  From your tech client (with LucidPC settings already imported):"
    Write-Host "    1. Type the device ID -> Connect"
    Write-Host "    2. Enter the password you set -> tick Remember"
    Write-Host "    3. Right-click the device -> Add to address book"
    Write-Host ""
    Write-Host "  You can disconnect this server's keyboard now if you want."
    Write-Host ""

    # Save the device ID to a file the user can find later (no password -- that stays only in their head/PM)
    $detailsFile = Join-Path $env:USERPROFILE 'Desktop\LucidPC-RustDesk-DeviceID.txt'
    $detailsContent = @"
LucidPC RustDesk - Server Install Details
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Hostname:  $env:COMPUTERNAME

Device ID: $(if ($deviceId) {$deviceId} else {'(open RustDesk to see)'})
Password:  (saved by user; not stored on disk)

Connect from tech client:
  1. RustDesk -> type Device ID -> Connect
  2. Enter the permanent password
  3. Tick Remember + add to address book
"@
    try {
        Set-Content -Path $detailsFile -Value $detailsContent -Encoding ASCII
        Write-Host "  Device ID also saved to: $detailsFile" -ForegroundColor DarkGray
    } catch { }

} catch {
    Write-Err $_.Exception.Message
    Write-Host "Details: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Read-Host "Press Enter to exit"
    exit 1
}
