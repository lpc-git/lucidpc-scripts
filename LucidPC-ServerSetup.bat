@echo off
REM LucidPC Remote Support -- one-file server setup.
REM
REM Download it, double-click it, done. Nothing to type and no flags to pass.
REM
REM This exists because the pre-configured RustDesk on lucidpc.com/connect is a
REM PORTABLE build: double-clicking it on a machine that already has an older
REM RustDesk installed does not upgrade anything. It just reports "Your
REM installation is lower version" and refuses to register. This wrapper always
REM installs or upgrades to the current release instead.
REM
REM Self-elevates, then runs LucidPC-ServerInstall.ps1 fetched through the GitHub
REM Contents API rather than raw.githubusercontent.com, so a fix is live the
REM moment it is pushed instead of after a 5-minute CDN cache.

title LucidPC Remote Support - Server Setup

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   Administrator permission is required. Approve the prompt...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    exit /b
)

echo.
echo   LucidPC Remote Support - Server Setup
echo   =====================================
echo.
echo   Installing or upgrading RustDesk to the current release.
echo   This replaces any older copy already on this machine.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }; $ErrorActionPreference='Stop'; try { $api='https://api.github.com/repos/lpc-git/lucidpc-scripts/contents/LucidPC-ServerInstall.ps1?ref=main'; $r=Invoke-RestMethod -Uri $api -Headers @{'Accept'='application/vnd.github.v3+json'} -UseBasicParsing -TimeoutSec 60; $src=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($r.content)); $f=Join-Path $env:TEMP 'LucidPC-ServerInstall.ps1'; [IO.File]::WriteAllText($f,$src,(New-Object Text.UTF8Encoding($false))); & $f } catch { Write-Host ''; Write-Host ('  Setup failed: ' + $_.Exception.Message) -ForegroundColor Red; Write-Host '  Call LucidPC on (212) 784-6219.' -ForegroundColor Yellow; exit 1 }"

if %errorlevel% neq 0 (
    echo.
    echo   Setup did not complete.
    echo.
)

pause
