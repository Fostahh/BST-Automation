#!/usr/bin/env bash
# common.sh — shared helpers + the state engine for the scenario scripts.
# Requires DEV_SERIAL in env (run-scenarios.sh sets it).
#
# UI interaction is resolution-independent: elements are located in a live
# `uiautomator dump` by their text / resource-id (lib/py/uifind.py) and tapped at
# their real bounds, and toggle state is read from the node's `checked` attribute
# — no fixed pixel coordinates and no screenshot colour sampling. Swipes still use
# ratios (px/py) because a scroll gesture needs no precision.
#
# TIMING — every wait is tunable via env (speed runs up or slow them down):
#   DELAY_SCALE  multiplier for every short UI settle (nap). 1=normal, 0.5=half.
#                Even at 0 each settle is still floored to NAP_MIN so the UI never
#                gets a tap/dump with no settle at all. Default 1.
#   NAP_MIN      the floor every settle is clamped to. Default 0.3s.
#   NAP_SHORT NAP_MED NAP_NAV NAP_SCROLL NAP_LSPOSED  the per-action settle lengths.
#   NAP_MAX      optional cap per settle. Empty (default) = no cap. Do NOT set it for
#                cases 1-3: a too-short settle makes the next dump read the old screen.
#   OPEN_SETTLE  seconds of boot_id stability to watch for when opening Magisk (the
#                Zygisk second-boot guard). Lower = faster but less safe. Default 6, min 2.
#   SETTLE_NEED / SETTLE_MAX  post-reboot stability required / overall cap. Default 20 (min 6) / 200.
#   BOOT_POLL    poll interval for boot/stability loops. Default 2 (min 1).
#   TAP_RETRIES  ui_tap_when dump+retry attempts. Default 10 (min 3).
#   MAGISK_FG_TRIES  wait_magisk_fg attempts (x0.5s). Default 40 (min 10).
#   MAGISK_WATCH_ALWAYS  1 = full boot_id settle watch on every Magisk open (~15s each).
#                Default 0: armed only right after a reboot, which is the only time the
#                Zygisk post-enable restart can happen.

: "${DEV_SERIAL:?DEV_SERIAL not set — launch scenarios via run-scenarios.sh}"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # this lib/ dir (the .sh helpers; python lives in lib/py)
. "$LIB/base.sh"                                      # BST_ROOT, FRIDAENV, pick_index, int_or

# Magisk module titles as shown on the Modules screen (override per device/version).
MOD_LSPOSED="${MOD_LSPOSED:-Zygisk - LSPosed}"
MOD_ZNEXT="${MOD_ZNEXT:-Zygisk Next}"

# --- tunable delays (seconds) -------------------------------------------------
# Every knob is validated HERE, where all paths meet, rather than at the prompt that asks
# for one of them. The runner used to check only the DELAY_SCALE it had just read from the
# keyboard, so DELAY_SCALE=abc in the environment sailed through to awk, coerced to 0, and
# floored every settle in every case to NAP_MIN without a word. num_or/int_or (base.sh)
# substitute the documented default and say which knob was rejected.
DELAY_SCALE="$(num_or "${DELAY_SCALE:-1}" 1 DELAY_SCALE)"          # global nap multiplier
NAP_MIN="$(num_or "${NAP_MIN:-0.3}" 0.3 NAP_MIN)"                  # floor: no settle is shorter
NAP_MAX="${NAP_MAX:-}"                   # OPTIONAL cap per settle (empty = none). See nap().
[ -z "$NAP_MAX" ] || NAP_MAX="$(num_or "$NAP_MAX" "" NAP_MAX)"     # junk cap = no cap
NAP_SHORT="$(num_or "${NAP_SHORT:-0.8}" 0.8 NAP_SHORT)"            # after a tap / minor settle
NAP_MED="$(num_or "${NAP_MED:-1.2}" 1.2 NAP_MED)"                  # after typing / toggle / dialog
NAP_NAV="$(num_or "${NAP_NAV:-1.5}" 1.5 NAP_NAV)"                  # after a screen change
NAP_SCROLL="$(num_or "${NAP_SCROLL:-0.6}" 0.6 NAP_SCROLL)"         # after a scroll swipe
NAP_LSPOSED="$(num_or "${NAP_LSPOSED:-3}" 3 NAP_LSPOSED)"          # LSPosed manager opening
MAGISK_WATCH_ALWAYS="$(int_or "${MAGISK_WATCH_ALWAYS:-0}" 0 MAGISK_WATCH_ALWAYS)"  # 1 = settle watch on EVERY open
MAGISK_WATCH_ARMED=0                     # runtime: set by reboot_wait, cleared after a clean open
# Integer knobs: validate before clamping. `[ abc -lt 2 ]` fails rather than compares, and
# the old `2>/dev/null` swallowed that error and left the junk in place to detonate later
# inside arithmetic — killing the case under `set -e` with nothing printed.
OPEN_SETTLE="$(int_or "${OPEN_SETTLE:-3}" 3 OPEN_SETTLE)";     [ "$OPEN_SETTLE"     -lt 2  ] && OPEN_SETTLE=2
SETTLE_NEED="$(int_or "${SETTLE_NEED:-20}" 20 SETTLE_NEED)";   [ "$SETTLE_NEED"     -lt 6  ] && SETTLE_NEED=6
SETTLE_MAX="$(int_or "${SETTLE_MAX:-200}" 200 SETTLE_MAX)"
BOOT_POLL="$(int_or "${BOOT_POLL:-2}" 2 BOOT_POLL)";           [ "$BOOT_POLL"       -lt 1  ] && BOOT_POLL=1
TAP_RETRIES="$(int_or "${TAP_RETRIES:-10}" 10 TAP_RETRIES)";   [ "$TAP_RETRIES"     -lt 3  ] && TAP_RETRIES=3
MAGISK_FG_TRIES="$(int_or "${MAGISK_FG_TRIES:-40}" 40 MAGISK_FG_TRIES)"; [ "$MAGISK_FG_TRIES" -lt 10 ] && MAGISK_FG_TRIES=10

