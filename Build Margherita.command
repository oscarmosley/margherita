#!/bin/bash
cd "$(dirname "$0")" || exit 1
# Includes checksum-verified FFmpeg/ffprobe download and local cache.
if /bin/bash scripts/build-app.sh; then
  echo
  echo "All done. Press Return to close this window."
else
  result=$?
  echo
  echo "The build stopped. The error is shown above."
  echo "Press Return to close this window."
  read -r _
  exit "$result"
fi
read -r _
