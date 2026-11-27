#!/bin/sh
# Installs the Holdfast background helper. Run as root by the app (one administrator prompt).
set -e
RES="$1"
LABEL=com.holdfast.enforcer
BIN="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
STATE="/Library/Application Support/Holdfast"

mkdir -p /Library/PrivilegedHelperTools "$STATE"
chown root:wheel "$STATE"; chmod 755 "$STATE"

launchctl bootout "system/$LABEL" 2>/dev/null || true
cp -f "$RES/holdfast-enforcer" "$BIN"
chown root:wheel "$BIN"; chmod 755 "$BIN"
cp -f "$RES/$LABEL.plist" "$PLIST"
chown root:wheel "$PLIST"; chmod 644 "$PLIST"

# bootout finishes asynchronously, so retry until the service slot is free.
i=0
until launchctl bootstrap system "$PLIST" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge 10 ] && { echo "Could not start the Holdfast helper." >&2; exit 1; }
    sleep 1
done
