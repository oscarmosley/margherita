#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
if [ "$(uname -s)" != Darwin ]; then echo "Sign releases on your Mac."; exit 1; fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Margherita/Info.plist)"
DMG="${1:-$ROOT/Margherita-$VERSION.dmg}"
KEY="${MARGHERITA_SPARKLE_KEY:-$HOME/margherita-sparkle-private-key.txt}"
if [ ! -f "$KEY" ]; then
  echo "Save your private signing key as ~/margherita-sparkle-private-key.txt first. Never upload it to GitHub."
  exit 1
fi
if [ ! -f "$DMG" ]; then echo "Run Make DMG.command first. Cannot find $DMG"; exit 1; fi
chmod 600 "$KEY"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/margherita-sign.XXXXXX")"
cleanup() { hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
xcrun swift "$ROOT/scripts/write-appcast.swift" "$DMG" "$KEY" "$MOUNT/Margherita.app" "$ROOT/Margherita/Info.plist" "$ROOT/appcast.xml"
