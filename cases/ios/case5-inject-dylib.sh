#!/usr/bin/env bash
# NAME: iOS Case 5 — Inject Dylib (via TrollFools)
#
# Inject a dylib into the app under test with TrollFools, then launch it. The app's
# own RASP checks deliver the verdict — whether it notices a foreign dylib in its address
# space.
#
# TrollFools re-signs the bundle in place, so the installed version does not change but the
# binary does. There is nothing the device inventory can read that proves an injection
# happened, which is why the log step below is not optional: TrollFools' own log is the
# only evidence.
#
# The taps are real — frida drives TrollFools' UI (see lib/ios/ui.sh), and the file
# picker's too: it belongs to another process, which the driver attaches to directly. The
# .dylib files in the folder the picker opens are listed, and you choose one.
#
#   env: TARGET_PKG=<bundle id>   DEV_SERIAL=<device udid>   (run-scenarios.sh sets both)
#        DYLIB=<name>             choose this dylib without asking (unattended runs)
#        TROLLFOOLS_ID=<bundle>   TrollFools itself (default wiki.qaq.TrollFools)
#        TROLLFOOLS_SCOPE=All     which scope tab lists the app: All, User, TrollStore, System
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/ios/device.sh"

DYLIB="${DYLIB:-}"
TROLLFOOLS_ID="${TROLLFOOLS_ID:-wiki.qaq.TrollFools}"
TROLLFOOLS_SCOPE="${TROLLFOOLS_SCOPE:-All}"

PKG="${TARGET_PKG:-}"
if [ -z "$PKG" ]; then
  read -rp "bundle id of the app under test: " PKG || PKG=""
fi
[ -n "$PKG" ] || { echo "!! a bundle id is required." >&2; exit 1; }

echo
echo "iOS Case 5 — Inject Dylib on ${DEV_NAME:-$DEV_SERIAL}"
echo "  target: $PKG"
echo "  dylib:  ${DYLIB:-chosen from the picker}"

# --- the opening every iOS case shares ----------------------------------------
ios_general_rules "$PKG" || exit 1

# TrollFools injects into whatever is installed, so record what that was. If the version
# changes under us the injection applied to a different binary than the one just checked.
VERSION_BEFORE="$(ios_version "$PKG")"

# --- TrollFools ----------------------------------------------------------------
step "Open TrollFools"
ios_ui_open "$TROLLFOOLS_ID" || exit 1

# The scope tab decides which apps are listed at all, and it does not default to the one
# with the app under test in it: a TestFlight build is a user app, and TrollFools opens on
# System. Without this the next step searches a list the app was never in.
step "Switch the scope to $TROLLFOOLS_SCOPE so $PKG is listed"
detail "set TROLLFOOLS_SCOPE=User|TrollStore|System if the app is filed elsewhere"
ios_tap_req "$TROLLFOOLS_SCOPE" || exit 1
nap "$NAP_SHORT"

# Searching by bundle id, not by name: the row says "Name, bundle.id, version", so the
# bundle id identifies exactly one row while a display name may not. The list is paged
# through until the row appears, because a row that has not been scrolled to does not
# exist in any form on an iOS list.
step "Find $PKG in the list and tap it"
ios_tap_in_list "$PKG" || exit 1
nap "$NAP_NAV"

step "Tap Inject"
ios_tap_req Inject || exit 1
nap "$NAP_MED"

# Inject opens a UIDocumentPickerViewController, which draws in its own process
# (com.apple.DocumentManager.Service): TrollFools holds only an empty remote view of it.
# So the driver attaches there, lists the .dylib files in whatever folder the picker
# opened, and taps the one chosen.
step "Choose the dylib in the file picker"
ios_use_picker || exit 1
ios_wait_for ".dylib" || {
  echo "!! the picker's folder has no .dylib in it — put the dylib there and run again." >&2
  exit 1
}
_ios_cmd 60 list .dylib || { echo "!! could not read the picker: $(_ios_why)" >&2; exit 1; }
IFS=$'\t' read -r -a DYLIBS <<< "${IOS_UI_RESP#OK }"
if [ -n "$DYLIB" ]; then
  found=""
  for name in "${DYLIBS[@]}"; do
    case "$name" in "$DYLIB"|"$DYLIB.dylib") found="$name" ;; esac
  done
  [ -n "$found" ] || {
    echo "!! DYLIB=$DYLIB is not in the picker's folder; it has: ${DYLIBS[*]}" >&2
    exit 1
  }
  DYLIB="$found"
