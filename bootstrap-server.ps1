# LucidPC Server Install bootstrap
# Downloads the install scripts from this GitHub repo and runs them as Administrator.
# Usage on any new Windows server (in admin PowerShell):
#
#   iex (irm https://raw.githubusercontent.com/<USER>/<REPO>/main/bootstrap-server.ps1)
#
# Replace <USER>/<REPO> with your actual GitHub repo (e.g. lucidpc/scripts).

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Edit this URL after you publish to GitHub
$BaseUrl = 'https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main'

$dest = Join-Path $env:TEMP 'lucidpc-install'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

Write-Host "Downloading LucidPC server-install scripts..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "$BaseUrl/LucidPC-ServerInstall.ps1" -OutFile (Join-Path $dest 'LucidPC-ServerInstall.ps1') -UseBasicParsing
Invoke-WebRequest -Uri "$BaseUrl/LucidPC-ServerInstall.bat" -OutFile (Join-Path $dest 'LucidPC-ServerInstall.bat') -UseBasicParsing
Write-Host "Downloaded to $dest" -ForegroundColor Green

Write-Host "Launching installer (will self-elevate to admin)..." -ForegroundColor Cyan
Start-Process -FilePath (Join-Path $dest 'LucidPC-ServerInstall.bat') -Verb RunAs
