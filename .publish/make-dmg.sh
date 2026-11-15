#!/bin/zsh
# Baut den DMG-Inhalt: App, Programme-Verknüpfung, LICENSE (GPL-3.0-or-later) und Quellverweis.
# Aufruf: .publish/make-dmg.sh <Pfad/FIRSTofFIFTH.app> <Ziel.dmg>
# Signieren und Notarisieren folgen danach wie bisher (codesign --timestamp, notarytool mit dem
# Keychain-Profil "FIRSTofFIFTH", stapler). Das Skript fasst keine Zugangsdaten an.
set -euo pipefail
APP=${1:?App-Pfad fehlt}
OUT=${2:?Ziel-DMG fehlt}
ROOT=${0:A:h:h}
VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/FIRSTofFIFTH.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
cat > "$STAGE/SOURCE.txt" <<EOT
FIRSTofFIFTH $VERSION
Copyright (c) 2026 Stephan Schmitt
License: GNU General Public License v3.0 or later (LICENSE.txt)

Source code (corresponding source for this release: tag v$VERSION):
https://github.com/easysteve-coder/FIRSTofFIFTH

Third-party notices: FIRSTofFIFTH.app/Contents/Resources/THIRD_PARTY_NOTICES.md
EOT

rm -f "$OUT"
hdiutil create -volname "FIRSTofFIFTH $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT" >/dev/null
echo "$OUT"
