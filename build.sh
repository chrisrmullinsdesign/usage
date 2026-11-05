#!/bin/zsh
# Builds build/ClaudeUsage.app as a universal binary (Apple silicon + Intel).
#
#   ./build.sh            build only
#   ./build.sh --install  also copy to ~/Applications and launch
#
# Signing: uses your "Developer ID Application" certificate when one is installed,
# otherwise falls back to an ad-hoc signature so anyone can build from source.
# Either way the hardened runtime is on and no entitlements are requested.
# CI sets SWIFTC_EXTRA_FLAGS="-warnings-as-errors" so a warning fails the build; local builds stay lenient.
# For a release users can install without Gatekeeper warnings, see Scripts/release.sh.
set -euo pipefail
cd "${0:A:h}"

APP="build/ClaudeUsage.app"
DEPLOYMENT_TARGET="14.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/arch

# One slice per architecture, then lipo them together: Rosetta-free on Intel Macs.
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 ${=SWIFTC_EXTRA_FLAGS:-} \
    -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
    Sources/*.swift -o "build/arch/ClaudeUsage-${arch}" &
done
wait
lipo -create build/arch/ClaudeUsage-arm64 build/arch/ClaudeUsage-x86_64 \
  -output "$APP/Contents/MacOS/ClaudeUsage"
rm -rf build/arch

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# `|| true`: with `pipefail`, a grep that matches nothing (no certificate installed) would
# otherwise abort the script here, before the ad-hoc fallback below could run.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/') || true
fi
if [[ -n "$IDENTITY" ]]; then
  # --timestamp needs the network; a release must have it, a local build can live without it.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP" 2>/dev/null \
    || codesign --force --options runtime --sign "$IDENTITY" "$APP"
  echo "Signed as: $IDENTITY"
else
  codesign --force --options runtime --sign - "$APP"
  echo "Signed ad-hoc (no Developer ID certificate found)."
fi
codesign --verify --strict --deep "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeUsage"))"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ClaudeUsage 2>/dev/null || true
  while pgrep -x ClaudeUsage >/dev/null; do sleep 0.2; done # `open` fails (-600) while the old copy is exiting
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ClaudeUsage.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/ClaudeUsage.app"
  echo "Installed and launched ~/Applications/ClaudeUsage.app"
fi
