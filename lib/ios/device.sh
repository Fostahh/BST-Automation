#!/usr/bin/env bash
# ios.sh — the iOS counterpart to common.sh. Requires DEV_SERIAL (a devicectl UDID).
#
# WHY THIS LOOKS NOTHING LIKE common.sh
# The Android layer has one way to see the screen (uiautomator) and one way to touch it
# (input tap). iOS has neither built in, so the work is split in two:
#
#   * ios/ui.sh  taps and reads the UI, through frida on a jailbroken device. Sourced
#                below; it explains why XCUITest is not an option here.
#   * this file  everything that does not touch the screen — the app inventory, the
#                install and uninstall sequencing, the waiting, and the verdicts.
#
# A tap that never lands stops the case with a message, as ui_tap_req does on Android.

: "${DEV_SERIAL:?DEV_SERIAL not set — launch scenarios via run-scenarios.sh}"

IOS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../lib/ios
. "$IOS_LIB/../base.sh"         # shared with Android: BST_ROOT, pick_index, int_or, num_or
# The tap layer. It calls step/detail from further down this file — resolved when the
# case runs, not when this line does, so the order here is not a problem.
. "$IOS_LIB/ui.sh"              # ios_ui_open, ios_tap_req, ios_tap_in_list, ios_dump

DEVICECTL_TIMEOUT="$(int_or "${DEVICECTL_TIMEOUT:-60}" 60 DEVICECTL_TIMEOUT)"

# --- talking to the device ----------------------------------------------------
# TWO BACKENDS, because one tool does not cover the devices these cases run on.
#
# xcrun devicectl is the iOS 17+ CoreDevice interface. Asking it to list apps on an
# iPhone XR running iOS 15/16 — which is what a Dopamine jailbreak implies — fails with
#   com.apple.dt.CoreDeviceError 1014: This device does not support acquiring a usage
#   assertion
# It can still read hardware properties over the restore layer, which is why the device
# shows up in `devicectl list devices` at all, as an ECID row with no UDID and no State.
#
# libimobiledevice speaks the lockdown protocol those devices do support, so it is
# preferred when present. devicectl is the fallback for an iOS 17+ device.
#
#   brew install libimobiledevice ideviceinstaller
#
# Every operation goes through one of these two, resolved once. A backend of "none" is not
# fatal: the cases still run, they just lose the verification between the steps, and each
# one says so rather than quietly skipping the check.
IOS_BACKEND="${IOS_BACKEND:-}"
ios_backend() {
  [ -n "$IOS_BACKEND" ] && { printf '%s' "$IOS_BACKEND"; return 0; }
  if command -v ideviceinstaller >/dev/null 2>&1 && command -v ideviceinfo >/dev/null 2>&1; then
    IOS_BACKEND=imd
  elif command -v xcrun >/dev/null 2>&1; then
    IOS_BACKEND=devicectl
  else
    IOS_BACKEND=none
  fi
  printf '%s' "$IOS_BACKEND"
}

_dc_json() {   # devicectl writes structured output to a file; the human table is padded columns
  local out rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/bst-dc.XXXXXX.json")" || return 1
  if ! xcrun devicectl "$@" --device "$DEV_SERIAL" --json-output "$out" \
       --timeout "$DEVICECTL_TIMEOUT" >/dev/null 2>&1; then
    rc=1
  fi
  [ -s "$out" ] && cat "$out"
  rm -f "$out"
  return "$rc"
}

# ios_apps : "<bundleid>\t<version>" per installed app, or rc1 if it could not be read.
# An unreadable inventory must NOT come back as an empty list — every caller would read
# that as "the app is not installed" and act on it.
#
# --all, not --user: TrollStore registers what it installs as a SYSTEM app, so a --user
# listing never shows the re-signed build case 4 puts on — and the wait for it to appear
# ran its full five minutes and then failed an install that had worked.
ios_apps() {
  case "$(ios_backend)" in
    imd)
      ideviceinstaller --udid "$DEV_SERIAL" list --all 2>/dev/null \
        | awk -F', ' 'NR>1 && NF>=2 {
            id=$1; ver=$2; gsub(/^"|"$/, "", id); gsub(/^"|"$/, "", ver)
            if (id != "") printf "%s\t%s\n", id, ver
          }' | grep . || return 1
      ;;
    devicectl)
      _dc_json device info apps | python3 -I -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError) as error:
    sys.exit(f"ios_apps: devicectl did not return JSON ({error})")
