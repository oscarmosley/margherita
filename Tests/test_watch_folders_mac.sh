#!/bin/bash
# Real macOS compile and native watch integration; never claims a Linux substitute.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then echo "SKIP: macOS SDK required"; exit 0; fi
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Retain AppDelegate references without compiling the app's entry point.
sed '/^@main$/d' Margherita/MargheritaApp.swift > "$tmp/AppLifecycle.swift"
sources=()
for source in Margherita/*.swift; do
    [[ "$source" == "Margherita/MargheritaApp.swift" ]] || sources+=("$source")
done
xcrun swiftc -swift-version 5 -parse-as-library "${sources[@]}" "$tmp/AppLifecycle.swift" \
    Tests/watch_folders_mac_harness.swift -o "$tmp/watch-mac-tests"
"$tmp/watch-mac-tests"
