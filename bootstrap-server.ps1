# LucidPC Server Install bootstrap
# Downloads the install scripts from GitHub and runs them as Administrator.
# Uses the GitHub API (not raw URL) so updates propagate instantly without 5-min CDN cache.
#
# Usage on any new Windows server (in admin PowerShell):
#   iex (irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/bootstrap-server.ps1)
#
# Note: this bootstrap file itself is fetched via raw URL (and may be cached 5 min).
# But the actual install scripts it downloads use the API for cache-free delivery.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Owner = 'lpc-git'
$Repo  = 'lucidpc-scripts'
$Branch = 'main'

$dest = Join-Path $env:TEMP 'lucidpc-install'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

function Get-RepoFile {
    param([string]$Path, [string]$OutFile)
    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/contents/$Path`?ref=$Branch"
    $response = Invoke-RestMethod -Uri $apiUrl -Headers @{'Accept'='application/vnd.github.v3+json'} -UseBasicParsing
    $content = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($response.content))
    [System.IO.File]::WriteAllText($OutFile, $content, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "Downloading LucidPC server-install scripts (via GitHub API, not cached)..." -ForegroundColor Cyan
Get-RepoFile -Path 'LucidPC-ServerInstall.ps1' -OutFile (Join-Path $dest 'LucidPC-ServerInstall.ps1')
Get-RepoFile -Path 'LucidPC-ServerInstall.bat' -OutFile (Join-Path $dest 'LucidPC-ServerInstall.bat')
Write-Host "Downloaded to $dest" -ForegroundColor Green

Write-Host "Launching installer (will self-elevate to admin)..." -ForegroundColor Cyan
Start-Process -FilePath (Join-Path $dest 'LucidPC-ServerInstall.bat') -Verb RunAs
