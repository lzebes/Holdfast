#!/bin/sh
# Removes the Holdfast background helper. Refuses while a lock is active.
LABEL=com.holdfast.enforcer
STATE="/Library/Application Support/Holdfast"
if [ -f "$STATE/state.json" ]; then
    echo "A lock is active. The helper can be removed once it ends." >&2
    exit 1
fi
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/PrivilegedHelperTools/$LABEL" "/Library/LaunchDaemons/$LABEL.plist" /var/run/holdfast.sock
rm -rf "$STATE"
sed -i '' '/^# >>> HOLDFAST BEGIN/,/^# <<< HOLDFAST END/d' /etc/hosts
exit 0
