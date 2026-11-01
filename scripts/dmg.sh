#!/bin/sh
# Builds build/Edmundz.dmg from build/Edmundz.app (run `task bundle` first).
set -eu
cd "$(dirname "$0")/.."
[ -d build/Edmundz.app ] || { echo "run task bundle first" >&2; exit 1; }
rm -rf build/dmg build/Edmundz.dmg
mkdir -p build/dmg
cp -R build/Edmundz.app build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname Edmundz -srcfolder build/dmg -ov -format UDZO build/Edmundz.dmg
echo "built build/Edmundz.dmg"
