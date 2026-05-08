# LucidPC RustDesk Setup -- unattended-access install for Windows
#
# Idempotent. Safe to run on:
#   - A fresh server (full install + config + password + auto-recovery)
#   - An existing server that needs auto-recovery added (skips already-done steps)
#   - Any server you just want to re-verify is correctly set up
#
# Run as Administrator.
#
# Usage:
#   iex (irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/bootstrap-server.ps1)
# Or:
#   powershell -ExecutionPolicy Bypass -File .\LucidPC-ServerInstall.ps1
#
# Re-run flags:
#   -ForcePassword     Re-prompt and re-set the permanent password even if already set
#   -SkipPassword      Skip the password step entirely (only refreshes config + recovery)
#   -Verbose           Show diagnostic output for troubleshooting

[CmdletBinding()]
param(
    [string]$PermanentPassword = '',
    [switch]$GeneratePassword,
    [switch]$ForcePassword,
    [switch]$SkipPassword,
    [int]$GeneratedLength = 20,
    [string]$RustDeskUrl = 'https://github.com/rustdesk/rustdesk/releases/latest/download/rustdesk-1.4.6-x86_64.exe'
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = if ($VerbosePreference -eq 'SilentlyContinue') { 'SilentlyContinue' } else { $VerbosePreference }

# --- LucidPC server config ---
$idServer    = 'live.lucidpc.com'
$relayServer = 'live.lucidpc.com'
$apiServer   = 'https://live.lucidpc.com'
$publicKey   = 'hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k='
# -----------------------------

function New-RandomPassword {
    param([int]$Length = 20)
    $charset = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%^&*-_=+'.ToCharArray()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new($Length)
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $charset[$_ % $charset.Length] })
}

function Show-Step {
    param([int]$Num, [int]$Total, [string]$Label)
    $prefix = "  Step $Num of $Total ".PadRight(15)
    $line = $prefix + $Label.PadRight(40)
    Write-Host -NoNewline $line
}
function Show-StepOk { Write-Host "done" -ForegroundColor Green }
function Show-StepFail { param([string]$msg) Write-Host "FAILED" -ForegroundColor Red; if ($msg) { Write-Host "    $msg" -ForegroundColor Red } }
function Show-Error { param([string]$msg) Write-Host "`n  Error: $msg" -ForegroundColor Red }

# Require admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Show-Error "This script must run as Administrator. Right-click PowerShell -> Run as Administrator."
    Read-Host "`nPress Enter to exit"
    exit 1
}

# --- Decide whether the password step is even needed ---
# Skip the password prompt entirely if:
#   - User passed -SkipPassword, OR
#   - The SYSTEM-profile RustDesk.toml already has a 'password = ...' entry
#     AND user did NOT pass -ForcePassword (so re-runs don't unnecessarily re-prompt)
$sysCfgFile = 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config\RustDesk.toml'
$pwAlreadySet = $false
if (Test-Path $sysCfgFile) {
    $existingToml = Get-Content $sysCfgFile -Raw -ErrorAction SilentlyContinue
    if ($existingToml -match "password\s*=\s*'[^']+'") { $pwAlreadySet = $true }
}
$skipPasswordStep = $SkipPassword.IsPresent -or ($pwAlreadySet -and -not $ForcePassword.IsPresent -and -not $GeneratePassword.IsPresent -and [string]::IsNullOrWhiteSpace($PermanentPassword))
Write-Verbose "Password step: pwAlreadySet=$pwAlreadySet skipPasswordStep=$skipPasswordStep"

