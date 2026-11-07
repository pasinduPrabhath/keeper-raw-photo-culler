#!/usr/bin/env bash
# Builds a release Keeper.app (ad-hoc signed) into ./dist.
#
#   ./Scripts/build-app.sh                         # build
#   ./Scripts/build-app.sh --run                   # build and open
#   KEEPER_GOOGLE_CLIENT_ID=xxx ./Scripts/build-app.sh   # bake a default Google OAuth client ID into the app
#   VERSION=1.2.0 ./Scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
APP="dist/Keeper.app"

echo "→ Compiling (release)…"
swift build -c release --product Keeper
BIN="$(swift build -c release --product Keeper --show-bin-path)/Keeper"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keeper"
sed -e "s/__VERSION__/$VERSION/" -e "s/__GOOGLE_CLIENT_ID__/${KEEPER_GOOGLE_CLIENT_ID:-}/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null

echo "✓ Built $APP"
if [[ "${1:-}" == "--run" ]]; then open "$APP"; fi
