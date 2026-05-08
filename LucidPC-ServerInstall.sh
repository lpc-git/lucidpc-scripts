#!/usr/bin/env bash
# LucidPC Server Install -- Linux unattended-access setup
#
# Idempotent. Safe to run on:
#   - A fresh Linux desktop/server (full install + config + password + auto-recovery)
#   - An existing system that needs auto-recovery added (skips already-done steps)
#
# Run as root (sudo). After it finishes, you can connect from your tech client
# using the device's 9-digit ID and the permanent password you set.
#
# Usage (interactive, prompts for password):
#   curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.sh | sudo bash
#
# Or with explicit password as env var (no prompts):
#   curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.sh | sudo LUCIDPC_RUSTDESK_PW='YourPassword' bash
#
# Or with skip flag to only refresh config + auto-recovery (existing servers):
#   curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.sh | sudo SKIP_PASSWORD=1 bash

set -euo pipefail

# --- LucidPC server config (public, safe to expose) ---
ID_SERVER="live.lucidpc.com"
RELAY_SERVER="live.lucidpc.com"
API_SERVER="https://live.lucidpc.com"
PUBLIC_KEY="hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k="
RUSTDESK_VERSION="1.4.6"
# -------------------------------------------------------

step()    { printf "  Step %s of %s  %-40s" "$1" "$2" "$3..."; }
step_ok() { printf "\033[32mdone\033[0m\n"; }
step_no() { printf "\033[31mFAILED\033[0m\n"; [[ -n "${1-}" ]] && echo "    $1"; }
err()     { printf "\n  \033[31mError:\033[0m %s\n" "$1" >&2; }
ok_line() { printf "    \033[32m[OK]\033[0m  %s\n" "$1"; }
no_line() { printf "    \033[31m[!!]\033[0m  %s\n" "$1"; }

if [[ $EUID -ne 0 ]]; then
    err "Run as root: sudo bash $0  (or pipe via curl ... | sudo bash)"
    exit 1
fi

# --- Resolve permanent password ---
PERMANENT_PASSWORD="${LUCIDPC_RUSTDESK_PW:-}"
SKIP_PASSWORD="${SKIP_PASSWORD:-0}"
PW_ALREADY_SET=0

# Detect if password is already set in the service config
SERVICE_CFG_DIR="/root/.config/rustdesk"
SERVICE_CFG_FILE="$SERVICE_CFG_DIR/RustDesk.toml"
if [[ -f "$SERVICE_CFG_FILE" ]] && grep -qE "^password\s*=\s*'[^']+'" "$SERVICE_CFG_FILE" 2>/dev/null; then
    PW_ALREADY_SET=1
fi

if [[ "$SKIP_PASSWORD" == "1" ]] || ([[ "$PW_ALREADY_SET" == "1" ]] && [[ -z "$PERMANENT_PASSWORD" ]]); then
    SKIP_PW_STEP=1