# --- Resolve permanent password if step not skipped ---
$pwWasGenerated = $false
if (-not $skipPasswordStep) {
    if ($GeneratePassword) {
        $PermanentPassword = New-RandomPassword -Length $GeneratedLength
        $pwWasGenerated = $true
        Write-Verbose "Generated random $GeneratedLength-char password"
    } elseif ([string]::IsNullOrWhiteSpace($PermanentPassword)) {
        Clear-Host
        Write-Host ""
        Write-Host "  LucidPC RustDesk Setup" -ForegroundColor White
        Write-Host "  ======================" -ForegroundColor White
        Write-Host ""
        if ($pwAlreadySet -and $ForcePassword) {
            Write-Host "  Permanent password is already set; -ForcePassword passed, re-prompting." -ForegroundColor DarkGray
        } else {
            Write-Host "  Paste the LucidPC support password (input is hidden)." -ForegroundColor DarkGray
        }
        Write-Host ""
        $secure1 = Read-Host "  Password" -AsSecureString
        if (-not $secure1 -or $secure1.Length -eq 0) { Show-Error "Password required."; exit 1 }
        $secure2 = Read-Host "  Confirm "  -AsSecureString
        $bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1)
        $bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
        try {
            $pw1 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr1)
            $pw2 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
            if ($pw1 -ne $pw2) { Show-Error "Passwords did not match."; exit 1 }
            if ($pw1.Length -lt 8) { Show-Error "Password must be at least 8 characters."; exit 1 }
            $PermanentPassword = $pw1
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
        }
    }
}

# --- Banner ---
Clear-Host
Write-Host ""
Write-Host "  LucidPC RustDesk Setup" -ForegroundColor White
Write-Host "  ======================" -ForegroundColor White
Write-Host ""