# nap <seconds> : the standard UI settle — max(NAP_MIN, <seconds>*DELAY_SCALE).
# NAP_MAX can cap it, but it is OFF by default and should stay off for the Magisk
# cases: a settle that is too short makes the NEXT ui_dump snapshot the PREVIOUS
# screen, and the state readers (ui_checked/read_modules) then decide on stale data.
# Retrying a tap cannot detect that, so speed here comes from DELAY_SCALE, knowingly.
#
# The arithmetic needs awk (bash has no floats), but DELAY_SCALE/NAP_MIN/NAP_MAX are
# fixed for the whole run and only ~19 distinct lengths are ever asked for, so each is
# computed once and reused. bash 3.2 ships on macOS and has no associative arrays, hence
# a string cache.
#
# _scale_into assigns to $_SCALED rather than echoing, because "$(_scaled ...)" would run
# it in a subshell and throw every cache write away with it — a memo that silently never
# memoises. Nothing calls nap inside a command substitution, so the cache persists.
_NAP_CACHE=""
_SCALED=""
_scale_into() {   # _scale_into <seconds> <cap:1|0>  ->  sets $_SCALED
  local key="$2:$1"
  case "$_NAP_CACHE" in
    *" $key="*) _SCALED="${_NAP_CACHE#*" $key="}"; _SCALED="${_SCALED%% *}"; return 0 ;;
  esac
  _SCALED=$(awk -v s="$1" -v scale="$DELAY_SCALE" -v lo="$NAP_MIN" -v cap="$NAP_MAX" -v docap="$2" \
    'BEGIN{v=s*scale; if(v<lo)v=lo; c=cap+0; if(docap&&c>0&&v>c)v=c; printf "%.3f", v}')
  _NAP_CACHE="$_NAP_CACHE $key=$_SCALED"
}
nap() { _scale_into "$1" 1; sleep "$_SCALED"; }
# nap_long <seconds> : for waits that are NOT a UI settle and must not be capped —
# a reboot handshake, keyguard coming back, another app's manager starting up.
nap_long() { _scale_into "$1" 0; sleep "$_SCALED"; }

adbx() { command adb -s "$DEV_SERIAL" "$@"; }

# adb_t <seconds> <adb args...> : adbx with a hard timeout, so a polling deadline cannot
# hang forever on a device that dropped off the bus. macOS ships no coreutils `timeout`,
# and spawning a python interpreter per call (what case 7 used to do) costs a process on
# every iteration of loops that poll every 2s for up to ten minutes. A watchdog subshell
# costs nothing and keeps the caller's stdout/stderr wiring intact.
# `set -m` makes the backgrounded adb a process-group leader, so the watchdog can signal
# the whole group (kill -TERM -$pid) instead of just adb. That matters inside "$(adb_t ...)":
# a command substitution does not return until every writer has closed the pipe, so a
# surviving grandchild keeps the caller blocked for the full duration of the call it was
# supposed to abandon. Job-control notices are suppressed; the monitor flag is restored.
adb_t() {
  local secs="$1" pid watchdog rc=0 monitor=; shift
  case "$-" in *m*) monitor=1 ;; esac
  set -m
  command adb -s "$DEV_SERIAL" "$@" &
  pid=$!
  [ -n "$monitor" ] || set +m
  ( sleep "$secs"; kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  # 143 = SIGTERM: the watchdog fired. Report it as 124, the conventional timeout status.
  [ "$rc" = 143 ] && { echo "adb timed out after ${secs}s: $*" >&2; return 124; }
  return "$rc"
}

