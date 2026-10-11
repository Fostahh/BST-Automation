#!/usr/bin/env bash
# NAME: Case 4 — Frida Function Hooking
# Bring up a version-matched frida-server on the device, then run a hook script
# from fridaenv/Hooking against the target package — as many passes as you like:
# after each detach it offers to replay the same hook without restarting the server.
#   Uses DEV_SERIAL + TARGET_PKG exported by run-scenarios.sh.
#   env: USE_VENV=1|0   SERVER_DIR=<dir>   MODE=spawn|attach
#        UI_EXEC=1|0    1 = start the server by hand via MT Manager's Script executor
#                       0 = start it headless over adb (setsid)
#        OPEN_MT=1|0    launch MT Manager as a visual aid in the headless path
#        FORCE_SERVER=0 reuse a server that is already answering instead of restarting
#                       it. Default is 1: stop whatever holds the port, then relaunch.
#        MT_PKG=<pkg>   MT Manager package (default bin.mt.plus, via lib/mtmanager.sh)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"                      # adbx(), inp(), launch(), focus_now(), swipr(), detect_size()
source "$HERE/../lib/mtmanager.sh"                   # mt_jump_to() — was duplicated here
# FRIDAENV and BST_ROOT come from lib/base.sh via common.sh.
HOOK_DIR="${HOOK_DIR:-}"                             # set HOOK_DIR to your own folder of .js hooks

# --- where are the hooks? -----------------------------------------------------
# $HERE is useless for this in the bundle: it points at the throwaway copy under
# $TMPDIR, not at the folder bst-tools.sh was run from. So search the launch
# directory (the bundle exports BST_LAUNCH_DIR; a repo run falls back to $PWD).
hook_id() {   # device:inode — "hooks" and "Hooks" are the same folder on a
              # case-insensitive volume, and symlinked copies collapse too
  stat -f '%d:%i' "$1" 2>/dev/null || stat -c '%d:%i' "$1" 2>/dev/null || printf '%s' "$1"
}
hook_scan() { # directories holding .js files, no more than two levels below $base
  local base="$1" depth=3
  # Depth is the whole filter, which is why there is no list of names to skip. Hooks sit
  # a level or two from the script — BST-Tools/Hooking, or BST-Tools/pythonvenv/Hooking —
  # whereas the .js a python venv carries of its own is always deeper: android-unpinner
  # bundles scripts 4 levels in, site-packages 5. Naming '*venv*' as a prune was both
  # unnecessary and actively wrong, since it skipped the folder being searched for.
  [ "$base" = "$HOME" ] && depth=2        # $HOME/Library alone would take minutes
  find -L "$base" -mindepth 1 -maxdepth "$depth" \
       \( -name '.*' -o -name 'node_modules' \) -prune -o \
       -type f -name '*.js' -print 2>/dev/null \
    | sed 's#/[^/]*$##' | awk '!seen[$0]++' \
    | awk '{ n=$0; sub(/.*\//,"",n)            # rank on the folder name, not the whole
             r = (tolower(n) ~ /hook|unpin|frida|script/) ? 0 : 1; print r"\t"$0 }' \
    | sort -s -k1,1n | cut -f2-
}

