#!/bin/bash
# Selects the newest Xcode on the runner by its version, not its name, and prints what the build will use.
set -euo pipefail
best= best_version=0
for app in /Applications/Xcode*.app; do
    [ -f "$app/Contents/version.plist" ] || continue
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/version.plist")
    key=$(echo "$version" | awk -F. '{ printf "%03d%03d%03d", $1, $2, $3 }')
    if [ "$key" \> "$best_version" ]; then best=$app best_version=$key; fi
done
[ -n "$best" ] || { echo "no Xcode on this runner" >&2; exit 1; }
sudo xcode-select -s "$best/Contents/Developer"
xcodebuild -version
swift --version
