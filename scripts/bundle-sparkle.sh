#!/bin/bash
# Official universal binary; no Xcode or package resolution required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
CACHE="$ROOT/build/dependencies/sparkle-$VERSION"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
case "${1:-}" in
  --prepare)
    mkdir -p "$CACHE"
    ARCHIVE="$CACHE/Sparkle-$VERSION.tar.xz"
    if [ ! -f "$ARCHIVE" ]; then
      curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 \
        --connect-timeout 15 --max-time 180 "$URL" -o "$ARCHIVE.part" >&2
      mv "$ARCHIVE.part" "$ARCHIVE"
    fi
    ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
    if [ "$ACTUAL" != "$SHA256" ]; then
      echo "Sparkle checksum mismatch; refusing to use this download." >&2
      rm -f "$ARCHIVE"
      exit 1
    fi
    # Always extract afresh from the verified archive, not a mutable cached framework.
    rm -rf "$CACHE/distribution"
    mkdir -p "$CACHE/distribution"
    tar -xJf "$ARCHIVE" -C "$CACHE/distribution"
    for arch in arm64 x86_64; do
      xcrun lipo "$CACHE/distribution/Sparkle.framework/Sparkle" -verify_arch "$arch" >&2
    done
    test -f "$CACHE/distribution/LICENSE"
    printf '%s\n' "$CACHE/distribution"
    ;;
  --embed)
    DIST="$2"; APP="$3"
    mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
    ditto "$DIST/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    cp "$DIST/LICENSE" "$APP/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
    FRAME="$APP/Contents/Frameworks/Sparkle.framework"
    # Local ad-hoc build only. Inside-out signatures, then outer app in build-app.sh.
    codesign --force -s - "$FRAME/Versions/B/Autoupdate"
    codesign --force -s - "$FRAME/Versions/B/Updater.app"
    codesign --force -s - "$FRAME/Versions/B/XPCServices/Downloader.xpc"
    codesign --force -s - "$FRAME/Versions/B/XPCServices/Installer.xpc"
    codesign --force -s - "$FRAME"
    codesign --verify --deep --strict "$FRAME"
    ;;
  *) echo "Usage: $0 --prepare | --embed DISTRIBUTION APP" >&2; exit 2 ;;
esac
