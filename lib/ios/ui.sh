#!/usr/bin/env bash
# ui.sh — real taps on an iOS device. Sourced by device.sh; needs step/detail from it.
#
# WHY FRIDA AND NOT XCUITEST
# Apple's way to drive an iOS app is XCUITest, which needs testmanagerd to authorise the
# process as a test runner — and only the `xcodebuild test` handshake grants that. A
# sideloaded WebDriverAgent therefore serves HTTP, presses hardware buttons, and sees no
# application at all (XCTDaemonErrorDomain 41); TrollStore solves signing, not that
# authorisation. On a jailbroken device frida is already inside the process and reads UIKit
# directly — no certificate, no Apple tooling, nothing of anyone else's to sign with.
#
# lib/ios/js/uitree.js invokes the handler a touch would have reached (control action, tap
# recogniser, segment selection) rather than synthesising a touch.
#
# TIMING is Android's, not a copy of it: nap, DELAY_SCALE, NAP_* and TAP_RETRIES come from
# base.sh, the same code lib/android/common.sh uses. ios_tap_req is ui_tap_req — retry
# TAP_RETRIES times with NAP_SHORT between, then stop the case with a message.
#
#   env: IOS_PY=<python>     a python that can `import frida`, if the search misses it

[ -n "${BST_IOS_UI_SOURCED:-}" ] && return 0
BST_IOS_UI_SOURCED=1

IOS_UI_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$IOS_UI_LIB/../base.sh"               # shared with Android: BST_ROOT, FRIDAENV, int_or, num_or

IOS_TREE="${TMPDIR:-/tmp}/bst-ios-tree.txt"       # where a failed lookup leaves the tree

# --- the driver process --------------------------------------------------------
# Same shape as common.sh's u2_start: one long-lived helper, two FIFOs, a line protocol.
# Injecting into an app costs seconds and a case taps it a dozen times, so the inject
# happens once per app. Different file descriptors from the Android side (5/6, not 7/8) so
# that sourcing both layers in one shell cannot cross the wires.
IOS_UI_READY=0; IOS_UI_PID=""; IOS_UI_WORK=""; IOS_UI_APP=""; IOS_UI_WHY=""; IOS_UI_RESP=""

IOS_PY="${IOS_PY:-}"
ios_ui_python() {
  [ -n "$IOS_PY" ] && { printf '%s' "$IOS_PY"; return 0; }
  local c
  for c in "$FRIDAENV/bin/python" "$HOME/.bst-tools/venv/bin/python" python3 python; do
    { [ -x "$c" ] || command -v "$c" >/dev/null 2>&1; } || continue
    "$c" -c 'import frida' >/dev/null 2>&1 && { IOS_PY="$c"; printf '%s' "$c"; return 0; }
  done
  return 1
}

ios_ui_stop() {
  [ -n "$IOS_UI_WORK" ] || { IOS_UI_READY=0; return 0; }
  printf 'quit\n' >&5 2>/dev/null || true
  exec 5>&- 2>/dev/null || true
  exec 6<&- 2>/dev/null || true
  [ -n "$IOS_UI_PID" ] && kill "$IOS_UI_PID" 2>/dev/null || true
  rm -rf "$IOS_UI_WORK" 2>/dev/null || true
  IOS_UI_READY=0; IOS_UI_PID=""; IOS_UI_WORK=""; IOS_UI_APP=""
}
trap 'ios_ui_stop' EXIT

