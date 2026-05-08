# LucidPC RustDesk install scripts

Public installer scripts for connecting Windows machines to the LucidPC support relay.

These files contain only public configuration (relay hostname, public key) — **no secrets**. The permanent unattended-access password is supplied at install time and never written to any of these files.

## For LucidPC technicians — set up a server for unattended remote access

Open Administrator PowerShell on the target server and run:

```powershell
iex (irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/bootstrap-server.ps1)
```

You'll be prompted to paste the shared LucidPC RustDesk password. The script installs RustDesk as a service, configures it for the LucidPC relay, sets the permanent password, and prints the device's 9-digit RustDesk ID.

## For end users — get help from LucidPC support

Open PowerShell on your PC and run:

```powershell
iex (irm https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/bootstrap-support.ps1)
```

Or download `LucidPC-RemoteSupport.bat` + `LucidPC-RemoteSupport.ps1` together as a zip and double-click the `.bat`.

Then read the LucidPC technician your 9-digit RustDesk ID and password.

## What's in this repo

| File | Purpose |
|---|---|
| `LucidPC-ServerInstall.bat` / `.ps1` | Unattended-access setup for servers/managed PCs |
| `LucidPC-RemoteSupport.bat` / `.ps1` | Ad-hoc support session setup for end users |
| `bootstrap-server.ps1` | Web-based one-liner to download + run the server installer |
| `bootstrap-support.ps1` | Web-based one-liner to download + run the support installer |
| `support-page.html` | Standalone HTML page with a "Copy Support Code" button (for clipboard-import flow) |

## Configuration baked in

```
ID server:    live.lucidpc.com
Relay:        live.lucidpc.com
API:          https://live.lucidpc.com
Public key:   hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k=
```
