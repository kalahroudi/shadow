#!/bin/bash
# Resets the macOS privacy (TCC) grants for Shadow only, after an explicit y/N confirmation.
# Use it to re-test how Shadow registers in System Settings > Privacy & Security.
set -euo pipefail

BUNDLE_ID="com.kalahroudi.shadow"

if [ ! -t 0 ]; then
  echo "Refusing to run: stdin is not a terminal, so the confirmation cannot be given." >&2
  exit 1
fi

read -r -p "Reset Screen/Microphone permissions for $BUNDLE_ID? [y/N] " answer || { echo "No answer; nothing reset." >&2; exit 1; }
case "$answer" in
  y|Y) ;;
  *) echo "Cancelled; nothing reset."; exit 0 ;;
esac

tccutil reset ScreenCapture "$BUNDLE_ID"
tccutil reset Microphone "$BUNDLE_ID"
echo "Reset done for $BUNDLE_ID."