# ios_ui_start : bring the driver up, once. A failure is REMEMBERED in IOS_UI_WHY and not
# retried — without that, a device with no frida-server would pay the full connect timeout
# on every tap in every step, which turns a case into a ten-minute hang.
ios_ui_start() {
  [ "$IOS_UI_READY" = 1 ] && return 0
  [ -n "$IOS_UI_WHY" ] && return 1
  local py resp=""
  py="$(ios_ui_python)" || {
    IOS_UI_WHY="no python here can 'import frida' (pip install frida, or set IOS_PY=)"
    return 1
  }
  IOS_UI_WORK="$(mktemp -d)" || { IOS_UI_WHY="could not create a work directory"; return 1; }
  mkfifo "$IOS_UI_WORK/cmd" "$IOS_UI_WORK/resp" 2>/dev/null || {
    IOS_UI_WHY="could not create the driver pipes"; ios_ui_stop; return 1; }
  "$py" "$IOS_UI_LIB/py/iosdriver.py" "$DEV_SERIAL" \
    <"$IOS_UI_WORK/cmd" >"$IOS_UI_WORK/resp" 2>"$IOS_UI_WORK/log" &
  IOS_UI_PID=$!
  exec 5>"$IOS_UI_WORK/cmd" 6<"$IOS_UI_WORK/resp" || {
    IOS_UI_WHY="could not open the driver pipes"; ios_ui_stop; return 1; }
  IFS= read -t 40 -r resp <&6 2>/dev/null || resp=""
  [ "$resp" = READY ] && { IOS_UI_READY=1; return 0; }
  # Carry the reason out before the work directory goes: once ios_ui_stop has run, the
  # log it would point at no longer exists.
  IOS_UI_WHY="${resp#ERR }"
  [ -n "$IOS_UI_WHY" ] && [ "$IOS_UI_WHY" != "$resp" ] || \
    IOS_UI_WHY="$(head -n 3 "$IOS_UI_WORK/log" 2>/dev/null | tr '\n' ' ')"
  [ -n "$IOS_UI_WHY" ] || IOS_UI_WHY="the frida driver did not answer"
  ios_ui_stop
  return 1
}

# _ios_cmd <seconds> <verb> [argument...] : one command, one reply, left in IOS_UI_RESP.
# A timeout is not survivable: a late reply would be read as the answer to the NEXT
# command, so the driver is torn down and the next tap stops the case.
_ios_cmd() {
  local secs="$1"; shift
  ios_ui_start || return 1
  IOS_UI_RESP=""
  printf '%s\n' "$*" >&5 2>/dev/null || {
    IOS_UI_WHY="the frida driver exited"; ios_ui_stop; return 1; }
  IFS= read -t "$secs" -r IOS_UI_RESP <&6 2>/dev/null || {
    IOS_UI_WHY="the frida driver stopped answering after ${secs}s"
    IOS_UI_RESP=""; ios_ui_stop; return 1; }
  case "$IOS_UI_RESP" in OK*) return 0 ;; *) return 1 ;; esac
}

_ios_why() {   # the best available explanation of the last failure, for one log line
  local r="${IOS_UI_RESP#ERR }"
  [ -n "$r" ] && [ "$r" != "${IOS_UI_RESP}" ] && { printf '%s' "$r"; return 0; }
  printf '%s' "${IOS_UI_WHY:-unknown}"
}

# --- what the cases call -------------------------------------------------------
# ios_ui_open <bundleid> : spawn the app and inject. Spawn rather than attach, because iOS
# freezes a backgrounded app and an injection into a frozen process never completes.
# Re-opening the app already open is a no-op, so a case can call this before every step.
# Then nap 2.5, as mt_launch_fresh does after launching MT Manager.
ios_ui_open() {
  [ "$IOS_UI_READY" = 1 ] && [ "$IOS_UI_APP" = "$1" ] && return 0
  _ios_cmd "$(int_or "${IOS_OPEN_TIMEOUT:-120}" 120)" open "$1" || {
    echo "  !! could not open $1: $(_ios_why)" >&2; return 1; }
  IOS_UI_APP="$1"
  nap 2.5
}

# ios_ui_attach <bundleid> : inject into the app as it is, no restart. For an app that
# another app just brought up with something to show — TrollStore, handed an IPA.
ios_ui_attach() {
  _ios_cmd "$(int_or "${IOS_OPEN_TIMEOUT:-120}" 120)" attach "$1" || {
    echo "  !! could not attach to $1: $(_ios_why)" >&2; return 1; }
  IOS_UI_APP="$1"
}

ios_find() { _ios_cmd 60 find "$*"; }     # rc0 when something visible says it
ios_tap()  { _ios_cmd 60 tap  "$*"; }     # one attempt; IOS_UI_RESP says how it was tapped

