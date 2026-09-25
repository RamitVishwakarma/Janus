#!/usr/bin/env bash
#
# Builds Janus.app.
#
# Needs the Xcode Command Line Tools and nothing else. No Xcode, no package
# manager, no signing certificate.
#
#   ./build.sh              build for this Mac
#   UNIVERSAL=1 ./build.sh  build for Apple silicon and Intel, as releases do

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Janus"
BUNDLE_ID="com.ramitvishwakarma.janus"
VERSION="${JANUS_VERSION:-$(tr -d '[:space:]' < VERSION)}"
APP="${APP_NAME}.app"
CONTENTS="${APP}/Contents"

echo "==> Building ${APP_NAME} ${VERSION}"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    # Built one architecture at a time and joined with lipo, rather than with
    # swiftpm's --arch, because that route needs a full Xcode install and this
    # one does not.
    SLICES=()
    for TRIPLE in arm64-apple-macosx13.0 x86_64-apple-macosx13.0; do
        echo "    ${TRIPLE}"
        swift build -c release --triple "${TRIPLE}"
        SLICES+=("$(swift build -c release --triple "${TRIPLE}" --show-bin-path)/${APP_NAME}")
    done
    BINARY="$(mktemp -d)/${APP_NAME}"
    lipo -create -output "${BINARY}" "${SLICES[@]}"
else
    swift build -c release
    BINARY="$(swift build -c release --show-bin-path)/${APP_NAME}"
fi

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BINARY}" "${CONTENTS}/MacOS/${APP_NAME}"

swift scripts/make-icon.swift "${CONTENTS}/Resources/AppIcon.icns" > /dev/null

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
    <!-- A regular app, not a menu-bar-only one: it keeps a Dock icon and opens
         its window on launch. A lone glyph in a crowded menu bar is too easy to
         lose, so the menu bar item is the shortcut rather than the whole app. -->
    <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Janus is deliberately not sandboxed: the App Sandbox
# would cut it off from the keychain entry and settings file it exists to move,
# which also means it could never ship through the App Store.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "${APP}"

echo
echo "Built $(pwd)/${APP}"
echo "Try it:     open ${APP}"
echo "Install it: cp -R ${APP} /Applications/"