else
  detail "dylibs in the picker:"
  for i in "${!DYLIBS[@]}"; do detail "  $((i + 1))) ${DYLIBS[$i]%.dylib}"; done
  while :; do
    read -rp "      choose a dylib [1]: " ans || { echo; echo "   no answer — stopping." >&2; exit 1; }
    idx="$(pick_index "${#DYLIBS[@]}" "${ans:-1}")" && break
    echo "      choose 1-${#DYLIBS[@]}." >&2
  done
  DYLIB="${DYLIBS[$((idx - 1))]}"
fi
# The picker takes several files: a tap only TICKS one, and Open (top right) is what
# hands the selection to TrollFools.
ios_tap_req "$DYLIB" || exit 1
TAPPED="${IOS_UI_RESP#OK }"
nap "$NAP_SHORT"                                # the tick lands and Open becomes enabled
ios_tap_req Open || exit 1
# A tap the picker ignored still reports success, so the proof is the picker CLOSING.
# Still on screen a few seconds after Open means nothing was chosen.
n=0
while ios_find "$DYLIB" >/dev/null 2>&1 && [ "$n" -lt 10 ]; do sleep 0.5; n=$((n + 1)); done
if [ "$n" -ge 10 ]; then
  echo "!! the picker is still open — $DYLIB was not chosen (tick: $TAPPED)." >&2
  exit 1
fi
detail "chose $DYLIB"
ios_use_app >/dev/null 2>&1 || true            # the picker is gone; back to TrollFools
nap "$NAP_MED"

# Not optional. TrollFools reports success in its log and nowhere else — the bundle id and
# version are unchanged afterwards, so without this the case has no evidence that anything
# was injected at all. The log is PRINTED rather than asked about: a verdict that depends
# on who was reading the phone is the thing this harness exists to get rid of.
step "Read the result in View Logs"
ios_tap_req "View Logs" || exit 1
nap "$NAP_NAV"
detail "TrollFools' log, as it reads on the device:"
ios_show_screen || detail "could not read the log from here"

if ! ios_installed "$PKG"; then
  echo "!! $PKG is no longer installed — the injection removed or broke the bundle." >&2
  exit 1
fi
VERSION_AFTER="$(ios_version "$PKG")"
echo
echo "   bundle still installed: $PKG ${VERSION_AFTER:+($VERSION_AFTER)}"
if [ -n "$VERSION_BEFORE" ] && [ "$VERSION_BEFORE" != "$VERSION_AFTER" ]; then
  echo "   NOTE: version changed $VERSION_BEFORE -> $VERSION_AFTER during the injection;" >&2
  echo "         TrollFools re-signs in place and should not alter it." >&2
fi

# --- launch --------------------------------------------------------------------
# Re-granted: TrollFools re-signed the bundle, and a permission is tied to the signature
# it was granted to.
step "Grant $PKG its permissions"
ios_grant "$PKG"

# Launched, never injected into: frida inside the app under test would make its own RASP
# report the tester's tooling, which is a worse outcome than no result at all.
step "Open $PKG"
detail "launched through SpringBoard, with nothing injected into the app"
ios_launch_checked "$PKG" || exit 1

echo
echo "iOS case 5 (Inject Dylib) done on ${DEV_NAME:-$DEV_SERIAL}"
echo "  $DYLIB is in the bundle — watch whether the app detects it"
reopen_loop "$PKG"
