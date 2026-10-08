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

# Magisk module titles as shown on the Modules screen (override per device/version).
MOD_LSPOSED="${MOD_LSPOSED:-Zygisk - LSPosed}"
MOD_ZNEXT="${MOD_ZNEXT:-Zygisk Next}"

# --- tunable delays (seconds) -------------------------------------------------
DELAY_SCALE=${DELAY_SCALE:-1}            # global multiplier for every nap
NAP_MIN=${NAP_MIN:-0.3}                  # floor: no settle is ever shorter than this
NAP_MAX=${NAP_MAX:-}                     # OPTIONAL cap per settle (empty = none). See nap().
NAP_SHORT=${NAP_SHORT:-0.8}             # after a tap / minor settle
NAP_MED=${NAP_MED:-1.2}                 # after typing / a toggle / a dialog
NAP_NAV=${NAP_NAV:-1.5}                 # after a screen or navigation change
NAP_SCROLL=${NAP_SCROLL:-0.6}           # after a scroll swipe
NAP_LSPOSED=${NAP_LSPOSED:-3}           # wait for the LSPosed manager to open
OPEN_SETTLE=${OPEN_SETTLE:-3}           # open_magisk_home: boot_id stability watch
SETTLE_NEED=${SETTLE_NEED:-20}          # reboot_wait: stable seconds required
SETTLE_MAX=${SETTLE_MAX:-200}           # wait_until_stable: overall cap
BOOT_POLL=${BOOT_POLL:-2}               # boot/stability poll interval
TAP_RETRIES=${TAP_RETRIES:-10}          # ui_tap_when attempts
MAGISK_FG_TRIES=${MAGISK_FG_TRIES:-40}  # wait_magisk_fg attempts (x0.5s)
MAGISK_WATCH_ALWAYS=${MAGISK_WATCH_ALWAYS:-0}   # 1 = run the full settle watch on EVERY Magisk open
MAGISK_WATCH_ARMED=0                            # runtime: set by reboot_wait, cleared after a clean open
# clamp the integer knobs to safe minimums so a too-low value can't break the flow
[ "$OPEN_SETTLE"     -lt 2  ] 2>/dev/null && OPEN_SETTLE=2
[ "$SETTLE_NEED"     -lt 6  ] 2>/dev/null && SETTLE_NEED=6
[ "$BOOT_POLL"       -lt 1  ] 2>/dev/null && BOOT_POLL=1
[ "$TAP_RETRIES"     -lt 3  ] 2>/dev/null && TAP_RETRIES=3
[ "$MAGISK_FG_TRIES" -lt 10 ] 2>/dev/null && MAGISK_FG_TRIES=10

# nap <seconds> : the standard UI settle — max(NAP_MIN, <seconds>*DELAY_SCALE).
# NAP_MAX can cap it, but it is OFF by default and should stay off for the Magisk
# cases: a settle that is too short makes the NEXT ui_dump snapshot the PREVIOUS
# screen, and the state readers (ui_checked/read_modules) then decide on stale data.
# Retrying a tap cannot detect that, so speed here comes from DELAY_SCALE, knowingly.
nap() {
  local s
  s=$(awk "BEGIN{v=$1*$DELAY_SCALE; lo=$NAP_MIN; if(v<lo)v=lo
                 hi=\"$NAP_MAX\"+0; if(hi>0 && v>hi)v=hi; printf \"%.3f\", v}")
  sleep "$s"
}
# nap_long <seconds> : for waits that are NOT a UI settle and must not be capped —
# a reboot handshake, keyguard coming back, another app's manager starting up.
nap_long() {
  local s; s=$(awk "BEGIN{v=$1*$DELAY_SCALE; lo=$NAP_MIN; if(v<lo)v=lo; printf \"%.3f\", v}")
  sleep "$s"
}

adbx() { command adb -s "$DEV_SERIAL" "$@"; }

