#!/usr/bin/env bash
# Internal Case 8 preparation step. Only this process targets the source phone.
set -euo pipefail
LIB8="$(cd "$(dirname "$0")" && pwd)"
DEV_SERIAL="$1"                             # an adb serial, chosen by the runner
TARGET_PKG="$2"
OUTPUT_DIR="$3"
DEV_NAME="$DEV_SERIAL"
export DEV_NAME DEV_SERIAL TARGET_PKG       # no PIN: device-ready.sh asks if it needs one
source "$LIB8/common.sh"
source "$LIB8/device-ready.sh"
source "$LIB8/mtmanager.sh"
detect_size          # mtmanager.sh locates MT Manager's bars by fractions of W/H
ensure_device_unlocked
mt_launch_fresh
mt_require_login
mt_extract "$TARGET_PKG"
case "$MT_APK_PATH" in
  *.apk|*.apks) : ;;                        # pulled raw — the .apks is unzipped downstream
  *) echo "!! Unsupported extraction: $MT_APK_PATH" >&2; exit 1 ;;
esac
mt_info_close
echo "   retrieving extracted file from $DEV_NAME ..."
mt_pull "$MT_APK_PATH"                      # -> Automation/extracted/ (shared destination)
mt_offer_device_cleanup "$MT_APK_PATH"      # optional: keep MT2/apks from piling up
printf '%s\n' "$PULLED" > "$OUTPUT_DIR/source-path.txt"
