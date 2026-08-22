@echo off
REM LucidPC Remote Support -- QUICK connect. Portable. No install.
REM
REM Double-click. No administrator prompt, no service, nothing installed.
REM RustDesk opens already pointed at live.lucidpc.com and shows an ID and a
REM one-time password; read LucidPC both and the session starts.
REM
REM HOW IT DIFFERS FROM THE OTHER TWO FILES ON THIS RELEASE
REM   LucidPC-QuickConnect.bat  (this)  portable, no admin, nothing installed.
REM                                     For a quick session on a machine that
REM                                     does NOT already run RustDesk.
REM   LucidPC-Connect.bat               installs/upgrades + config, no password
REM                                     step. For a device that should stay
REM                                     reachable.
REM   LucidPC-ServerSetup.bat           full install, LucidPC sets the permanent
REM                                     per-device password. LucidPC runs this.
REM
REM WHY THIS WORKS WITHOUT ADMIN
REM   RustDesk's GUI process reads %APPDATA%\RustDesk\config\RustDesk2.toml, and
REM   writing there needs no elevation. So the settings land BEFORE the program
REM   starts and it comes up configured. The renamed-exe trick on /connect could
REM   not do this: its filename carries only host/key/api - never the relay, and
REM   WebSocket is not expressible in it at all.
REM
REM   Caveat, stated honestly: on a machine where RustDesk is ALREADY INSTALLED
REM   as a service, the service owns the config and will overwrite this. Use
REM   LucidPC-Connect.bat there instead.

title LucidPC Remote Support - Quick Connect

echo.
echo   LucidPC Remote Support
echo   ======================
echo.
echo   Starting RustDesk. Nothing is being installed.
echo.

set "RDDIR=%TEMP%\LucidPC-QuickConnect"
set "CFGDIR=%APPDATA%\RustDesk\config"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$ErrorActionPreference='Stop';" ^
 "try {" ^
 "  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12;" ^
 "  $cfgDir = Join-Path $env:APPDATA 'RustDesk\config';" ^
 "  New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null;" ^
 "  $toml = \"rendezvous_server = 'live.lucidpc.com:21116'`nnat_type = 1`nserial = 0`n`n[options]`nrelay-server = 'live.lucidpc.com'`nallow-websocket = 'Y'`napi-server = 'https://live.lucidpc.com'`ncustom-rendezvous-server = 'live.lucidpc.com'`nkey = 'hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k='`napprove-mode = 'password'`n\";" ^
 "  [IO.File]::WriteAllText((Join-Path $cfgDir 'RustDesk2.toml'), $toml, (New-Object Text.UTF8Encoding($false)));" ^
 "  $dir = Join-Path $env:TEMP 'LucidPC-QuickConnect';" ^
 "  New-Item -ItemType Directory -Force -Path $dir | Out-Null;" ^
 "  $exe = Join-Path $dir 'rustdesk.exe';" ^
 "  if (-not (Test-Path $exe)) {" ^
 "    Write-Host '  Downloading RustDesk...' -ForegroundColor DarkGray;" ^
 "    $url = $null;" ^
 "    try { $r = Invoke-RestMethod -Uri 'https://flow.lucidpc.com/webhook/rustdesk-latest' -UseBasicParsing -TimeoutSec 30; if ($r.url -match '^https://github\.com/rustdesk/rustdesk/releases/download/') { $url = $r.url } } catch { }" ^
 "    if (-not $url) { $url = 'https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.exe' }" ^
 "    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing -TimeoutSec 300;" ^
 "  }" ^
 "  Write-Host '  Opening RustDesk. Read LucidPC the ID and Password it shows.' -ForegroundColor Green;" ^
 "  Start-Process -FilePath $exe;" ^
 "} catch {" ^
 "  Write-Host '';" ^
 "  Write-Host ('  Could not start: ' + $_.Exception.Message) -ForegroundColor Red;" ^
 "  Write-Host '  Call LucidPC on (212) 784-6219.' -ForegroundColor Yellow;" ^
 "  exit 1;" ^
 "}"

if %errorlevel% neq 0 (
    echo.
    echo   Did not start. Call LucidPC on (212) 784-6219.
    echo.
    pause
    exit /b 1
)

echo.
echo   RustDesk should now be open. Read LucidPC the ID and the Password.
echo.
pause
