#!/bin/sh
set -eu

host_plist="$SRCROOT/iosApp/Info.plist"
extension_plist="$SCRIPT_OUTPUT_FILE_0"
mkdir -p "$(dirname "$extension_plist")"
cp "$SRCROOT/RemoteNowPlaying/Info.plist" "$extension_plist"
for key in CFBundleVersion CFBundleShortVersionString; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$host_plist")
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$extension_plist"
done
