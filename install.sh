#!/bin/bash
# Installs Autologin-VIT-Wifi for the current macOS user.
#   1. stores your registration number and password in the login Keychain
#   2. copies autologin-vit-wifi.sh to ~/Library/Application Support/autologin-vit-wifi/
#   3. installs a LaunchAgent that keeps it running in --watch mode (from login, restarted if it stops)
# Re-run it to change the password. Undo everything with uninstall.sh.

set -eu

SERVICE="autologin-vit-wifi"
LABEL="com.local.autologin-vit-wifi"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/autologin-vit-wifi"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

existing=$(security find-generic-password -s "$SERVICE" 2>/dev/null | awk -F'"' '/"acct"/{print $4}' || true)
if [ -n "$existing" ]; then
  printf 'A password is stored for %s. Replace it? [y/N] ' "$existing"
  read -r ans
  case "$ans" in [yY]*) security delete-generic-password -s "$SERVICE" >/dev/null ;; *) existing="keep" ;; esac
fi
if [ "$existing" != "keep" ]; then
  printf 'VIT registration number (Wi-Fi user ID): '
  read -r user
  [ -n "$user" ] || { echo "no user ID given" >&2; exit 1; }
  echo "Now type your Wi-Fi password twice (nothing is shown while you type):"
  security add-generic-password -U -s "$SERVICE" -a "$user" -l "Autologin-VIT-Wifi" -w
  echo "Stored in the login Keychain as \"$SERVICE\"."
fi

mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$HERE/autologin-vit-wifi.sh" "$DEST/autologin-vit-wifi.sh"
chmod 755 "$DEST/autologin-vit-wifi.sh"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DEST/autologin-vit-wifi.sh</string>
    <string>--watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Standard</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/autologin-vit-wifi.err.log</string>
</dict>
</plist>
EOF

# bootout returns before a running agent has finished exiting, and bootstrap fails until it has,
# so wait for the old one to be gone (it stops within a second or two).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in $(seq 1 50); do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 3
echo
echo "Installed. Current status:"
/bin/bash "$DEST/autologin-vit-wifi.sh" --status
