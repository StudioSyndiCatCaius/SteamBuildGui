#!/bin/bash
# Build SteamBuildGui for macOS. Double-click in Finder or run from Terminal.
#
#   ./MacOs_Build.command          optimized build -> bin/SteamBuildGui.app
#   ./MacOs_Build.command debug    debug build     -> bin/SteamBuildGui (run from Terminal to see logs)
#
# The .app keeps its data in ~/Library/Application Support/SteamBuildGui
# (config, steamcmd/, steam_build/). The loose debug binary keeps it next to itself in bin/.

set -e
cd "$(dirname "$0")"

if ! command -v odin >/dev/null 2>&1; then
    # Homebrew isn't on PATH when launched from Finder.
    for p in /opt/homebrew/bin /usr/local/bin "$HOME/odin"; do
        [ -x "$p/odin" ] && export PATH="$p:$PATH"
    done
fi
if ! command -v odin >/dev/null 2>&1; then
    echo "Odin compiler not found. Run MacOs_InstallOdin.command first."
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

mkdir -p bin

if [ "$1" = "debug" ]; then
    odin build src -out:bin/SteamBuildGui -debug -vet -strict-style
    echo "Built bin/SteamBuildGui"
    exit 0
fi

odin build src -out:bin/SteamBuildGui -o:speed -vet -strict-style

APP=bin/SteamBuildGui.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv bin/SteamBuildGui "$APP/Contents/MacOS/SteamBuildGui"

# App icon: render the procedural icon to PNG, then build an .icns.
ICONSET=$(mktemp -d)/SteamBuildGui.iconset
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/SteamBuildGui" --write-icon "$ICONSET/icon_512x512.png" >/dev/null
for s in 16 32 128 256; do
    sips -z $s $s "$ICONSET/icon_512x512.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICONSET/icon_512x512.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/SteamBuildGui.icns" || echo "(icon generation failed, continuing)"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SteamBuildGui</string>
    <key>CFBundleDisplayName</key><string>SteamBuildGui</string>
    <key>CFBundleIdentifier</key><string>com.steambuildgui.app</string>
    <key>CFBundleExecutable</key><string>SteamBuildGui</string>
    <key>CFBundleIconFile</key><string>SteamBuildGui</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper/Keychain treat it as a stable app on this Mac.
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "Built $APP"
