#!/usr/bin/env bash
# NAME: iOS Case 5 — Inject Dylib (SSLKillSwitch via TrollFools)
# PLATFORM: ios
#
# Inject SSLKillSwitch2 into the app under test with TrollFools, then launch it. The app's
# own RASP checks deliver the verdict — specifically whether it notices a foreign dylib in
# its address space, and whether its pinning survives.
#
# TrollFools re-signs the bundle in place, so the installed version does not change but the
# binary does. There is nothing devicectl can read that proves an injection happened, which
# is why the log step below is not optional: TrollFools' own log is the only evidence.
#
#   env: TARGET_PKG=<bundle id>   DEV_SERIAL=<devicectl udid>   (run-scenarios.sh sets both)
#        DYLIB=<name>   the dylib to inject (default SSLKillSwitch22.dylib)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/ios.sh"

DYLIB="${DYLIB:-SSLKillSwitch22.dylib}"

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
gate "open?"

# Same reasoning as case 4: search rather than scroll. The bundle id is already known, so
# browsing discovers nothing, and a filtered list removes the wrong-row tap.
step "Find $PKG — search for it rather than scrolling the whole list"
detail "a typed bundle id is one step and tells you straight away if the app is absent"
gate "found and tapped?"

step "Tap Inject"
gate "tapped?"

step "Choose $DYLIB"
detail "set DYLIB=<name> to inject something else"
gate "chosen?"

# Not optional. TrollFools reports success in its log and nowhere else — the bundle id and
# version are unchanged afterwards, so skipping this means the case has no evidence that
# anything was injected at all.
step "Open View Logs and read the result"
detail "this is the only confirmation that exists: the version below will not change,"
detail "so the log is what distinguishes a successful injection from a no-op"
gate "does the log show the injection succeeded?"

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
step "Open $PKG"
ios_launch "$PKG"
detail "launch requested over devicectl; tap it on the device if it did not come up"
gate "is it running?"

echo
echo "iOS case 5 (Inject Dylib) done on ${DEV_NAME:-$DEV_SERIAL}"
echo "  $DYLIB is in the bundle — watch whether the app detects it, and whether pinning holds"
reopen_loop "$PKG"
