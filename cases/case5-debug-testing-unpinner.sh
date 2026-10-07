#!/usr/bin/env bash
# NAME: Case 5 — Debug Testing (android-unpinner)
# Pull the target app's APK off the device with MT Manager, unpin/patch it to be
# debuggable with android-unpinner, then install the patched build over adb and open it.
#   Uses DEV_SERIAL (+ TARGET_PKG) exported by run-scenarios.sh.
#   env: USE_VENV=1|0   UNPINNER=<path-or-dir>   MT_PKG=<pkg, default bin.mt.plus>
#        APK_SOURCE=auto|manual   skip the source prompt.
#        APK=<path.apk>           provide a local APK (implies manual; skips extraction).
#
# Notes:
#  * Auto mode extracts the APK from the device with MT Manager (must be LOGGED IN; the
#    script exits if it sees "Not logged in"). Split bundles (.apks) are converted to a
#    single apk via MT Manager's "Convert to apk". The APK lands in fridaenv/.
#  * `android-unpinner all` reports "No ADB Device Detected" and exits non-zero at its
#    install step AFTER creating <name>.unpinned.apk — expected; we install via adb.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"                      # adbx(), launch(), ui_dump(), $UI_XML, LIB
source "$HERE/../lib/mtmanager.sh"                    # MT Manager helpers: mt_launch_fresh/login/extract/convert
FRIDAENV="$(cd "$HERE/../.." && pwd)/fridaenv"       # BST Tools/fridaenv

unquote() { local s="$1"; s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"; printf '%s' "$s"; }

# Resolve a runnable android-unpinner from a user-supplied path/dir, else auto-detect.
resolve_unpinner() {
  local in c
  in="$(unquote "${1:-}")"
  if [ -n "$in" ]; then
    if [ -d "$in" ]; then
      for c in "$in/bin/android-unpinner" "$in/android-unpinner"; do
        [ -f "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
      done
      return 1
    fi
    [ -f "$in" ] && [ -x "$in" ] && { echo "$in"; return 0; }
    return 1
  fi
  c="$(command -v android-unpinner 2>/dev/null || true)"; [ -n "$c" ] && { echo "$c"; return 0; }
  [ -f "$FRIDAENV/bin/android-unpinner" ] && [ -x "$FRIDAENV/bin/android-unpinner" ] && { echo "$FRIDAENV/bin/android-unpinner"; return 0; }
  return 1
}

detect_package() {   # <unpinner-cmd> <apk> -> prints the package id (for manual mode)
  "$1" package-name "$2" 2>/dev/null | tr -d '\r' \
    | grep -oE '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+' | tail -1
}

# extract_apk <pkg> : extract via MT Manager (shared helpers), resolve a single .apk
# (converting a .apks bundle), pull it into fridaenv/. Sets EXTRACTED to the local path.
extract_apk() {
  local pkg="$1" dev_apk
  mt_launch_fresh || exit 1
  mt_require_login || exit 1
  mt_extract "$pkg" || exit 1                 # -> MT_APK_PATH (Info alert left open)
  case "$MT_APK_PATH" in
    *.apk)  mt_info_close; dev_apk="$MT_APK_PATH" ;;
    *.apks) mt_convert_apks "$MT_APK_PATH" || exit 1; dev_apk="$CONVERTED" ;;
    *) echo "!! unexpected extract type: $MT_APK_PATH" >&2; exit 1 ;;
  esac
  mt_pull "$dev_apk" || exit 1          # -> Automation/extracted/ (shared destination)
  EXTRACTED="$PULLED"
}

# --- 1) Python environment (android-unpinner only runs inside the venv) --------
ans="${USE_VENV:-}"
if [ -z "$ans" ]; then
  # Only meaningful where a fridaenv venv exists; elsewhere android-unpinner comes from PATH.
  if [ -f "$FRIDAENV/bin/activate" ]; then
    read -rp "1) Are you using the Python virtual env (fridaenv)? [Y/n]: " ans
  else
    ans=n
  fi
