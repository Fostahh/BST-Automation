#!/usr/bin/env bash
# NAME: iOS Case 5 — Inject Dylib (SSLKillSwitch via TrollFools)
#
# Inject SSLKillSwitch2 into the app under test with TrollFools, then launch it. The app's
# own RASP checks deliver the verdict — specifically whether it notices a foreign dylib in
# its address space, and whether its pinning survives.
#
# TrollFools re-signs the bundle in place, so the installed version does not change but the
# binary does. There is nothing the device inventory can read that proves an injection
# happened, which is why the log step below is not optional: TrollFools' own log is the
# only evidence.
#
# The taps are real — frida drives TrollFools' UI (see lib/ios/ui.sh). The ONE step that
# cannot be tapped is choosing the dylib: that file picker is a remote view belonging to
# another process, so nothing inside TrollFools can reach it. That step asks you.
#
#   env: TARGET_PKG=<bundle id>   DEV_SERIAL=<device udid>   (run-scenarios.sh sets both)
#        DYLIB=<name>             the dylib to inject (default SSLKillSwitch22.dylib)
#        TROLLFOOLS_ID=<bundle>   TrollFools itself (default wiki.qaq.TrollFools)
#        TROLLFOOLS_SCOPE=All     which scope tab lists the app: All, User, TrollStore, System
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/ios/device.sh"

DYLIB="${DYLIB:-SSLKillSwitch22.dylib}"
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
echo "  dylib:  $DYLIB"

# --- the opening every iOS case shares ----------------------------------------
ios_general_rules "$PKG" || exit 1

# TrollFools injects into whatever is installed, so record what that was. If the version
# changes under us the injection applied to a different binary than the one just checked.
VERSION_BEFORE="$(ios_version "$PKG")"

# --- TrollFools ----------------------------------------------------------------
step "Open TrollFools"
ios_open_or_ask "$TROLLFOOLS_ID" TrollFools

# The scope tab decides which apps are listed at all, and it does not default to the one
# with the app under test in it: a TestFlight build is a user app, and TrollFools opens on
# System. Without this the next step searches a list the app was never in.
step "Switch the scope to $TROLLFOOLS_SCOPE so $PKG is listed"
detail "set TROLLFOOLS_SCOPE=User|TrollStore|System if the app is filed elsewhere"
ios_tap_or_ask "$TROLLFOOLS_SCOPE" "tap the $TROLLFOOLS_SCOPE tab above the app list"

# Searching by bundle id, not by name: the row says "Name, bundle.id, version", so the
# bundle id identifies exactly one row while a display name may not. The list is paged
# through until the row appears, because a row that has not been scrolled to does not
# exist in any form on an iOS list.
step "Find $PKG in the list and tap it"
ios_row_or_ask "$PKG" "find $PKG in the list — the search field filters it — and tap it"

step "Tap Inject"
ios_tap_or_ask Inject

# The one step that stays manual, and not for lack of trying: tapping Inject opens
# UIDocumentPickerViewController, which draws in another process and arrives here as an
# empty _UIRemoteView. Nothing running inside TrollFools can see or touch its contents.
step "Choose $DYLIB in the file picker"
detail "set DYLIB=<name> to inject something else"
detail "this picker belongs to another process — it is the one thing here nothing can tap"
gate "chosen?"

# Not optional. TrollFools reports success in its log and nowhere else — the bundle id and
# version are unchanged afterwards, so without this the case has no evidence that anything
# was injected at all. The log is PRINTED rather than asked about: a verdict that depends
# on who was reading the phone is the thing this harness exists to get rid of.
step "Read the result in View Logs"
ios_tap_or_ask "View Logs" "open View Logs"
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
# Launched, never injected into: frida inside the app under test would make its own RASP
# report the tester's tooling, which is a worse outcome than no result at all.
step "Open $PKG"
detail "launched through SpringBoard, with nothing injected into the app"
ios_launch_checked "$PKG" || exit 1

echo
echo "iOS case 5 (Inject Dylib) done on ${DEV_NAME:-$DEV_SERIAL}"
echo "  $DYLIB is in the bundle — watch whether the app detects it, and whether pinning holds"
reopen_loop "$PKG"
