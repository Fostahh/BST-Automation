#!/usr/bin/env bash
# NAME: Case 7 — Certificate Tamper
# Extract -> Locate -> sign in MT Manager -> uninstall via ADB -> install/launch
# in MT Manager. APK and APKS stay on the device; uses the configured signing key.
# env: TARGET_PKG, MT_PKG; SIGN_TIMEOUT=600, INSTALL_TIMEOUT=600, ADB_TIMEOUT=45
# Uninstalling clears the target app's local data. The signed build remains installed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"

# Bound individual ADB calls too, so polling deadlines cannot hang on a lost device.
adbx() {
  python3 - "$DEV_SERIAL" "${ADB_TIMEOUT:-45}" "$@" <<'PY'
import subprocess, sys
try:
    result = subprocess.run(["adb", "-s", sys.argv[1], *sys.argv[3:]],
                            timeout=int(sys.argv[2]))
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print("ADB operation timed out", file=sys.stderr)
    sys.exit(124)
PY
}
source "$HERE/../lib/mtmanager.sh"

c7_fail() { echo "!! $*" >&2; return 1; }
c7_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Case-local strict snapshots/retries; existing scenarios retain their behavior.
ui_dump() {
  # Busy signing/compression screens can prevent uiautomator from producing a
  # file even when it exits successfully. Never read/reuse an old snapshot.
  : > "$UI_XML"
  adbx shell 'rm -f /sdcard/ui.xml && uiautomator dump /sdcard/ui.xml && test -s /sdcard/ui.xml' >/dev/null 2>&1 || return 1
  adbx shell cat /sdcard/ui.xml > "$UI_XML" 2>/dev/null || { : > "$UI_XML"; return 1; }
  python3 - "$UI_XML" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
    sys.exit(0 if root.tag == "hierarchy" and root.find("node") is not None else 1)
except (OSError, ET.ParseError):
    sys.exit(1)
PY
}
ui_tap_when() {
  local i
  for i in 1 2 3 4 5 6 7 8; do
    if ui_dump && ui_find "$@" >/dev/null 2>&1; then ui_tap "$@"; return $?; fi
    sleep 1
  done
  c7_fail "UI element not found: $*"
}

c7_file_stamp() {
  local quoted
  quoted="$(c7_quote "$1")"
  adbx shell "if [ -s $quoted ]; then stat -c '%s:%Y' $quoted; fi" | tr -d '\r'
}

c7_scheme_matches() {
  local value wanted
  value="$(ui_find --near-text Scheme res=text1)" || return 1
  wanted="$(ui_find --near-text Scheme res=text1 textequals='V1 + V2 + V3')" || return 1
  [ "$value" = "$wanted" ]
}

c7_set_scheme() {
  ui_dump || return 1
  if ! c7_scheme_matches; then
    ui_tap_when --near-text Scheme res=text1 || return 1
    ui_tap_when textequals='V1 + V2 + V3' || return 1
    nap 0.5
    ui_dump || return 1
    c7_scheme_matches || { c7_fail 'Signing Scheme did not become V1 + V2 + V3.'; return 1; }
  fi
  echo '   Scheme verified: V1 + V2 + V3'
}

c7_close_tip() {
  if ui_find textequals=Tip >/dev/null 2>&1 || ui_find textequals=Tips >/dev/null 2>&1; then
    { ui_tap res=button1 textequals=CLOSE || ui_tap textequals=Close || ui_tap textequals=CLOSE; } || return 1
    nap 0.5
    return 2  # dismissed; the polling loop must obtain a fresh snapshot
  fi
}

c7_ui_error() {
  # Only inspect MT Manager/installer text; never use a generic CLOSE as success.
  python3 - "$UI_XML" <<'PY'
import re, sys, xml.etree.ElementTree as ET
for node in ET.parse(sys.argv[1]).iter("node"):
    text = node.get("text", "")
    if re.search(r"\b(failed|failure|error|not installed|insufficient storage)\b|INSTALL_FAILED", text, re.I):
        print(text, file=sys.stderr)
        sys.exit(0)
sys.exit(1)
PY
}

