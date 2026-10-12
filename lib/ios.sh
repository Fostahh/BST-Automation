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
# devicectl writes structured output to a file rather than stdout, which is the only
# format worth parsing — the human table is columns of padded text that shift with the
# longest device name on the machine.
_dc_json() {   # _dc_json <subcommand...> : echo the JSON devicectl produced, or rc1
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

# ios_apps : "<bundleid>\t<version>" per installed app.
# Parsed in python, not with grep: an unexpected shape must be an error, not a silent
# empty list that every caller then reads as "the app is not installed".
ios_apps() {
  _dc_json device info apps | python3 -I -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError) as error:
    sys.exit(f"ios_apps: devicectl did not return JSON ({error})")
apps = doc.get("result", {}).get("apps")
if apps is None:
    sys.exit("ios_apps: no result.apps in the devicectl output; its schema changed")
for app in apps:
    bundle = app.get("bundleIdentifier") or ""
    version = app.get("version") or app.get("shortVersion") or "?"
    if bundle:
        print(f"{bundle}\t{version}")
'
}

ios_installed() {   # exit 0 if <bundleid> is installed
  ios_apps 2>/dev/null | awk -F'\t' -v b="$1" '$1==b{f=1} END{exit f?0:1}'
}

ios_version() {     # echo the installed version of <bundleid>, empty if absent
  ios_apps 2>/dev/null | awk -F'\t' -v b="$1" '$1==b{print $2; exit}'
}

ios_uninstall() {   # remove <bundleid>; succeeds quietly when it was not there
  echo "   uninstalling $1 ..."
  if ! ios_installed "$1"; then echo "   not installed — nothing to remove."; return 0; fi
  _dc_json device uninstall app "$1" >/dev/null || true
  if ios_installed "$1"; then
    echo "!! $1 is still installed after the uninstall request." >&2
    return 1
  fi
  echo "   removed."
}

ios_launch() {      # bring <bundleid> to the foreground
  _dc_json device process launch --terminate-existing "$1" >/dev/null 2>&1 || true
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
  local pkg="$1" before
  step "Settings > General > About — confirm the device and iOS version"
  gate "done?"

  step "TestFlight > tap the app under test > scroll to Previous Builds > tap the build you want"
  detail "target: $pkg"
  gate "done?"

  before="$(ios_version "$pkg")"
  detail "installed version right now: ${before:-not installed}"
  step "If that build shows an UPDATE button, tap it and let it finish"
  detail "the case must not continue against the old build"
  gate "is the build installed and up to date?"

  local after; after="$(ios_version "$pkg")"
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