detect_size() {
  local out sz
  out=$(adbx shell wm size)
  sz=$(echo "$out" | awk -F': ' '/Override/{o=$2} /Physical/{p=$2} END{print (o?o:p)}' | tr -d '\r')
  W=${sz%x*}; H=${sz#*x}
  : "${W:?could not detect screen width}" "${H:?could not detect screen height}"
}
px() { awk "BEGIN{printf \"%d\", $1*$W}"; }
py() { awk "BEGIN{printf \"%d\", $1*$H}"; }

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
# route it through su; on a non-rooted one (device2) plain `input` works. One probe, one
# implementation — `inpx` is the real one, `inp` is the long-standing alias cases 1-4 call.
HAS_SU=0
if adbx shell 'su -c id' >/dev/null 2>&1; then HAS_SU=1; fi
inpx() { if [ "$HAS_SU" = 1 ]; then adbx shell "su -c 'input $*'"; else adbx shell input "$@"; fi; }
inp()  { inpx "$@"; }
wake() { inpx keyevent 224 >/dev/null 2>&1 || true; }
swipr() { inp swipe "$(px "$1")" "$(py "$2")" "$(px "$3")" "$(py "$4")" "${5:-300}"; }
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
           "$(cd "$LIB/../.." 2>/dev/null && pwd)/fridaenv/bin/python" \
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

ui_dump() {                      # snapshot the current screen into $UI_XML (overwritten each call)
  [ "$U2_READY" = 1 ] || u2_start || true
  if [ "$U2_READY" = 1 ]; then
    printf 'dump %s\n' "$UI_XML" >&7 2>/dev/null
    local resp=""; IFS= read -t 25 -r resp <&8 2>/dev/null || resp=""
    [ "$resp" = "OK" ] && return 0
    u2_stop                      # u2 hiccuped -> fall through to the legacy dump
  fi
  adbx exec-out "uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; cat /sdcard/ui.xml" 2>/dev/null | tr -d '\r' > "$UI_XML"
}

trap 'u2_stop; rm -f "$UI_XML"' EXIT      # stop the driver + remove the temp on exit
ui_find() { python3 "$LIB/py/uifind.py" "$UI_XML" "$@"; }            # echoes per --print; rc1 if none
ui_checked() { ui_find --print checked "$@" 2>/dev/null || true; } # "true"/"false"/"" (not found)
# ui_tap taps against the caller's existing snapshot and never re-dumps: callers read
# state from that same snapshot, so silently replacing it underneath them is unsafe.
ui_tap() { local xy; xy="$(ui_find "$@" 2>/dev/null || true)"; [ -n "$xy" ] || return 1; inp tap $xy; }
# ui_tap_when: re-dump until the element appears (slow screens, esp. just after boot), then tap it.
ui_tap_when() {
  local i
  for (( i=1; i<=TAP_RETRIES; i++ )); do
    ui_dump
    if ui_find "$@" >/dev/null 2>&1; then ui_tap "$@"; return 0; fi
    nap "$NAP_SHORT"
  done
  echo "  WARN: element not found after retries: $*" >&2; return 0   # best-effort; verify step reports the result
}

# --- reboot & unlock ----------------------------------------------------------
enter_pin() {   # type a numeric PIN via keyevents (KEYCODE_0=7 .. KEYCODE_9=16)
  local codes="" i d
  for (( i=0; i<${#1}; i++ )); do d="${1:$i:1}"; codes="$codes $((7 + d))"; done
  inp keyevent $codes
}
unlock() {      # wake, reveal keyguard, enter $PIN (empty = no PIN)
  inp keyevent 224; nap 0.8                 # WAKEUP
  swipr 0.5 0.80 0.5 0.25 200; nap 1.0      # reveal the PIN pad
  if [ -n "${PIN:-}" ]; then enter_pin "$PIN"; nap 0.4; inp keyevent 66; nap "$NAP_MED"; fi
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
    ui_dump
    ui_find textequals="Enforce DenyList" >/dev/null 2>&1 && return 0
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

# read_modules : set globals ZN, LP (ON/OFF) and MOD (ON if either). Modules screen must be open.
read_modules() {
  ui_dump
  local z l
  z="$(ui_checked --near-text "$MOD_ZNEXT"  res=module_indicator)"
  l="$(ui_checked --near-text "$MOD_LSPOSED" res=module_indicator)"
  ZN=OFF; [ "$z" = "true" ] && ZN=ON
  LP=OFF; [ "$l" = "true" ] && LP=ON
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
# set_denylist_state <want_enf> <want_dl> <pkg> <search>
# Opens Settings once; for each control reads its state from the UI, taps only if it
# differs from wanted, then reads it back in place to confirm. Mismatch -> VERIFY_RC=1.
set_denylist_state() {
  local wenf="$1" wdl="$2" pkg="$3" search="$4"
  echo "Enforce/DenyList (set + verify via UI):"
  open_magisk_settings

  # Enforce DenyList toggle — read, toggle if wrong, read back.
  ui_dump
  local uenf=OFF; [ "$(ui_checked --near-text 'Enforce DenyList' res=selector_indicator)" = true ] && uenf=ON
  if [ "$uenf" != "$wenf" ]; then
    echo "  Enforce DenyList $uenf -> $wenf"
    ui_tap_when --near-text "Enforce DenyList" res=selector_indicator; nap "$NAP_MED"
    ui_dump; uenf=OFF; [ "$(ui_checked --near-text 'Enforce DenyList' res=selector_indicator)" = true ] && uenf=ON
  fi
  echo "  enforce: $uenf (want $wenf)"
  if [ "$uenf" = "$wenf" ]; then echo "  enforce PASS"; else echo "  enforce FAIL" >&2; VERIFY_RC=1; fi

  # Target's denylist checkbox — Configure DenyList, search, read, toggle if wrong, read back.
  ui_tap_when textequals="Configure DenyList"; nap "$NAP_NAV"
  ui_tap_when clickable=true desccontains=Search || ui_tap_when res=search_button; nap "$NAP_SHORT"
  inp text "$search"; nap "$NAP_NAV"
  ui_dump
  local uchk=OFF; [ "$(ui_checked --near-text "$pkg" res=hide_expand_icon)" = true ] && uchk=ON
  if [ "$uchk" != "$wdl" ]; then
    echo "  target '$pkg' $uchk -> $wdl"
    ui_tap_when textequals="$pkg"; nap "$NAP_SHORT"                            # tap the target package row first
    ui_tap_when --near-text "$pkg" res=hide_expand_icon; nap "$NAP_SHORT"      # then toggle its checkbox
    ui_dump; uchk=OFF; [ "$(ui_checked --near-text "$pkg" res=hide_expand_icon)" = true ] && uchk=ON
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
  if [ "$reread" = 1 ]; then open_magisk_modules; read_modules
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

  open_magisk_modules; read_modules
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

# VERIFY_RC defaults to 1 (FAIL) so a case that never verified cannot report a false PASS.
VERIFY_RC=${VERIFY_RC:-1}
verdict_exit() {
  echo
  if [ "${VERIFY_RC:-1}" = 0 ]; then
    echo "VERDICT: PASS — all rules match target (verified via UI)"
    exit 0
  fi
  echo "VERDICT: FAIL — UI state does not match target (see the FAIL lines above)" >&2
  exit 1
}