c7_wait_signed() {
  local deadline=$((SECONDS + SIGN_TIMEOUT)) stamp last='' stable=0 rc
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 2
    if ! ui_dump; then stable=0; last=''; continue; fi
    if c7_ui_error; then c7_fail 'MT Manager reported a signing error.'; return 1; fi
    # Handle replacement here too: the first snapshot after OK may be unavailable.
    if ui_find textcontains='already exists' >/dev/null 2>&1; then
      ui_tap res=button1 textequals=OK || return 1
      stable=0; last=''; continue
    fi
    if c7_close_tip; then :; else
      rc=$?
      if [ "$rc" = 2 ]; then continue; fi
      return 1
    fi
    stamp="$(c7_file_stamp "$SIGNED_PATH")" || return 1
    # An existing result must change; the newly written file must stop growing.
    if [ -n "$stamp" ] && [ "$stamp" != "$PRE_SIGN_STAMP" ] && [ "$stamp" = "$last" ]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    last="$stamp"
    # Require the browser to return, with no progress indicator or signing dialog.
    if [ "$stable" -ge 3 ] && ! ui_find cls=ProgressBar >/dev/null 2>&1 \
      && ! ui_find textequals=Scheme >/dev/null 2>&1 \
      && ui_find clickable=true cls=TextView textprefix=/ >/dev/null 2>&1; then
      echo "   signed file ready: $SIGNED_PATH"
      return 0
    fi
  done
  c7_fail "Signing timed out; original app has not been uninstalled. Expected fresh output: $SIGNED_PATH"
}

c7_sign() {
  local extracted="$1"
  case "$extracted" in
    *.apks) SIGNED_PATH="${extracted%.apks}_sign.apks" ;;
    *.apk) SIGNED_PATH="${extracted%.apk}_sign.apk" ;;
    *) c7_fail "Unsupported extracted file: $extracted"; return 1 ;;
  esac
  PRE_SIGN_STAMP="$(c7_file_stamp "$SIGNED_PATH")" || return 1
  mt_locate_tap_file "$extracted" || return 1
  case "$extracted" in
    *.apks) ui_tap_when textequals='Sign file' || return 1 ;;
    *.apk)
      ui_tap_when res=button3 textequals=FUNCTION || return 1
      ui_tap_when textequals='Sign APK' || return 1 ;;
  esac
  c7_set_scheme || return 1
  ui_tap_when res=button1 textequals=OK || return 1
  c7_wait_signed
}

# Several apps can handle an install intent, so Android may show a chooser instead of
# installing straight away. MT Manager's own installer is the one that completes the
# split (.apks) flow, so select it; prefer "just once" over setting a lasting default.
c7_pick_installer() {
  local name label
  for name in MTManager2 'MT Manager 2' MTManager; do
    ui_find textequals="$name" >/dev/null 2>&1 || continue
    echo "   install chooser shown — selecting $name ..."
    ui_tap textequals="$name" || return 1
    nap 1
    ui_dump || return 0
    for label in 'JUST ONCE' 'Just once' ONCE Once; do
      if ui_find textequals="$label" >/dev/null 2>&1; then ui_tap textequals="$label" || true; break; fi
    done
    return 0
  done
  return 1
}

