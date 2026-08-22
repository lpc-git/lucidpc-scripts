# LucidPC — switch a machine between WebSocket and native RustDesk transport.
#
# WHY THIS EXISTS
#   You cannot change RustDesk's transport from inside a RustDesk session:
#     * the settings UI is locked while a session is active, and
#     * applying the change requires restarting the RustDesk service, which
#       kills the very session you are working through.
#   Running the full installer has the same problem, plus it ends on a
#   "press any key" prompt that would hang a scheduled run.
#
#   So this does the minimum: stop the service, write the option, start it.
#   With -Detached it schedules ITSELF to run 60 seconds later as SYSTEM and
#   returns immediately, so you can disconnect and let it complete without you.
#
# ☠ WEBSOCKET IS ALL-OR-NOTHING ACROSS THE FLEET
#   A WebSocket peer and a native TCP/UDP peer CANNOT connect to each other -
#   the server refuses the relay ("WebSocket Mode and native TCP/UDP cannot
#   share a relay session", upstream #290). Converting a machine MOVES it to
#   the other island; it does not add it to the current one. A machine you
#   convert while your own workstation is still native becomes unreachable
#   until you convert yourself too.
#
# ☠ WHY THE SERVICE MUST BE STOPPED FIRST
#   RustDesk rewrites its config file when the service shuts down. Editing the
#   TOML while it is running gets silently clobbered on the next stop. Stop,
#   write, start - in that order.
#
# USAGE
#   Run in an ELEVATED PowerShell on the target machine.
#
#   Over a RustDesk session (the normal case) - schedules and returns:
#       .\LucidPC-SetWebSocket.ps1 -On -Detached
#     ...then disconnect. It converts ~60s later.
#
#   Locally, at the console:
#       .\LucidPC-SetWebSocket.ps1 -On
#       .\LucidPC-SetWebSocket.ps1 -Off
#
#   One-liner over a session:
#     iex "& { $(irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-SetWebSocket.ps1) } -On -Detached"

[CmdletBinding()]
param(
    [switch]$On,
    [switch]$Off,
    [switch]$Detached,
    [int]$DelaySeconds = 60
)

$ErrorActionPreference = 'Stop'

if ($On -and $Off) { throw "Choose -On or -Off, not both." }
if (-not $On -and -not $Off) { throw "Specify -On or -Off." }
$want = if ($On) { 'Y' } else { $null }   # $null = remove the line, which is what RustDesk itself does for 'off'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) { throw "Run this in an ELEVATED PowerShell (Run as Administrator)." }

# ---------------------------------------------------------------- detached ---
if ($Detached) {
    # Re-schedule this same script as SYSTEM, shortly in the future, so the work
    # happens after the RustDesk session that launched it has gone away.
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) {
        # Invoked via iex - persist a copy so the scheduled task has something to run.
        $self = Join-Path $env:ProgramData 'LucidPC-SetWebSocket.ps1'
        $MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text |
            Set-Content -LiteralPath $self -Encoding UTF8
    }
    $flag = if ($On) { '-On' } else { '-Off' }
    $when = (Get-Date).AddSeconds($DelaySeconds)
    $task = 'LucidPC-SetWebSocket'
    $cmd  = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$self`" $flag"

    # ☠ /SD is REQUIRED. /SC ONCE with only /ST assumes TODAY, so a delay that
    #   crosses midnight schedules the task in the past and it never fires.
    #   /SD must use the CURRENT CULTURE's short-date pattern - schtasks parses
    #   it by locale, so a hardcoded MM/dd/yyyy breaks outside en-US.
    cmd.exe /c "schtasks /Delete /TN ""$task"" /F >nul 2>&1" | Out-Null
    $sd = $when.ToString((Get-Culture).DateTimeFormat.ShortDatePattern)
    $st = $when.ToString('HH:mm')
    cmd.exe /c "schtasks /Create /TN ""$task"" /TR ""$cmd"" /SC ONCE /SD $sd /ST $st /RU SYSTEM /RL HIGHEST /F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /Create failed with exit $LASTEXITCODE" }

    Write-Host ""
    Write-Host "  Scheduled: transport -> $(if($On){'WebSocket'}else{'native'}) at $sd $st (in ~$DelaySeconds s)." -ForegroundColor Cyan
    Write-Host "  DISCONNECT NOW. The RustDesk service will restart and your session will drop." -ForegroundColor Yellow
    Write-Host "  The machine reconnects on the new transport by itself." -ForegroundColor Gray
    Write-Host ""
    return
}

# ------------------------------------------------------------------- apply ---
$configs = @(
    'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config\RustDesk2.toml',
    'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml',
    (Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml')
) | Where-Object { Test-Path $_ }

if (-not $configs) { throw "No RustDesk2.toml found - is RustDesk installed?" }

Write-Host "  Stopping RustDesk service..." -ForegroundColor Gray
# sc.exe, not Stop-Service: Stop-Service blocks with no timeout if the SCM stalls.
& sc.exe stop RustDesk 2>&1 | Out-Null
$waited = 0
while ((Get-Service RustDesk -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and $waited -lt 30) {
    Start-Sleep -Seconds 1; $waited++
}

foreach ($cfg in $configs) {
    $lines = [System.IO.File]::ReadAllLines($cfg)
    $out = New-Object System.Collections.Generic.List[string]
    $inOptions = $false
    $written = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*\[options\]\s*$') {
            $inOptions = $true
            $out.Add($line)
            if ($want) { $out.Add("allow-websocket = '$want'"); $written = $true }
            continue
        }
        # drop any existing allow-websocket; we re-add it under [options] above
        if ($line -match "^\s*allow-websocket\s*=") { continue }
        $out.Add($line)
    }
    if ($want -and -not $written) {
        # no [options] table at all - create one
        $out.Add(''); $out.Add('[options]'); $out.Add("allow-websocket = '$want'")
    }
    [System.IO.File]::WriteAllLines($cfg, $out, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  wrote $cfg" -ForegroundColor DarkGray
}

Write-Host "  Starting RustDesk service..." -ForegroundColor Gray
& sc.exe start RustDesk 2>&1 | Out-Null

Write-Host ""
Write-Host "  Transport is now: $(if($On){'WebSocket (allow-websocket = Y)'}else{'native TCP/UDP'})" -ForegroundColor Green
Write-Host "  Verify on the server:  docker logs <betterdesk> --since 5m | grep -E 'WS upgrade|PK registered'" -ForegroundColor Gray
Write-Host ""
