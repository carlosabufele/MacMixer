#!/bin/bash
# Builds MacMixer in Release mode, signs it to run locally with Hardened Runtime,
# optionally installs it in /Applications, and zips it into releases/.
#
# Usage (from the repo root):
#   scripts/build-release.sh            # build + zip
#   scripts/build-release.sh --install  # build + zip + copy to /Applications
#
# The build goes to ~/Library/Developer/Xcode/DerivedData/MacMixer, NOT inside
# this folder: Documents is synced by iCloud, which adds file attributes that
# make code signing fail.
set -euo pipefail

cd "$(dirname "$0")/.."
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/MacMixer"
APP="$DERIVED/Build/Products/Release/MacMixer.app"

xcodebuild -project MacMixer.xcodeproj -scheme MacMixer -configuration Release \
    -derivedDataPath "$DERIVED" clean build | grep -E "error|warning:|BUILD" || true

# Xcode turns Hardened Runtime off for ad-hoc ("Sign to Run Locally") builds,
# so sign again with it on. This also drops the debugging entitlement.
codesign --force --options runtime --timestamp=none --sign - "$APP"
codesign --verify --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p releases
# Never overwrite a release that already exists (e.g. MacMixer-1.0.0.zip):
# bump MARKETING_VERSION in Xcode for a new build instead.
if [[ -e "releases/MacMixer-$VERSION.zip" ]]; then
    echo "releases/MacMixer-$VERSION.zip already exists; bump the version first." >&2
    exit 1
fi
ditto -c -k --keepParent "$APP" "releases/MacMixer-$VERSION.zip"
echo "Built MacMixer $VERSION -> releases/MacMixer-$VERSION.zip"

if [[ "${1:-}" == "--install" ]]; then
    # Quit any running copy (it removes its taps on the way out).
    pkill -TERM -x MacMixer || true   # exact process name only
    sleep 2
    rm -rf /Applications/MacMixer.app
    ditto "$APP" /Applications/MacMixer.app
    open /Applications/MacMixer.app
    echo "Installed and launched /Applications/MacMixer.app"
fi
