#!/bin/bash
# Install Stats SMC helper as a legacy LaunchDaemon (root-owned, runs as
# root). Workaround for the upstream SMAppService path being broken on
# macOS 14+ where the Helper LaunchDaemon plist ships unsigned and
# SMAppService rejects registration with error -67028.
#
# Stats' Homebrew Cask at /Applications/Stats.app is what the launchd
# plist helper binary is signed against; we copy that same binary out
# of the bundle so it stays in sync with whatever version the user
# has installed.
#
# Re-run after Stats updates — the helper is part of the bundle, not
# a system component.

set -e

STATS_APP="/Applications/Stats.app"
HELPER_SRC="$STATS_APP/Contents/Library/LaunchServices/eu.exelban.Stats.SMC.Helper"
HELPER_DST="/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper"
LAUNCHD_DST="/Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist"

if [[ ! -f "$HELPER_SRC" ]]; then
    echo "ERROR: $HELPER_SRC not found. Install Stats first." >&2
    exit 1
fi

# Tear down any existing install so we start clean
if [[ -f "$LAUNCHD_DST" ]]; then
    sudo launchctl unload "$LAUNCHD_DST" 2>/dev/null || true
fi
sudo rm -f "$HELPER_DST" "$LAUNCHD_DST"

# Copy helper binary out, owned by root, mode 0755 (same as
# com.crystalidea.macsfancontrol.smcwrite next to it).
sudo cp "$HELPER_SRC" "$HELPER_DST"
sudo chmod 0755 "$HELPER_DST"
sudo chown root:wheel "$HELPER_DST"

# Write the LaunchDaemon plist. The signature is ad-hoc — launchd
# doesn't validate LaunchDaemon plist signatures the way SMAppService
# does, only the binary's own signature (which the bundle keeps).
sudo tee "$LAUNCHD_DST" > /dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>eu.exelban.Stats.SMC.Helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HELPER_DST</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>eu.exelban.Stats.SMC.Helper</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
sudo chmod 0644 "$LAUNCHD_DST"
sudo chown root:wheel "$LAUNCHD_DST"

# Load it. launchd starts the helper as root on Mach service
# eu.exelban.Stats.SMC.Helper; Stats (and my Swift probe above) talk
# to it over XPC.
sudo launchctl load "$LAUNCHD_DST"

# Give launchd a moment to start the helper.
sleep 1

if pgrep -f "$HELPER_DST" > /dev/null; then
    echo "OK: helper running as root"
    pgrep -lf "$HELPER_DST"
else
    echo "WARN: helper didn't appear in process list. Check 'sudo launchctl list | grep Stats'."
fi