fi
case "$ans" in
  n|N|0) echo "   not using venv — will auto-detect android-unpinner on PATH / in fridaenv." ;;
  *)
    [ -f "$FRIDAENV/bin/activate" ] || { echo "   venv activate not found: $FRIDAENV/bin/activate" >&2; exit 1; }
    # shellcheck disable=SC1091
    source "$FRIDAENV/bin/activate"
    echo "   venv active: ${VIRTUAL_ENV:-$FRIDAENV}"
    ;;
esac

# --- 2) android-unpinner location (blank = auto-detect) -----------------------
UIN="${UNPINNER:-}"
if [ -z "$UIN" ]; then read -rp "2) android-unpinner location (blank = auto-detect): " UIN; fi
UNPINNER_CMD="$(resolve_unpinner "$UIN")" || { echo "!! android-unpinner not found${UIN:+ at: $UIN}." >&2; exit 1; }
echo "   using: $UNPINNER_CMD"

# --- 3) APK source: auto-extract from the device, or a manual local path ------
# APK=<file> env implies manual; APK_SOURCE=auto|manual skips the prompt.
APK="$(unquote "${APK:-}")"
SRC="${APK_SOURCE:-}"
[ -n "$APK" ] && SRC=manual
if [ -z "$SRC" ]; then
  read -rp "3) APK source — [A]uto-extract via MT Manager, or [m]anual local path? [A/m]: " SRC
fi
case "$SRC" in
  m|M|manual|Manual)
    if [ -z "$APK" ]; then read -rp "   path to the APK (.apk): " APK; APK="$(unquote "$APK")"; fi
    [ -n "$APK" ] || { echo "!! APK path is required." >&2; exit 1; }
    [ -f "$APK" ] || { echo "!! not a file: $APK" >&2; exit 1; }
    case "$APK" in *.apk|*.APK) : ;; *) echo "!! '$APK' is not a .apk file." >&2; exit 1 ;; esac
    PKG="$(detect_package "$UNPINNER_CMD" "$APK")"; [ -n "$PKG" ] || PKG="${TARGET_PKG:-}"
    [ -n "$PKG" ] || { echo "!! could not determine the package id from the APK." >&2; exit 1; }
    echo "   manual APK: $APK   (package $PKG)" ;;
  *)
    PKG="${TARGET_PKG:-}"
    if [ -z "$PKG" ]; then read -rp "   target app package id to extract: " PKG; fi
    [ -n "$PKG" ] || { echo "!! package id is required for extraction." >&2; exit 1; }
    echo "   auto-extracting $PKG from $DEV_SERIAL via MT Manager ..."
    extract_apk "$PKG"
    APK="$EXTRACTED" ;;
esac
echo "   APK: $APK"

# --- 5) run `android-unpinner all` (patches; install step errors — expected) --
echo "4) running: $(basename "$UNPINNER_CMD") all \"$APK\""
echo "   (the 'No ADB Device Detected' error at the install step is expected here)"
"$UNPINNER_CMD" all "$APK" || true                   # tolerate the install-step failure
UNPINNED="${APK%.*}.unpinned.${APK##*.}"             # foo.apk -> foo.unpinned.apk
[ -f "$UNPINNED" ] || { echo "!! patched APK was not produced: $UNPINNED" >&2; exit 1; }
echo "   patched APK ready: $UNPINNED"

# --- 6) on the device: uninstall the same package if present ------------------
echo "5) checking $DEV_SERIAL for $PKG ..."
if [ -n "$(adbx shell pm path --user current "$PKG" 2>/dev/null | tr -d '\r')" ]; then
  echo "   present — uninstalling ..."
  adbx uninstall "$PKG" >/dev/null 2>&1 && echo "   uninstalled." || echo "   WARN: uninstall failed (continuing)."
else
  echo "   not installed — continuing."
fi

# --- 7) install the patched APK via adb ---------------------------------------
echo "6) installing the patched APK via adb ..."
if adbx install --no-incremental "$UNPINNED" || adbx install "$UNPINNED"; then
  echo "   installed $PKG (patched/debuggable) on $DEV_SERIAL."
else
  echo "!! adb install failed." >&2
  exit 1
fi

# --- 8) open the app ----------------------------------------------------------
echo "7) opening $PKG ..."
wake
launch "$PKG"                                        # monkey LAUNCHER intent

echo "case5 (Debug Testing — android-unpinner) done on ${DEV_NAME:-$DEV_SERIAL}"
exit 0
