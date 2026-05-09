#!/usr/bin/env bash
# LucidPC Server Install -- macOS unattended-access setup
#
# Idempotent. Safe to run on:
#   - A fresh Mac (full install + config + password + auto-recovery)
#   - An existing Mac that needs auto-recovery added (skips already-done steps)
#
# Run as the desktop user; it will sudo for the privileged steps. After it
# finishes, you can connect from your tech client using the device's 9-digit
# ID and the permanent password you set.
#
# Usage (interactive, prompts for password):
#   curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.command | bash
#
# Or with explicit password as env var (no prompts):
#   curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.command | LUCIDPC_RUSTDESK_PW='YourPassword' bash
#
# Or with skip flag to only refresh config + auto-recovery:
#   curl -sfL https://raw.githubusercontent.com/lpc-git/lucidpc-scripts/main/LucidPC-ServerInstall.command | SKIP_PASSWORD=1 bash

# Note: deliberately NOT using `set -e`. Errors are handled explicitly with
# step_no calls and `|| true`. set -e makes pipelines and globs in command
# substitutions ($(...)) brittle and is not worth the false positives.
set -uo pipefail

# --- LucidPC server config (public, safe to expose) ---
ID_SERVER="live.lucidpc.com"
RELAY_SERVER="live.lucidpc.com"
API_SERVER="https://live.lucidpc.com"
PUBLIC_KEY="hRakm22D+ZsyQUwQ5nf3tRAPAlbb39LYEQAP0UDet9k="
RUSTDESK_VERSION="1.4.6"
WATCHDOG_LABEL="com.lucidpc.rustdesk-watchdog"
WATCHDOG_PLIST="/Library/LaunchDaemons/${WATCHDOG_LABEL}.plist"
WATCHDOG_SCRIPT="/usr/local/sbin/lucidpc-rustdesk-watchdog"
RD_AGENT_LABEL="com.lucidpc.rustdesk-launcher"
RD_AGENT_PLIST="/Library/LaunchAgents/${RD_AGENT_LABEL}.plist"
# -------------------------------------------------------

step()    { printf "  Step %s of %s  %-40s" "$1" "$2" "$3..."; }
step_ok() { printf "\033[32mdone\033[0m\n"; }
step_no() { printf "\033[31mFAILED\033[0m\n"; [[ -n "${1-}" ]] && echo "    $1"; }
err()     { printf "\n  \033[31mError:\033[0m %s\n" "$1" >&2; }
ok_line() { printf "    \033[32m[OK]\033[0m  %s\n" "$1"; }
no_line() { printf "    \033[31m[!!]\033[0m  %s\n" "$1"; }

# Architecture
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
    exit 1
fi

# Identify the human user (the one whose GUI should show RustDesk)
TARGET_USER="${SUDO_USER:-$USER}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(stat -f '%Su' /dev/console 2>/dev/null || echo "$USER")"
fi
TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -z "$TARGET_HOME" ]] && TARGET_HOME="/Users/$TARGET_USER"

# Acquire sudo up front so prompts don't interleave with progress lines later.
# The script asks for two passwords during install:
#   1. Mac account password (this sudo prompt) -- needed to write to
#      /Applications, /Library/LaunchAgents, /Library/LaunchDaemons.
#   2. LucidPC support password (later) -- the permanent unattended-access
#      password that the technician uses to remote into this Mac.
# Both prompts are announced clearly so users know which is which.
if [[ "$(id -u)" != "0" ]]; then
    if ! sudo -n true 2>/dev/null; then
        clear
        cat <<'EOF'

  LucidPC RustDesk Setup (macOS)
  ==============================

  This installer will ask you for TWO passwords:

    [1/2]  Your Mac account password (the one you use to log into this
           computer). Needed to install RustDesk to /Applications. Just
           the standard macOS password prompt -- typed by hand, not
           pasted from a message.

    [2/2]  The LucidPC support password. This is the permanent password
           your LucidPC technician uses to remote into this Mac.
           If you don't have it, contact your technician.

  Press Ctrl+C any time to abort.

