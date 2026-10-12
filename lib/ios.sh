#!/usr/bin/env bash
# ios.sh — the iOS counterpart to common.sh. Requires DEV_SERIAL (a devicectl UDID).
#
# WHY THIS LOOKS NOTHING LIKE common.sh
# Nothing on a Mac can synthesise a tap on an iOS device without extra machinery on the
# phone — WebDriverAgent, idb's companion, or a jailbreak touch injector. All three break
# whenever iOS or the jailbreak updates, and none of them is what these cases are actually
# testing. So the taps are yours: each case prints the exact step and gates on it.
#
# What IS automated is the part that goes wrong by hand:
#   * waiting — for a TestFlight update, for a decrypt to finish
#   * sequencing — uninstalling the old bundle BEFORE installing the re-signed one
#   * verification — that the version really changed, that the app really is installed
# xcrun devicectl does all of that without touching the screen.
#
# The seams are deliberate. Replacing `gate "tap Full IPA"` with a real tap later is a
# one-line change per step; the flow around it does not move.

: "${DEV_SERIAL:?DEV_SERIAL not set — launch scenarios via run-scenarios.sh}"

IOS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$IOS_LIB/base.sh"            # BST_ROOT, pick_index, int_or, num_or

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
# fatal: the cases are gated manual flows and still run, they just lose the verification
# between the steps, and each one says so rather than quietly skipping the check.
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

DEVICECTL_TIMEOUT="$(int_or "${DEVICECTL_TIMEOUT:-60}" 60 DEVICECTL_TIMEOUT)"

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
ios_apps() {
  case "$(ios_backend)" in
    imd)
      ideviceinstaller --udid "$DEV_SERIAL" list --user 2>/dev/null \
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

ios_os_version() {  # the iOS version, for the opening report. Empty when unreadable.
  case "$(ios_backend)" in
    imd) ideviceinfo --udid "$DEV_SERIAL" -k ProductVersion 2>/dev/null | tr -d '\r' ;;
    *)   : ;;
  esac
}

ios_uninstall() {   # remove <bundleid>; quiet success when it was not there
  echo "   uninstalling $1 ..."
  case "$(ios_installed "$1"; echo $?)" in
    1) echo "   not installed — nothing to remove."; return 0 ;;
    2) echo "   cannot read the app list, so cannot confirm what is installed." >&2
       gate "remove $1 BY HAND in Settings, then continue?"
       return 0 ;;
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

ios_launch() {      # best effort; the operator can always tap the icon
  case "$(ios_backend)" in
    imd)       idevicedebug --udid "$DEV_SERIAL" run "$1" >/dev/null 2>&1 & disown || true ;;
    devicectl) _dc_json device process launch --terminate-existing "$1" >/dev/null 2>&1 || true ;;
  esac
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

# await <description> <shell-condition> : poll until the condition holds, or let the
# operator say it is done / give up. Used for the waits that are easy to get wrong by
# hand — a TestFlight download, a decrypt — where proceeding early breaks the case.
await() {
  local what="$1" cond="$2" tries=0 limit="${AWAIT_TRIES:-60}"
  printf '      waiting: %s\n' "$what"
  while [ "$tries" -lt "$limit" ]; do
    if eval "$cond"; then printf '      confirmed: %s\n' "$what"; return 0; fi
    tries=$((tries + 1))
    sleep "${AWAIT_SLEEP:-5}"
  done
  echo "      still not confirmed after $((limit * ${AWAIT_SLEEP:-5}))s." >&2
  gate "continue anyway?"
}

# --- the flow every iOS case starts with --------------------------------------
# Identical opening for all six cases: confirm what build is on the phone, and make sure
# TestFlight is not holding a newer one. Running a scenario against a stale build makes
# the verdict describe the wrong binary.
ios_general_rules() {
  local pkg="$1" before after os backend
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

  step "Settings > General > About — confirm the device and iOS version"
  gate "done?"

  step "TestFlight > tap the app under test > scroll to Previous Builds > tap the build you want"
  detail "target: $pkg"
  gate "done?"

  before="$(ios_version "$pkg")"
  ios_can_verify && detail "installed version right now: ${before:-not installed}"

  step "If that build shows an UPDATE button, tap it and let it finish"
  detail "the case must not continue against the old build"
  gate "is the build installed and up to date?"

  # Only draw conclusions from the inventory when the inventory is actually readable.
  # Treating an unreadable one as "not installed" would stop every case on this device.
  if ! ios_can_verify; then
    detail "cannot confirm the version from here — trusting your answer above"
    return 0
  fi
  after="$(ios_version "$pkg")"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    detail "version changed: $before -> $after"
  elif [ -n "$after" ]; then
    detail "version: $after (unchanged)"
  fi
  if [ -z "$after" ]; then
    echo "!! $pkg is not installed on the device — TestFlight has not put it there yet." >&2
    return 1
  fi
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
