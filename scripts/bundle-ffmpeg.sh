#!/bin/bash
# Standalone, best-effort helper. Parent treats failure as a warning.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?app bundle required}"
shift
ARCHS=("$@")
[ "${#ARCHS[@]}" -gt 0 ] || exit 1
CACHE="$ROOT/.ffmpeg-cache"
mkdir -p "$CACHE" "$APP/Contents/Resources/bin"
WORK="$(mktemp -d "$CACHE/.download.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CURL=(curl --fail --location --proto '=https' --proto-redir '=https'
      --connect-timeout 20 --max-time 240 --retry 2 --silent --show-error)

# Pinned release URLs and publisher SHA256 of the ZIP archives, checked 2026-10-19.
# https://ffmpeg.martin-riedl.de/ publishes both architectures and checksum files.
download_tool() {
  local arch="$1" tool="$2" release hash archive actual
  case "$arch/$tool" in
    arm64/ffmpeg)
      release="arm64/1789931890_9.0.2"; hash="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924" ;;
    arm64/ffprobe)
      release="arm64/1789931890_9.0.2"; hash="fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6" ;;
    x86_64/ffmpeg)
      release="amd64/1789931006_9.0.2"; hash="7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4" ;;
    x86_64/ffprobe)
      release="amd64/1789931006_9.0.2"; hash="2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd" ;;
    *) echo "Unsupported media tool architecture $arch" >&2; return 1 ;;
  esac
  archive="$CACHE/$tool-9.0.2-$arch.zip"
  if [ -f "$archive" ]; then
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [ "$actual" != "$hash" ]; then
      echo "Discarding corrupt cached $tool archive." >&2
      rm -f "$archive"
    fi
  fi
  if [ ! -f "$archive" ]; then
    echo "Downloading $tool 9.0.2 for $arch..."
    "${CURL[@]}" "https://ffmpeg.martin-riedl.de/download/macos/$release/$tool.zip" -o "$WORK/$tool-$arch.zip"
    actual="$(shasum -a 256 "$WORK/$tool-$arch.zip" | awk '{print $1}')"
    if [ "$actual" != "$hash" ]; then
      echo "SHA256 verification failed for $tool ($arch). Refusing to run it." >&2
      return 1
    fi
    mv "$WORK/$tool-$arch.zip" "$archive"
  fi
  # Stream only the expected member; never extract archive paths or symlinks.
  unzip -p "$archive" "$tool" > "$WORK/$tool-$arch"
  [ -s "$WORK/$tool-$arch" ]
  xcrun lipo -verify_arch "$arch" "$WORK/$tool-$arch"
}
for tool in ffmpeg ffprobe; do
  slices=()
  for arch in "${ARCHS[@]}"; do
    download_tool "$arch" "$tool"
    slices+=("$WORK/$tool-$arch")
  done
  output="$WORK/$tool"
  if [ "${#slices[@]}" -gt 1 ]; then
    xcrun lipo -create "${slices[@]}" -output "$output"
  else
    cp "${slices[0]}" "$output"
  fi
  chmod 755 "$output"
  xattr -dr com.apple.quarantine "$output" 2>/dev/null || true
  codesign --force -s - "$output"
  codesign --verify --strict "$output"
  "$output" -version > "$WORK/$tool-version.txt" 2>&1
done
# Install the pair only after both have passed all checks.
for tool in ffmpeg ffprobe; do
  cp "$WORK/$tool" "$APP/Contents/Resources/bin/$tool"
  cp "$WORK/$tool-version.txt" "$APP/Contents/Resources/bin/$tool-version.txt"
done
echo "Bundled checksum-verified FFmpeg and ffprobe. Future builds reuse .ffmpeg-cache."