else
    SKIP_PW_STEP=0
    if [[ -z "$PERMANENT_PASSWORD" ]]; then
        clear
        echo ""
        echo "  LucidPC RustDesk Setup (Linux)"
        echo "  =============================="
        echo ""
        echo "  Paste the LucidPC support password (input is hidden)."
        echo ""
        read -r -s -p "  Password: " PW1 ; echo
        if [[ -z "$PW1" ]]; then err "Password required."; exit 1; fi
        read -r -s -p "  Confirm : " PW2 ; echo
        if [[ "$PW1" != "$PW2" ]]; then err "Passwords did not match."; exit 1; fi
        if [[ ${#PW1} -lt 8 ]]; then err "Password must be at least 8 characters."; exit 1; fi
        PERMANENT_PASSWORD="$PW1"
        unset PW1 PW2
    fi
fi

clear
echo ""
echo "  LucidPC RustDesk Setup (Linux)"
echo "  =============================="
echo ""

# Step 1: Detect package manager + install if needed
step 1 5 "Installing RustDesk"
if command -v rustdesk >/dev/null 2>&1; then
    step_ok
else
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"; PKG_EXT="deb"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"; PKG_EXT="rpm"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"; PKG_EXT="rpm"
    else
        step_no "No supported package manager (apt, dnf, yum)"
        exit 1
    fi
    TMPDIR_RD="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_RD"' EXIT
    PKG_FILE="$TMPDIR_RD/rustdesk.$PKG_EXT"
    URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-x86_64.${PKG_EXT}"
    if ! curl -fsSL "$URL" -o "$PKG_FILE" 2>/dev/null; then
        step_no "Download failed: $URL"; exit 1
    fi
    case "$PKG_MGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG_FILE" >/dev/null 2>&1 ;;
        dnf) dnf install -y "$PKG_FILE" >/dev/null 2>&1 ;;
        yum) yum install -y "$PKG_FILE" >/dev/null 2>&1 ;;
    esac
    if ! command -v rustdesk >/dev/null 2>&1; then
        step_no "Install completed but rustdesk binary not found"; exit 1
    fi
    step_ok
fi

# Step 2: Write the server config to BOTH service dir AND user dir.
# The service runs as root and reads from /root/.config/rustdesk/.
# The GUI runs as the human user and reads from ~/.config/rustdesk/.
# Both must agree, otherwise the service has correct settings but the GUI shows
# defaults and confuses the operator.
step 2 5 "Configuring server connection"
TOML_BODY=$(cat <<EOF
rendezvous_server = '${ID_SERVER}:21116'
nat_type = 1
serial = 0

[options]
relay-server = '$RELAY_SERVER'
api-server = '$API_SERVER'
custom-rendezvous-server = '$ID_SERVER'
key = '$PUBLIC_KEY'
approve-mode = 'password'
verification-method = 'use-permanent-password'
EOF
)
# Service-side (root)
mkdir -p "$SERVICE_CFG_DIR"
echo "$TOML_BODY" > "$SERVICE_CFG_DIR/RustDesk2.toml"
chmod 600 "$SERVICE_CFG_DIR/RustDesk2.toml"
# User-side (the desktop user, if any)
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
fi
if [[ -n "$TARGET_USER" ]]; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    mkdir -p "$TARGET_HOME/.config/rustdesk"
    echo "$TOML_BODY" > "$TARGET_HOME/.config/rustdesk/RustDesk2.toml"
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/rustdesk"
    chmod 600 "$TARGET_HOME/.config/rustdesk/RustDesk2.toml"
fi
step_ok

# Step 3: Enable + start the systemd service
step 3 5 "Starting RustDesk service"
# RustDesk's deb installs a systemd unit. Name varies by version: try both.
SVC_UNIT=""
for u in rustdesk rustdesk-server; do
    if systemctl list-unit-files 2>/dev/null | grep -qE "^${u}\.service"; then
        SVC_UNIT="$u"
        break
    fi
done
if [[ -z "$SVC_UNIT" ]]; then
    # Fallback: create a minimal systemd service ourselves
    SVC_UNIT="rustdesk"
    cat > "/etc/systemd/system/rustdesk.service" <<EOF
[Unit]
Description=RustDesk Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/rustdesk --service
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
fi
systemctl enable "$SVC_UNIT" >/dev/null 2>&1 || true
systemctl restart "$SVC_UNIT" >/dev/null 2>&1 || systemctl start "$SVC_UNIT" >/dev/null 2>&1 || true
sleep 3
if ! systemctl is-active "$SVC_UNIT" >/dev/null 2>&1; then
    step_no "Service did not start (unit: $SVC_UNIT)"
    exit 1
fi
step_ok

# Step 4: Set permanent password (skipped on re-run if already set)
if [[ "$SKIP_PW_STEP" == "1" ]]; then
    step 4 5 "Permanent password (already set, skipping)"
    step_ok
else
    step 4 5 "Setting permanent password"
    # On Linux, `rustdesk --password X` requires root + RustDesk being installed.
    # systemctl-run-as-root ensures we have the right context.
    if rustdesk --password "$PERMANENT_PASSWORD" >/dev/null 2>&1; then
        step_ok
    else
        # Some versions need the service running and ipc available -- restart and retry
        systemctl restart "$SVC_UNIT" >/dev/null 2>&1 || true
        sleep 3
        if rustdesk --password "$PERMANENT_PASSWORD" >/dev/null 2>&1; then
            step_ok
        else
            step_no "Could not set permanent password automatically; set via the GUI: Settings > Security > Set Permanent Password"
        fi
    fi
fi

# Step 5: Read device ID
step 5 5 "Reading Device ID"
DEVICE_ID=""
for i in 1 2 3 4 5 6; do
    sleep 2
    OUT="$(rustdesk --get-id 2>&1 || true)"
    ID="$(echo "$OUT" | grep -oE '\b[0-9]{6,12}\b' | head -1 || true)"
    if [[ -n "$ID" ]]; then DEVICE_ID="$ID"; break; fi
done
if [[ -n "$DEVICE_ID" ]]; then
    step_ok
else
    step_no "ID not auto-retrieved; open RustDesk on this device to see it"
fi

# --- Auto-recovery layers ---
# Layer 1: Service already enabled at boot (set above)
# Layer 2: Always install a Restart=always drop-in (idempotent; the package's unit
# may or may not have Restart= set, so unconditionally adding our override is safe).
mkdir -p "/etc/systemd/system/${SVC_UNIT}.service.d"
cat > "/etc/systemd/system/${SVC_UNIT}.service.d/lucidpc-recovery.conf" <<EOF
[Service]
Restart=always
RestartSec=5
EOF
systemctl daemon-reload
# Verify systemd actually applied it
RECOVERY_RESTART_OK=0
if systemctl show "$SVC_UNIT" -p Restart 2>/dev/null | grep -qE "Restart=(always|on-failure)"; then
    RECOVERY_RESTART_OK=1
fi

# Layer 3: Watchdog systemd timer that runs every 5 min, ensures service is enabled + running.
# Equivalent of the Windows scheduled task. Survives the case where someone runs
# `systemctl disable --now rustdesk` -- the timer re-enables and re-starts it.
WATCHDOG_DIR="/etc/systemd/system"
WATCHDOG_SCRIPT="/usr/local/sbin/lucidpc-rustdesk-watchdog"
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# LucidPC RustDesk watchdog -- ensures the service is enabled + running.
SVC="rustdesk"
if ! systemctl list-unit-files 2>/dev/null | grep -qE "^${SVC}\.service"; then
    SVC="rustdesk-server"
fi
systemctl is-enabled "$SVC" >/dev/null 2>&1 || systemctl enable "$SVC" >/dev/null 2>&1 || true
systemctl is-active  "$SVC" >/dev/null 2>&1 || systemctl start  "$SVC" >/dev/null 2>&1 || true
EOF
chmod +x "$WATCHDOG_SCRIPT"

cat > "$WATCHDOG_DIR/lucidpc-rustdesk-watchdog.service" <<EOF
[Unit]
Description=LucidPC RustDesk watchdog (one-shot)

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

cat > "$WATCHDOG_DIR/lucidpc-rustdesk-watchdog.timer" <<EOF
[Unit]
Description=LucidPC RustDesk watchdog (every 5 min)

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now lucidpc-rustdesk-watchdog.timer >/dev/null 2>&1 || true

WATCHDOG_OK=0
if systemctl is-active lucidpc-rustdesk-watchdog.timer >/dev/null 2>&1; then
    WATCHDOG_OK=1
fi

# Self-verify all three layers
echo ""
if [[ -n "$DEVICE_ID" ]]; then
    cat <<EOF

  +------------------------------------+
  |                                    |
  |   Device ID:  $(printf "%-21s" "$DEVICE_ID")|
  |                                    |
  +------------------------------------+
EOF
fi

echo ""
echo "  Auto-recovery active:"
if systemctl is-enabled "$SVC_UNIT" >/dev/null 2>&1; then
    ok_line "Service auto-start on Linux boot"
    AUTOSTART_OK=1
else
    no_line "Service auto-start on Linux boot"
    AUTOSTART_OK=0
fi
if [[ "$RECOVERY_RESTART_OK" == "1" ]]; then
    ok_line "Service Recovery (Restart=always on crash)"
else
    no_line "Service Recovery NOT verified"
fi
if [[ "$WATCHDOG_OK" == "1" ]]; then
    ok_line "Watchdog timer (every 5 min, runs as root via systemd)"
else
    no_line "Watchdog timer NOT verified"
fi

echo ""
echo "  Connect from your tech client using the Device ID + your password."
echo "  You can leave this terminal."
echo ""
