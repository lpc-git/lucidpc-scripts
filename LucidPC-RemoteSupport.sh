#!/usr/bin/env bash
# LucidPC Remote Support -- Linux end-user setup (one-time access, no permanent password)
#
# Installs RustDesk and configures it to connect to LucidPC's support relay.
# After this runs, the user opens RustDesk and reads the technician their
# 9-digit ID and one-time password.
#
# Usage:
#   curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-RemoteSupport.sh | sudo bash
# Or download and run:
#   sudo bash ./LucidPC-RemoteSupport.sh

set -euo pipefail

# --- LucidPC support server config (public, safe to expose) ---
ID_SERVER="live.lucidpc.com"
RELAY_SERVER="live.lucidpc.com"
API_SERVER="https://live.lucidpc.com"
PUBLIC_KEY="hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k="
RUSTDESK_VERSION="1.4.6"
# ---------------------------------------------------------------

step()    { printf "  Step %s of %s  %-40s" "$1" "$2" "$3..."; }
step_ok() { printf "\033[32mdone\033[0m\n"; }
step_no() { printf "\033[31mFAILED\033[0m\n"; [[ -n "${1-}" ]] && echo "    $1"; }
err()     { printf "\n  \033[31mError:\033[0m %s\n" "$1" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Run as root (sudo bash $0)"
    exit 1
fi

# Find the human user (the one who'll run RustDesk's GUI), not root
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
fi
if [[ -z "$TARGET_USER" ]]; then
    err "Could not determine the desktop user. Re-run with sudo from your normal user account."
    exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

clear
echo ""
echo "  LucidPC Remote Support"
echo "  ======================"
echo ""
echo "  This will set up RustDesk so the LucidPC technician can help you."
echo "  Your screen is NOT shared until you give them the ID and password."
echo ""

# Step 1: Detect package manager
step 1 4 "Checking system"
if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PKG_EXT="deb"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_EXT="rpm"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_EXT="rpm"
else
    step_no "No supported package manager (apt, dnf, yum)"
    exit 1
fi
step_ok

# Step 2: Install RustDesk if not already there
step 2 4 "Installing RustDesk"
if command -v rustdesk >/dev/null 2>&1; then
    step_ok
else
    TMPDIR_RD="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_RD"' EXIT
    PKG_FILE="$TMPDIR_RD/rustdesk.$PKG_EXT"
    URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-x86_64.${PKG_EXT}"
    if ! curl -fsSL "$URL" -o "$PKG_FILE" 2>/dev/null; then
        step_no "Download failed: $URL"
        exit 1
    fi
    case "$PKG_MGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG_FILE" >/dev/null 2>&1 ;;
        dnf) dnf install -y "$PKG_FILE" >/dev/null 2>&1 ;;
        yum) yum install -y "$PKG_FILE" >/dev/null 2>&1 ;;
    esac
    if ! command -v rustdesk >/dev/null 2>&1; then
        step_no "Install completed but rustdesk binary not found"
        exit 1
    fi
    step_ok
fi

# Step 3: Write LucidPC config to BOTH user dir AND service dir, restart service.
# The Linux .deb starts the rustdesk service as root immediately on install. The
# service writes its OWN config to /root/.config/rustdesk/RustDesk2.toml using
# RustDesk's public defaults, which then propagates to the user dir on next GUI
# launch. We must (a) write our config to the service dir, (b) restart the
# service so it loads our config, (c) write to the user dir so the GUI shows
# the right thing.
step 3 4 "Connecting to LucidPC servers"
TOML_BODY=$(cat <<EOF
rendezvous_server = '${ID_SERVER}:21116'
nat_type = 1
serial = 0

[options]
relay-server = '$RELAY_SERVER'
api-server = '$API_SERVER'
custom-rendezvous-server = '$ID_SERVER'
key = '$PUBLIC_KEY'
EOF
)
# Write to service dir (root) -- service uses this
mkdir -p /root/.config/rustdesk
echo "$TOML_BODY" > /root/.config/rustdesk/RustDesk2.toml
chmod 600 /root/.config/rustdesk/RustDesk2.toml
# Write to user dir (target user) -- GUI uses this
USER_CFG_DIR="$TARGET_HOME/.config/rustdesk"
mkdir -p "$USER_CFG_DIR"
echo "$TOML_BODY" > "$USER_CFG_DIR/RustDesk2.toml"
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/rustdesk"
chmod 600 "$USER_CFG_DIR/RustDesk2.toml"
# Restart the service so it reloads from the service dir
systemctl restart rustdesk >/dev/null 2>&1 || true
sleep 2
step_ok

# Step 4: Launch RustDesk for the user (only if a desktop session exists)
step 4 4 "Opening RustDesk"
if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]] || pgrep -u "$TARGET_USER" -x Xorg >/dev/null 2>&1 || pgrep -u "$TARGET_USER" -f gnome-shell >/dev/null 2>&1; then
    USER_ID="$(id -u "$TARGET_USER")"
    sudo -u "$TARGET_USER" \
         DISPLAY="${DISPLAY:-:0}" \
         XDG_RUNTIME_DIR="/run/user/$USER_ID" \
         nohup rustdesk >/dev/null 2>&1 &
    sleep 2
    step_ok
else
    printf "\033[33mskipped (no display)\033[0m\n"
    echo "    Open RustDesk manually from your applications menu."
fi

echo ""
echo "  Setup complete."
echo ""
echo "  Look at the RustDesk window. Tell your technician:"
echo "     - The 9-digit ID number (top of the RustDesk window)"
echo "     - The password shown right under the ID"
echo ""
echo "  Your screen is not shared until they connect with that info."
echo ""
