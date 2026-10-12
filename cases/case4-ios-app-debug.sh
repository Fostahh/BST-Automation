#!/usr/bin/env bash
# NAME: iOS Case 4 — App Debug (decrypt + re-sign via TrollStore)
# PLATFORM: ios
#
# Take the TestFlight build, decrypt it with TrollDecrypt, and install the decrypted IPA
# through TrollStore so the app runs re-signed and debuggable. The app's own RASP checks
# deliver the verdict, same as every Android case.
#
# The taps are yours — see lib/ios.sh for why. What this script owns is the order and the
# waiting: the decrypt has to finish before TrollStore sees the IPA, and the old bundle has
# to be gone before the re-signed one goes on, or the install fails on a signature
# conflict. Both are easy to get wrong by hand and neither is visible until later.
#
#   env: TARGET_PKG=<bundle id>   DEV_SERIAL=<devicectl udid>   (run-scenarios.sh sets both)
#        TROLLDECRYPT_FIND=type|scroll   how to locate the app in TrollDecrypt (default type)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/ios.sh"

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
gate "open?"

# Typing beats scrolling, and this suite has already paid for the alternative: every
# scroll-to-find loop on the Android side has been a defect source, because the number of
# swipes depends on how many apps are installed and "I scrolled and did not see it" is
# indistinguishable from "it is not there". A typed bundle id is one step and it verifies
# itself — no result means not installed, which is an answer.
case "${TROLLDECRYPT_FIND:-type}" in
  scroll)
    step "Scroll the app list until $PKG appears, then tap it"
    detail "typing is usually quicker — set TROLLDECRYPT_FIND=type to be prompted that way"
    ;;
  *)
    step "Tap the keyboard icon (top right) and type the bundle id"
    detail "$PKG"
    detail "then tap the app in the filtered list"
    ;;
esac
gate "app selected?"

step "In the alert, tap Full IPA"
gate "tapped?"

step "Wait for the alert titled Success / \"Decryption Complete!\", then tap OK"
detail "the decrypted IPA lands in TrollStore's Decrypted IPA folder"
detail "do not continue before the alert appears — TrollStore will not see a partial file"
gate "did Success appear, and did you tap OK?"

# --- TrollStore ----------------------------------------------------------------
step "Open TrollStore and tap the + icon (top right)"
gate "open?"

# "Install IPA File" over "Install from URL": the IPA is already on the device, so the URL
# path would mean standing up an HTTP server on the Mac, putting the phone on the same
# network, and sending a decrypted client binary over the LAN to get it back onto the
# phone it came from. The file picker is local and has no network in it.
step "Choose \"Install IPA File\" (not \"Install from URL\")"
detail "the IPA is already on the device; the URL path would serve a decrypted"
detail "client binary over the network to reach the same phone it came from"
gate "picker open?"

# The conflict step, done here rather than left to the operator: installing over an
# existing bundle id fails on a signature mismatch, and the failure appears as an install
# error with no hint about the cause.
echo
echo "   removing the existing install first, so the re-signed IPA has no conflict"
detail "installed version: ${VERSION_BEFORE:-unknown}"
ios_uninstall "$PKG" || {
  echo "!! could not remove $PKG; installing over it will fail on a signature conflict." >&2
  exit 1
}

step "Pick the decrypted IPA in the picker and let TrollStore install it"
detail "folder: TrollStore > Decrypted IPA"
gate "installed?"

await "$PKG to appear as installed" "ios_installed '$PKG'"

if ! ios_installed "$PKG"; then
  echo "!! $PKG is not installed — the TrollStore install did not complete." >&2
  exit 1
fi
VERSION_AFTER="$(ios_version "$PKG")"
echo "   installed: $PKG ${VERSION_AFTER:+($VERSION_AFTER)}"

step "Tap the installed app in TrollStore, then tap Open in the alert"
gate "opened?"

echo
echo "iOS case 4 (App Debug) done on ${DEV_NAME:-$DEV_SERIAL}"
echo "  the app is now running decrypted and re-signed — watch what its RASP checks say"
reopen_loop "$PKG"