if "error" in doc:
    info = doc["error"].get("userInfo", {}).get("NSLocalizedDescription", {})
    why = info.get("string") if isinstance(info, dict) else info
    sys.exit(f"ios_apps: devicectl refused: {why or doc[chr(34)]+chr(34)}")
apps = doc.get("result", {}).get("apps")
if apps is None:
    sys.exit("ios_apps: no result.apps in the devicectl output; its schema changed")
for app in apps:
    bundle = app.get("bundleIdentifier") or ""
    version = app.get("version") or app.get("shortVersion") or "?"
    if bundle:
        print(f"{bundle}\t{version}")
'
      ;;
    *) return 1 ;;
  esac
}

# ios_can_verify : true when the inventory is actually readable on this device.
# Checked once per case so a flow can say "running without verification" up front rather
# than reporting a cheerful but meaningless result at every step.
IOS_VERIFY=""
ios_can_verify() {
  if [ -z "$IOS_VERIFY" ]; then
    if ios_apps >/dev/null 2>&1; then IOS_VERIFY=1; else IOS_VERIFY=0; fi
  fi
  [ "$IOS_VERIFY" = 1 ]
}

ios_installed() {   # exit 0 if <bundleid> is installed; rc2 means "could not tell"
  local apps
  apps="$(ios_apps 2>/dev/null)" || return 2
  printf '%s\n' "$apps" | awk -F'\t' -v b="$1" '$1==b{f=1} END{exit f?0:1}'
}

ios_version() {     # echo the installed version of <bundleid>, empty if absent or unknown
  ios_apps 2>/dev/null | awk -F'\t' -v b="$1" '$1==b{print $2; exit}'
}

# ios_display_name : what the app is CALLED. TestFlight and Settings list apps by their
# display name, never by bundle id, so a lookup on those screens needs this.
ios_display_name() {
  case "$(ios_backend)" in
    imd) ideviceinstaller --udid "$DEV_SERIAL" list --all 2>/dev/null \
           | awk -F', ' -v b="$1" 'NR>1 && $1==b {
               name=$3; gsub(/^"|"$/, "", name); print name; exit }' ;;
    *) : ;;
  esac
}

ios_os_version() {  # the iOS version, for the opening report. Empty when unreadable.
  case "$(ios_backend)" in
    imd) ideviceinfo --udid "$DEV_SERIAL" -k ProductVersion 2>/dev/null | tr -d '\r' ;;
    *)   : ;;
  esac
}

# ios_store_name <bundleid> : the name TestFlight and the App Store list the app under —
# iTunesMetadata's itemName, read over lockdown. It need not be the display name: an app
# shown as "Foo" on the home screen can be "Foo Bank" in TestFlight, and a lookup by
# display name then finds nothing.
ios_store_name() {
  [ "$(ios_backend)" = imd ] || return 0
  ideviceinstaller --udid "$DEV_SERIAL" list --all --xml -a CFBundleIdentifier -a iTunesMetadata \
      2>/dev/null | python3 -I -c '
import plistlib, sys
try:
    apps = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
for app in apps:
    if app.get("CFBundleIdentifier") == sys.argv[1] and isinstance(app.get("iTunesMetadata"), bytes):
        try:
            print(plistlib.loads(app["iTunesMetadata"]).get("itemName", ""))
        except Exception:
            pass
        break
' "$1"
}

ios_uninstall() {   # remove <bundleid>; quiet success when it was not there
  echo "   uninstalling $1 ..."
  case "$(ios_installed "$1"; echo $?)" in
    1) echo "   not installed — nothing to remove."; return 0 ;;
    2) echo "   WARN: cannot read the app list — uninstalling anyway, unverified." >&2 ;;
  esac
  case "$(ios_backend)" in
    imd)       ideviceinstaller --udid "$DEV_SERIAL" uninstall "$1" >/dev/null 2>&1 || true ;;
    devicectl) _dc_json device uninstall app "$1" >/dev/null 2>&1 || true ;;
  esac
  if ios_installed "$1"; then
    echo "!! $1 is still installed after the uninstall request." >&2
    return 1
  fi
  echo "   removed."
}

