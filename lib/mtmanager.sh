#!/usr/bin/env bash
# mtmanager.sh — shared MT Manager (bin.mt.plus) UI automation.
# Used by case 5 (Debug Testing) and case 7 (Certificate Tamper).
# Source AFTER lib/common.sh — relies on adbx(), launch(), ui_dump(), $UI_XML and $LIB
# from there. Taps/reads go through lib/py/uifind.py and are resolution-independent.

MT_PKG="${MT_PKG:-bin.mt.plus}"

# Shared destination: every case that pulls an APK off the device puts it here.
EXTRACTED_DIR="${EXTRACTED_DIR:-$(cd "$LIB/.." && pwd)/extracted}"   # Automation/extracted

# inpx/wake/ui_dump/ui_find/ui_tap come from common.sh. The one thing we need that
# common.sh does not provide is a STRICT tap-when: common's mt_tap_when is best-effort
# (returns 0 even when the element never appears, which cases 1-3 rely on under set -e),
# whereas every mt_* flow below wants `|| { fail }` to actually fire.
mt_tap_when() {                                          # dump+retry until found, then tap; rc1 if never
  local i
  for i in 1 2 3 4 5 6 7 8; do
    ui_dump
    if ui_find "$@" >/dev/null 2>&1; then ui_tap "$@"; return 0; fi
    sleep 1
  done
  return 1
}

mt_launch_fresh() {   # force-stop + launch MT Manager to its Home
  [ -n "$(adbx shell pm path --user current "$MT_PKG" 2>/dev/null | tr -d '\r')" ] \
    || { echo "!! MT Manager ($MT_PKG) is not installed on $DEV_SERIAL." >&2; return 1; }
  echo "   opening MT Manager ..."
  wake; adbx shell am force-stop "$MT_PKG" >/dev/null 2>&1; nap 1
  launch "$MT_PKG"; nap 2.5
}

mt_require_login() {   # open the top-left burger drawer and verify we're logged in
  mt_tap_when clickable=true cls=ImageButton maxx=300 maxy=320 || { echo "!! MT Manager burger menu not found." >&2; return 1; }
  nap 1.2; ui_dump
  if ui_find textcontains="Not logged in" >/dev/null 2>&1; then
    echo "!! MT Manager is NOT logged in — log in to MT Manager first, then re-run." >&2
    return 1
  fi
  return 0
}