# ios_dump [path] : the whole visible tree, for working out why a lookup missed.
ios_dump() { _ios_cmd 60 dump "${1:-$IOS_TREE}"; }

# ios_scroll [down|up|top] : page the biggest list on screen. rc1 when it did not move,
# which is how a search through a list knows it has reached the end.
ios_scroll() { _ios_cmd 60 scroll "${1:-down}"; }

# ios_open_url <url> : put a screen on the phone — Settings panes, itms-beta:, anything
# with a URL. Opened by the device itself, with nothing injected anywhere.
ios_open_url() { _ios_cmd 60 url "$1"; }

# --- the file picker, which is a different process ----------------------------
# A document picker belongs to com.apple.DocumentManager.Service, not to the app that
# opened it — the app holds an empty _UIRemoteView and can neither see nor touch it. The
# driver can attach there directly, and once it has, every helper below (ios_find,
# ios_tap, ios_dump, ios_scroll, ios_tap_req) acts on the picker instead, because they
# all go through the same target. Switch back with ios_use_app.
IOS_PICKER_PROC="${IOS_PICKER_PROC:-com.apple.DocumentManager.Service}"

# ios_use_picker : wait for the picker to come up, then aim at it.
# The service is spawned when the picker opens, so the first attempt is usually too early.
ios_use_picker() {
  local i
  for (( i=1; i<=TAP_RETRIES; i++ )); do
    _ios_cmd 60 service "$IOS_PICKER_PROC" && return 0
    [ "$IOS_UI_READY" = 1 ] || break
    nap "$NAP_SHORT"
  done
  echo "      the file picker never appeared: $(_ios_why)" >&2
  return 1
}

ios_use_app() { _ios_cmd 60 service app; }

# ios_in_picker <text> : tap something inside the picker, then hand
# the driver back to the app whatever happens — leaving it aimed at a dismissed picker
# would make every later step look for things in the wrong process.
ios_in_picker() {
  local rc=0
  ios_use_picker || return 1
  ios_tap_req "$@" || rc=$?
  ios_use_app >/dev/null 2>&1 || true
  return "$rc"
}

# ios_running <bundleid> : rc0 when the app is running, and IOS_UI_RESP has its pid.
# Nothing is injected — this only reads the device's process list.
ios_running() { _ios_cmd 30 running "$1"; }

# ios_wait_running <bundleid> : the same, given a few seconds to come up.
ios_wait_running() {
  local i
  for (( i=1; i<=TAP_RETRIES; i++ )); do
    ios_running "$1" && return 0
    [ "$IOS_UI_READY" = 1 ] || return 1
    nap "$NAP_SHORT"
  done
  return 1
}

# ios_wait_front <bundleid> : wait until that app is the one on screen. Android's
# wait_magisk_fg: check, sleep 0.5, up to 40 times. A launch request returns as soon as the
# process exists, which at DELAY_SCALE=0.5 was before the app had drawn anything — the
# step "showed" TestFlight and the next one opened another app over its launch screen.
ios_wait_front() {
  local n=0
  until _ios_cmd 30 front "$1"; do
    [ "$IOS_UI_READY" = 1 ] || break
    sleep 0.5; n=$((n+1)); [ "$n" -gt 40 ] && break
  done
  [ "${IOS_UI_RESP%% *}" = OK ] && return 0
  echo "  !! $1 never came to the front ($(_ios_why))" >&2
  return 1
}

# ios_wait_for <text> : wait until the screen shows it — the UI a step is meant to put up,
# confirmed before the next step runs. Android's wait_magisk_fg loop: look, sleep 0.5, up
# to 40 times. NOT scaled by DELAY_SCALE: what is awaited is a screen loading — TestFlight
# fetches its list over the network — and that is no faster at DELAY_SCALE=0.5.
ios_wait_for() {
  local n=0
  until ios_find "$@"; do
    [ "$IOS_UI_READY" = 1 ] || break
    sleep 0.5; n=$((n+1)); [ "$n" -gt 40 ] && break
  done
  [ "${IOS_UI_RESP%% *}" = OK ] && return 0
  echo "  !! expected screen not shown: $* ($(_ios_why))" >&2
  return 1
}

