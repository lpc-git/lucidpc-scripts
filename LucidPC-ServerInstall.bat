@echo off
REM LucidPC Server Install - one-click unattended-access setup
REM Double-click this. It self-elevates to admin and runs the .ps1.
REM
REM At the password prompt:
REM   - Open your password manager on your tech machine
REM   - Copy your shared LucidPC RustDesk password
REM   - Paste into the masked prompt (Ctrl+V or right-click)
REM   - Paste again to confirm
REM   - Done

setlocal

net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "SCRIPT=%~dp0LucidPC-ServerInstall.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Could not find LucidPC-ServerInstall.ps1 in the same folder.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

endlocal
exit
