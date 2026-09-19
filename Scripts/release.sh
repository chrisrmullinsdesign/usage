#!/bin/zsh
# Builds a distributable, notarized ClaudeUsage-<version>.dmg.
#
#   Scripts/release.sh            build, sign, notarize, staple, verify
#   Scripts/release.sh --no-notarize   skip notarization (the DMG will warn on other Macs)
#
# Notarization is what lets someone open the app by double-clicking it. Set it up once:
#
#   xcrun notarytool store-credentials ClaudeUsage \
#     --apple-id <your-apple-id> --team-id <your-team-id>
#
# (It asks for an app-specific password from appleid.apple.com, and stores it in your
# Keychain. Nothing secret is ever read by, or committed from, this script.)
set -euo pipefail
cd "${0:A:h}/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-ClaudeUsage}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP="build/ClaudeUsage.app"
DMG="build/ClaudeUsage-${VERSION}.dmg"
STAGE="build/dmg"

# 1. Build and sign. A release must carry a real Developer ID, never an ad-hoc signature.
./build.sh
if ! codesign -dv "$APP" 2>&1 | grep -q '^TeamIdentifier=[A-Z0-9]'; then
  echo "error: $APP is ad-hoc signed. A release needs a Developer ID Application certificate." >&2
  exit 1
fi

# 2. Notarize the app itself, then staple the ticket into the bundle, so the copy
#    inside the DMG is already trusted even if the DMG is unpacked or moved.
if [[ "${1:-}" != "--no-notarize" ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: no notarytool profile '$NOTARY_PROFILE'. See the header of this script." >&2
    exit 1
  fi
  ditto -c -k --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f build/notarize.zip
  xcrun stapler staple "$APP"
else
  echo "warning: skipping notarization — this build will be blocked by Gatekeeper on other Macs." >&2
fi

# 3. Package: the app beside an /Applications symlink, the familiar drag-to-install window.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Claude Usage" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/')}"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
[[ "${1:-}" != "--no-notarize" ]] && {
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
}

# 4. Verify exactly what a user's Mac will check on first launch.
echo "\n--- verification ---"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vvv -t install "$DMG"
spctl -a -vvv "$APP"
xcrun stapler validate "$DMG" || true
shasum -a 256 "$DMG"
echo "\nReady: $DMG"
