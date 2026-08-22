# LucidPC Remote Support -- one-click setup for an end-user PC
# After this runs, just tell your LucidPC technician the 9-digit ID and password
# shown by the RustDesk window that opens.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
# Opt out of PS7.4+ throwing on native commands' non-zero exits (no-op on PS5.1)
$PSNativeCommandUseErrorActionPreference = $false
# GitHub requires TLS 1.2+; some Windows PowerShell setups don't offer it by default
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# --- LucidPC support server config ---
$idServer    = 'live.lucidpc.com'
$relayServer = 'live.lucidpc.com'
$apiServer   = 'https://live.lucidpc.com'
$publicKey   = 'hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k='
# Fallback installer if the GitHub API can't be reached. Full-version URLs stay
# downloadable forever; only the version goes stale. Never use a
# releases/latest/download/ URL with a versioned filename -- it 404s as soon as
# RustDesk publishes a newer release (bit us at 1.4.6 -> 1.4.9, 2026-08-11).
$rustdeskFallbackUrl = 'https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.exe'
# --------------------------------------

function Show-Step {
    param([int]$Num, [int]$Total, [string]$Label)
    $line = ("  Step $Num of $Total ".PadRight(15)) + $Label.PadRight(40)
    Write-Host -NoNewline $line
}
function Show-StepOk { Write-Host "done" -ForegroundColor Green }
function Show-Error { param([string]$msg) Write-Host "`n  Error: $msg" -ForegroundColor Red }

function Get-RustDeskInstallerUrl {
    # Source 1: LucidPC's own resolver (n8n on flow.lucidpc.com). Always warm,
    # cached server-side, never rate-limited. Only URLs pointing at RustDesk's
    # official GitHub releases are accepted, so the resolver can't redirect
    # installs anywhere else.
    try {
        $resolved = Invoke-RestMethod -Uri 'https://flow.lucidpc.com/webhook/rustdesk-latest' -UseBasicParsing -TimeoutSec 10
        if ($resolved -and $resolved.url -match '^https://github\.com/rustdesk/rustdesk/releases/download/') { return $resolved.url }
        Write-Verbose "LucidPC resolver returned no usable URL; trying GitHub API"
    } catch {
        Write-Verbose "LucidPC resolver unreachable ($($_.Exception.Message)); trying GitHub API"
    }
    # Source 2: GitHub releases API directly (rate-limited to 60/hr per IP).
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -Headers @{ 'Accept' = 'application/vnd.github.v3+json' } -UseBasicParsing -TimeoutSec 30
        $asset = $release.assets | Where-Object { $_.name -match '^rustdesk-[0-9][0-9.]*-x86_64\.exe$' } | Select-Object -First 1
        if ($asset -and $asset.browser_download_url) { return $asset.browser_download_url }
        Write-Verbose "No x86_64 exe asset found in latest release; using fallback URL"
    } catch {
        Write-Verbose "GitHub API lookup failed ($($_.Exception.Message)); using fallback URL"
    }
    # Source 3: pinned full-version URL. Never 404s, only goes stale.
    return $rustdeskFallbackUrl
}

# All three resolver tiers return a URL shaped like
#   https://github.com/rustdesk/rustdesk/releases/download/<ver>/rustdesk-<ver>-x86_64.exe
# so the version we are ABOUT to install can always be read straight off the URL.
function Get-RustDeskVersionFromUrl {
    param([string]$Url)
    if ($Url -match '/releases/download/([0-9]+(?:\.[0-9]+)*)/') { return $Matches[1] }
    return ''
}

function Get-InstalledRustDeskVersion {
    param([string]$ExePath)
    if ([string]::IsNullOrWhiteSpace($ExePath) -or -not (Test-Path $ExePath)) { return '' }
    try {
        $info = (Get-Item $ExePath).VersionInfo
        foreach ($candidate in @($info.ProductVersion, $info.FileVersion)) {
            if ($candidate -and ($candidate -match '([0-9]+(?:\.[0-9]+)+)')) { return $Matches[1] }
        }
    } catch {
        Write-Verbose "Could not read version from ${ExePath}: $($_.Exception.Message)"
    }
    return ''
}

# Normalise to exactly three components before comparing. Without this,
# [version]'1.4.9' -lt [version]'1.4.9.0' is TRUE (Revision -1 vs 0), which would
# make an already-current machine reinstall on every single run.
function ConvertTo-RdVersion {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    if ($Raw -notmatch '([0-9]+(?:\.[0-9]+)*)') { return $null }
    $parts = $Matches[1].Split('.')
    $nums  = @(0, 0, 0)
    for ($i = 0; $i -lt 3; $i++) {
        if ($i -lt $parts.Count) {
            try { $nums[$i] = [int]$parts[$i] } catch { $nums[$i] = 0 }
        }
    }
    return [version]("{0}.{1}.{2}" -f $nums[0], $nums[1], $nums[2])
}

Clear-Host
Write-Host ""
Write-Host "  LucidPC Remote Support" -ForegroundColor White
Write-Host "  ======================" -ForegroundColor White
Write-Host ""
Write-Host "  This will set up RustDesk so your LucidPC technician can help you." -ForegroundColor DarkGray
Write-Host "  Your screen is NOT shared until you give them the ID and password." -ForegroundColor DarkGray
Write-Host ""