# mt_extract <pkg> : from the burger drawer, Extract APK -> search -> tap the row ->
# EXTRACT APK (replacing if "File already exists"). Leaves the final "Info" alert open
# and sets MT_APK_PATH to the saved device path. Returns non-zero on any failure.
mt_extract() {
  local pkg="$1" path="" i
  mt_tap_when textequals="Extract APK" || { echo "!! 'Extract APK' not found in the menu." >&2; return 1; }
  nap 1.5
  mt_tap_when clickable=true desccontains=Search || { echo "!! search button not found." >&2; return 1; }
  nap 1
  inpx text "$pkg"; nap 1.5
  ui_dump
  ui_tap textequals="$pkg" miny=300 || { echo "!! package '$pkg' not found in the Extract APK list." >&2; return 1; }
  nap 2
  mt_tap_when res=button1 textequals="EXTRACT APK" || { echo "!! 'EXTRACT APK' button not found." >&2; return 1; }
  nap 1.5
  ui_dump
  if ui_find textcontains="already exists" >/dev/null 2>&1; then
    echo "   file already exists — choosing OK (replace) ..."
    { ui_tap res=button1 textequals="OK" || ui_tap res=button1; } || true
    nap 1
  fi
  for ((i=1;i<=40;i++)); do
    sleep 2; ui_dump
    path="$(grep -oE 'text="The file has been saved to [^"]*"' "$UI_XML" | sed 's/.*saved to //;s/"$//' | head -1)"
    [ -n "$path" ] && break
  done
  [ -n "$path" ] || { echo "!! extraction did not finish (no 'saved to' alert appeared)." >&2; return 1; }
  MT_APK_PATH="$path"
  echo "   extracted on device: $path"
}

mt_info_close()  { { ui_tap res=button1 textequals="CLOSE" || true; } >/dev/null 2>&1; }   # dismiss the Info alert
mt_info_locate() { mt_tap_when res=button3 textequals="LOCATE"; }                           # Locate from the Info alert

# mt_locate_tap_file <device-path> : from the Info alert, Locate then tap that file in the
# dual pane (by basename). Leaves the file's action dialog/chooser open.
mt_locate_tap_file() {
  local p="$1"
  mt_info_locate || { echo "!! LOCATE button not found." >&2; return 1; }
  nap 1.5
  mt_tap_when textequals="$(basename "$p")" || { echo "!! file not found after Locate: $(basename "$p")" >&2; return 1; }
  nap 1.5
}

# mt_convert_apks <device .apks path> : Locate -> tap file -> "Convert to apk" -> OK,
# then poll for "<name>_apks.apk" in the same folder. Sets CONVERTED. (case 5)
mt_convert_apks() {
  local apks="$1" result="${1%.apks}_apks.apk" i
  echo "   split bundle — converting via MT Manager (Locate -> Convert to apk) ..."
  mt_locate_tap_file "$apks" || return 1
  mt_tap_when textequals="Convert to apk" || { echo "!! 'Convert to apk' option not found." >&2; return 1; }
  nap 1.5
  mt_tap_when res=button1 textequals="OK" || { echo "!! convert 'OK' button not found." >&2; return 1; }
  echo "   converting (no progress dialog) — waiting for $(basename "$result") ..."
  for ((i=1;i<=60;i++)); do
    sleep 2
    [ -n "$(adbx shell "ls $(shq "$result")" 2>/dev/null | tr -d '\r')" ] && { CONVERTED="$result"; echo "   converted: $result"; return 0; }
  done
  echo "!! conversion timed out (no $result appeared)." >&2; return 1
}

# mt_jump_to <dir> : navigate the active pane to <dir> via the "Jump to path" dialog.
mt_jump_to() {
  local path="$1" dels
  dels="$(printf '67 %.0s' $(seq 1 80))"                # KEYCODE_DEL x80 (clear the field)
  mt_tap_when clickable=true cls=TextView textprefix=/ maxy=300 || { echo "!! path bar not found." >&2; return 1; }
  nap 1
  mt_tap_when cls=EditText || { echo "!! 'Jump to path' input not found." >&2; return 1; }
  nap 0.4
  inpx keyevent 123                                     # MOVE_END
  inpx keyevent $dels                                   # clear
  inpx text "$path"
  nap 0.3
  { mt_tap_when textequals=OK res=button1 || mt_tap_when textequals=OK; } || { echo "!! OK button not found." >&2; return 1; }
  nap 1.2
}


# NOTE: device paths here are scraped from MT Manager's own UI text, i.e. they are
# attacker-influenceable by whatever created the file. Always pass them through shq().
# mt_pull <device-path> : copy it to $EXTRACTED_DIR on the mac. Sets PULLED to the local path.
mt_pull() {
  local p="$1" out
  mkdir -p "$EXTRACTED_DIR" 2>/dev/null || { echo "!! cannot create $EXTRACTED_DIR" >&2; return 1; }
  out="$EXTRACTED_DIR/$(basename "$p")"
  adbx pull "$p" "$out" >/dev/null 2>&1 || { echo "!! adb pull failed: $p" >&2; return 1; }
  echo "   pulled to: $out"
  PULLED="$out"
}

# mt_offer_device_cleanup <device-path> : ask whether to remove the on-device copy, since
# MT Manager's output folder fills up fast. DELETE_DEVICE_COPY=1|0 skips the prompt.
mt_offer_device_cleanup() {
  local p="$1" ans="${DELETE_DEVICE_COPY:-}"
  if [ -z "$ans" ]; then read -rp "   delete the extracted file on the device? [y/N]: " ans || ans=""; fi
  case "$ans" in
    y|Y|1) adbx shell "rm -f $(shq "$p")" >/dev/null 2>&1 \
             && echo "   deleted on device: $p" || echo "   WARN: could not delete $p" >&2 ;;
    *) echo "   kept on device: $p" ;;
  esac
}

