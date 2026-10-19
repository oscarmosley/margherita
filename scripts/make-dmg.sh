#!/bin/bash
# Stock macOS tools only. Never modifies or rebuilds the app being packaged.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Create the DMG on a Mac after running Build Margherita.command."
  exit 1
fi
APP="$ROOT/build/Margherita.app"
if [ ! -d "$APP" ] || [ -L "$APP" ] || [ ! -f "$APP/Contents/Info.plist" ]; then
  echo "No built app found. Run Build Margherita.command first."
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
case "$VERSION" in
  ""|*[!0-9.]*|.*|*.) echo "The app has an invalid release version."; exit 1 ;;
esac
DEST="$ROOT/Margherita-$VERSION.dmg"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  echo "A DMG already exists at $DEST"
  echo "Move it out of the way before creating another. Nothing was overwritten."
  exit 1
fi
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/build"
WORK="$(mktemp -d "$ROOT/build/.margherita-dmg.XXXXXX")"
MOUNT="/Volumes/Margherita $VERSION"
ATTACHED=0
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$ATTACHED" = 1 ]; then
    if ! hdiutil detach "$MOUNT" -force; then
      echo "Could not eject $MOUNT. Eject it manually; temporary files retained." >&2
      exit 1
    fi
  fi
  rm -rf "$WORK"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
STAGE="$WORK/Drag Margherita to Applications"
mkdir -p "$STAGE"
# ditto preserves executable bits, resource forks and the app's existing signature.
ditto "$APP" "$STAGE/Margherita.app"
ln -s /Applications "$STAGE/Applications"
# Render at both native and Retina resolution, with logical dimensions retained
# in the multi-resolution TIFF used by Finder. No third-party packaging tools.
mkdir -p "$STAGE/.background"
if [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -force || true; fi
swiftc "$ROOT/scripts/render-dmg.swift" -o "$WORK/render-dmg"
"$WORK/render-dmg" "$STAGE/.background" "$VERSION"
tiffutil -cathidpicheck "$STAGE/.background/background.png" \
  "$STAGE/.background/background@2x.png" -out "$STAGE/.background/background.tiff"
test -s "$STAGE/.background/background.tiff"
ICON="$APP/Contents/Resources/AppIcon.icns"
if [ ! -s "$ICON" ]; then
  echo "The built app's pizza icon is missing. Rebuild the app first." >&2
  exit 1
fi
cp "$ICON" "$STAGE/.VolumeIcon.icns"
hdiutil create -volname "Margherita $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDRW "$WORK/writable.dmg"
# Mark before attach: even a partially failed attach must attempt cleanup.
ATTACHED=1
hdiutil attach "$WORK/writable.dmg" -readwrite -noverify
"$WORK/render-dmg" --volume-icon "$MOUNT"
echo "Arranging Finder. Allow Terminal to control Finder if macOS asks."
sleep 2
osascript "$ROOT/scripts/layout-dmg.applescript" "$MOUNT" "Margherita $VERSION"
sync; sleep 3
if [ ! -s "$MOUNT/.DS_Store" ]; then
  echo "Finder did not save the installer layout. No release DMG was published; retry with Finder automation allowed." >&2
  exit 1
fi
hdiutil detach "$MOUNT"
ATTACHED=0
hdiutil convert "$WORK/writable.dmg" -format UDZO -imagekey zlib-level=9 \
  -o "$WORK/release.dmg"
hdiutil verify "$WORK/release.dmg"
# A hard link publishes exclusively, avoiding replacement if another process
# created the destination while hdiutil was working. Both paths share a volume.
ln "$WORK/release.dmg" "$DEST"
echo
echo "Created $DEST"
echo "Open the DMG, drag Margherita.app into Applications, then eject the image."
echo "The source ZIP is unchanged."
echo "This does not notarise the app or satisfy third-party binary source obligations."