# ios_launch : start <bundleid> with NOTHING of ours inside it.
#
# The frida driver asks SpringBoard to launch it, which works for any app including a
# TrollStore-installed one, and injects nothing. That distinction matters: the app under
# test must never have frida in it, or its own RASP reports the tester's tooling as a
# finding and the run is worthless. idevicedebug needs get-task-allow and so only ever
# worked for development builds; devicectl needs iOS 17. Hence the order.
ios_launch() {
  ios_ui_start 2>/dev/null && _ios_cmd 60 launch "$1" && return 0
  case "$(ios_backend)" in
    imd)       idevicedebug --udid "$DEV_SERIAL" run "$1" >/dev/null 2>&1 & disown || true ;;
    devicectl) _dc_json device process launch --terminate-existing "$1" >/dev/null 2>&1 || true ;;
  esac
}

# ios_launch_checked <bundleid> : launch it and confirm it is running.
#
# "is it running?" is read from the process list, never asked.
ios_launch_checked() {
  local pkg="$1"
  ios_launch "$pkg"
  ios_wait_front "$pkg" || return 1           # on screen, not merely a process
  detail "on screen: $pkg (${IOS_UI_RESP#OK })"
}

# --- talking to the operator ---------------------------------------------------
IOS_STEP=0
step() {   # numbered instruction. The tap is manual; the number keeps the log readable.
  IOS_STEP=$((IOS_STEP + 1))
  printf '\n%2d) %s\n' "$IOS_STEP" "$1"
}
detail() { printf '      %s\n' "$1"; }   # a sub-instruction under the current step

# gate <question> : Enter or y continues, n stops the case.
# Exits on a failed read: at EOF read keeps returning empty and a loop would never end.
gate() {
  local ans
  while :; do
    read -rp "      $1 [Y/n]: " ans || { echo; echo "   no answer — stopping." >&2; exit 1; }
    case "${ans:-y}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   echo "   stopped by the operator."; exit 0 ;;
      *) echo "      answer Y or n." >&2 ;;
    esac
  done
}

# await <description> <command> [args...] : poll until the command succeeds, then carry on.
#
# For the waits that are easy to get wrong by hand — a decrypt finishing, an install
# appearing — where continuing early breaks the case. A timeout is a FAILURE, not a
# question: "continue anyway?" produced runs whose verdict depended on whether someone
# was feeling patient. Same loop as Android's install wait (case 7's c7_wait_install):
# sleep 2s, check, until INSTALL_TIMEOUT runs out.
#
# A command and its arguments, never a string to eval: the arguments carry a bundle id
# the operator typed, and eval would run whatever was typed after a quote.
await() {
  local what="$1" deadline
  shift
  deadline=$((SECONDS + $(int_or "${INSTALL_TIMEOUT:-600}" 600 INSTALL_TIMEOUT)))
  printf '      waiting: %s\n' "$what"
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 2
    if "$@"; then printf '      confirmed: %s\n' "$what"; return 0; fi
  done
  echo "!! gave up waiting for $what after ${INSTALL_TIMEOUT:-600}s (INSTALL_TIMEOUT)." >&2
  return 1
}