if [ -z "$HOOK_DIR" ] && ls "$FRIDAENV/Hooking"/*.js >/dev/null 2>&1; then
  HOOK_DIR="$FRIDAENV/Hooking"                       # author's own layout wins, unchanged
fi
if [ -z "$HOOK_DIR" ]; then
  HOOK_BASE="${BST_LAUNCH_DIR:-$PWD}"
  HOOK_CANDS=(); hook_seen=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    hid="$(hook_id "$d")"
    case " $hook_seen " in *" $hid "*) continue;; esac
    hook_seen="$hook_seen $hid"
    HOOK_CANDS+=("$d")
    if [ "${#HOOK_CANDS[@]}" -ge 10 ]; then break; fi
  done <<EOF
$(hook_scan "$HOOK_BASE")
EOF
  case "${#HOOK_CANDS[@]}" in
    0) : ;;                                          # nothing found — the prompt below asks
    1) HOOK_DIR="${HOOK_CANDS[0]}"
       echo "   hooks folder auto-detected: $HOOK_DIR  (set HOOK_DIR to override)"
       ;;
    *) echo "   folders with .js hooks under $HOOK_BASE:"
       for ((n=0; n<${#HOOK_CANDS[@]}; n++)); do
         printf '     %d) %s  (%s .js)\n' "$((n+1))" "${HOOK_CANDS[$n]}" \
           "$(ls "${HOOK_CANDS[$n]}"/*.js 2>/dev/null | grep -c . || true)"
       done
       read -rp "   hooks folder number (blank = type a path instead): " hsel || hsel=""
       if hidx="$(pick_index "${#HOOK_CANDS[@]}" "$hsel")"; then
         HOOK_DIR="${HOOK_CANDS[$((hidx-1))]}"      # the menu is 1-based, this array 0-based
       fi
       ;;
  esac
fi

# Ask for the hooks folder up front if detection came up empty. Doing it here (rather
# than at the hook prompt) means a wrong path can't strand a half-started frida-server.
# Set HOOK_DIR in the environment to skip the question entirely.
while ! ls "$HOOK_DIR"/*.js >/dev/null 2>&1; do
  [ -n "$HOOK_DIR" ] && echo "   no .js hooks in: $HOOK_DIR" >&2
  read -rp "frida hooks folder (the one holding your .js files): " HOOK_DIR \
    || { echo "!! a hooks folder is required for case 4." >&2; exit 1; }
  HOOK_DIR="${HOOK_DIR%\"}"; HOOK_DIR="${HOOK_DIR#\"}"      # tolerate drag-and-drop quoting
  HOOK_DIR="${HOOK_DIR%\'}"; HOOK_DIR="${HOOK_DIR#\'}"
  case "$HOOK_DIR" in "~"*) HOOK_DIR="$HOME${HOOK_DIR#\~}";; esac   # read does not expand ~
done
SERVER_DIR="${SERVER_DIR:-/data/local/tmp}"          # MT Manager shows this as "tmp" (no spaces)
FRIDA_PORT="${FRIDA_PORT:-27042}"   # frida's default; the stale-server checks key off it

# --- UI automation helpers (tap by on-screen text/id, not fixed coordinates) --
# ui_dump/$UI_XML/ui_find/ui_tap_fresh all come from common.sh. This file used to carry
# its own dump-then-tap under the name ui_tap, shadowing common.sh's snapshot-only one;
# that behaviour is ui_tap_fresh now. ui_tap_scroll stays local — swiping a specific
# column is an MT Manager two-pane concern no other case has.
ui_tap_scroll() {                                    # ui_tap_scroll <tries> [--sx <xratio>] <matchers...>
  local tries="$1"; shift
  local sx=0.5                                        # default: swipe down the middle
  [ "${1:-}" = "--sx" ] && { sx="$2"; shift 2; }      # or down a specific column (MT Manager panes)
  local i xy
  for ((i=1;i<=tries;i++)); do
    if ui_dump && xy="$(ui_find "$@")"; then inp tap $xy; return 0; fi
    swipr "$sx" 0.80 "$sx" 0.33 250; nap 0.6        # scroll the list down one page-ish
  done
  return 1
}

# MT Manager is a 2-pane file browser; /data/local/tmp opens in whichever pane was
# focused. Swiping the middle scrolls nothing, so find the pane showing SERVER_DIR
# (by the x of its path bar) and return the x-ratio to swipe on (left ~0.25 / right ~0.75).
pane_scroll_x() {
  ui_dump || { echo 0.75; return 0; }                 # unreadable: assume the right pane
  local xy cx
  local top; top="$(py 0.13)"                         # the path-bar strip, not a pixel count
  xy="$(ui_find textcontains="$SERVER_DIR" maxy="$top" 2>/dev/null || true)"
  [ -z "$xy" ] && xy="$(ui_find textcontains=data/local/tmp maxy="$top" 2>/dev/null || true)"
  cx="${xy%% *}"
  if [ -n "$cx" ] && [ "$cx" -lt "$(( ${W:-1080} / 2 ))" ]; then echo 0.25; else echo 0.75; fi
}

# --- 1) Python environment ----------------------------------------------------
choose_python_env() {
  local ans="${USE_VENV:-}"
  if [ -z "$ans" ]; then
    # Only meaningful where a fridaenv venv exists; elsewhere frida comes from PATH.
    if [ -f "$FRIDAENV/bin/activate" ]; then
      read -rp "1) Are you using the Python virtual env (fridaenv)? [Y/n]: " ans
    else
      ans=n
    fi
  fi
  case "$ans" in
    n|N|0)
      echo "   not using venv — detecting python & frida on PATH ..."
      command -v python3 >/dev/null || { echo "   python3 not found" >&2; exit 1; }
      command -v frida   >/dev/null || { echo "   frida not on PATH — install it or use the venv" >&2; exit 1; }
      echo "   python3: $(command -v python3)  ($(python3 --version 2>&1))"
      echo "   frida:   $(command -v frida)"
      ;;
    *)
      [ -f "$FRIDAENV/bin/activate" ] || { echo "   venv activate not found: $FRIDAENV/bin/activate" >&2; exit 1; }
      # shellcheck disable=SC1091
      source "$FRIDAENV/bin/activate"
      command -v frida >/dev/null || { echo "   frida missing inside venv" >&2; exit 1; }
      echo "   venv active: ${VIRTUAL_ENV:-$FRIDAENV}"
      ;;
  esac
}

# --- MT Manager (UI must be shown on the device) ------------------------------
open_mt_manager() {
  if [ -z "$(adbx shell pm path --user current "$MT_PKG" 2>/dev/null | tr -d '\r')" ]; then
    echo "   (MT Manager '$MT_PKG' not installed — skipping)"
    return 1
  fi
  inp keyevent 224 >/dev/null 2>&1 || true           # WAKEUP: turn the screen on
  nap 0.5
  launch "$MT_PKG"                                    # bring the file manager to the foreground
  local n=0
  until focus_now | grep -q "$MT_PKG"; do
    sleep 0.5; n=$((n+1))
    [ "$n" -gt 16 ] && { echo "   WARN: MT Manager may not be foreground (check the device)" >&2; break; }
  done
  echo "   MT Manager is up on the device."
  nap 1
}

# --- 3+4) frida version, matched server, launch ------------------------------
server_pid() {   # PID of the process whose cmdline contains "$1" (empty if none)
  # Read the process table and filter here rather than using `pgrep -f`: pgrep matches
  # the very shell running it (bogus pid), and the usual "[f]rida-server" bracket dodge
  # is taken literally by some toybox builds, which then matches nothing at all.
  adbx shell "su -c 'ps -A -o PID,ARGS 2>/dev/null || ps -A'" 2>/dev/null | tr -d '\r' \
    | grep -F "$1" | grep -v -e pgrep -e pkill -e ' ps ' | awk '{print $1}' | head -1 || true
}

port_pid() {     # PID holding local TCP port $1 (empty if nothing/unknown)
  # A server under a different filename still owns 27042, so the port is the only
  # name-independent evidence. netstat prints "pid/name", ss prints "pid=NNN".
  adbx shell "su -c 'netstat -anp 2>/dev/null; ss -lptnH 2>/dev/null'" 2>/dev/null \
    | tr -d '\r' | grep -F ":$1" \
    | sed -n -e 's#.*[[:space:]]\([0-9]\{1,\}\)/[^[:space:]]*.*#\1#p' \
             -e 's#.*pid=\([0-9]\{1,\}\).*#\1#p' | head -1 || true
}

stop_frida() {   # clear every frida-server on the device, whatever it is called
  adbx shell "su -c 'pkill -9 -f \"[f]rida-server\"'" >/dev/null 2>&1 || true
  local p
  for p in "$(server_pid frida-server)" "$(port_pid "$FRIDA_PORT")"; do
    # Only ever interpolate something that is unambiguously a pid.
    case "$p" in ''|*[!0-9]*) continue;; esac
    su_sh "kill -9 $p" >/dev/null 2>&1 || true
  done
  nap 1
}

terminal_up() {  # true once the executor terminal (or Termux) is on screen
  case "$(focus_now)" in *com.termux*) return 0;; esac
  ui_dump || return 1
  ui_find textequals=Esc >/dev/null 2>&1 || ui_find textequals=Ctrl >/dev/null 2>&1
}

terminal_error() {   # best-effort: scrape error-looking text off the console (may be empty)
  # Raw-XML scrape on purpose: it greps English keywords across every node, so entity
  # encoding cannot change the outcome, and a failed dump must not break diagnostics.
  ui_dump || return 0
  grep -oE 'text="[^"]*"' "$UI_XML" | sed 's/^text="//;s/"$//' \
    | grep -iE 'error|unable|failed|denied|not executable|cannot execute|no such|already in use|bind|refused|segmentation|abort|fatal' \
    || true
}

ui_launch_server() {   # drive MT Manager: tmp folder -> server -> Script executor -> EXECUTE
  open_mt_manager || { echo "   cannot run the UI launch without MT Manager." >&2; return 1; }
  echo "   navigating to $SERVER_DIR ..."
  mt_jump_to "$SERVER_DIR" || return 1
  local sx; sx="$(pane_scroll_x)"                     # scroll the pane that actually holds the folder
  echo "   scrolling (pane x=$sx) to $SERVER and tapping it ..."
  ui_tap_scroll 14 --sx "$sx" textequals="$SERVER" || { echo "   could not find $SERVER in the list" >&2; return 1; }
  nap 1
  echo "   choosing 'Script executor' ..."
  ui_tap_scroll 6 textequals="Script executor" || { echo "   'Script executor' option not found" >&2; return 1; }
  nap 1.2
  echo "   tapping EXECUTE (runs with root) ..."
  ui_tap_fresh textequals=EXECUTE || { echo "   EXECUTE button not found" >&2; return 1; }
  # wait for the terminal console to appear
  local n=0
  until terminal_up; do
    sleep 1; n=$((n+1)); [ "$n" -gt 15 ] && { echo "   WARN: terminal not detected on screen" >&2; break; }
  done
  echo "   terminal console is up."
}

bring_up_server() {
  echo
  echo "3) frida version on this macOS: $FRIDA_VER"

  # map the device ABI to the arch token used in server filenames
  local abi arch listing
  abi=$(adbx shell getprop ro.product.cpu.abi | tr -d '\r')
  case "$abi" in
    arm64*)        arch=arm64;;
    armeabi*|arm*) arch=arm;;
    x86_64)        arch=x86_64;;
    x86)           arch=x86;;
    *)             arch="$abi";;
  esac

  # Pick the server whose filename carries the exact macOS version (prefer the arch match).
  # Guard every one of these: grep exits 1 when nothing matches, `set -o pipefail` turns
  # that into a failed assignment, and `set -e` then kills the scenario with NO message —
  # the symptom is the script stopping right after step 3 on a device that has no server.
  # List WITHOUT su: /data/local/tmp belongs to the shell user, and on a KernelSU device
  # the su domain (u:r:ksu:s0) is denied read on shell_data_file under enforcing SELinux —
  # `su -c ls` answers "Permission denied" while the plain shell listing works fine.
  # Only fall back to su for a custom SERVER_DIR that the shell user cannot read.
  listing=$(adbx shell "ls $(shq "$SERVER_DIR")" 2>/dev/null | tr -d '\r' | grep -i 'frida-server' || true)
  [ -n "$listing" ] || listing=$(su_sh "ls $(shq "$SERVER_DIR")" 2>/dev/null | tr -d '\r' | grep -i 'frida-server' || true)
  SERVER=$(printf '%s\n' "$listing" | grep -F "$FRIDA_VER" | grep -i "$arch" | head -n1 || true)
  [ -n "$SERVER" ] || SERVER=$(printf '%s\n' "$listing" | grep -F "$FRIDA_VER" | head -n1 || true)
  if [ -z "$SERVER" ]; then
    echo "!! no frida-server matching $FRIDA_VER ($arch) in $SERVER_DIR on $DEV_NAME." >&2
    if ! has_su; then
      echo "   this device has no working su — case 4 needs root (Magisk)." >&2
    elif [ -z "$listing" ]; then
      local want="frida-server-$FRIDA_VER-android-$arch"
      echo "   $SERVER_DIR holds no frida-server* file at all. Push the matching one:" >&2
      echo "     # from https://github.com/frida/frida/releases/tag/$FRIDA_VER  ($want.xz)" >&2
      echo "     adb -s $DEV_SERIAL push $want $SERVER_DIR/" >&2
      echo "     adb -s $DEV_SERIAL shell \"su -c 'chmod 755 $SERVER_DIR/$want'\"" >&2
    else
      echo "   present there, but none carry $FRIDA_VER:" >&2
      printf '%s\n' "$listing" | sed 's/^/     /' >&2
      echo "   either push a $FRIDA_VER server, or match the Mac to one of the above" >&2
      echo "   (pip install frida-tools==<version matching a server above>)." >&2
    fi
    exit 1
  fi
  echo "4) matched device server: $SERVER  (abi=$abi)"

  if [ "${UI_EXEC:-1}" = "1" ]; then
    detect_size                                      # swipr/ratio taps need the screen size
    # A server may already be running: from an earlier run, a boot script, or a root
    # manager that keeps one up. On Magisk the port holder is visible and killable, so the
    # default is to STOP it and launch our own — reusing a server of unknown provenance
    # means the scenario no longer controls what is instrumenting the app.
    #
    # KernelSU is the exception the old default was built around: there the su domain is
    # blind to the process table (ps/lsof/proc all come back empty), so stop_frida cannot
    # kill what it cannot see. That is handled below by falling back to the server that is
    # already answering, rather than ending the case. FORCE_SERVER=0 skips the restart.
    local stale holder
    stale="$(server_pid "$SERVER")"
    [ -n "$stale" ] || stale="$(server_pid frida-server)"
    holder="$(port_pid "$FRIDA_PORT")"
    [ -n "$stale" ] || stale="$holder"

    if [ "${FORCE_SERVER:-1}" = 0 ] && frida-ps -D "$DEV_SERIAL" >/dev/null 2>&1; then
      echo "   FORCE_SERVER=0 — reusing the frida-server already answering on $DEV_SERIAL."
      echo ">> frida-server ready (reused)."
      return 0
    fi

    echo
    echo "   bringing up frida-server on $DEV_SERIAL"
    if [ -n "$stale" ] || frida-ps -D "$DEV_SERIAL" >/dev/null 2>&1; then
      printf '   found a running server: pid %s' "${stale:-unknown}"
      [ -n "$holder" ] && printf ' (holding port %s)' "$FRIDA_PORT"
      printf '\n'
      echo "   stopping it so our own launch binds cleanly ..."
      stop_frida
      if [ -n "$(port_pid "$FRIDA_PORT")" ] || frida-ps -D "$DEV_SERIAL" >/dev/null 2>&1; then
        echo "   !! port $FRIDA_PORT is still held and could not be freed." >&2
        echo "      On KernelSU the process is invisible to su, so it cannot be killed." >&2
        if frida-ps -D "$DEV_SERIAL" >/dev/null 2>&1; then
          echo "      It does answer frida-ps, so continuing with THAT server instead." >&2
          echo "      Reboot first if you need a known-clean one: adb -s $DEV_SERIAL reboot" >&2
          echo ">> frida-server ready (pre-existing; could not be replaced)."
          return 0
        fi
        echo "      It does not answer frida-ps either. Reboot and re-run:" >&2
        echo "        adb -s $DEV_SERIAL reboot" >&2
        exit 1
      fi
      echo "   stopped; port $FRIDA_PORT is free."
    else
      echo "   nothing running; port $FRIDA_PORT is free."
    fi
    echo "   launching $SERVER via MT Manager (runs with root) ..."
    ui_launch_server || { echo "!! could not launch frida-server through MT Manager." >&2; exit 1; }

    # --- make sure it did not error, then confirm the server via CLI ---------
    # The MT terminal renders in a view uiautomator can't read, so the decisive
    # check is the process + host CLI: a server that errored simply isn't there.
    # Poll rather than guess with one sleep: on a slower device the server can take
    # several seconds to bind after EXECUTE.
    local pid="" i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 1
      pid="$(server_pid "$SERVER")"
      [ -n "$pid" ] && break
    done
    if [ -n "$pid" ] && frida-ps -D "$DEV_SERIAL" >/dev/null 2>&1; then
      echo ">> no error. CLI check: targeted server '$SERVER' is RUNNING (pid $pid), reachable via frida-ps."
    else
      echo "!! frida-server errored — it is not running after EXECUTE." >&2
      echo "   what happened (captured by running it once on the device):" >&2
      local diag
      # $SERVER comes from a device directory listing, so it must be quoted: it reaches
      # a root shell, where a crafted filename would otherwise run as a command.
      diag="$(su_sh "timeout 3 $(shq "$SERVER_DIR/$SERVER") 2>&1 | head -5" 2>/dev/null | tr -d '\r' || true)"
      [ -n "$diag" ] && printf '%s\n' "$diag" | sed 's/^/     /' >&2
      local scr; scr="$(terminal_error)"; [ -n "$scr" ] && printf '     %s\n' "$scr" >&2
      case "$diag$scr" in
        *"already in use"*)
          echo "   something else holds frida's port $FRIDA_PORT. Clear it with:"      >&2
          echo "     adb -s $DEV_SERIAL shell \"su -c 'pkill -9 -f frida'\""           >&2
          echo "     adb -s $DEV_SERIAL shell \"su -c 'am force-stop $MT_PKG'\""       >&2
          echo "   then re-run Case 4 (or reboot the device if it comes back)."        >&2
          ;;
      esac
      echo ">> finishing: fix the error above, then re-run Case 4." >&2
      exit 1
    fi
  else
    # headless fallback: optional visual aid + background start over adb
    [ "${OPEN_MT:-1}" = "1" ] && open_mt_manager || true
    if frida-ps -D "$DEV_SERIAL" >/dev/null 2>&1 || [ -n "$(server_pid "$SERVER")" ]; then
      echo "   a frida-server is already running — reusing it."
    else
      su_sh "chmod 755 $(shq "$SERVER_DIR/$SERVER"); setsid $(shq "$SERVER_DIR/$SERVER") >/dev/null 2>&1 &" || true
      nap 2
    fi
    frida-ps -D "$DEV_SERIAL" >/dev/null 2>&1 || { echo "!! frida-server did not come up (frida-ps failed)." >&2; exit 1; }
    echo ">> frida-server ($FRIDA_VER) runs."
  fi
}

# --- 5) pick a hook + run ------------------------------------------------------
pick_hook() {
  echo
  echo "5) Hook scripts in $HOOK_DIR"
  local i=0 sel; HOOKS=()
  for f in "$HOOK_DIR"/*.js; do
    [ -e "$f" ] || continue
    i=$((i+1)); HOOKS[$i]="$f"
    printf "   %d) %s\n" "$i" "$(basename "$f")"
  done
  [ "$i" -gt 0 ] || { echo "   no .js hooks in $HOOK_DIR" >&2; exit 1; }
  read -rp "hook number: " sel || sel=""
  local idx
  idx="$(pick_index "$i" "$sel")" \
    || { echo "invalid hook: ${sel:-<blank>} — choose 1-$i" >&2; exit 1; }
  HOOK="${HOOKS[$idx]}"
}

run_hook() {
  echo
  echo ">> frida ${MODE:-spawn} -> $PKG   hook=$(basename "$HOOK")   (Ctrl-C / Ctrl-D to detach)"
  echo
  # Run in the foreground instead of exec'ing, so we come back here and can offer a
  # re-run. Ctrl-C must land on frida alone: with a trap installed, bash defers the
  # signal until frida has exited rather than taking the whole scenario down with it.
  trap ':' INT
  case "${MODE:-spawn}" in
    attach) frida -D "$DEV_SERIAL" -N "$PKG" -l "$HOOK" || true;;   # attach to a running process by identifier
    *)      frida -D "$DEV_SERIAL" -f "$PKG" -l "$HOOK" || true;;    # spawn so the hook loads before app startup checks
  esac
  trap - INT
}

hook_again() {   # true if the tester wants another pass with the same hook
  local ans
  echo
  read -rp "   hook again with $(basename "$HOOK") on $PKG? [y/N]: " ans || ans=""
  case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

# --- flow ---------------------------------------------------------------------
choose_python_env

# 2) package id — run-scenarios.sh usually supplies it as TARGET_PKG; prompt if blank.
PKG="${TARGET_PKG:-}"
if [ -z "$PKG" ]; then
  read -rp "2) target app package id: " PKG
else
  echo "2) target app package id: $PKG"             # echoed so the step numbering stays sequential
fi
[ -n "$PKG" ] || { echo "package id required for frida hooking" >&2; exit 1; }

FRIDA_VER="$(frida --version)"

bring_up_server
pick_hook

# The u2 agent is only needed for the UI steps above; drop it so the device is quiet
# while the hook runs. The EXIT trap in common.sh cleans up whatever is left.
u2_stop 2>/dev/null || true
rm -f "$UI_XML"

# Re-run the same hook as many times as the tester wants — a RASP check often needs a
# few passes (spawn re-launches the app each time), and restarting the whole case just
# to replay one .js would mean bringing the server up again.
while :; do
  run_hook
  hook_again || break
  if ! frida-ps -D "$DEV_SERIAL" >/dev/null 2>&1; then
    echo "   frida-server is no longer reachable — re-run Case 4 to bring it back up." >&2
    break
  fi
done
echo
echo ">> case 4 finished."
