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

# PowerShell 7.4+ default: throws NativeCommandException when a native command exits
# non-zero AND ErrorActionPreference=Stop. We use sc.exe and schtasks.exe with patterns
# like "delete if exists, ignore if missing" -- those exit non-zero on missing items
# which is expected, not an error. Disable the new behavior to keep the legacy 5.1 semantics.
# (No-op on Windows PowerShell 5.1 since this variable doesn't exist there.)
$PSNativeCommandUseErrorActionPreference = $false

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

# Self-elevate to admin if needed. UAC prompt appears, user clicks Yes once,
# the elevated copy runs in a new window with the original parameters forwarded.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if (-not $PSCommandPath) {
        # Running via iex / piped -- no script file to re-launch. Bootstrap should be used instead.
        Show-Error "Run via the bootstrap one-liner so it can self-elevate, or save the script to a file first."
        Write-Host "  Bootstrap: iex (irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/bootstrap-server.ps1)" -ForegroundColor DarkGray
        Read-Host "`nPress Enter to exit"
        exit 1
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($GeneratePassword.IsPresent)            { $argList += '-GeneratePassword' }
    if ($ForcePassword.IsPresent)               { $argList += '-ForcePassword' }
    if ($SkipPassword.IsPresent)                { $argList += '-SkipPassword' }
    if (-not [string]::IsNullOrEmpty($PermanentPassword)) {
        $argList += '-PermanentPassword'; $argList += "`"$PermanentPassword`""
    }
    if ($GeneratedLength -ne 20)                { $argList += '-GeneratedLength'; $argList += $GeneratedLength }
    if ($VerbosePreference -eq 'Continue')      { $argList += '-Verbose' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit 0
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

    # Step 3: Ensure the Windows service exists, then start it.
    # Each sub-action wrapped so failures report which one specifically broke -- useful
    # when the user's Windows build has unusual restrictions (Defender quarantine, AppLocker,
    # disabled service install, etc.). Reports stay informative even with EAP=Stop.
    Show-Step 3 5 "Starting RustDesk service..."
    $stage = "init"
    try {
        $stage = "Get-Service initial check"
        $svc = $null
        try { $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue } catch { Write-Verbose "Initial Get-Service threw: $($_.Exception.Message)" }

        if (-not $svc) {
            $stage = "rustdesk.exe --install-service"
            Write-Verbose "RustDesk service not registered. rustdeskExe='$rustdeskExe'. Running --install-service."
            if (-not $rustdeskExe -or -not (Test-Path $rustdeskExe)) {
                Show-StepFail "rustdesk.exe path is invalid: '$rustdeskExe'"
                throw "rustdesk.exe missing"
            }
            $installOut = & $rustdeskExe --install-service 2>&1 | Out-String
            Write-Verbose "--install-service output: $installOut"
            Start-Sleep -Seconds 3
            $stage = "Get-Service after --install-service"
            try { $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue } catch { Write-Verbose "Post-install Get-Service threw: $($_.Exception.Message)" }
        }

        if (-not $svc) {
            Show-StepFail "Could not register RustDesk service. Output of --install-service: $installOut"
            throw "Service registration failed"
        }

        $stage = "Set-Service Automatic"
        Set-Service -Name 'RustDesk' -StartupType Automatic -ErrorAction SilentlyContinue

        if ($svc.Status -ne 'Running') {
            $stage = "Start-Service"
            Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
        }

        $stage = "wait for Running state"
        Start-Sleep -Seconds 4
        $svc.Refresh()
        $tries = 0
        while ($svc.Status -ne 'Running' -and $tries -lt 6) { Start-Sleep -Seconds 2; $svc.Refresh(); $tries++ }

        if ($svc.Status -ne 'Running') {
            Show-StepFail "Service registered but didn't start (status: $($svc.Status))"
            throw "Service not running"
        }
    } catch {
        # Add stage context to whatever bubbled up
        if ($_.Exception.Message -notmatch 'rustdesk\.exe missing|Service registration failed|Service not running') {
            Show-StepFail "stage=[$stage] $($_.Exception.Message)"
        }
        throw
    }

    # Auto-recovery layers -- each wrapped so a single failure doesn't abort the whole install.
    # The script should ALWAYS reach Steps 4 and 5 even if recovery setup hits environmental
    # quirks (AV-mediated stream interception, weird Windows policies, etc.). Layers that
    # don't apply correctly get reported as [!!] in the final summary.
    $script:recoveryStatus = @{ AutoStart = $false; Recovery = $false; Watchdog = $false }

    # Layer 1: Service auto-start verification (we already set it via Set-Service above)
    try {
        $svcCheck = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
        if ($svcCheck -and $svcCheck.StartType -eq 'Automatic') { $script:recoveryStatus.AutoStart = $true }
    } catch { Write-Verbose "AutoStart verify threw: $($_.Exception.Message)" }

    # Layer 2: Service Recovery -- restart on crash with 5s delay (3 attempts)
    try {
        # cmd.exe /c form to fully decouple from PS error stream interpretation
        cmd.exe /c "sc failure RustDesk reset= 86400 actions= restart/5000/restart/5000/restart/5000 >nul 2>&1"
        $failureOut = (cmd.exe /c "sc qfailure RustDesk 2>&1") 2>$null | Out-String
        if ($failureOut -match 'RESTART') { $script:recoveryStatus.Recovery = $true }
        Write-Verbose "Service Recovery configured (failure dump len=$($failureOut.Length))"
    } catch { Write-Verbose "Recovery setup threw: $($_.Exception.Message)" }

    # Layer 3: Watchdog scheduled task -- runs every 5 min as SYSTEM. Handles both
    # service-stopped and service-deleted (RustDesk "Stop Service" button calls sc delete).
    try {
        $watchdogName = 'LucidPC-RustDesk-Watchdog'
        $watchdogDir = Join-Path $env:ProgramData 'LucidPC'
        $watchdogPath = Join-Path $watchdogDir 'rustdesk-watchdog.ps1'

        if (-not (Test-Path $watchdogDir)) { New-Item -ItemType Directory -Force -Path $watchdogDir | Out-Null }
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

        # Delete prior task if present, then create. cmd.exe /c form so PowerShell's error
        # stream handling never sees the `ERROR: The system cannot find the file specified.`
        # output that schtasks produces when the target doesn't exist.
        cmd.exe /c "schtasks /Delete /TN ""$watchdogName"" /F >nul 2>&1"
        $taskCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogPath`""
        cmd.exe /c "schtasks /Create /TN ""$watchdogName"" /TR ""$taskCommand"" /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /F >nul 2>&1"
        # Verify
        cmd.exe /c "schtasks /Query /TN ""$watchdogName"" >nul 2>&1"
        if ($LASTEXITCODE -eq 0) { $script:recoveryStatus.Watchdog = $true }
        Write-Verbose "Watchdog registered: $($script:recoveryStatus.Watchdog)"
    } catch { Write-Verbose "Watchdog setup threw: $($_.Exception.Message)" }

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
        # CRITICAL: -Verbose:$false suppresses the cmdlet's automatic XML dump which would
        # otherwise leak the password (which is in $action's arguments) to verbose output.
        # Same for Get-ScheduledTask / Get-ScheduledTaskInfo / Unregister -- they can dump
        # task definitions including the original arguments.
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -Verbose:$false | Out-Null
        Start-ScheduledTask -TaskName $taskName -Verbose:$false
        $waited = 0
        while ((Get-ScheduledTask -TaskName $taskName -Verbose:$false).State -ne 'Ready' -and $waited -lt 30) {
            Start-Sleep -Seconds 1; $waited++
        }
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -Verbose:$false
        Write-Verbose "Scheduled password-set task LastTaskResult: $($taskInfo.LastTaskResult) (waited ${waited}s)"
        if ($taskInfo.LastTaskResult -eq 0) { $passwordSet = $true }
    } catch {
        Write-Verbose "Scheduled task method failed: $($_.Exception.Message)"
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue -Verbose:$false
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
