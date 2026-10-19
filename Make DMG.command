#!/bin/bash
cd "$(dirname "$0")" || exit 1
if /bin/bash scripts/make-dmg.sh; then
  echo
  echo "All done. Press Return to close this window."
  read -r _
else
  result=$?
  echo
  echo "Packaging stopped. The error is shown above."
  echo "Press Return to close this window."
  read -r _
  exit "$result"
fi