try {
    # Step 1: Stop RustDesk if open
    Show-Step 1 4 "Preparing..."
    Get-Process -Name 'rustdesk', 'RustDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Show-StepOk

    # Step 2: Install RustDesk, or upgrade it when the installed copy is older
    # than the current release. Checking only "is it present" left every machine
    # that had ever run RustDesk stuck on its original version -- which is what
    # produces "Your installation is lower version" and a client that will not
    # register. A support call is exactly when that must not happen.
    $rustdeskExePaths = @("$env:ProgramFiles\RustDesk\rustdesk.exe", "$env:ProgramFiles\RustDesk\RustDesk.exe")
    $rustdeskExe = $rustdeskExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    $rustdeskUrl = Get-RustDeskInstallerUrl
    $latestVersion    = ConvertTo-RdVersion (Get-RustDeskVersionFromUrl $rustdeskUrl)
    $installedVersion = ConvertTo-RdVersion (Get-InstalledRustDeskVersion $rustdeskExe)

    $needsInstall = $false
    $installVerb  = 'Installing'
    if (-not $rustdeskExe) {
        $needsInstall = $true
    } elseif ($null -eq $installedVersion) {
        $needsInstall = $true
        $installVerb  = 'Repairing'
    } elseif ($null -ne $latestVersion -and $installedVersion -lt $latestVersion) {
        $needsInstall = $true
        $installVerb  = 'Updating'
    }

    if ($needsInstall) {
        Show-Step 2 4 "$installVerb RustDesk..."
        $installer = Join-Path $env:TEMP 'rustdesk-installer.exe'
        Write-Verbose "Downloading $rustdeskUrl"
        Invoke-WebRequest -Uri $rustdeskUrl -OutFile $installer -UseBasicParsing
        $proc = Start-Process -FilePath $installer -ArgumentList '--silent-install' -PassThru

        # An upgrade cannot be detected by "does the exe exist" -- it already does.
        $waited  = 0
        $settled = $false
        while ($waited -lt 180) {
            Start-Sleep -Seconds 2; $waited += 2
            $currentExe = $rustdeskExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $currentExe) { continue }
            if ($null -eq $latestVersion) { $settled = $true; break }
            $currentVersion = ConvertTo-RdVersion (Get-InstalledRustDeskVersion $currentExe)
            if ($null -ne $currentVersion -and $currentVersion -ge $latestVersion) { $settled = $true; break }
        }
        if (-not $settled -and -not ($rustdeskExePaths | Where-Object { Test-Path $_ })) {
            Write-Host "FAILED" -ForegroundColor Red
            Show-Error "Install timed out. You may need to run as Administrator."
            Read-Host "`n  Press Enter to exit"
            exit 1
        }
        Start-Sleep -Seconds 5
        Get-Process -Name 'rustdesk', 'RustDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
        $rustdeskExe = $rustdeskExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    } else {
        Show-Step 2 4 "RustDesk already current..."
    }
    Show-StepOk

    # Step 3: Configure RustDesk for LucidPC servers
    Show-Step 3 4 "Connecting to LucidPC servers..."
    $configToml = @"
rendezvous_server = '${idServer}:21116'
nat_type = 1
serial = 0

[options]
relay-server = '$relayServer'
api-server = '$apiServer'
custom-rendezvous-server = '$idServer'
key = '$publicKey'
"@
    # Write to ALL THREE config locations, not just the user one.
    #
    # This script restarts the RustDesk SERVICE a few lines below, and the service
    # runs as LocalSystem - so it reads the SYSTEM copy, never %APPDATA%. Writing
    # only the user copy meant the restart picked up the OLD settings, and worse:
    # RustDesk's ipc::get_options_() pulls options FROM the service and overwrites
    # the user copy with them, so a correct user-side write gets silently reverted
    # on any machine where the service exists.
    #
    # The two SYSTEM paths need elevation. An attended, non-admin support session
    # legitimately cannot write them - and does not need to, because with no
    # service installed the GUI process reads the user copy. So this is
    # best-effort per directory rather than a hard failure.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $wrote = 0
    foreach ($cfgDir in @(
        (Join-Path $env:APPDATA 'RustDesk\config'),
        'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config',
        'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config'
    )) {
        try {
            New-Item -ItemType Directory -Force -Path $cfgDir -ErrorAction Stop | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $cfgDir 'RustDesk2.toml'), $configToml, $utf8NoBom)
            $wrote++
        } catch {
            Write-Verbose "Could not write $cfgDir (needs Administrator): $($_.Exception.Message)"
        }
    }
    if ($wrote -eq 0) { Show-Error "Could not write the RustDesk configuration anywhere." }

    # Restart service if it exists, so it picks up the config
    Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue | Start-Service -ErrorAction SilentlyContinue

    # Also put the import code on clipboard as a fallback
    try {
        $cfgObj = [ordered]@{ host = $idServer; relay = $relayServer; api = $apiServer; key = $publicKey }
        $cfgJson = $cfgObj | ConvertTo-Json -Compress
        $cfgB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cfgJson))
        $cfgArr = $cfgB64.ToCharArray(); [Array]::Reverse($cfgArr)
        Set-Clipboard -Value (-join $cfgArr)
    } catch { }
    Show-StepOk

    # Step 4: Launch RustDesk
    Show-Step 4 4 "Opening RustDesk..."
    Start-Process -FilePath $rustdeskExe
    Start-Sleep -Seconds 3
    Show-StepOk

    Write-Host ""
    Write-Host ""
    Write-Host "  Setup complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Look at the RustDesk window. Tell your technician:" -ForegroundColor White
    Write-Host "     - The 9-digit ID number"
    Write-Host "     - The password under the ID"
    Write-Host ""
    Write-Host "  Your screen is not shared until they connect with that info." -ForegroundColor DarkGray
    Write-Host ""

} catch {
    Show-Error $_.Exception.Message
    Write-Verbose $_.ScriptStackTrace
    Read-Host "`n  Press Enter to exit"
    exit 1
}

Read-Host "  Press Enter to close"
