#!/usr/bin/env bash
# NAME: iOS Case 4 — App Debug (decrypt + re-sign via TrollStore)
#
# Take the TestFlight build, decrypt it with TrollDecrypt, and install the decrypted IPA
# through TrollStore so the app runs re-signed and debuggable. The app's own RASP checks
# deliver the verdict, same as every Android case.
#
# Every step is a real tap on the phone — frida drives TrollDecrypt's and TrollStore's UI
# (see lib/ios/ui.sh), so the run is visible on the device, not just in this log. What
# this script owns beyond the taps is the order and the waiting: the decrypt has to finish
# before the IPA is handed over, the old bundle has to be gone before TrollStore installs,
# and every sheet has to finish sliding in before its buttons are tapped. Timing is
# Android's: nap NAP_MED after a tap that opens a sheet or alert, NAP_NAV after a screen
# change, and a tap that never lands stops the case (ios_tap_req = ui_tap_req).
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

# --- TrollDecrypt: decrypt -----------------------------------------------------
step "Open TrollDecrypt"
ios_ui_open "$TROLLDECRYPT_ID" || exit 1

# Searching by bundle id, not by name: every row reads "<version> • <bundle id>", so the
# bundle id picks exactly one row while a display name may not. The list is paged through
# until the row appears, because a row an iOS list has not reached does not exist in any
# form — not as a view, not as an accessibility element.
step "Find $PKG in the list and tap it"
ios_tap_in_list "$PKG" || exit 1
nap "$NAP_MED"                                  # the Decrypt alert slides up

# "Full IPA" over "Main Binary Only": the frameworks and extensions in the bundle are
# encrypted too, and a main binary on its own re-signs into an app that crashes on the
# first framework call. DECRYPT_MODE overrides it when only the binary is wanted.
step "In the Decrypt alert, choose $DECRYPT_MODE"
detail "the alert also offers Main Binary Only, which leaves the frameworks encrypted"
ios_tap_req "$DECRYPT_MODE" || exit 1

# The decrypt takes as long as the app is big, and the IPA is partial until it ends.
# Polling the alert is what replaces guessing: the success alert IS the completion signal.
step "Wait for the decrypt to finish"
await "the \"Decryption Complete\" alert" ios_find "Decryption Complete" || exit 1
nap "$NAP_MED"
ios_tap_req OK || exit 1

# --- the conflict, removed before it bites -------------------------------------
# TrollStore refuses to install over a bundle id it did not install itself, and the
# failure is an alert that says nothing about the cause. The decrypted IPA is already
# written, so the original is no longer needed.
echo
echo "   removing the existing install first, so TrollStore has no conflict"
detail "installed version: ${VERSION_BEFORE:-unknown}"
ios_uninstall "$PKG" || {
  echo "!! could not remove $PKG; TrollStore will refuse to install over it." >&2
  exit 1
}

# --- TrollDecrypt: hand the IPA to TrollStore ----------------------------------
# TrollDecrypt names its output <bundle id>_<version>_decrypted.ipa, so the version read
# above picks this build's file out of every earlier decrypt still in the list.
if [ -n "$VERSION_BEFORE" ]; then
  IPA="${PKG}_${VERSION_BEFORE}_decrypted.ipa"
else
  IPA="${PKG}_"          # version unreadable: any decrypt of this app, if it is the only one
fi

step "Decrypted Files — find $IPA"
ios_tap_req "Decrypted Files" || exit 1
nap "$NAP_NAV"
ios_tap_in_list "$IPA" || exit 1
nap "$NAP_MED"                                  # the share sheet slides up

# The share sheet draws a third-party app's name out of process, so "TrollStore" is not
# text anything here can read. The cell is found by what it does — hand the file to an
# app — and the attach below confirms which app that was: it waits for TrollStore to be
# the app in front, and fails if anything else came up.
step "Share it to TrollStore"
ios_tap_req "Open in app" || exit 1
ios_ui_attach "$TROLLSTORE_ID" || {
  echo "!! TrollStore did not come up from the share sheet ($(_ios_why))." >&2
  exit 1
}

step "Install"
detail "TrollStore shows the IPA's name and version before it installs"
nap "$NAP_MED"
ios_tap_req Install || exit 1

await "$PKG to appear as installed" ios_installed "$PKG" || exit 1
VERSION_AFTER="$(ios_version "$PKG")"
echo "   installed: $PKG ${VERSION_AFTER:+($VERSION_AFTER)}"
nap "$NAP_MED"                                  # the Installing alert on its way out

# Again: the uninstall above took every permission with it, and this build is about to
# open for the first time.
step "Grant $PKG its permissions again"
ios_grant "$PKG"                                # hidden — TrollStore stays on screen

# --- run it --------------------------------------------------------------------
# Opened from TrollStore's own row, the way a tester would, and never injected into:
# frida inside the app under test would make its own RASP report the tester's tooling,
# which is a worse outcome than no result at all.
step "Open $PKG from TrollStore"
ios_tap_in_list "$PKG" || exit 1
nap "$NAP_MED"                                  # the app's alert slides up
ios_tap_req Open || exit 1
ios_wait_front "$PKG" || exit 1                 # on screen, not merely a process
detail "on screen: $PKG (${IOS_UI_RESP#OK })"

echo
echo "iOS case 4 (App Debug) done on ${DEV_NAME:-$DEV_SERIAL}"
echo "  the app is now running decrypted and re-signed — watch what its RASP checks say"
reopen_loop "$PKG"
