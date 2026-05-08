@echo off
REM LucidPC Remote Support - launcher
REM Double-click this file to install + configure RustDesk for LucidPC support.

setlocal

REM Find the .ps1 next to this .bat
set "SCRIPT=%~dp0LucidPC-RemoteSupport.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Could not find LucidPC-RemoteSupport.ps1 in the same folder.
    echo Please make sure both files are extracted together.
    pause
    exit /b 1
)

REM Run the PowerShell script with execution policy bypass for this session only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

endlocal