# --- the flow every iOS case starts with --------------------------------------
# Identical opening for every iOS case: say what is on the cable, and establish that the
# build about to be tested is the build meant to be tested. Running a scenario against a
# stale build makes the verdict describe the wrong binary.
#
# This used to be three questions — confirm the device in Settings, pick the TestFlight
# build, let any UPDATE finish. All three asked a human to confirm something readable from
# here: the model and iOS version arrive over lockdown, and so does the installed version.
# So nothing is asked. Set EXPECT_VERSION=<version> to make "the right build" a check
# rather than an assumption; the run stops if the phone is holding anything else.
ios_general_rules() {
  local pkg="$1" version os backend name
  backend="$(ios_backend)"
  os="$(ios_os_version)"
  printf '  device:  %s%s\n' "${DEV_NAME:-$DEV_SERIAL}" "${os:+  (iOS $os)}"
  printf '  verify:  '
  if ios_can_verify; then
    printf 'via %s — app inventory readable\n' "$backend"
  else
    printf 'UNAVAILABLE'
    case "$backend" in
      none)      printf ' (no device tooling installed)\n' ;;
      devicectl) printf ' (devicectl cannot read apps on iOS < 17)\n' ;;
      *)         printf ' (%s could not read the app list)\n' "$backend" ;;
    esac
    echo "           install libimobiledevice to get it back:" >&2
    echo "             brew install libimobiledevice ideviceinstaller" >&2
    echo "           the case still runs; it just cannot check its own steps." >&2
  fi
  ios_ui_report || return 1

  # An unreadable inventory must not be read as "not installed" — that would stop every
  # case on a device the cases can otherwise drive perfectly well.
  if ! ios_can_verify; then
    printf '  build:   cannot be read from here — the case runs against whatever is installed\n'
    return 0
  fi

  version="$(ios_version "$pkg")"
  if [ -z "$version" ]; then
    echo "!! $pkg is not installed on this device." >&2
    echo "   install the build under test (TestFlight, or iOS case 4) and run this again." >&2
    return 1
  fi

  # --- the two screens, opened on the phone ------------------------------------
  # Performed, not asked and not skipped. The values below are read over lockdown, so the
  # script does not need these screens — the tester watching, and the recording, do.
  #
  # Each screen is CONFIRMED on the phone before the next step runs, then held for nap 3.
  # A fixed nap alone was not enough: at DELAY_SCALE=0.5 the next app opened over
  # TestFlight's launch screen, so the step ran and nothing was ever shown.
  step "Settings > General > About"
  ios_open_url "prefs:root=General&path=About" || {
    echo "!! could not open Settings > General > About ($(_ios_why))." >&2; return 1; }
  # Capacity is a row only the About pane has, so General itself cannot pass for it.
  ios_ui_attach com.apple.Preferences && ios_wait_for Capacity || return 1
  detail "${DEV_NAME:-$DEV_SERIAL}${os:+ — iOS $os}, read over lockdown and now on screen"
  nap 3

  # Granted HERE, before anything can launch the app: TrollDecrypt launches it to decrypt
  # it, and its permission chain (Bluetooth, then Notifications) landed on top of the wait
  # for "Decryption Complete".
  step "Grant $pkg its permissions, so no permission alert interrupts a step"
  ios_grant "$pkg"

  # Confirmed by the app's own row, "<Name>, Version <v> (<build>)", which exists only once
  # the list has loaded. <Name> is the App Store name — TestFlight's, not the home screen's. Nothing in TestFlight is tapped — its SwiftUI rows answer no route.
  name="$(ios_store_name "$pkg")"
  [ -n "$name" ] || name="$(ios_display_name "$pkg")"
  step "TestFlight > ${name:-$pkg}"
  ios_ui_open com.apple.TestFlight || return 1
  # The list first — any app's row — because TestFlight fetches it over the network and a
  # search through a list that has not arrived yet finds nothing however far it pages.
  ios_wait_for ", Version " || return 1
  if [ -n "$name" ]; then
    ios_find_in_list "$name, Version" || return 1   # paged: the app may sit below the fold
  else
    ios_wait_front com.apple.TestFlight || return 1
  fi
  nap 3

  # The UPDATE button is deliberately NOT tapped. Every row on that screen has one, they
  # are identical, and the one belonging to this app is identified only by where it sits —
  # so a miss would start installing a different client's app. The build that matters is
  # checked below against what is actually installed, which cannot be mistaken.
  if [ -n "${EXPECT_VERSION:-}" ] && [ "$EXPECT_VERSION" != "$version" ]; then
    echo "!! the phone has $pkg $version, and EXPECT_VERSION says $EXPECT_VERSION." >&2
    echo "   install that build in TestFlight — it is open on the entry — and run again." >&2
    return 1
  fi
  printf '  build:   %s %s%s\n' "$pkg" "$version" \
    "${EXPECT_VERSION:+  (matches EXPECT_VERSION)}"
}

# --- end of every case --------------------------------------------------------
# Same idea as common.sh's reopen_loop: a detection result is worth seeing more than once,
# and relaunching costs nothing next to re-running the whole scenario.
reopen_loop() {
  local pkg="${1:-${TARGET_PKG:-}}" ans
  [ -n "$pkg" ] || return 0
  while :; do
    echo
    read -rp "  open $pkg again? [y/N]: " ans || { echo; return 0; }
    case "$ans" in
      y|Y|yes|YES) ;;
      *) return 0 ;;
    esac
    ios_launch "$pkg"
    echo "  launched $pkg"
  done
}
