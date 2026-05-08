# LucidPC RustDesk Setup -- unattended-access install for Windows
#
# Run as Administrator. After it finishes, you can connect to this device from your
# LucidPC tech client using the 9-digit Device ID and the password you set.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\LucidPC-ServerInstall.ps1
# Or double-click LucidPC-ServerInstall.bat (self-elevates and prompts for password).
#
# For diagnostic output:
#   powershell -ExecutionPolicy Bypass -File .\LucidPC-ServerInstall.ps1 -Verbose

[CmdletBinding()]
param(
    [string]$PermanentPassword = '',
    [switch]$GeneratePassword,
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

# --- Resolve permanent password (silent on success) ---
$pwWasGenerated = $false
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
    Write-Host "  Paste the LucidPC support password (input is hidden)." -ForegroundColor DarkGray
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
    # Runs every 5 min as SYSTEM so it has admin/SCM privileges without any UAC prompt.
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
    Write-Verbose "Watchdog task '$watchdogName' registered (handles both stopped AND deleted service)"

    # Self-verify all three recovery layers are actually in place
    $script:recoveryStatus = @{
        AutoStart  = $false
        Recovery   = $false
        Watchdog   = $false
    }
    $svcCheck = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if ($svcCheck -and $svcCheck.StartType -eq 'Automatic') { $script:recoveryStatus.AutoStart = $true }
    $failureOut = & sc.exe qfailure RustDesk 2>&1 | Out-String
    if ($failureOut -match 'RESTART') { $script:recoveryStatus.Recovery = $true }
    if (Get-ScheduledTask -TaskName $watchdogName -ErrorAction SilentlyContinue) { $script:recoveryStatus.Watchdog = $true }
    Write-Verbose ("Recovery verify: AutoStart={0} Recovery={1} Watchdog={2}" -f $script:recoveryStatus.AutoStart, $script:recoveryStatus.Recovery, $script:recoveryStatus.Watchdog)

    Show-StepOk

    # Step 4: Set permanent password as SYSTEM (one-shot scheduled task)
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
        while ((Get-ScheduledTask -TaskName $taskName).State -ne 'Ready' -and $waited -lt 15) {
            Start-Sleep -Seconds 1; $waited++
        }
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        Write-Verbose "Scheduled task LastTaskResult: $($taskInfo.LastTaskResult)"
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
    Start-Sleep -Seconds 4

    # Verify by checking the SYSTEM-profile config has the password field
    $sysCfgFile = 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config\RustDesk.toml'
    $verified = $false
    if (Test-Path $sysCfgFile) {
        $tomlContent = Get-Content $sysCfgFile -Raw -ErrorAction SilentlyContinue
        if ($tomlContent -match "password\s*=\s*'[^']+'") { $verified = $true }
    }
    Write-Verbose "Password verification (config file has password field): $verified"
    if ($passwordSet -or $verified) { Show-StepOk } else {
        Show-Step 4 5 "Setting permanent password..." # rewrite line in case of partial output
        Show-StepFail "Could not confirm password was set; check Settings -> Security -> Password for unattended access"
    }

    # Step 5: Get device ID
    Show-Step 5 5 "Reading Device ID..."
    $deviceId = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        Start-Sleep -Seconds 2
        $deviceIdRaw = & $rustdeskExe --get-id 2>&1 | Out-String
        $match = [regex]::Match($deviceIdRaw, '\b\d{6,12}\b')
        if ($match.Success) { $deviceId = $match.Value; break }
    }
    Start-Process -FilePath $rustdeskExe -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
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
    Read-Host "`n  Press Enter to exit"
    exit 1
}

Read-Host "  Press Enter to close"
