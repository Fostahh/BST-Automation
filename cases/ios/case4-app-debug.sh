#!/usr/bin/env bash
# NAME: iOS Case 4 — App Debug (decrypt + re-sign via TrollStore)
#
# Take the TestFlight build, decrypt it with TrollDecrypt, and install the decrypted IPA
# through TrollStore so the app runs re-signed and debuggable. The app's own RASP checks
# deliver the verdict, same as every Android case.
#
# The taps are real — frida drives TrollDecrypt's and TrollStore's UI (see lib/ios/ui.sh).
# What this script owns beyond the taps is the order and the waiting: the decrypt has to
# finish before TrollStore sees the IPA, and the old bundle has to be gone before the
# re-signed one goes on, or the install fails on a signature conflict. Both are easy to get
# wrong by hand and neither is visible until later.
#
# ONE step cannot be tapped: picking the IPA in TrollStore's file picker. That picker is a
# remote view belonging to another process, so nothing running inside TrollStore can reach
# it. The script stops and asks for exactly that tap.
#
#   env: TARGET_PKG=<bundle id>    DEV_SERIAL=<device udid>   (run-scenarios.sh sets both)
#        DECRYPT_MODE=<label>      which alert button to take (default "Full IPA")
#        TROLLDECRYPT_ID=<bundle>  default com.fiore.trolldecrypt
#        TROLLSTORE_ID=<bundle>    default com.opa334.TrollStore
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/ios/device.sh"

DECRYPT_MODE="${DECRYPT_MODE:-Full IPA}"
TROLLDECRYPT_ID="${TROLLDECRYPT_ID:-com.fiore.trolldecrypt}"
TROLLSTORE_ID="${TROLLSTORE_ID:-com.opa334.TrollStore}"

PKG="${TARGET_PKG:-}"
if [ -z "$PKG" ]; then
  read -rp "bundle id of the app under test: " PKG || PKG=""
fi
[ -n "$PKG" ] || { echo "!! a bundle id is required." >&2; exit 1; }

echo
echo "iOS Case 4 — App Debug on ${DEV_NAME:-$DEV_SERIAL}"
echo "  target: $PKG"

# --- the opening every iOS case shares ----------------------------------------
ios_general_rules "$PKG" || exit 1
VERSION_BEFORE="$(ios_version "$PKG")"

# --- TrollDecrypt --------------------------------------------------------------
step "Open TrollDecrypt"
ios_open_or_ask "$TROLLDECRYPT_ID" TrollDecrypt

# Searching by bundle id, not by name: every row reads "<version> • <bundle id>", so the
# bundle id picks exactly one row while a display name may not. The list is paged through
# until the row appears, because a row an iOS list has not reached does not exist in any
# form — not as a view, not as an accessibility element.
step "Find $PKG in the list and tap it"
detail "the keyboard icon (top right) filters the list, if you end up doing this by hand"
ios_row_or_ask "$PKG" "find $PKG in TrollDecrypt's list and tap it"

# "Full IPA" over "Main Binary Only": the frameworks and extensions in the bundle are
# encrypted too, and a main binary on its own re-signs into an app that crashes on the
# first framework call. DECRYPT_MODE overrides it when only the binary is wanted.
step "In the Decrypt alert, choose $DECRYPT_MODE"
detail "the alert also offers Main Binary Only, which leaves the frameworks encrypted"
ios_tap_or_ask "$DECRYPT_MODE" "tap $DECRYPT_MODE in the alert"

# The decrypt takes as long as the app is big, and TrollStore cannot see a partial file.
# Polling the alert is what replaces guessing: the success alert IS the completion signal.
step "Wait for the decrypt to finish"
detail "the decrypted IPA lands in TrollStore's Decrypted IPA folder"
await "the \"Decryption Complete\" alert" "ios_find Complete" || exit 1
ios_tap_or_ask OK "tap OK on the Decryption Complete alert"

# --- the conflict, removed before it bites -------------------------------------
# Installing over an existing bundle id fails on a signature mismatch, and the failure
# shows up as an install error with no hint about the cause. Done here, before the picker
# is open, so the operator is not holding a modal sheet while this runs.
echo
echo "   removing the existing install first, so the re-signed IPA has no conflict"
detail "installed version: ${VERSION_BEFORE:-unknown}"
ios_uninstall "$PKG" || {
  echo "!! could not remove $PKG; installing over it will fail on a signature conflict." >&2
  exit 1
}

# --- TrollStore ----------------------------------------------------------------
step "Open TrollStore"
ios_open_or_ask "$TROLLSTORE_ID" TrollStore

# "Install IPA File" over "Install from URL": the IPA is already on the device, so the URL
# path would mean standing up an HTTP server on the Mac, putting the phone on the same
# network, and sending a decrypted client binary over the LAN to get it back onto the phone
# it came from. The file picker is local and has no network in it.
#
# Tapped straight from the + button's menu. The entries of a UIMenu are addressable before
# the menu is on screen, so the + does not have to be opened first.
step "Choose \"Install IPA File\" from the + menu"
ios_tap_or_ask "Install IPA File" "tap + (top right), then Install IPA File"

step "Pick the decrypted IPA in the picker and let TrollStore install it"
detail "folder: TrollStore > Decrypted IPA"
detail "this picker belongs to another process — it is the one thing here nothing can tap"
gate "installed?"

await "$PKG to appear as installed" "ios_installed '$PKG'" || exit 1

if ! ios_installed "$PKG"; then
  echo "!! $PKG is not installed — the TrollStore install did not complete." >&2
  exit 1
fi
VERSION_AFTER="$(ios_version "$PKG")"
echo "   installed: $PKG ${VERSION_AFTER:+($VERSION_AFTER)}"

# --- run it --------------------------------------------------------------------
# Launched, never injected into: frida inside the app under test would make its own RASP
# report the tester's tooling, which is a worse outcome than no result at all.
step "Open $PKG"
detail "launched through SpringBoard, with nothing injected into the app"
ios_launch_checked "$PKG" || exit 1

echo
echo "iOS case 4 (App Debug) done on ${DEV_NAME:-$DEV_SERIAL}"
echo "  the app is now running decrypted and re-signed — watch what its RASP checks say"
reopen_loop "$PKG"