# ios_grant <bundleid> : grant the app every permission it declares, so no permission
# alert ever lands on top of a step. Done by a hidden copy of Settings: nothing changes on
# screen, and the app under test itself is never injected. Best effort, like ui_tap_when:
# a permission it could not grant costs an alert on screen, not the case.
ios_grant() {
  if _ios_cmd 60 grant "$1"; then
    detail "granted: ${IOS_UI_RESP#OK }"
  else
    echo "  WARN: permissions for $1: $(_ios_why)" >&2
  fi
  return 0
}

# ios_show_screen [pattern] : put what is on screen INTO THE RUN OUTPUT.
#
# For the places where the evidence is text on the phone — TrollFools' injection log is
# the only proof an injection happened. Asking "does the log look right?" makes the result
# depend on who was reading; printing the log makes it part of the run.
ios_show_screen() {
  local pattern="${1:-.}"
  ios_dump || return 1
  awk -v want="$pattern" '
    NR == 1 { next }                                  # the dump header
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      # the class is the first column, what the view SAYS is the rest before the rect
      said = line
      sub(/^[^ ]+[[:space:]]+/, "", said)
      sub(/[[:space:]]+-?[0-9]+,-?[0-9]+ [0-9]+x[0-9]+[[:space:]]*$/, "", said)
      gsub(/[[:space:]]+$/, "", said)
      if (said != "" && said ~ want && !seen[said]++) print "      | " said
    }
  ' "$IOS_TREE"
}

# ios_tap_req <text> : Android's ui_tap_req. Up to TAP_RETRIES attempts, nap NAP_SHORT
# between them, rc1 with a message when the element never appears.
ios_tap_req() {
  local i
  for (( i=1; i<=TAP_RETRIES; i++ )); do
    ios_tap "$@" && return 0
    [ "$IOS_UI_READY" = 1 ] || break     # a dead driver will not come back this case
    nap "$NAP_SHORT"
  done
  echo "  !! required element not found after retries: $* ($(_ios_why))" >&2
  return 1
}

# ios_tap_in_list <text> : page the list looking for it, then tap.
#
# A row that has not been scrolled to exists in NO form — not as a view, not as an
# accessibility element — so "not on screen" is the normal state for one app among forty,
# not a failure. Separate from ios_tap_req on purpose: scrolling while waiting for an
# alert to appear would move the list underneath it for nothing.
#
# Paged like Android's read_modules: a fixed number of pages, nap NAP_SCROLL after each.
# Up to three passes, NAP_NAV apart: a list that is still loading — TrollStore's, right
# after an install — has no row to find on the first pass, and that is a wait, not a miss.
ios_tap_in_list()  { _ios_in_list ios_tap "$@"; }
# ios_find_in_list <text> : the same paging, to CONFIRM a row is there without tapping it.
ios_find_in_list() { _ios_in_list ios_find "$@"; }

_ios_in_list() {
  local act="$1" i pass why=""
  shift
  for (( pass=1; pass<=3; pass++ )); do
    [ "$pass" = 1 ] || nap "$NAP_NAV"
    ios_scroll top >/dev/null 2>&1 || true      # start from a known end of the list
    "$act" "$@" && return 0
    why="$(_ios_why)"                           # why it failed, before a scroll overwrites it
    [ "$IOS_UI_READY" = 1 ] || break
    for (( i=1; i<=20; i++ )); do
      ios_scroll down || break                  # rc1 means the list stopped moving
      nap "$NAP_SCROLL"
      "$act" "$@" && return 0
      why="$(_ios_why)"
    done
  done
  echo "  !! required element not found in the list: $* ($why)" >&2
  return 1
}

# ios_ui_report : one line in the opening report. rc1 when the driver cannot start —
# every step taps, so a case without one stops here instead of at its first tap.
ios_ui_report() {
  printf '  taps:    '
  if ios_ui_start; then
    printf 'automatic — frida drives the UI\n'
    return 0
  fi
  printf 'UNAVAILABLE — %s\n' "$IOS_UI_WHY"
  return 1
}
