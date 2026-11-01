#!/bin/sh
# Assembles build/Edmundz.app. Usage: scripts/bundle.sh direct|mas
#   direct: Developer ID channel (Sparkle updates, hardened runtime)
#   mas:    Mac App Store channel (no Sparkle, App Sandbox entitlements)
# Ad-hoc signed by default; set SIGN_IDENTITY to a certificate name to sign for distribution.
set -eu
cd "$(dirname "$0")/.."
CHANNEL="${1:-direct}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
IDENTITY="${SIGN_IDENTITY:--}"
APP=build/Edmundz.app

[ -f Resources/mermaid.min.js ] || scripts/vendor.sh

if [ "$CHANNEL" = direct ]; then
  export EDMUNDZ_DIRECT=1
else
  unset EDMUNDZ_DIRECT || true
fi
swift build -c release --product Edmundz --arch arm64
BIN=$(swift build -c release --product Edmundz --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Edmundz" "$APP/Contents/MacOS/Edmundz"
cp -R Resources/. "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/AppIcon.iconset"

EXTRAFILE=$(mktemp)
if [ "$CHANNEL" = direct ]; then
  cat > "$EXTRAFILE" <<'PLIST'
    <key>SUFeedURL</key><string>https://example.com/edmundz/appcast.xml</string>
    <key>SUPublicEDKey</key><string>REPLACE_WITH_SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><false/>
PLIST
fi
awk -v v="$VERSION" -v b="$BUILD" -v ef="$EXTRAFILE" '
  /@EXTRA@/ { while ((getline line < ef) > 0) print line; next }
  { gsub(/@VERSION@/, v); gsub(/@BUILD@/, b); print }' scripts/Info.plist.in > "$APP/Contents/Info.plist"
rm -f "$EXTRAFILE"

# Sparkle.framework travels with the direct channel only
if [ "$CHANNEL" = direct ]; then
  SP=$(find .build -type d -name Sparkle.framework -path "*macos-arm64*" 2>/dev/null | head -1)
  [ -n "$SP" ] || SP=$(find .build -type d -name Sparkle.framework 2>/dev/null | head -1)
  if [ -n "$SP" ]; then
    cp -R "$SP" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Edmundz" 2>/dev/null || true
  fi
fi
rmdir "$APP/Contents/Frameworks" 2>/dev/null || true

# Quick Look preview extension (Finder space-bar preview of .md files)
swift build -c release --product EdmundzQuickLook --arch arm64
QLBIN=$(swift build -c release --product EdmundzQuickLook --arch arm64 --show-bin-path)/EdmundzQuickLook
APPEX="$APP/Contents/PlugIns/EdmundzQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$QLBIN" "$APPEX/Contents/MacOS/EdmundzQuickLook"
awk -v v="$VERSION" -v b="$BUILD" '{ gsub(/@VERSION@/, v); gsub(/@BUILD@/, b); print }' scripts/QuickLook-Info.plist.in > "$APPEX/Contents/Info.plist"

ENT=scripts/entitlements/$CHANNEL.entitlements
QLENT=scripts/entitlements/quicklook.entitlements
sign() { # sign <path> [entitlements]
  if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - ${2:+--entitlements "$2"} "$1"
  else
    codesign --force --timestamp --options runtime --sign "$IDENTITY" ${2:+--entitlements "$2"} "$1"
  fi
}
# nested code first, each with its own entitlements; the app last (no --deep, which would reuse the app's entitlements)
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] && sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APPEX" "$QLENT"
sign "$APP" "$ENT"
codesign --verify --deep --strict "$APP" && echo "built $APP ($CHANNEL, version $VERSION, signed: $IDENTITY)"
