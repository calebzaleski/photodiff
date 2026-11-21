#!/bin/bash
# Builds PhotoDiff.app.
#
# SwiftPM has no macOS app target: it emits a bare executable with no bundle. PhotoKit
# reads NSPhotoLibraryUsageDescription out of a bundle's Info.plist, so without this
# step the permission prompt is attributed to the terminal or never appears at all.
#
# Launch the result with `open PhotoDiff.app`, never the raw binary.
set -euo pipefail

CONFIG="${1:-release}"
NAME="PhotoDiff"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/$NAME.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.1.0)"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/$NAME"
[ -x "$BIN" ] || { echo "No binary at $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>$NAME</string>
  <key>CFBundleDisplayName</key>          <string>$NAME</string>
  <key>CFBundleIdentifier</key>           <string>app.photodiff.viewer</string>
  <key>CFBundleExecutable</key>           <string>$NAME</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
  <key>CFBundleVersion</key>              <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>       <string>14.0</string>
  <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>PhotoDiff reads your photo library to work out which pictures your old libraries have that this one does not. It never adds, changes or deletes anything in it.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for the privacy prompt to be attributed to this app; not
# notarized, so the first launch needs a right-click then Open.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP ($VERSION)"
echo "    Run it with:  open \"$APP\""