_PX_CACHE=""        # ratio->pixels, valid for the current W/H (cleared by detect_size)
detect_size() {
  local out sz
  out=$(adbx shell wm size)
  sz=$(echo "$out" | awk -F': ' '/Override/{o=$2} /Physical/{p=$2} END{print (o?o:p)}' | tr -d '\r')
  W=${sz%x*}; H=${sz#*x}
  : "${W:?could not detect screen width}" "${H:?could not detect screen height}"
  _PX_CACHE=""
}
# Memoised for the same reason as nap(), and assigning to $_RATIO for the same reason:
# a value echoed from a subshell cannot carry the cache back out.
_RATIO=""
_ratio_into() {   # _ratio_into <ratio> <extent> <axis-tag>  ->  sets $_RATIO
  local key="$3:$1"
  case "$_PX_CACHE" in
    *" $key="*) _RATIO="${_PX_CACHE#*" $key="}"; _RATIO="${_RATIO%% *}"; return 0 ;;
  esac
  _RATIO=$(awk -v r="$1" -v e="$2" 'BEGIN{printf "%d", r*e}')
  _PX_CACHE="$_PX_CACHE $key=$_RATIO"
}
# px/py keep their echoing shape for any case script that calls them directly; swipr,
# the hot path, goes through the setter so a scroll costs no subprocesses after the first.
px() { _ratio_into "$1" "$W" x; printf '%s' "$_RATIO"; }
py() { _ratio_into "$1" "$H" y; printf '%s' "$_RATIO"; }

# Quoting for the device. `adb shell` does NOT pass argv through: it joins everything
# into one string that the device's shell re-parses, so any path we interpolate must be
# quoted for that shell. shq() single-quotes safely (embedded ' becomes '\''), and
# su_sh() re-quotes once more for the second parse inside `su -c '...'`.
shq() {   # single-quote "$1" for the device shell: an embedded ' becomes '\''
  # Parameter expansion, not sed: the sed form needs backslashes that are easy to lose
  # when this file is generated or edited, and losing them silently re-opens injection.
  local s="$1" q="'"
  printf "'%s'" "${s//$q/$q\\$q$q}"
}
su_sh() { adbx shell "su -c $(shq "$1")"; }

# Input: MIUI blocks injection for the shell user (INJECT_EVENTS), so on a rooted device
# route it through su; on a non-rooted one plain `input` works. One probe, one
# implementation — `inpx` is the real one, `inp` is the long-standing alias cases 1-4 call.
#
# has_su is the single answer to "is there working root here?", cached after the first
# call. It used to be asked three times per run — here at source time, again in
# device-ready.sh, and a third time in case 4 — and the source-time copy charged an adb
# round trip to every scenario, including ones that never send input.
HAS_SU=""
has_su() {
  if [ -z "$HAS_SU" ]; then
    if adbx shell 'su -c id' >/dev/null 2>&1; then HAS_SU=1; else HAS_SU=0; fi
  fi
  [ "$HAS_SU" = 1 ]
}
inpx() { if has_su; then adbx shell "su -c 'input $*'"; else adbx shell input "$@"; fi; }
inp()  { inpx "$@"; }
wake() { inpx keyevent 224 >/dev/null 2>&1 || true; }
swipr() {   # swipr <x1 ratio> <y1 ratio> <x2 ratio> <y2 ratio> [ms]
  local x1 y1 x2 y2
  _ratio_into "$1" "$W" x; x1="$_RATIO"
  _ratio_into "$2" "$H" y; y1="$_RATIO"
  _ratio_into "$3" "$W" x; x2="$_RATIO"
  _ratio_into "$4" "$H" y; y2="$_RATIO"
  inp swipe "$x1" "$y1" "$x2" "$y2" "${5:-300}"
}
launch(){ adbx shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true; }
         # never fails: its output is suppressed, so a non-zero exit under `set -e`
         # would kill the scenario silently. Callers poll focus_now() to confirm.
home()  { inp keyevent 3; }
back()  { inp keyevent 4; }

# --- uiautomator UI layer (find by text/id, tap real bounds, read checked) -----
UI_XML="${TMPDIR:-/tmp}/.uidump.$$.xml"   # one reusable scratch file per run (not per dump)