EOF
        # Custom sudo prompt makes it unmistakable which password is wanted
        sudo -p "  [1/2] Mac account password: " -v
        echo
    fi
    # Keep sudo alive for the duration of the script
    ( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT
fi

# --- Resolve permanent password ---
PERMANENT_PASSWORD="${LUCIDPC_RUSTDESK_PW:-}"
SKIP_PASSWORD="${SKIP_PASSWORD:-0}"
PW_ALREADY_SET=0

# Detect if password is already set in the system config
SYS_CFG_DIR="/var/root/Library/Preferences/com.carriez.RustDesk/config"
SYS_CFG_FILE="$SYS_CFG_DIR/RustDesk.toml"
if sudo test -f "$SYS_CFG_FILE" && sudo grep -qE "^password\s*=\s*'[^']+'" "$SYS_CFG_FILE" 2>/dev/null; then
    PW_ALREADY_SET=1
fi

if [[ "$SKIP_PASSWORD" == "1" ]] || ([[ "$PW_ALREADY_SET" == "1" ]] && [[ -z "$PERMANENT_PASSWORD" ]]); then
    SKIP_PW_STEP=1
else
    SKIP_PW_STEP=0
    if [[ -z "$PERMANENT_PASSWORD" ]]; then
        # Read from /dev/tty so the prompt works under `curl ... | bash` --
        # without this, `read` would compete with bash's stdin (the script
        # itself) and silently get nothing.
        if [[ ! -r /dev/tty ]]; then
            err "No terminal available for password prompt."
            echo "    Re-run with the password as an env var:" >&2
            echo "    curl ... | LUCIDPC_RUSTDESK_PW='YourPw' bash" >&2
            exit 1
        fi
        echo ""
        echo "  [2/2] LucidPC support password"
        echo "  ------------------------------"
        echo "  This is the permanent password your LucidPC technician uses to"
        echo "  remote into this Mac. NOT your Mac account password (that was"
        echo "  step 1). If you don't have this password, contact your technician."
        echo "  Paste it now (input is hidden -- nothing will appear as you type)."
        echo ""
        read -r -s -p "  LucidPC support password: " PW1 < /dev/tty ; echo
        if [[ -z "$PW1" ]]; then err "Password required."; exit 1; fi
        read -r -s -p "  Confirm                 : " PW2 < /dev/tty ; echo
        if [[ "$PW1" != "$PW2" ]]; then err "Passwords did not match."; exit 1; fi
        if [[ ${#PW1} -lt 8 ]]; then err "Password must be at least 8 characters."; exit 1; fi
        PERMANENT_PASSWORD="$PW1"
        unset PW1 PW2
    fi
fi

clear
echo ""
echo "  LucidPC RustDesk Setup (macOS)"
echo "  =============================="
echo ""

APP_PATH="/Applications/RustDesk.app"
RUSTDESK_BIN="$APP_PATH/Contents/MacOS/RustDesk"

# Step 1: Install RustDesk if not already present
step 1 5 "Installing RustDesk"
if [[ -d "$APP_PATH" ]]; then
    step_ok
else
    TMPDIR_RD="$(mktemp -d)"
    DMG_FILE="$TMPDIR_RD/rustdesk.dmg"
    URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-${DMG_ARCH}.dmg"
    if ! curl -fsSL "$URL" -o "$DMG_FILE" 2>/dev/null; then
        step_no "Download failed: $URL"; rm -rf "$TMPDIR_RD"; exit 1
    fi
    MOUNT_POINT="$TMPDIR_RD/mount"
    mkdir -p "$MOUNT_POINT"
    if ! hdiutil attach "$DMG_FILE" -mountpoint "$MOUNT_POINT" -nobrowse -readonly -quiet 2>/dev/null; then
        step_no "Could not mount disk image"; rm -rf "$TMPDIR_RD"; exit 1
    fi
    SRC_APP="$MOUNT_POINT/RustDesk.app"
    if [[ ! -d "$SRC_APP" ]]; then
        step_no "RustDesk.app not found inside DMG"
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
        rm -rf "$TMPDIR_RD"; exit 1
    fi
    sudo cp -R "$SRC_APP" /Applications/
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    rm -rf "$TMPDIR_RD"
    if [[ ! -d "$APP_PATH" ]]; then
        step_no "Install completed but RustDesk.app not in /Applications"; exit 1
    fi
    sudo xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
    step_ok
fi

# Step 2: Write LucidPC config to BOTH system service dir AND user dir.
# RustDesk on macOS has two config locations:
#   - /var/root/Library/Preferences/com.carriez.RustDesk/config/  (the privileged service)
#   - ~/Library/Preferences/com.carriez.RustDesk/config/          (the GUI)
# Both must agree.
step 2 5 "Configuring server connection"
TOML_BODY="rendezvous_server = '${ID_SERVER}:21116'
nat_type = 1
serial = 0

[options]
relay-server = '$RELAY_SERVER'
api-server = '$API_SERVER'
custom-rendezvous-server = '$ID_SERVER'
key = '$PUBLIC_KEY'
approve-mode = 'password'
verification-method = 'use-permanent-password'
"
# System service side (root)
sudo mkdir -p "$SYS_CFG_DIR"
echo "$TOML_BODY" | sudo tee "$SYS_CFG_DIR/RustDesk2.toml" >/dev/null
sudo chmod 600 "$SYS_CFG_DIR/RustDesk2.toml"
# User GUI side
USER_CFG_DIR="$TARGET_HOME/Library/Preferences/com.carriez.RustDesk/config"
mkdir -p "$USER_CFG_DIR"
echo "$TOML_BODY" > "$USER_CFG_DIR/RustDesk2.toml"
chmod 600 "$USER_CFG_DIR/RustDesk2.toml"
step_ok

# Step 3: Install our own LaunchAgent that auto-starts RustDesk on user login.
#
# Why a LaunchAgent and not a LaunchDaemon: RustDesk on macOS needs the user's
# graphical session because TCC permissions (Screen Recording, Accessibility,
# Input Monitoring) are scoped per-user and require a logged-in user. A
# LaunchDaemon running as root cannot meaningfully accept connections.
#
# Why we don't use `RustDesk --install-service`: on macOS that flag is silently
# a no-op (verified Sequoia 15.7) -- it does NOT create a launchd plist the way
# the Linux .deb / Windows .exe equivalents do. The recommended pattern is to
# install via the GUI (Settings > Install RustDesk), which we automate here.
#
# Why a system-wide LaunchAgent (/Library/LaunchAgents) instead of per-user
# (~/Library/LaunchAgents): system-wide survives a fresh user account creation
# and works for whichever user logs in, which matches the unattended-access
# server profile.
step 3 5 "Setting up auto-start"
run_quiet() {
    "$@" >/dev/null 2>&1 &
    local pid=$!
    wait "$pid" 2>/dev/null
    return $?
}
sudo tee "$RD_AGENT_PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${RD_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>${APP_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/var/log/lucidpc-rustdesk-launcher.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/lucidpc-rustdesk-launcher.log</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$RD_AGENT_PLIST"
sudo chmod 644 "$RD_AGENT_PLIST"
# Load into the current GUI user's launchd domain so it takes effect now.
# bootstrap targets gui/<uid>; legacy `launchctl load` works on older macOS too.
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo 501)"
run_quiet sudo launchctl bootout "gui/${TARGET_UID}" "$RD_AGENT_PLIST" || true
run_quiet sudo launchctl bootstrap "gui/${TARGET_UID}" "$RD_AGENT_PLIST" || true
# Also unload+load for older macOS versions that don't support bootstrap
run_quiet sudo launchctl unload "$RD_AGENT_PLIST" || true
run_quiet sudo launchctl load -w "$RD_AGENT_PLIST" || true
sleep 1
# Detect: is RustDesk running, OR is the agent registered?
RD_RUNNING=0
if pgrep -x RustDesk >/dev/null 2>&1; then
    RD_RUNNING=1
fi
AGENT_LOADED=0
if sudo launchctl list 2>/dev/null | awk '{print $3}' | grep -q "$RD_AGENT_LABEL"; then
    AGENT_LOADED=1
fi
if [[ -f "$RD_AGENT_PLIST" ]]; then
    step_ok
else
    step_no "Could not write LaunchAgent plist"
fi

# Step 4: Set permanent password (skipped on re-run if already set)
if [[ "$SKIP_PW_STEP" == "1" ]]; then
    step 4 5 "Permanent password (already set, skipping)"
    step_ok
else
    step 4 5 "Setting permanent password"
    PW_OK=0
    for attempt in 1 2 3; do
        if run_quiet sudo "$RUSTDESK_BIN" --password "$PERMANENT_PASSWORD"; then
            PW_OK=1; break
        fi
        sleep 2
    done
    if [[ "$PW_OK" == "1" ]]; then
        step_ok
    else
        step_no "Could not set permanent password automatically; set via the GUI: Settings > Security > Set Permanent Password"
    fi
fi

# Step 5: Read device ID
step 5 5 "Reading Device ID"
DEVICE_ID=""
for i in 1 2 3 4 5 6; do
    sleep 2
    # Capture stdout from async run; bash signal-death messages are suppressed
    OUT="$(sudo "$RUSTDESK_BIN" --get-id 2>/dev/null & wait $! 2>/dev/null; true)"
    ID="$(echo "$OUT" | grep -oE '[0-9]{6,12}' | head -1 || true)"
    if [[ -n "$ID" ]]; then DEVICE_ID="$ID"; break; fi
done
if [[ -n "$DEVICE_ID" ]]; then
    step_ok
else
    step_no "ID not auto-retrieved; open RustDesk on this Mac to see it"
fi

# --- Auto-recovery layers ---
# Layer 1: launchd auto-loads the RustDesk daemon at boot (RunAtLoad=true is the
#          default in RustDesk's installed plist).
# Layer 2: launchd's KeepAlive=true (also set by RustDesk's installer) restarts
#          the service if it crashes.
# Layer 3: Independent watchdog -- a separate LaunchDaemon that fires every 5 min
#          and reloads the RustDesk daemon if it's gone missing. Survives the
#          case where someone runs `launchctl unload` against the main daemon.
sudo mkdir -p /usr/local/sbin
sudo tee "$WATCHDOG_SCRIPT" >/dev/null <<WDEOF
#!/usr/bin/env bash
# LucidPC RustDesk watchdog -- ensures the LaunchAgent is loaded and RustDesk
# is running for the currently-logged-in console user.
AGENT_PLIST="${RD_AGENT_PLIST}"
AGENT_LABEL="${RD_AGENT_LABEL}"
APP_PATH="${APP_PATH}"

# Re-load the LaunchAgent if it's not registered. The agent's RunAtLoad will
# then open RustDesk on next login; for the current session we also try to
# bootstrap into the live GUI domain.
if ! launchctl list 2>/dev/null | awk '{print \$3}' | grep -q "\$AGENT_LABEL"; then
    [[ -f "\$AGENT_PLIST" ]] && launchctl load -w "\$AGENT_PLIST" >/dev/null 2>&1
fi

CONSOLE_USER="\$(stat -f '%Su' /dev/console 2>/dev/null)"
if [[ -n "\$CONSOLE_USER" && "\$CONSOLE_USER" != "root" ]]; then
    CONSOLE_UID="\$(id -u "\$CONSOLE_USER" 2>/dev/null)"
    if [[ -n "\$CONSOLE_UID" ]]; then
        launchctl bootstrap "gui/\$CONSOLE_UID" "\$AGENT_PLIST" >/dev/null 2>&1 || true
    fi
    # If RustDesk isn't running for the console user, open it.
    if ! pgrep -x RustDesk >/dev/null 2>&1; then
        sudo -u "\$CONSOLE_USER" /usr/bin/open -a "\$APP_PATH" >/dev/null 2>&1 &
        wait \$! 2>/dev/null
    fi
fi
WDEOF
sudo chmod +x "$WATCHDOG_SCRIPT"

sudo tee "$WATCHDOG_PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${WATCHDOG_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${WATCHDOG_SCRIPT}</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/lucidpc-rustdesk-watchdog.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/lucidpc-rustdesk-watchdog.log</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$WATCHDOG_PLIST"
sudo chmod 644 "$WATCHDOG_PLIST"
# Reload (unload then load) so changes take effect
sudo launchctl unload "$WATCHDOG_PLIST" 2>/dev/null || true
sudo launchctl load -w "$WATCHDOG_PLIST" 2>/dev/null || true

# Self-verify the layers. On macOS the layers are:
#   Layer 1: LaunchAgent that opens RustDesk on user login (our plist)
#   Layer 2: RustDesk's built-in restart-on-crash (the GUI keeps a watchdog
#            on its own service helper; we don't manage it)
#   Layer 3: Our LaunchDaemon watchdog that re-loads the agent every 5 min
AGENT_PLIST_OK=0
AGENT_LOADED=0
WATCHDOG_LOADED=0
if [[ -f "$RD_AGENT_PLIST" ]]; then
    AGENT_PLIST_OK=1
fi
if sudo launchctl list 2>/dev/null | awk '{print $3}' | grep -q "$RD_AGENT_LABEL"; then
    AGENT_LOADED=1
fi
if sudo launchctl list 2>/dev/null | awk '{print $3}' | grep -q "$WATCHDOG_LABEL"; then
    WATCHDOG_LOADED=1
fi

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
if [[ "$AGENT_PLIST_OK" == "1" ]]; then
    ok_line "LaunchAgent installed (auto-start on user login)"
else
    no_line "LaunchAgent NOT installed"
fi
if [[ "$AGENT_LOADED" == "1" ]]; then
    ok_line "LaunchAgent loaded in current user session"
else
    no_line "LaunchAgent not loaded yet (will load on next login)"
fi
if [[ "$WATCHDOG_LOADED" == "1" ]]; then
    ok_line "Watchdog (every 5 min, runs as root via launchd)"
else
    no_line "Watchdog NOT verified"
fi

echo ""
echo "  IMPORTANT first-time setup -- macOS permissions:"
echo "    System Preferences > Security & Privacy > Privacy"
echo "    Grant RustDesk access to:"
echo "      - Screen Recording (so the tech can see the screen)"
echo "      - Accessibility   (so the tech can control mouse/keyboard)"
echo "      - Input Monitoring (so keystrokes pass through)"
echo "    Without these, the tech connects but sees a black screen."
echo ""
echo "  Connect from your tech client using the Device ID + your password."
echo ""