c7_wait_install() {
  local deadline=$((SECONDS + INSTALL_TIMEOUT)) label
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 2
    ui_dump || continue
    if c7_ui_error; then c7_fail "Installation failed. Signed file remains at $SIGNED_PATH"; return 1; fi
    if ui_find textequals='Successful installation' >/dev/null 2>&1; then
      adbx shell pm path --user current "$PKG" | tr -d '\r' | grep -q '^package:' \
        || { c7_fail 'Success dialog appeared but the target package is not installed.'; return 1; }
      for label in LAUNCH Launch OPEN Open DONE Done; do
        if ui_find textequals="$label" >/dev/null 2>&1; then
          ui_tap textequals="$label" || return 1
          nap 2
          case "$(focus_now)" in
            *"$PKG/"*) return 0 ;;
          esac
          launch "$PKG" || { c7_fail 'Installed, but could not launch the target app.'; return 1; }
          return 0
        fi
      done
      c7_fail 'Installation succeeded, but no Launch/Open/Done button was found.'
      return 1
    fi
    # An installer chooser can appear before anything installs — answer it first.
    if c7_pick_installer; then continue; fi
    # Installing a split bundle (_sign.apks) raises an extra "Install" confirmation.
    # The OK sits bottom-right (button1); the chooser has no OK, so this cannot collide.
    if ui_find textequals=Install >/dev/null 2>&1 \
       && ui_find res=button1 textequals=OK >/dev/null 2>&1; then
      echo "   install confirmation shown — accepting (OK) ..."
      ui_tap res=button1 textequals=OK || return 1
      continue
    fi
    # Some devices hand APK installation to the system package installer.
    case "$(focus_now)" in
      *packageinstaller*|*permissioncontroller*)
        if ui_find textequals=INSTALL >/dev/null 2>&1; then ui_tap textequals=INSTALL || return 1
        elif ui_find textequals=Install >/dev/null 2>&1; then ui_tap textequals=Install || return 1; fi ;;
    esac
  done
  c7_fail "Installation timed out. Signed file remains at $SIGNED_PATH"
}

c7_install() {
  local installed
  installed="$(adbx shell pm list packages --user current "$PKG" | tr -d '\r')" || return 1
  if printf '%s\n' "$installed" | grep -Fxq "package:$PKG"; then
    echo "   uninstalling $PKG (clears app data) ..."
    adbx uninstall "$PKG" || return 1
    installed="$(adbx shell pm list packages --user current "$PKG" | tr -d '\r')" || return 1
    if printf '%s\n' "$installed" | grep -Fxq "package:$PKG"; then
      c7_fail 'Target package is still installed; stopping.'; return 1
    fi
  fi
  # Signing leaves us in the extraction folder. Tap the new file right there.
  ui_tap_when textequals="$(basename "$SIGNED_PATH")" || return 1
  case "$SIGNED_PATH" in
    *.apks) ui_tap_when textequals=Install || return 1 ;;
    *.apk) ui_tap_when res=button1 textequals=INSTALL || return 1 ;;
  esac
  c7_wait_install
}

c7_main() {
  local knob
  SIGN_TIMEOUT="${SIGN_TIMEOUT:-600}"; INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-600}"
  for knob in "$SIGN_TIMEOUT" "$INSTALL_TIMEOUT" "${ADB_TIMEOUT:-45}"; do
    case "$knob" in ''|*[!0-9]*|0|0*) c7_fail 'Timeouts must be positive whole seconds without leading zeros.'; return 1 ;; esac
  done
  PKG="${TARGET_PKG:-}"
  [ -n "$PKG" ] || read -rp 'Target app package id to extract and re-sign: ' PKG
  case "$PKG" in ''|*[!A-Za-z0-9_.]*) c7_fail 'A valid target package id is required.'; return 1 ;; esac
  adbx shell pm path --user current "$PKG" | tr -d '\r' | grep -q '^package:' \
    || { c7_fail "Target package is not installed: $PKG"; return 1; }
  detect_size
  # Shared MT scrolling uses swipr -> inp; route input correctly on non-rooted devices too.
  inp() { inpx "$@"; }
  echo "Case 7: extract and re-sign $PKG on ${DEV_NAME:-$DEV_SERIAL}"
  mt_launch_fresh || return 1
  mt_require_login || return 1
  mt_extract "$PKG" || return 1
  c7_sign "$MT_APK_PATH" || return 1
  c7_install || return 1
  echo "Case 7 complete: signed build installed and launch requested for $PKG."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then c7_main; fi