# --- fast dumps via a persistent uiautomator2 driver (falls back to `uiautomator dump`) ---
# The driver keeps a u2 connection open so each hierarchy dump is ~0.2s instead of ~2s.
# Taps stay on `su -c input` (MIUI blocks the agent's INJECT_EVENTS). bash 3.2 has no
# coproc, so we talk to the driver over two FIFOs on fds 7 (cmd) and 8 (resp).
# Any python that can `import uiautomator2` gives ~0.23s dumps; without one we fall back
# to `uiautomator dump` (~2s) and everything still works. Resolved once, then cached in U2_PY.
U2_PY="${U2_PY:-}"
u2_python() {
  [ -n "$U2_PY" ] && { echo "$U2_PY"; return 0; }
  local c
  for c in "$HOME/.bst-tools/venv/bin/python" \
           "$FRIDAENV/bin/python" \
           python3 python; do
    { [ -x "$c" ] || command -v "$c" >/dev/null 2>&1; } || continue
    "$c" -c 'import uiautomator2' >/dev/null 2>&1 && { U2_PY="$c"; echo "$c"; return 0; }
  done
  return 1
}
U2_READY=0; U2_PID=""; U2_DIR=""
u2_start() {
  [ "$U2_READY" = 1 ] && return 0
  [ -n "$U2_PY" ] || U2_PY="$(u2_python)" || return 1
  U2_DIR="$(mktemp -d)" || return 1
  mkfifo "$U2_DIR/cmd" "$U2_DIR/resp" 2>/dev/null || { rm -rf "$U2_DIR"; U2_DIR=""; return 1; }
  "$U2_PY" "$LIB/py/u2driver.py" "$DEV_SERIAL" <"$U2_DIR/cmd" >"$U2_DIR/resp" 2>"$U2_DIR/log" &
  U2_PID=$!
  exec 7>"$U2_DIR/cmd" 8<"$U2_DIR/resp" || { u2_stop; return 1; }
  local r=""; IFS= read -t 25 -r r <&8 2>/dev/null || r=""
  [ "$r" = "READY" ] && { U2_READY=1; return 0; }
  u2_stop; return 1
}
u2_stop() {
  [ -n "${U2_DIR:-}" ] || { U2_READY=0; return 0; }
  printf 'quit\n' >&7 2>/dev/null || true
  exec 7>&- 2>/dev/null || true
  exec 8<&- 2>/dev/null || true
  [ -n "$U2_PID" ] && kill "$U2_PID" 2>/dev/null || true
  rm -rf "$U2_DIR" 2>/dev/null || true
  U2_READY=0; U2_PID=""; U2_DIR=""
}

# A usable snapshot has a <hierarchy> root and at least one <node>. A busy screen (MT
# Manager mid-signing is the reliable way to see it) makes uiautomator exit 0 having
# written nothing, and a zero-byte or truncated $UI_XML then reads as "no elements on
# screen" — which is indistinguishable from a real answer. Two greps, no interpreter.
_ui_xml_ok() {
  [ -s "$UI_XML" ] || return 1
  grep -q '<hierarchy' "$UI_XML" && grep -q '<node' "$UI_XML"
}
# ui_dump : snapshot the current screen into $UI_XML (overwritten each call).
# Returns non-zero when it could not produce a usable snapshot. Callers in a retry loop
# should treat that as "try again"; callers that READ STATE from the result must not
# carry on, because an empty dump makes every toggle look OFF.
ui_dump() {
  : > "$UI_XML"
  [ "$U2_READY" = 1 ] || u2_start || true
  if [ "$U2_READY" = 1 ]; then
    printf 'dump %s\n' "$UI_XML" >&7 2>/dev/null
    local resp=""; IFS= read -t 25 -r resp <&8 2>/dev/null || resp=""
    [ "$resp" = "OK" ] && _ui_xml_ok && return 0
    u2_stop                      # u2 hiccuped -> fall through to the legacy dump
  fi
  adbx exec-out "uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; cat /sdcard/ui.xml" 2>/dev/null | tr -d '\r' > "$UI_XML"
  _ui_xml_ok
}

trap 'u2_stop; rm -f "$UI_XML"' EXIT      # stop the driver + remove the temp on exit
ui_find() { python3 "$LIB/py/uifind.py" "$UI_XML" "$@"; }            # echoes per --print; rc1 if none
ui_checked() { ui_find --print checked "$@" 2>/dev/null || true; } # "true"/"false"/"" (not found)

# Four tap helpers, because the difference between them is exactly what used to get
# reimplemented per case (case 4 and case 6 each grew a private dump-then-tap; case 7 and
# mtmanager.sh each grew a private retry-then-fail). Pick by what should happen on a miss:
#
#   ui_tap       tap from the CALLER'S existing snapshot, never re-dumps. rc1 if absent.
#                Callers that read state from that snapshot need it left alone.
#   ui_tap_fresh dump first, then tap. rc1 if absent.
#   ui_tap_when  re-dump until it appears, then tap. WARNS and returns 0 if it never
#                does — deliberately lenient, because cases 1-3 walk screens where a
#                control's absence is itself a legitimate state, and the verify step
#                reports the outcome. Do not use it to guard a destructive next step.
#   ui_tap_req   the same retry loop, but rc1 with a message when it never appears.
ui_tap() { local xy; xy="$(ui_find "$@" 2>/dev/null || true)"; [ -n "$xy" ] || return 1; inp tap $xy; }
ui_tap_fresh() { ui_dump || return 1; ui_tap "$@"; }
_ui_tap_retry() {
  local i
  for (( i=1; i<=TAP_RETRIES; i++ )); do
    # A tap can still miss after a successful find — the element may leave the screen in
    # between — so a failed tap re-enters the loop rather than ending it.
    if ui_dump && ui_find "$@" >/dev/null 2>&1; then
      ui_tap "$@" && return 0
    fi
    nap "$NAP_SHORT"
  done
  return 1
}
ui_tap_when() {
  _ui_tap_retry "$@" && return 0
  echo "  WARN: element not found after retries: $*" >&2; return 0   # best-effort; verify step reports the result
}
ui_tap_req() {
  _ui_tap_retry "$@" && return 0
  echo "  !! required element not found after retries: $*" >&2; return 1
}

