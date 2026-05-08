# LucidPC End-User Remote Support bootstrap
# For end users who need to give LucidPC tech support remote control of their PC.
# Usage in PowerShell (any user, will prompt for admin if needed):
#
#   iex (irm https://raw.githubusercontent.com/<USER>/<REPO>/main/bootstrap-support.ps1)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseUrl = 'https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main'

$dest = Join-Path $env:TEMP 'lucidpc-support'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

Write-Host "Downloading LucidPC remote-support setup..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "$BaseUrl/LucidPC-RemoteSupport.ps1" -OutFile (Join-Path $dest 'LucidPC-RemoteSupport.ps1') -UseBasicParsing
Invoke-WebRequest -Uri "$BaseUrl/LucidPC-RemoteSupport.bat" -OutFile (Join-Path $dest 'LucidPC-RemoteSupport.bat') -UseBasicParsing
Write-Host "Downloaded to $dest" -ForegroundColor Green

Write-Host "Launching..." -ForegroundColor Cyan
Start-Process -FilePath (Join-Path $dest 'LucidPC-RemoteSupport.bat')
