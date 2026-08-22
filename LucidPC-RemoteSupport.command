#!/usr/bin/env bash
# LucidPC Remote Support -- macOS end-user setup (one-time access)
#
# Installs RustDesk and configures it to connect to LucidPC's support relay.
# The user opens RustDesk and reads the technician their 9-digit ID and
# one-time password.
#
# Usage (double-click in Finder, or run from Terminal):
#   bash LucidPC-RemoteSupport.command
# Or via curl:
#   curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-RemoteSupport.command | bash

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

# Architecture detection -- RustDesk ships separate DMGs for Intel and Apple Silicon
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  DMG_ARCH="x86_64" ;;
    arm64)   DMG_ARCH="aarch64" ;;
    *) err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# macOS version check -- RustDesk 1.4.x requires 10.14+
OS_VER="$(sw_vers -productVersion)"
OS_MAJOR="$(echo "$OS_VER" | cut -d. -f1)"
OS_MINOR="$(echo "$OS_VER" | cut -d. -f2)"
if [[ "$OS_MAJOR" == "10" ]] && [[ "$OS_MINOR" -lt 14 ]]; then
    err "macOS $OS_VER is too old. RustDesk requires macOS 10.14 (Mojave) or newer."
    echo "    Update macOS via System Preferences > Software Update, then re-run."
    exit 1
fi

# Identify the human user (Finder owner). When run with sudo we need this for
# config paths; without sudo it's the current user.
TARGET_USER="${SUDO_USER:-$USER}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(stat -f '%Su' /dev/console 2>/dev/null || echo "$USER")"
fi
TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -z "$TARGET_HOME" ]] && TARGET_HOME="/Users/$TARGET_USER"

clear
echo ""
echo "  LucidPC Remote Support"
echo "  ======================"
echo ""
echo "  This will set up RustDesk so the LucidPC technician can help you."
echo "  Your screen is NOT shared until you give them the ID and password."
echo ""

# Step 1: Quit RustDesk if running
step 1 4 "Preparing"
pkill -x RustDesk 2>/dev/null || true
sleep 1
step_ok

# Step 2: Install RustDesk if not already present
step 2 4 "Installing RustDesk"
APP_PATH="/Applications/RustDesk.app"
if [[ -d "$APP_PATH" ]]; then
    step_ok
else
    TMPDIR_RD="$(mktemp -d)"
    trap 'hdiutil detach "$TMPDIR_RD/mount" >/dev/null 2>&1 || true; rm -rf "$TMPDIR_RD"' EXIT
    DMG_FILE="$TMPDIR_RD/rustdesk.dmg"
    URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-${DMG_ARCH}.dmg"
    if ! curl -fsSL "$URL" -o "$DMG_FILE" 2>/dev/null; then
        step_no "Download failed: $URL"; exit 1
    fi
    MOUNT_POINT="$TMPDIR_RD/mount"
    mkdir -p "$MOUNT_POINT"
    if ! hdiutil attach "$DMG_FILE" -mountpoint "$MOUNT_POINT" -nobrowse -readonly -quiet 2>/dev/null; then
        step_no "Could not mount disk image"; exit 1
    fi
    SRC_APP="$MOUNT_POINT/RustDesk.app"
    if [[ ! -d "$SRC_APP" ]]; then
        step_no "RustDesk.app not found inside DMG"; exit 1
    fi
    # Copying to /Applications needs sudo; if we don't have it, fall back to ~/Applications
    if [[ -w /Applications ]]; then
        cp -R "$SRC_APP" /Applications/
    else
        if ! sudo -n true 2>/dev/null; then
            echo
            echo "    Need administrator access to install to /Applications."
            echo "    You'll be asked for your Mac password."
        fi
        sudo cp -R "$SRC_APP" /Applications/
    fi
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    if [[ ! -d "$APP_PATH" ]]; then
        step_no "Install completed but RustDesk.app not in /Applications"; exit 1
    fi
    # Strip the quarantine flag so Gatekeeper doesn't block first launch
    xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
    step_ok
fi

# Step 3: Write LucidPC config so RustDesk connects to our relay
step 3 4 "Connecting to LucidPC servers"
TOML_BODY="rendezvous_server = '${ID_SERVER}:21116'
nat_type = 1
serial = 0

[options]
relay-server = '$RELAY_SERVER'
api-server = '$API_SERVER'
custom-rendezvous-server = '$ID_SERVER'
key = '$PUBLIC_KEY'
"
USER_CFG_DIR="$TARGET_HOME/Library/Preferences/com.carriez.RustDesk/config"
mkdir -p "$USER_CFG_DIR"
echo "$TOML_BODY" > "$USER_CFG_DIR/RustDesk2.toml"
chmod 600 "$USER_CFG_DIR/RustDesk2.toml"
# Ensure the user owns it (in case we're running under sudo)
if [[ "$(id -u)" == "0" ]]; then
    chown -R "$TARGET_USER:staff" "$TARGET_HOME/Library/Preferences/com.carriez.RustDesk" 2>/dev/null || true
fi
step_ok

# Step 4: Launch RustDesk
step 4 4 "Opening RustDesk"
# `open` must run as the desktop user, not root, otherwise the GUI shows on
# nobody's screen. If we're root via sudo, drop privileges.
if [[ "$(id -u)" == "0" ]]; then
    sudo -u "$TARGET_USER" open -a "$APP_PATH" 2>/dev/null || open "$APP_PATH"
else
    open -a "$APP_PATH" 2>/dev/null || open "$APP_PATH"
fi
sleep 3
step_ok

echo ""
echo "  Setup complete."
echo ""
echo "  Look at the RustDesk window. Tell your technician:"
echo "     - The 9-digit ID number (top of the RustDesk window)"
echo "     - The password shown right under the ID"
echo ""
echo "  Your screen is not shared until they connect with that info."
echo ""
echo "  First time only: macOS may ask you to grant RustDesk permission for"
echo "  Screen Recording, Accessibility, and Input Monitoring. Click 'Open"
echo "  System Preferences', tick the boxes, then quit and reopen RustDesk."
echo ""