# --- reboot & unlock ----------------------------------------------------------
enter_pin() {   # type a numeric PIN via keyevents (KEYCODE_0=7 .. KEYCODE_9=16)
  local codes="" i d
  for (( i=0; i<${#1}; i++ )); do d="${1:$i:1}"; codes="$codes $((7 + d))"; done
  inp keyevent $codes
}
# unlock : wake, reveal the keyguard, type $PIN if there is one.
# Asks for the PIN if it does not have one and the keyguard is still up. Cases 2 and 3
# reboot, which brings the keyguard back; without this the only way to get past it was a
# PIN stored on disk via BST_PIN_<PROFILE>, which no longer exists. The case runs as
# `bash <case>` with stdin inherited, so there is a terminal here to ask on.
unlock() {
  inp keyevent 224; nap 0.8                 # WAKEUP
  swipr 0.5 0.80 0.5 0.25 200; nap 1.0      # reveal the PIN pad
  if [ -z "${PIN:-}" ] && [ -t 0 ] && _keyguard_up; then
    read -rsp "  PIN for $DEV_SERIAL (digits; not stored): " PIN || PIN=""
    echo
    export PIN                              # a later reboot in the same case reuses it
  fi
  if [ -n "${PIN:-}" ]; then enter_pin "$PIN"; nap 0.4; inp keyevent 66; nap "$NAP_MED"; fi
}
# _keyguard_up : true only when the policy dump says a keyguard field is showing. Unknown
# counts as NOT up, so an unreadable dump cannot make the run stop and ask for nothing.
_keyguard_up() {
  adbx shell dumpsys window policy 2>/dev/null | tr -d '\r' | awk '
    /^[[:space:]]*(showing|mIsShowing|mKeyguardShowing|isStatusBarKeyguard|mShowingLockscreen)=(true|false)([[:space:]]|$)/ {
      if ($0 ~ /=true([[:space:]]|$)/) up = 1
    }
    END { exit up ? 0 : 1 }'
}
# Each boot has a unique kernel boot_id; a change in it means the device rebooted.
boot_id()   { adbx shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r'; }
device_up() { [ "$(adbx shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }

# wait_until_stable [stable_secs] [max_secs] — absorb an auto-reboot (e.g. the second
# restart Zygisk triggers after it is enabled). Returns once boot_id has stayed the same
# and the device has been booted for <stable_secs> continuously. Sets SECOND_REBOOT=1 if
# it observed the boot_id change (i.e. a reboot happened) while waiting.
SECOND_REBOOT=0
wait_until_stable() {
  local need="${1:-$SETTLE_NEED}" max="${2:-$SETTLE_MAX}" step="${BOOT_POLL:-2}" t=0 stable=0 bid last=""
  SECOND_REBOOT=0
  while [ "$t" -lt "$max" ]; do
    adbx wait-for-device 2>/dev/null || true
    if ! device_up; then stable=0; last=""; sleep "$step"; t=$((t+step)); continue; fi
    bid="$(boot_id)"
    if [ -z "$bid" ]; then stable=0; last=""; sleep "$step"; t=$((t+step)); continue; fi
    if [ -n "$last" ] && [ "$bid" != "$last" ]; then
      echo "  detected a reboot/refresh — waiting for the system to settle ..." >&2
      SECOND_REBOOT=1; stable=0
    fi
    last="$bid"; stable=$((stable+step)); sleep "$step"; t=$((t+step))
    [ "$stable" -ge "$need" ] && return 0
  done
  echo "  WARN: system not fully settled within ${max}s (continuing)" >&2
}

reboot_wait() {
  echo "  rebooting $DEV_NAME ..."
  adbx reboot; nap_long 5; adbx wait-for-device
  local n=0
  until device_up; do
    sleep "${BOOT_POLL:-2}"; n=$((n+1)); [ "$n" -gt 180 ] && { echo "  boot timeout" >&2; return 1; }
  done
  nap_long 3; unlock
  # Enabling Zygisk makes the system auto-restart a few seconds into the first boot;
  # wait that second reboot out, then unlock again if it actually happened.
  wait_until_stable "$SETTLE_NEED" "$SETTLE_MAX"
  if [ "$SECOND_REBOOT" = 1 ]; then nap_long 3; unlock; fi
  MAGISK_WATCH_ARMED=1        # the next Magisk open is the one that needs the full watch
  echo "  boot complete (stable)."
}
do_reboot() {   # honour REBOOT=1 (unattended) or prompt
  local ans
  if [ "${REBOOT:-}" = "1" ]; then ans=y; else read -rp "Reboot $DEV_NAME now? [y/N]: " ans; fi
  case "$ans" in y|Y) reboot_wait;; *) echo "  reboot skipped — state may not be applied" >&2;; esac
}

# --- Magisk navigation --------------------------------------------------------
focus_now() {   # focused-window line
  adbx shell dumpsys window 2>/dev/null | tr -d '\r' | awk '/mCurrentFocus=/ && !f {print; f=1}' || true
}
wait_magisk_fg() {   # wait until Magisk is focused before tapping (esp. after a reboot)
  local n=0
  while :; do
    case "$(focus_now)" in *com.topjohnwu.magisk*) return 0;; esac
    sleep 0.5; n=$((n+1)); [ "$n" -gt "$MAGISK_FG_TRIES" ] && return 1
  done
}
# open_magisk_home's two settle watches guard exactly ONE event: enabling Zygisk makes
# the system restart a few seconds into the first boot. Each watch needs OPEN_SETTLE
# seconds of boot_id stability at BOOT_POLL granularity, so the pair costs ~15s on every
# Magisk open — and apply_state opens Magisk 2-3 times. Arm them only while that restart
# is actually possible (right after a reboot). Outside that window a refresh is still
# DETECTED by the boot_id comparison below and still triggers a reopen; we just don't
# pay 15s waiting for one that cannot come. MAGISK_WATCH_ALWAYS=1 restores the old cost.
magisk_settle_watch() {   # $1 = overall cap
  if [ "$MAGISK_WATCH_ALWAYS" = 1 ] || [ "$MAGISK_WATCH_ARMED" = 1 ]; then
    wait_until_stable "$OPEN_SETTLE" "$1"
  else
    SECOND_REBOOT=0       # nothing observed, so nothing to report
  fi
}
open_magisk_home() {   # fresh launch -> Home, resilient to the Zygisk post-enable refresh
  local try bid0
  for try in 1 2 3 4 5; do
    magisk_settle_watch 120                         # don't launch into a refreshing system
    bid0="$(boot_id)"
    adbx shell am force-stop com.topjohnwu.magisk >/dev/null 2>&1; nap "$NAP_SHORT"
    launch com.topjohnwu.magisk
    wait_magisk_fg || true
    magisk_settle_watch 90                          # the refresh often hits a few seconds AFTER opening
    if [ "$SECOND_REBOOT" = 1 ] || [ "$(boot_id)" != "$bid0" ]; then
      echo "  (system refreshed after opening Magisk — reopening)" >&2
      nap_long 2; unlock; continue
    fi
    case "$(focus_now)" in
      *com.topjohnwu.magisk*) nap "$NAP_SHORT"; MAGISK_WATCH_ARMED=0; return 0;;   # post-reboot window survived
    esac
    echo "  (Magisk not foreground, retry $try)" >&2; nap 2
  done
  echo "  WARN: Magisk not stably foreground after retries" >&2; nap "$NAP_NAV"
}
open_magisk_modules() {             # Home -> Modules tab
  open_magisk_home
  ui_tap_when clickable=true desccontains=Modules; nap "$NAP_NAV"
}
open_magisk_settings() {            # -> Settings (DenyList section). The Settings gear
  # only works from the Home tab, so navigate Home -> gear in-app; reopen the app only
  # if Magisk isn't already foreground (e.g. right after a reboot).
  case "$(focus_now)" in *com.topjohnwu.magisk*) : ;; *) open_magisk_home ;; esac
  ui_tap_when res=homeFragment; nap "$NAP_SHORT"       # Home tab
  ui_tap_when res=action_settings; nap "$NAP_MED"      # Settings gear
  local i
  for i in 1 2 3 4 5 6; do          # scroll until "Enforce DenyList" is on screen
    if ui_dump && ui_find textequals="Enforce DenyList" >/dev/null 2>&1; then return 0; fi
    swipr 0.5 0.75 0.5 0.30 350; nap "$NAP_SCROLL"
  done
  echo "  WARN: DenyList section not found in Settings" >&2
}

