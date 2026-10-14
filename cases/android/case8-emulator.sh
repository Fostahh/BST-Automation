#!/usr/bin/env bash
# NAME: Case 8 — Emulator
# Manual APK/APKS or automatic MT Manager extraction -> clean install -> launch.
# env: APK_SOURCE=manual|auto, APK=<Mac path>, AVD=<name>,
#      TARGET_PKG=<source package>, EMULATOR=<binary>, AAPT2=<binary>, BOOT_TIMEOUT=300.
# Automatic mode extracts from the device the runner selected (DEV_SERIAL).
# Manual mode needs no physical device. The emulator stays open after completion.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -u "$HERE/../../lib/android/py/emulator-case.py"
