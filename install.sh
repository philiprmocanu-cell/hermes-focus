#!/bin/bash
# Build and install Hermes Focus to ~/Applications/HermesFocus.app.
#   ./install.sh            build, sign (ad-hoc, or HERMES_FOCUS_SIGN_ID), install
#   ./install.sh --launch   ...and open it
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="HermesFocus"
BUNDLE_ID="app.hermesfocus.mac"
DEST="$HOME/Applications/$APP_NAME.app"
LAUNCH=0; for a in "$@"; do [ "$a" = "--launch" ] && LAUNCH=1; done
cd "$HERE"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"
STAGE="$HERE/build/$APP_NAME.app"
rm -rf "$STAGE"; mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/Fonts"
cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$STAGE/Contents/Resources/Fonts/"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
SIGN_ID="${HERMES_FOCUS_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | grep 'Apple Development' | head -1 | awk '{print $2}' || true)"
fi
if [ -n "$SIGN_ID" ]; then codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" --timestamp=none "$STAGE"
else echo "note: no Apple Development identity; ad-hoc signing (macOS will re-ask permissions after each rebuild)"; codesign --force --sign - --identifier "$BUNDLE_ID" "$STAGE"; fi
mkdir -p "$HOME/Applications"; rm -rf "$DEST"; ditto "$STAGE" "$DEST"
echo "installed $DEST"
[ "$LAUNCH" = 1 ] && open -a "$DEST" || true
