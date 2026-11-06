#!/bin/zsh
# Builds "Claude Profiles.app" for Apple silicon and Intel.
#
#   ./build.sh              ad-hoc signed, for running on this Mac
#   ./build.sh --install    the same, then copied to /Applications and launched
#   ./build.sh --release    Developer ID signed, notarized, stapled, and packaged as
#                           build/ClaudeProfiles.dmg. Needs these environment variables:
#                             DEVID_P12, DEVID_P12_PASSWORD   the Developer ID Application certificate
#                             NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key
#                           or SIGN_IDENTITY to use a certificate already in your keychain.
#   MARKETING_VERSION=1.2.0 sets the version (default 1.0).
set -euo pipefail
cd "${0:A:h}"

MODE="${1:-}"
APP="build/Claude Profiles.app"
VERSION="${MARKETING_VERSION:-1.0}"
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

rm -rf "$APP" "build/Claude Usage Bar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos26" \
    Sources/*.swift -o "build/obj/ClaudeProfiles-$arch"
done
lipo -create build/obj/ClaudeProfiles-arm64 build/obj/ClaudeProfiles-x86_64 \
  -output "$APP/Contents/MacOS/ClaudeProfiles"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.kevinabouhanna.ClaudeProfiles</string>
  <key>CFBundleName</key><string>Claude Profiles</string>
  <key>CFBundleDisplayName</key><string>Claude Profiles</string>
  <key>CFBundleExecutable</key><string>ClaudeProfiles</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [[ "$MODE" != "--release" ]]; then
  codesign --force --sign - "$APP"
  echo "Built $APP"
  if [[ "$MODE" == "--install" ]]; then
    pkill -x ClaudeProfiles 2>/dev/null || true
    pkill -x ClaudeUsageBar 2>/dev/null || true   # the app's old name
    rm -rf "/Applications/Claude Profiles.app" "/Applications/Claude Usage Bar.app"
    cp -R "$APP" /Applications/
    open "/Applications/Claude Profiles.app"
    echo "Installed and launched"
  fi
  exit 0
fi

# MARK: Release: Developer ID, hardened runtime, notarized and stapled.

KEYCHAIN=""
cleanup() { [[ -n "$KEYCHAIN" ]] && security delete-keychain "$KEYCHAIN" 2>/dev/null || true; }
trap cleanup EXIT

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  : "${DEVID_P12:?set DEVID_P12 (or SIGN_IDENTITY)}" "${DEVID_P12_PASSWORD:?set DEVID_P12_PASSWORD}"
  KEYCHAIN="$PWD/build/signing.keychain-db"
  KEYCHAIN_PASSWORD=$(uuidgen)
  rm -f "$KEYCHAIN"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings -lut 3600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security import "$DEVID_P12" -k "$KEYCHAIN" -P "$DEVID_P12_PASSWORD" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  SIGN_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  [[ -n "$SIGN_IDENTITY" ]] || { echo "No Developer ID Application identity in DEVID_P12" >&2; exit 1; }
fi
: "${NOTARY_KEY:?set NOTARY_KEY}" "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER:?set NOTARY_ISSUER}"

notarize() {
  xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait --timeout 30m --output-format json | tee build/notary.json
  grep -q '"status" *: *"Accepted"' build/notary.json || {
    id=$(sed -nE 's/.*"id" *: *"([^"]+)".*/\1/p' build/notary.json | head -1)
    [[ -n "$id" ]] && xcrun notarytool log "$id" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
    echo "Notarization failed" >&2; exit 1
  }
}

echo "Signing with $SIGN_IDENTITY"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# The app first, so it's stapled before it's packaged: it then opens without a
# warning even offline, after being dragged out of the disk image.
ditto -c -k --keepParent "$APP" build/ClaudeProfiles.zip
notarize build/ClaudeProfiles.zip
xcrun stapler staple "$APP"
rm build/ClaudeProfiles.zip

DMG=build/ClaudeProfiles.dmg
rm -rf build/dmg "$DMG"
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Claude Profiles" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
rm -rf build/dmg
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

spctl -a -vv "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "Released $DMG ($VERSION, build $BUILD_NUMBER)"
