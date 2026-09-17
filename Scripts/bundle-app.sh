#!/usr/bin/env bash
# Builds MieSQL and assembles a runnable MieSQL.app.
#
# SwiftPM produces a bare executable; macOS needs it inside a bundle with an Info.plist
# before it can show a window, own a menu bar or reach the Keychain. This script does that
# assembly, so the whole project builds with the command line tools and no Xcode project.
#
#   ./Scripts/bundle-app.sh [debug|release]

set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MieSQL"
BUNDLE="$ROOT/build/$APP_NAME.app"

# Xcode's own tools are not required; the standalone Command Line Tools are enough, and
# using them avoids the Xcode licence prompt on machines that have never opened Xcode.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

echo "==> Building ($CONFIGURATION)"
cd "$ROOT"
swift build -c "$CONFIGURATION"

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
if [ ! -x "$BINARY" ]; then
    echo "error: built binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# An ad-hoc signature is enough for local use and keeps Keychain access working across
# launches. Replace "-" with a Developer ID to produce something distributable.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 || {
    echo "warning: ad-hoc signing failed; the app will still run locally" >&2
}

echo "==> Done: $BUNDLE"
