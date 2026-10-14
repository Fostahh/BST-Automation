#!/usr/bin/env bash
# ui.sh — real taps on an iOS device. Sourced by device.sh; needs step/detail/gate from it.
#
# WHY FRIDA AND NOT XCUITEST
# Apple's way to drive an iOS app is XCUITest, which needs testmanagerd to authorise the
# process as a test runner — and only the `xcodebuild test` handshake grants that. A
# sideloaded WebDriverAgent therefore serves HTTP, presses hardware buttons, and sees no
# application at all (XCTDaemonErrorDomain 41); TrollStore solves signing, not that
# authorisation. On a jailbroken device frida is already inside the process and reads UIKit
# directly — no certificate, no Apple tooling, nothing of anyone else's to sign with.
#
# The price is honest: lib/ios/js/uitree.js invokes the handler a touch would have reached
# (control action, tap recogniser, segment selection) rather than synthesising a touch, and
# it reaches into UIKit ivars whose names are iOS-16-specific. So every tap here degrades
# to the manual instruction it replaced instead of failing the case — see ios_tap_or_ask.
#
#   env: IOS_TAP_RETRIES=6   how many times to look for an element before giving up
#        IOS_TAP_SLEEP=1.5   seconds between those attempts
#        IOS_SCROLL_PAGES=20 how many pages to page through when looking for a list row
#        IOS_SHOW=3          seconds to leave a screen up so it can be read, or recorded
#        IOS_SETTLE=3.5      seconds to let a freshly spawned app draw (read by iosdriver.py)
#        IOS_PY=<python>     a python that can `import frida`, if the search misses it

[ -n "${BST_IOS_UI_SOURCED:-}" ] && return 0
BST_IOS_UI_SOURCED=1

IOS_UI_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$IOS_UI_LIB/../base.sh"               # shared with Android: BST_ROOT, FRIDAENV, int_or, num_or

IOS_TAP_RETRIES="$(int_or "${IOS_TAP_RETRIES:-6}" 6 IOS_TAP_RETRIES)"
IOS_TAP_SLEEP="$(num_or "${IOS_TAP_SLEEP:-1.5}" 1.5 IOS_TAP_SLEEP)"
IOS_SCROLL_PAGES="$(int_or "${IOS_SCROLL_PAGES:-20}" 20 IOS_SCROLL_PAGES)"
# A performed step has to stay on screen long enough to be seen — these runs get recorded.
IOS_SHOW="$(num_or "${IOS_SHOW:-3}" 3 IOS_SHOW)"
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
# command, so the driver is torn down and the rest of the case falls back to manual steps.
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
ios_ui_open() {
  [ "$IOS_UI_READY" = 1 ] && [ "$IOS_UI_APP" = "$1" ] && return 0
  _ios_cmd "$(int_or "${IOS_OPEN_TIMEOUT:-120}" 120)" open "$1" || return 1
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

# ios_running <bundleid> : rc0 when the app is running, and IOS_UI_RESP has its pid.
# Nothing is injected — this only reads the device's process list.
ios_running() { _ios_cmd 30 running "$1"; }

# ios_wait_running <bundleid> : the same, given a few seconds to come up.
ios_wait_running() {
  local i
  for (( i=1; i<=IOS_TAP_RETRIES; i++ )); do
    ios_running "$1" && return 0
    [ "$IOS_UI_READY" = 1 ] || return 1
    sleep "$IOS_TAP_SLEEP"
  done
  return 1
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

# ios_tap_req <text> : look for the element until it appears, then tap it. rc1 with a
# message when it never does — the strict helper, same contract as ui_tap_req on Android.
ios_tap_req() {
  local i
  for (( i=1; i<=IOS_TAP_RETRIES; i++ )); do
    ios_tap "$@" && return 0
    # A driver that has been torn down will not come back within this case; stop looping.
    [ "$IOS_UI_READY" = 1 ] || break
    sleep "$IOS_TAP_SLEEP"
  done
  echo "      could not tap '$*': $(_ios_why)" >&2
  return 1
}

# ios_tap_in_list <text> : page the list looking for it, then tap.
#
# A row that has not been scrolled to exists in NO form — not as a view, not as an
# accessibility element — so "not on screen" is the normal state for one app among forty,
# not a failure. Separate from ios_tap_req on purpose: scrolling while waiting for an
# alert to appear would move the list underneath it for nothing.
ios_tap_in_list() {
  local i why
  ios_scroll top >/dev/null 2>&1 || true        # start from a known end of the list
  ios_tap "$@" && return 0
  why="$(_ios_why)"                             # why the TAP failed, before a scroll overwrites it
  for (( i=1; i<=IOS_SCROLL_PAGES; i++ )); do
    ios_scroll down || break                    # rc1 means the list stopped moving
    ios_tap "$@" && return 0
    why="$(_ios_why)"
  done
  echo "      '$*' is nowhere in the list: $why" >&2
  return 1
}

# THE two helpers the cases use: tap it if the driver can, otherwise print what to do and
# gate on it. Not every widget in these flows is proven — a segmented control, a menu entry
# and a SwiftUI row are, a UIAlertController button is not — and TrollStore's file picker
# is a remote view belonging to another process, which nothing in here can reach. A harness
# whose job is to verify an app's defences must not become unrunnable because one button
# resisted, so a failed tap costs the operator a tap, not the case.
_ios_or_ask() {
  sleep "$IOS_TAP_SLEEP"
  local finder="$1" needle="$2" manual="${3:-tap \"$2\"}"
  if "$finder" "$needle"; then
    detail "tapped \"$needle\" (${IOS_UI_RESP#OK })"
    return 0
  fi
  if [ "$IOS_UI_READY" = 1 ] && ios_dump; then
    detail "what is on screen is in $IOS_TREE (${IOS_UI_RESP#OK } entries)"
  fi
  gate "$manual BY HAND, then continue?"
}
ios_tap_or_ask() { _ios_or_ask ios_tap_req "$@"; }      # a button, an alert, a menu entry
ios_row_or_ask() { _ios_or_ask ios_tap_in_list "$@"; }  # a row in a long list

# ios_open_or_ask <bundleid> [name] : restart the app with frida inside it, so the taps
# that follow can reach it. Only ever used on the TOOLS — never on the app under test,
# whose own RASP would then report the frida the tester injected.
ios_open_or_ask() {
  local bundle="$1" name="${2:-$1}"
  if ios_ui_open "$bundle"; then
    detail "opened $name (${IOS_UI_RESP#OK })"
    return 0
  fi
  detail "could not open $name from here: $(_ios_why)"
  gate "open $name BY HAND, then continue?"
}

# ios_ui_report : one line, in the opening report, so the operator knows up front whether
# this run taps for itself or asks. Printed once per case.
ios_ui_report() {
  printf '  taps:    '
  if ios_ui_start; then
    printf 'automatic — frida drives the UI\n'
  else
    printf 'MANUAL — %s\n' "$IOS_UI_WHY"
    printf '           every step still runs; it asks you to tap instead.\n'
  fi
}
