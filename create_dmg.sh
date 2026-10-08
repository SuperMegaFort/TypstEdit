#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./bundle_universal.sh "$@"
DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/typstedit-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "${APP_OUTPUT:-.build/TypstEdit.app}" "$DMG_STAGE/TypstEdit.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname TypstEdit -srcfolder "$DMG_STAGE" -ov -format UDZO .build/TypstEdit_Installer.dmg
