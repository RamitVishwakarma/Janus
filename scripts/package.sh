#!/usr/bin/env bash
#
# Packages an already-built Switchboard.app for distribution: a disk image, a
# zip for anyone who would rather not mount one, and checksums for both.
#
#   ./build.sh && scripts/package.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP="Switchboard.app"
VERSION="${SWITCHBOARD_VERSION:-$(tr -d '[:space:]' < VERSION)}"
OUT="dist"

[[ -d "${APP}" ]] || { echo "No ${APP} — run ./build.sh first." >&2; exit 1; }

rm -rf "${OUT}"
mkdir -p "${OUT}"

echo "==> Disk image"
STAGING="$(mktemp -d)/Switchboard"
mkdir -p "${STAGING}"
cp -R "${APP}" "${STAGING}/"
# The shortcut is what makes the window a drag-to-install rather than a puzzle.
ln -s /Applications "${STAGING}/Applications"
hdiutil create \
    -volname "Switchboard ${VERSION}" \
    -srcfolder "${STAGING}" \
    -ov -quiet -format UDZO \
    "${OUT}/Switchboard-${VERSION}.dmg"
rm -rf "${STAGING}"

echo "==> Zip"
# ditto rather than zip: it keeps the bundle's symlinks and signature intact.
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${OUT}/Switchboard-${VERSION}.zip"

echo "==> Checksums"
( cd "${OUT}" && shasum -a 256 ./*.dmg ./*.zip | sed 's| \./| |' > SHA256SUMS.txt )

echo
ls -lh "${OUT}"
cat "${OUT}/SHA256SUMS.txt"
