# LucidPC RustDesk install scripts

Public installer scripts for connecting Windows, Linux, and macOS machines to the LucidPC support relay.

These files contain only public configuration (relay hostname, public key) — **no secrets**. The permanent unattended-access password is supplied at install time and never written to any of these files.

## Windows

### Set up a server for unattended remote access (technicians)

Open Administrator PowerShell on the target server and run:

```powershell
iex (irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/bootstrap-server.ps1)
```

You'll be prompted to paste the shared LucidPC RustDesk password. The script installs RustDesk as a service, configures it for the LucidPC relay, sets the permanent password, applies 3-layer auto-recovery, and prints the device's 9-digit RustDesk ID.

### One-time end-user support session

Open PowerShell on the user's PC and run:

```powershell
iex (irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/bootstrap-support.ps1)
```

User reads the technician their 9-digit ID and one-time password.

## Linux (Ubuntu, Debian, Fedora, RHEL)

### Set up a Linux desktop/server for unattended access (technicians)

```bash
curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.sh | sudo bash
```

The script will prompt for the permanent password with input hidden. If you'd rather pass it non-interactively (e.g. for automation), use:

```bash
curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.sh | sudo LUCIDPC_RUSTDESK_PW='YourPassword' bash
```

To re-run on an existing server (skip the password prompt, just refresh config + recovery):

```bash
curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.sh | sudo SKIP_PASSWORD=1 bash
```

### One-time end-user support session

```bash
curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-RemoteSupport.sh | sudo bash
```

User reads the technician their 9-digit ID and one-time password from the RustDesk window.

## macOS (10.14 Mojave or newer; Intel and Apple Silicon)

### Set up a Mac for unattended access (technicians)

```bash
curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.command | bash
```

The script will prompt for the permanent password with input hidden. For non-interactive use:

```bash
curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.command | LUCIDPC_RUSTDESK_PW='YourPassword' bash
```

To re-run on an already-onboarded Mac (skip the password prompt, just refresh config + recovery):

```bash
curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.command | SKIP_PASSWORD=1 bash
```

**First-time only**: macOS will block remote control until you manually grant
RustDesk these permissions in **System Preferences > Security & Privacy > Privacy**:
Screen Recording, Accessibility, Input Monitoring. There is no way to grant
these programmatically without a managed device profile (MDM).

### One-time end-user support session

```bash
curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-RemoteSupport.command | bash
```

User reads the technician the 9-digit ID and one-time password from the RustDesk window.

## What's in this repo

| File | Platform | Purpose |
|---|---|---|
| `LucidPC-ServerInstall.bat` / `.ps1` | Windows | Unattended-access setup for servers/managed PCs |
| `LucidPC-RemoteSupport.bat` / `.ps1` | Windows | Ad-hoc support session setup for end users |
| `bootstrap-server.ps1` | Windows | Web-based one-liner to download + run the server installer |
| `bootstrap-support.ps1` | Windows | Web-based one-liner to download + run the support installer |
| `LucidPC-ServerInstall.sh` | Linux | Unattended-access setup (Debian/Ubuntu/Fedora/RHEL) |
| `LucidPC-RemoteSupport.sh` | Linux | Ad-hoc support session setup |
| `LucidPC-ServerInstall.command` | macOS | Unattended-access setup (10.14+, Intel + Apple Silicon) |
| `LucidPC-RemoteSupport.command` | macOS | Ad-hoc support session setup |
| `support-page.html` | All | Standalone HTML page with copy-to-clipboard support code (clipboard-import flow) |

## Auto-recovery (server installs)

Every server install (Windows + Linux) sets up three layers of recovery so the RustDesk service stays running:

1. **Auto-start on boot** (Windows: service StartType=Automatic; Linux: systemd `enable`; macOS: launchd `RunAtLoad`)
2. **Auto-restart on crash** (Windows: service Recovery actions; Linux: systemd `Restart=always`; macOS: launchd `KeepAlive`)
3. **Watchdog every 5 minutes** as SYSTEM/root — re-installs the service if someone deletes it (e.g., RustDesk's own "Stop Service" button calls `sc delete` on Windows / `systemctl disable` on Linux / `launchctl unload` on macOS)

Worst-case access loss: 5 minutes, then automatic recovery.

## Configuration baked in

```
ID server:    live.lucidpc.com
Relay:        live.lucidpc.com
API:          https://live.lucidpc.com
Public key:   hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k=
```
