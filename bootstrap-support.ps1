# LucidPC End-User Remote Support bootstrap
# Downloads the support setup files from GitHub via the API (not cached).
#
# Usage in PowerShell (any user, will prompt for admin if needed):
#   iex (irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/bootstrap-support.ps1)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Owner = 'lpc-git'
$Repo  = 'lucidpc-scripts'
$Branch = 'main'

$dest = Join-Path $env:TEMP 'lucidpc-support'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

function Get-RepoFile {
    param([string]$Path, [string]$OutFile)
    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/contents/$Path`?ref=$Branch"
    $response = Invoke-RestMethod -Uri $apiUrl -Headers @{'Accept'='application/vnd.github.v3+json'} -UseBasicParsing
    $content = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($response.content))
    [System.IO.File]::WriteAllText($OutFile, $content, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "Downloading LucidPC remote-support setup..." -ForegroundColor Cyan
Get-RepoFile -Path 'LucidPC-RemoteSupport.ps1' -OutFile (Join-Path $dest 'LucidPC-RemoteSupport.ps1')
Get-RepoFile -Path 'LucidPC-RemoteSupport.bat' -OutFile (Join-Path $dest 'LucidPC-RemoteSupport.bat')
Write-Host "Downloaded to $dest" -ForegroundColor Green

Write-Host "Launching..." -ForegroundColor Cyan
Start-Process -FilePath (Join-Path $dest 'LucidPC-RemoteSupport.bat')