# --- Magisk state readers (CLI, fast; used for decisions) ---------------------
dl_enforced() {   # "1" if Enforce DenyList ON, else "0"
  adbx shell "su -c 'magisk --sqlite \"SELECT key,value FROM settings\"'" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^key=denylist|value=//p'
}
dl_in_list() {    # exit 0 if pkg is in the denylist (exact package match)
  adbx shell "su -c 'magisk --denylist ls'" 2>/dev/null | tr -d '\r' \
    | awk -F'|' -v p="$1" '$1==p{f=1} END{exit f?0:1}'
}

# read_modules : set globals ZN, LP (ON/OFF) and MOD (ON if either). Modules screen must
# be open. Returns non-zero when the screen could not be read at all, leaving the three
# globals at UNKNOWN.
#
# This used to return 0 unconditionally, and a dump that produced nothing set ZN=OFF
# LP=OFF MOD=OFF — identical to a genuine reading of "all modules disabled". Case 1 wants
# exactly that state, so a failed dump made case 1 report PASS without having looked.
# A missing snapshot and an absent row are now both distinguishable from "switch is off".
read_modules() {
  ZN=UNKNOWN; LP=UNKNOWN; MOD=UNKNOWN
  local z="" l="" i read_any=0
  # Page down the list rather than reading one screenful. A module sitting below the fold
  # came back empty, and the old code turned empty into OFF — a real state, indistinguishable
  # from a genuine reading. With more modules installed than fit on screen, case 1 (which
  # wants everything OFF) therefore reported PASS without having seen the module at all.
  # Each title is read on whichever screen it appears on; the first definite answer sticks.
  for (( i=1; i<=8; i++ )); do
    if ui_dump; then
      read_any=1
      [ -n "$z" ] || z="$(ui_checked --near-text "$MOD_ZNEXT"  res=module_indicator)"
      [ -n "$l" ] || l="$(ui_checked --near-text "$MOD_LSPOSED" res=module_indicator)"
      { [ -n "$z" ] && [ -n "$l" ]; } && break
    fi
    swipr 0.5 0.75 0.5 0.30 350; nap "$NAP_SCROLL"
  done
  [ "$read_any" = 1 ] || { echo "  !! Modules screen unreadable (no usable UI snapshot)" >&2; return 1; }

  [ "$z" = true ]  && ZN=ON
  [ "$z" = false ] && ZN=OFF
  [ "$l" = true ]  && LP=ON
  [ "$l" = false ] && LP=OFF
  # Both states must be definite. UNKNOWN cannot be folded into MOD, because "not known to
  # be ON" is not the same as OFF, and every target state here is defined over both modules.
  if [ "$ZN" = UNKNOWN ] || [ "$LP" = UNKNOWN ]; then
    [ "$ZN" = UNKNOWN ] && echo "  !! '$MOD_ZNEXT' not found on the Modules list — set MOD_ZNEXT to its exact title" >&2
    [ "$LP" = UNKNOWN ] && echo "  !! '$MOD_LSPOSED' not found on the Modules list — set MOD_LSPOSED to its exact title" >&2
    return 1
  fi
  MOD=OFF; { [ "$ZN" = ON ] || [ "$LP" = ON ]; } && MOD=ON
  return 0
}
tap_module() {   # toggle a module's switch by its title ($1)
  ui_tap_when --near-text "$1" res=module_indicator
}

