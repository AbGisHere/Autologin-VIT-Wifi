#!/bin/bash
# Removes Autologin-VIT-Wifi, its files and the stored Keychain password.
LABEL="com.local.autologin-vit-wifi"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/autologin-vit-wifi"
security delete-generic-password -s "autologin-vit-wifi" >/dev/null 2>&1
echo "Removed. The log is kept at ~/Library/Logs/autologin-vit-wifi.log (delete it by hand if you like)."
