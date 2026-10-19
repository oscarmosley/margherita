#!/bin/bash
# Build with Apple's Command Line Tools, without Xcode or asset-catalog tools.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Build Margherita on a Mac running macOS 13 or newer."
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Install Apple's Command Line Tools by running this in Terminal"
  echo "  xcode-select --install"
  echo "When installation finishes, double-click Build Margherita.command again."
  exit 1
fi
if ! SDK="$(xcrun --sdk macosx --show-sdk-path)" ||
   ! SWIFTC="$(xcrun --find swiftc)" || [ ! -d "$SDK" ] || [ ! -x "$SWIFTC" ]; then
  echo "The selected developer tools do not include a usable macOS SDK and Swift compiler."
  echo "Run xcode-select --install, then retry."
  echo "If CLT is already installed, select it with"
  echo "  sudo xcode-select --switch /Library/Developer/CommandLineTools"
  exit 1
fi

# Default to this Mac's architecture. MARGHERITA_UNIVERSAL=1 builds both slices.
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported Mac architecture $ARCH"; exit 1 ;;
esac
ARCHS=("$ARCH")
if [ "${MARGHERITA_UNIVERSAL:-0}" = "1" ]; then
  ARCHS=(arm64 x86_64)
fi
SOURCES=()
while IFS= read -r -d '' source; do
  SOURCES+=("$source")
done < <(find "$ROOT/Margherita" -type f -name '*.swift' -print0)
if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "No Margherita Swift sources found."; exit 1
fi

mkdir -p "$ROOT/build"
WORK="$(mktemp -d "$ROOT/build/.margherita-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Margherita.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK/modules"
FRAMEWORKS=(Foundation SwiftUI AppKit ApplicationServices CoreServices CoreGraphics CoreImage
            ImageIO CoreText Vision AVFoundation AudioToolbox PDFKit UniformTypeIdentifiers
            UserNotifications ServiceManagement CryptoKit)
LINK_FLAGS=()
for framework in "${FRAMEWORKS[@]}"; do
  LINK_FLAGS+=(-framework "$framework")
done
# Sparkle is optional for offline builds. Probe import before linking.
SPARKLE_DIST=""
if [ "${MARGHERITA_SPARKLE:-1}" != "0" ]; then
  if SPARKLE_DIST="$(/bin/bash "$ROOT/scripts/bundle-sparkle.sh" --prepare)"; then
    echo 'import Sparkle' > "$WORK/SparkleProbe.swift"
    for arch in "${ARCHS[@]}"; do
      if ! "$SWIFTC" -sdk "$SDK" -target "${arch}-apple-macos13" -F "$SPARKLE_DIST" -typecheck "$WORK/SparkleProbe.swift"; then
        SPARKLE_DIST=""
        break
      fi
    done
  else
    SPARKLE_DIST=""
  fi
fi
if [ -n "$SPARKLE_DIST" ]; then
  LINK_FLAGS+=(-F "$SPARKLE_DIST" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
else
  echo "WARNING: Sparkle unavailable with these tools/network. Building without automatic updates."
fi
BINARIES=()
for arch in "${ARCHS[@]}"; do
  echo "Compiling Margherita for $arch. The first build can take a few minutes."
  "$SWIFTC" -sdk "$SDK" -target "${arch}-apple-macos13" \
    -swift-version 5 -O -parse-as-library -module-name Margherita \
    -module-cache-path "$WORK/modules" \
    "${SOURCES[@]}" "${LINK_FLAGS[@]}" -o "$WORK/Margherita-$arch"
  BINARIES+=("$WORK/Margherita-$arch")
done
if [ "${#BINARIES[@]}" -gt 1 ]; then
  xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Margherita"
else
  cp "${BINARIES[0]}" "$APP/Contents/MacOS/Margherita"
fi
chmod 755 "$APP/Contents/MacOS/Margherita"

# Preserve the project's plist settings, including LSUIElement if one is added.
# These are the only Xcode build variables used by the checked-in Info.plist.
sed -e 's/$(EXECUTABLE_NAME)/Margherita/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.oscar.margherita/g' \
    -e 's/$(PRODUCT_NAME)/Margherita/g' \
    "$ROOT/Margherita/Info.plist" > "$APP/Contents/Info.plist"
if grep -q '\$(' "$APP/Contents/Info.plist"; then
  echo "Info.plist contains an unresolved build setting. Build stopped."
  exit 1
fi
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon.icns' "$PLIST"
plutil -lint "$PLIST"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# No actool needed. Runtime views use literal colors and SF Symbols, not assets.
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$ROOT/Margherita-icon.png" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -s format png -z "$double" "$double" "$ROOT/Margherita-icon.png" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Copy additional resources, retaining relative paths (including .lproj folders).
while IFS= read -r -d '' resource; do
  relative="${resource#"$ROOT/Margherita/"}"
  case "$relative" in
    *.swift|Info.plist|*.entitlements|.DS_Store|*/.DS_Store) continue ;;
  esac
  mkdir -p "$APP/Contents/Resources/$(dirname "$relative")"
  cp -p "$resource" "$APP/Contents/Resources/$relative"
done < <(find "$ROOT/Margherita" -type d -name '*.xcassets' -prune -o -type f -print0)

# Build.command delegates here. Media tools are optional if the network is unavailable.
if ! /bin/bash "$ROOT/scripts/bundle-ffmpeg.sh" "$APP" "${ARCHS[@]}"; then
  rm -f "$APP/Contents/Resources/bin/ffmpeg" "$APP/Contents/Resources/bin/ffprobe"
  echo "WARNING: FFmpeg download/bundling failed. The app still builds; advanced formats need FFmpeg on PATH or Homebrew."
fi

if [ -n "$SPARKLE_DIST" ]; then
  /bin/bash "$ROOT/scripts/bundle-sparkle.sh" --embed "$SPARKLE_DIST" "$APP"
fi

# Strip inherited download attributes from the new local bundle, not its source.
xattr -cr "$APP"
if [ -n "$SPARKLE_DIST" ]; then
  codesign --force -s - "$APP"
else
  # Keep legacy signing for builds without pre-signed nested Sparkle components.
  codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict "$APP"

# Only replace our previous build after compilation, bundling and signing succeed.
DEST="$ROOT/build/Margherita.app"
if [ -L "$DEST" ]; then
  echo "Refusing to replace a symbolic link at $DEST"; exit 1
fi
if [ -e "$DEST" ]; then
  mv "$DEST" "$WORK/Previous-Margherita.app"
fi
if ! mv "$APP" "$DEST"; then
  if [ -d "$WORK/Previous-Margherita.app" ]; then
    mv "$WORK/Previous-Margherita.app" "$DEST"
  fi
  exit 1
fi
echo
echo "Built $DEST"
echo "Open the build folder, then drag Margherita.app into Applications."
echo "Quit any running copy before replacing it. No Xcode is needed."