# open the LSPosed manager via the module's "Action" button (used by case 3)
lsposed_action() {
  open_magisk_modules
  echo "tapping LSPosed 'Action' ..."
  ui_tap_when --near-text "$MOD_LSPOSED" res=module_config; nap_long "$NAP_LSPOSED"
}

# --- set + verify Enforce/DenyList via the UI (one Settings session) ----------
# _ui_toggle_state <anchor-label> <resource-id> -> ON | OFF | UNKNOWN
# UNKNOWN covers both "no usable snapshot" and "that row is not on screen". Keeping it
# distinct from OFF matters: the old inline `[ "$(ui_checked ...)" = true ] && x=ON` read
# an unreadable screen as OFF, which is a real answer for half the target states.
_ui_toggle_state() {
  ui_dump || { printf 'UNKNOWN'; return 0; }
  case "$(ui_checked --near-text "$1" res="$2")" in
    true)  printf 'ON' ;;
    false) printf 'OFF' ;;
    *)     printf 'UNKNOWN' ;;
  esac
}

# set_denylist_state <want_enf> <want_dl> <pkg> <search>
# Opens Settings once; for each control reads its state from the UI, taps only if it
# differs from wanted, then reads it back in place to confirm. Mismatch -> VERIFY_RC=1.
set_denylist_state() {
  local wenf="$1" wdl="$2" pkg="$3" search="$4"
  echo "Enforce/DenyList (set + verify via UI):"
  open_magisk_settings

  # Enforce DenyList toggle — read, toggle if wrong, read back.
  local uenf; uenf="$(_ui_toggle_state 'Enforce DenyList' selector_indicator)"
  if [ "$uenf" != "$wenf" ]; then
    echo "  Enforce DenyList $uenf -> $wenf"
    ui_tap_when --near-text "Enforce DenyList" res=selector_indicator; nap "$NAP_MED"
    uenf="$(_ui_toggle_state 'Enforce DenyList' selector_indicator)"
  fi
  echo "  enforce: $uenf (want $wenf)"
  if [ "$uenf" = "$wenf" ]; then echo "  enforce PASS"; else echo "  enforce FAIL" >&2; VERIFY_RC=1; fi

  # Target's denylist checkbox — Configure DenyList, search, read, toggle if wrong, read back.
  #
  # These two taps are REQUIRED, not best-effort. ui_tap_when returns 0 even when the
  # element never appeared, so a miss here used to fall through to `inp text "$search"`
  # and type the target package id into whatever happened to hold focus — some other
  # app's search box or message field. The verdict still came out FAIL, but the name had
  # already been typed somewhere it did not belong.
  if ! ui_tap_req textequals="Configure DenyList"; then
    echo "  denylist FAIL — 'Configure DenyList' never appeared; target name not typed" >&2
    VERIFY_RC=1; back; nap 0.5; return 0
  fi
  nap "$NAP_NAV"
  if ! { ui_tap_req clickable=true desccontains=Search || ui_tap_req res=search_button; }; then
    echo "  denylist FAIL — DenyList search box not found; target name not typed" >&2
    VERIFY_RC=1; back; nap 0.5; return 0
  fi
  nap "$NAP_SHORT"
  inp text "$search"; nap "$NAP_NAV"
  local uchk; uchk="$(_ui_toggle_state "$pkg" hide_expand_icon)"
  if [ "$uchk" != "$wdl" ]; then
    echo "  target '$pkg' $uchk -> $wdl"
    ui_tap_when textequals="$pkg"; nap "$NAP_SHORT"                            # tap the target package row first
    ui_tap_when --near-text "$pkg" res=hide_expand_icon; nap "$NAP_SHORT"      # then toggle its checkbox
    uchk="$(_ui_toggle_state "$pkg" hide_expand_icon)"
  fi
  echo "  denylist checkbox: $uchk (want $wdl)"
  if [ "$uchk" = "$wdl" ]; then echo "  denylist PASS"; else echo "  denylist FAIL" >&2; VERIFY_RC=1; fi
  back; nap 0.5
}

