#!/usr/bin/env bash
# Builds dist/Keeper-<version>.zip and dist/Keeper-<version>.dmg ready to attach to a GitHub release.
#   VERSION=1.0.0 ./Scripts/package-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
export VERSION
./Scripts/build-app.sh

echo "→ Zipping"
rm -f "dist/Keeper-$VERSION.zip" "dist/Keeper-$VERSION.dmg"
ditto -c -k --keepParent dist/Keeper.app "dist/Keeper-$VERSION.zip"

echo "→ Building disk image"
STAGE="$(mktemp -d)"
cp -R dist/Keeper.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Keeper" -srcfolder "$STAGE" -ov -format UDZO "dist/Keeper-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
shasum -a 256 dist/Keeper-$VERSION.zip dist/Keeper-$VERSION.dmg
echo "✓ dist/Keeper-$VERSION.zip  dist/Keeper-$VERSION.dmg"