try {
    # Step 1: Install RustDesk if needed
    Show-Step 1 5 "Installing RustDesk..."
    Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'rustdesk', 'RustDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $rustdeskExePaths = @("$env:ProgramFiles\RustDesk\rustdesk.exe", "$env:ProgramFiles\RustDesk\RustDesk.exe")
    $rustdeskExe = $rustdeskExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $rustdeskExe) {
        $installer = Join-Path $env:TEMP 'rustdesk-installer.exe'
        Write-Verbose "Downloading $RustDeskUrl to $installer"
        Invoke-WebRequest -Uri $RustDeskUrl -OutFile $installer -UseBasicParsing
        Write-Verbose "Running silent install"
        $proc = Start-Process -FilePath $installer -ArgumentList '--silent-install' -PassThru
        $waited = 0
        while (-not (Test-Path "$env:ProgramFiles\RustDesk\rustdesk.exe") -and $waited -lt 180) {
            Start-Sleep -Seconds 2; $waited += 2
        }
        if (-not (Test-Path "$env:ProgramFiles\RustDesk\rustdesk.exe")) {
            Show-StepFail "Install timed out after 180s"
            throw "Install timeout"
        }
        Start-Sleep -Seconds 5
        Get-Process -Name 'rustdesk', 'RustDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
        $rustdeskExe = $rustdeskExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    Show-StepOk

    # Step 2: Write configs to all 3 locations
    Show-Step 2 5 "Configuring server connection..."
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
    foreach ($cfgDir in @(
        (Join-Path $env:APPDATA 'RustDesk\config'),
        'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config',
        'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config'
    )) {
        New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $cfgDir 'RustDesk2.toml'), $configToml, $utf8NoBom)
        Write-Verbose "Config written: $cfgDir\RustDesk2.toml"
    }
    Show-StepOk

    # Step 3: Start service so the password CLI can talk to it via IPC
    Show-Step 3 5 "Starting RustDesk service..."
    Set-Service -Name 'RustDesk' -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    $tries = 0
    while ($svc -and $svc.Status -ne 'Running' -and $tries -lt 6) { Start-Sleep -Seconds 2; $svc.Refresh(); $tries++ }
    if (-not $svc -or $svc.Status -ne 'Running') {
        Show-StepFail "Service didn't start (status: $($svc.Status))"
        throw "Service not running"
    }

    # Configure Windows Service Recovery: restart on crash with 5s delay (3 attempts).
    # This handles the "service crashes mid-session" case (when service still exists).
    & sc.exe failure RustDesk reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Write-Verbose "Service failure recovery: restart on crash, 3 attempts, 5s delay"

    # Watchdog scheduled task -- handles BOTH failure modes:
    #   (a) service exists but Status=Stopped -> Start-Service
    #   (b) service entry deleted entirely (RustDesk's "Stop Service" button calls
    #       `sc delete RustDesk` -- the service literally vanishes from Windows)
    #       In this case we need to RE-INSTALL the service via `rustdesk.exe --install-service`
    # Runs every 5 min as SYSTEM. We use schtasks.exe (legacy, universally reliable on
    # all Windows versions including Windows Server) instead of New-ScheduledTask cmdlets
    # which have flaky Register/Get visibility especially on Server SKUs.
    $watchdogName = 'LucidPC-RustDesk-Watchdog'
    $watchdogDir = Join-Path $env:ProgramData 'LucidPC'
    $watchdogPath = Join-Path $watchdogDir 'rustdesk-watchdog.ps1'

    # 1. Write the watchdog logic to disk (file-based; task references this file)
    New-Item -ItemType Directory -Force -Path $watchdogDir | Out-Null
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
    Set-Content -Path $watchdogPath -Value $watchdogScript -Encoding ASCII -Force

    # 2. Delete any prior task with this name (idempotent; ignores "doesn't exist")
    & schtasks.exe /Delete /TN $watchdogName /F *>$null

    # 3. Register the watchdog task via schtasks.exe -- runs every 5 min as SYSTEM
    $taskCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogPath`""
    $schOutput = & schtasks.exe /Create /TN $watchdogName /TR $taskCommand /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /F 2>&1
    $schExit = $LASTEXITCODE
    Write-Verbose "schtasks /Create exit=$schExit output: $schOutput"

    # 4. Verify the task exists
    & schtasks.exe /Query /TN $watchdogName *>$null
    $watchdogRegistered = ($LASTEXITCODE -eq 0)
    if (-not $watchdogRegistered) {
        Write-Verbose "Watchdog NOT visible via schtasks /Query after Create. Output was: $schOutput"
    }

    # Self-verify all three recovery layers are actually in place
    $script:recoveryStatus = @{
        AutoStart  = $false
        Recovery   = $false
        Watchdog   = $watchdogRegistered
    }
    $svcCheck = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if ($svcCheck -and $svcCheck.StartType -eq 'Automatic') { $script:recoveryStatus.AutoStart = $true }
    $failureOut = & sc.exe qfailure RustDesk 2>&1 | Out-String
    if ($failureOut -match 'RESTART') { $script:recoveryStatus.Recovery = $true }
    Write-Verbose ("Recovery verify: AutoStart={0} Recovery={1} Watchdog={2}" -f $script:recoveryStatus.AutoStart, $script:recoveryStatus.Recovery, $script:recoveryStatus.Watchdog)

    Show-StepOk

    # Step 4: Set permanent password as SYSTEM (one-shot scheduled task) -- skipped on re-run
    if ($skipPasswordStep) {
        Show-Step 4 5 "Permanent password (already set, skipping)..."
        Show-StepOk
    } else {
    Show-Step 4 5 "Setting permanent password..."
    $taskName = "lucidpc-pw-$(([guid]::NewGuid()).ToString('N').Substring(0,8))"
    $passwordSet = $false
    try {
        $action = New-ScheduledTaskAction -Execute $rustdeskExe -Argument "--password `"$PermanentPassword`""
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -RunLevel Highest -LogonType ServiceAccount
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 30)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $waited = 0
        while ((Get-ScheduledTask -TaskName $taskName).State -ne 'Ready' -and $waited -lt 30) {
            Start-Sleep -Seconds 1; $waited++
        }
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        Write-Verbose "Scheduled task LastTaskResult: $($taskInfo.LastTaskResult) (waited ${waited}s)"
        if ($taskInfo.LastTaskResult -eq 0) { $passwordSet = $true }
    } catch {
        Write-Verbose "Scheduled task method failed: $($_.Exception.Message)"
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Restart service so it picks up the password
    Stop-Service -Name 'RustDesk' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 6   # service needs time to receive IPC + write the toml back

    # Verify the password landed somewhere -- check ALL plausible config locations,
    # and retry a few times because the SYSTEM service writes asynchronously after IPC.
    $candidatePaths = @(
        'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config\RustDesk.toml',
        'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml',
        (Join-Path $env:APPDATA 'RustDesk\config\RustDesk.toml')
    )
    $verified = $false
    for ($vAttempt = 1; $vAttempt -le 5 -and -not $verified; $vAttempt++) {
        foreach ($p in $candidatePaths) {
            if (Test-Path $p) {
                $tomlContent = Get-Content $p -Raw -ErrorAction SilentlyContinue
                if ($tomlContent -match "password\s*=\s*'[^']+'") {
                    $verified = $true
                    Write-Verbose "Password verified in $p (attempt $vAttempt)"
                    break
                }
            }
        }
        if (-not $verified) { Start-Sleep -Seconds 2 }
    }

    if ($passwordSet -or $verified) {
        Show-StepOk
    } else {
        Show-StepFail "Could not confirm password was set; check Settings -> Security -> Password for unattended access"
    }
    }  # end if (-not $skipPasswordStep)

    # Step 5: Get device ID
    Show-Step 5 5 "Reading Device ID..."
    $deviceId = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        Start-Sleep -Seconds 2
        $deviceIdRaw = & $rustdeskExe --get-id 2>&1 | Out-String
        $match = [regex]::Match($deviceIdRaw, '\b\d{6,12}\b')
        if ($match.Success) { $deviceId = $match.Value; break }
    }
    # NOTE: deliberately NOT launching the RustDesk UI at the end of install --
    # the window steals keyboard focus from the cmd console and breaks the
    # "Press any key to close" prompt for several minutes. The service is already
    # running (device is registered with hbbs), and the Device ID is shown in
    # the output + clipboard + Desktop file -- no UI launch needed.
    if ($deviceId) {
        try { Set-Clipboard -Value $deviceId } catch { }
        Show-StepOk
    } else {
        Show-StepFail "ID not retrieved automatically; open RustDesk to see it"
    }

    # Final summary
    Write-Host ""
    Write-Host ""
    if ($deviceId) {
        Write-Host "  +------------------------------------+" -ForegroundColor Green
        Write-Host "  |                                    |" -ForegroundColor Green
        Write-Host "  |   Device ID:  $($deviceId.PadRight(21))|" -ForegroundColor Green
        Write-Host "  |                                    |" -ForegroundColor Green
        Write-Host "  +------------------------------------+" -ForegroundColor Green
        Write-Host "  Copied to clipboard." -ForegroundColor DarkGray
    } else {
        Write-Host "  Open RustDesk on this device to see the 9-digit ID at the top." -ForegroundColor Yellow
    }
    if ($pwWasGenerated) {
        Write-Host ""
        Write-Host "  Password (save now -- shown only once):" -ForegroundColor Yellow
        Write-Host "    $PermanentPassword" -ForegroundColor Yellow
    }
    Write-Host ""

    # Show recovery layer status (verified above)
    Write-Host "  Auto-recovery active:"
    $allOk = $true
    foreach ($pair in @(
        @{ Label = 'Service auto-start on Windows boot      '; Ok = $script:recoveryStatus.AutoStart },
        @{ Label = 'Service Recovery (auto-restart on crash)'; Ok = $script:recoveryStatus.Recovery },
        @{ Label = 'Watchdog task (every 5 min as SYSTEM)   '; Ok = $script:recoveryStatus.Watchdog }
    )) {
        if ($pair.Ok) {
            Write-Host "    [OK]  $($pair.Label)" -ForegroundColor Green
        } else {
            Write-Host "    [!!]  $($pair.Label)  -- not verified, see -Verbose for details" -ForegroundColor Yellow
            $allOk = $false
        }
    }
    if (-not $allOk) {
        Write-Host ""
        Write-Host "  One or more recovery layers did not verify. Server is still accessible," -ForegroundColor Yellow
        Write-Host "  but if RustDesk gets stopped you may need to manually intervene." -ForegroundColor Yellow
        Write-Host "  Re-run with -Verbose to see what failed." -ForegroundColor Yellow
    }
    Write-Host ""

    # Save device ID to a desktop file (no password)
    $detailsFile = Join-Path $env:USERPROFILE 'Desktop\LucidPC-DeviceID.txt'
    $detailsContent = "LucidPC RustDesk - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`nDevice ID: $(if ($deviceId) {$deviceId} else {'(open RustDesk to see)'})`r`n"
    try { Set-Content -Path $detailsFile -Value $detailsContent -Encoding ASCII -ErrorAction SilentlyContinue } catch { }

} catch {
    Show-Error $_.Exception.Message
    Write-Verbose $_.ScriptStackTrace
    Write-Host ""
    Write-Host "  Press any key to exit..." -NoNewline -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

Write-Host "  Press any key to close..." -NoNewline -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
exit 0