# --- modules UI verification --------------------------------------------------
# verify_modules <want_mod> <reread> : reread=1 re-opens Modules and reads the switches;
# reread=0 reuses apply_state's initial read. Mismatch -> VERIFY_RC=1.
verify_modules() {
  local wmod="$1" reread="$2"
  echo "Modules (verify via UI):"
  if [ "$reread" = 1 ]; then
    open_magisk_modules
    read_modules || { echo "  modules FAIL — state could not be read" >&2; VERIFY_RC=1; return 0; }
  else echo "  unchanged — reusing the initial UI read"; fi
  echo "  modules: ZN=$ZN LP=$LP (want $wmod)"
  if [ "$MOD" = "$wmod" ]; then echo "  modules PASS"; else echo "  modules FAIL" >&2; VERIFY_RC=1; fi
}

# --- the state engine ---------------------------------------------------------
# apply_state <want_mod> <want_enf> <want_dl> <pkg> <search>   (values are ON/OFF)
#   * changes only what differs   * reboots iff a module toggled
#   * when turning modules OFF->ON, sets Enforce/DenyList AFTER the reboot (Zygisk live)
#   * verifies each rule via the UI at the point it's touched; folds into VERIFY_RC
apply_state() {
  local wmod="$1" wenf="$2" wdl="$3" pkg="$4" search="$5"
  VERIFY_RC=0

  open_magisk_modules
  # Without a trustworthy starting state there is nothing to diff against, and guessing
  # would mean toggling modules based on a blank screen. Stop and let the verdict be FAIL.
  if ! read_modules; then
    echo "!! cannot read the current module state — refusing to change it blind." >&2
    VERIFY_RC=1
    return 0
  fi
  local cenf=OFF; if [ "$(dl_enforced)" = "1" ]; then cenf=ON; fi
  local cdl=OFF;  if dl_in_list "$pkg"; then cdl=ON; fi
  echo "current: modules=$MOD (ZN=$ZN LP=$LP)  enforce=$cenf  denylist=$cdl"
  echo "target : modules=$wmod  enforce=$wenf  denylist=$wdl"

  local modchg=0; if [ "$MOD" != "$wmod" ]; then modchg=1; fi

  if [ "$modchg" = 1 ]; then
    echo "modules $MOD -> $wmod"
    if [ "$wmod" = ON ]; then
      [ "$ZN" = OFF ] && { tap_module "$MOD_ZNEXT";   nap "$NAP_NAV"; }
      [ "$LP" = OFF ] && { tap_module "$MOD_LSPOSED"; nap "$NAP_NAV"; }
    else
      [ "$ZN" = ON ]  && { tap_module "$MOD_ZNEXT";   nap "$NAP_NAV"; }
      [ "$LP" = ON ]  && { tap_module "$MOD_LSPOSED"; nap "$NAP_NAV"; }
    fi
  fi

  local defer=0
  if [ "$wmod" = ON ] && [ "$MOD" = OFF ]; then defer=1; fi
  if [ "$defer" = 0 ]; then set_denylist_state "$wenf" "$wdl" "$pkg" "$search"; fi

  if [ "$modchg" = 1 ]; then do_reboot; fi

  if [ "$defer" = 1 ]; then set_denylist_state "$wenf" "$wdl" "$pkg" "$search"; fi

  verify_modules "$wmod" "$modchg"
}

# open_target : go home, then launch the target app (final step of every case)
open_target() {
  home
  if [ -n "${TARGET_PKG:-}" ]; then echo "opening target app: $TARGET_PKG"; launch "$TARGET_PKG"; fi
}

# VERIFY_RC starts at 1 (FAIL) so a case that never verified cannot report a false PASS.
# A plain assignment, deliberately: `${VERIFY_RC:-1}` let the environment seed the verdict,
# and VERIFY_RC=0 in the caller's shell would have printed PASS without checking anything.
VERIFY_RC=1
verdict_exit() {
  echo
  if [ "${VERIFY_RC:-1}" = 0 ]; then
    echo "VERDICT: PASS — all rules match target (verified via UI)"
    exit 0
  fi
  echo "VERDICT: FAIL — UI state does not match target (see the FAIL lines above)" >&2
  exit 1
}
