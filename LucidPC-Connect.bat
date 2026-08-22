@echo off
REM LucidPC Remote Support -- quick connect for a NEW device.
REM
REM Download it, double-click it, approve the one admin prompt. It installs or
REM upgrades RustDesk with LucidPC's server settings (ID, relay, key, WebSocket)
REM and starts it. NO PASSWORD IS EVER ASKED FOR - this on purpose:
REM
REM   Stage 1 (this file):  the device comes up configured and registers with
REM                         live.lucidpc.com. Whoever is at the machine reads
REM                         LucidPC the ID and the one-time code on screen.
REM   Stage 2 (LucidPC):    once connected, LucidPC runs the full setup
REM                         (LucidPC-ServerSetup.bat) through the session and
REM                         sets the permanent per-device password themselves.
REM
REM So the support password never has to be spoken, typed or sent to anyone.
REM
REM Same delivery as ServerSetup: the install script is fetched through the
REM GitHub Contents API, so a pushed fix is live immediately, not after a CDN
REM cache. The only difference is the -SkipPassword switch.

title LucidPC Remote Support - Quick Connect

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   Administrator permission is required. Approve the prompt...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    exit /b
)

echo.
echo   LucidPC Remote Support - Quick Connect
echo   ======================================
echo.
echo   Setting this computer up to reach LucidPC support.
echo   You will not be asked for any password.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }; $ErrorActionPreference='Stop'; try { $api='https://api.github.com/repos/lpc-git/lucidpc-scripts/contents/LucidPC-ServerInstall.ps1?ref=main'; $r=Invoke-RestMethod -Uri $api -Headers @{'Accept'='application/vnd.github.v3+json'} -UseBasicParsing -TimeoutSec 60; $src=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($r.content)); $f=Join-Path $env:TEMP 'LucidPC-ServerInstall.ps1'; [IO.File]::WriteAllText($f,$src,(New-Object Text.UTF8Encoding($false))); & $f -SkipPassword } catch { Write-Host ''; Write-Host ('  Setup failed: ' + $_.Exception.Message) -ForegroundColor Red; Write-Host '  Call LucidPC on (212) 784-6219.' -ForegroundColor Yellow; exit 1 }"

if %errorlevel% neq 0 (
    echo.
    echo   Setup did not complete.
    echo.
)

echo.
echo   Done. Open RustDesk and read LucidPC the ID and the password shown in the window.
echo.
pause
