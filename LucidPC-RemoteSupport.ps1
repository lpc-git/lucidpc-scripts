# LucidPC Remote Support -- one-click setup
# This script installs RustDesk and configures it to connect to LucidPC's support servers.
# After running, just open RustDesk and tell your support technician the 9-digit ID and password shown.

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "[!!] $msg" -ForegroundColor Red }

# --- Configuration (LucidPC support server) ---
$idServer    = 'live.lucidpc.com'
$relayServer = 'live.lucidpc.com'
$apiServer   = 'https://live.lucidpc.com'
$publicKey   = 'hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k='
$rustdeskUrl = 'https://github.com/rustdesk/rustdesk/releases/latest/download/rustdesk-1.4.6-x86_64.exe'
# ----------------------------------------------

Clear-Host
Write-Host "================================================================" -ForegroundColor White
Write-Host "  LucidPC Remote Support -- Setup" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-Host "  This will install RustDesk and prepare it for support sessions."
Write-Host "  Your screen will not be shared until you give the support tech"
Write-Host "  your ID and password (shown by RustDesk after setup)."
Write-Host ""

try {
    # 1. Stop any running RustDesk so we can safely write config
    Write-Step "Closing any open RustDesk windows..."
    Get-Process -Name 'rustdesk', 'RustDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # 2. Download and install RustDesk if needed
    $installer = Join-Path $env:TEMP 'rustdesk-installer.exe'
    $rustdeskExePaths = @(
        "$env:ProgramFiles\RustDesk\rustdesk.exe",
        "$env:ProgramFiles\RustDesk\RustDesk.exe"
    )
    $rustdeskExe = $rustdeskExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $rustdeskExe) {
        Write-Step "Downloading RustDesk... (~50 MB, takes ~30 seconds)"
        Invoke-WebRequest -Uri $rustdeskUrl -OutFile $installer -UseBasicParsing
        Write-Ok "Downloaded"

        Write-Step "Installing RustDesk (silent)..."
        $proc = Start-Process -FilePath $installer -ArgumentList '--silent-install' -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Err "Installer returned exit code $($proc.ExitCode). You may need to run as Administrator."
            Write-Host "Manual fallback: re-run this script as Administrator (right-click -> Run as Administrator)." -ForegroundColor Yellow
            Read-Host "Press Enter to continue anyway"
        }
        $rustdeskExe = $rustdeskExePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $rustdeskExe) {
            Write-Err "Could not find rustdesk.exe after install. Run this script as Administrator."
            Read-Host "Press Enter to exit"
            exit 1
        }
        Write-Ok "Installed at $rustdeskExe"
    } else {
        Write-Ok "RustDesk already installed at $rustdeskExe"
    }

    # 3. Write the RustDesk config file with LucidPC server settings
    Write-Step "Configuring RustDesk for LucidPC support servers..."
    $configDir = Join-Path $env:APPDATA 'RustDesk\config'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

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
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $configDir 'RustDesk2.toml'), $configToml, $utf8NoBom)
    Write-Ok "Config written to $configDir\RustDesk2.toml"

    # 4. Stop RustDesk service if running so it picks up the new config on next launch
    Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue | Start-Service -ErrorAction SilentlyContinue

    # 5. Put the encoded import-string on clipboard as a fallback
    try {
        $cfgObj = [ordered]@{ host = $idServer; relay = $relayServer; api = $apiServer; key = $publicKey }
        $cfgJson = $cfgObj | ConvertTo-Json -Compress
        $cfgB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cfgJson))
        $cfgArr = $cfgB64.ToCharArray(); [Array]::Reverse($cfgArr)
        $importString = -join $cfgArr
        Set-Clipboard -Value $importString
        Write-Ok "Backup support code copied to clipboard (use RustDesk -> three-dots menu -> Network -> Import if needed)"
    } catch { }

    # 6. Launch RustDesk
    Write-Step "Launching RustDesk..."
    Start-Process -FilePath $rustdeskExe
    Start-Sleep -Seconds 3

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  DONE! RustDesk is now open and connected to LucidPC servers." -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next steps:"
    Write-Host "   1. RustDesk is showing a 9-digit ID number and a password."
    Write-Host "   2. Tell your LucidPC support technician:"
    Write-Host "        - The ID number (top of RustDesk window)"
    Write-Host "        - The password (right below the ID)"
    Write-Host "   3. They will connect, fix the issue, and disconnect when done."
    Write-Host ""
    Write-Host "  You do NOT need to enter anything -- just read out the numbers."
    Write-Host ""

    Read-Host "Press Enter to close this window"

} catch {
    Write-Err $_.Exception.Message
    Write-Host "Details: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Write-Host "If this keeps failing, contact LucidPC support directly." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}
