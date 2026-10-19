#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Install Xcode from the Mac App Store and open it once first."
  exit 1
fi
xcodebuild -project Margherita.xcodeproj -scheme Margherita -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
echo "Built app at $(pwd)/build/Build/Products/Release/Margherita.app"
echo "Drag that app into Applications, then open it."
open -R build/Build/Products/Release/Margherita.app
