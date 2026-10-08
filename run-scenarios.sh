#!/usr/bin/env bash
# run-scenarios.sh — pick a device + a scenario, run it, then open a target app.
#   ./run-scenarios.sh                              interactive (prompts for all 3)
#   ./run-scenarios.sh device1 1 com.example.app       device, scenario#, app to open
#   ./run-scenarios.sh device1 1 -                     run scenario, open nothing
# Interactive target selection lists installed third-party packages by number.
#   env: TARGET_PREFIX=<package prefix>  narrow that list; asked at run time if unset
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Was DELAY_SCALE set by the user? Capture it BEFORE sourcing common.sh, which
# defaults it to 1 (otherwise the prompt below would always think it's preset).
DELAY_SCALE_PRESET="${DELAY_SCALE+set}"
source "$HERE/lib/devices.sh"
source "$HERE/lib/preflight.sh"
preflight || exit 1

# --- pick scenario ------------------------------------------------------------
echo
echo "== Scenarios =="
i=0
CASES=()
for f in "$HERE"/cases/*.sh; do
  [ -e "$f" ] || continue
  i=$((i+1)); CASES[$i]="$f"
  name=$(grep -m1 '^# NAME:' "$f" | sed 's/^# NAME:[[:space:]]*//')
  printf "  %d) %s\n" "$i" "${name:-$(basename "$f")}"
done
[ "$i" -gt 0 ] || { echo "no scenarios in cases/" >&2; exit 1; }
echo

SEL="${2:-}"
if [ -z "$SEL" ]; then read -rp "scenario number: " SEL; fi
TARGET="${CASES[$SEL]:-}"
[ -n "$TARGET" ] || { echo "invalid selection: $SEL" >&2; exit 1; }

# --- speed: one multiplier, applied to every scenario -------------------------
# Every settle in every case is now DELAY_SCALE-aware (it was cases 1-3 only before).
# 1 = the timings these flows were tuned with; below ~0.5 the Magisk screens start
# being read before they have finished changing. Skipped if DELAY_SCALE is preset.
if [ -z "$DELAY_SCALE_PRESET" ]; then
  read -rp "UI delay scale — 1=normal, 0.5=faster, 2=slower/flaky device [1]: " DELAY_SCALE || DELAY_SCALE=""
  DELAY_SCALE="${DELAY_SCALE:-1}"
  case "$DELAY_SCALE" in ''|*[!0-9.]*) echo "  '$DELAY_SCALE' is not a number — using 1"; DELAY_SCALE=1;; esac
  export DELAY_SCALE
fi

# Case 8 owns source selection: manual files do not require a connected phone.
if [ "$(basename "$TARGET")" = case8-emulator.sh ]; then
  export SOURCE_DEVICE="${1:-}" TARGET_PKG="${3:-}"   # DELAY_SCALE/NAP_MAX already exported above
  exec bash "$TARGET"
fi

# --- pick source device (cases 1–7) -------------------------------------------
echo "== Connected (adb) =="
adb devices | sed '1d;/^$/d' || true
echo
echo "== Known device profiles =="
for n in $DEVICE_NAMES; do
  printf "  %-8s %s\n" "$n" "$(device_serial "$n" 2>/dev/null || echo "(not configured)")"
done
echo
DEV_NAME="${1:-}"
if [ -z "$DEV_NAME" ]; then read -rp "device profile: " DEV_NAME; fi
DEV_SERIAL="$(device_serial "$DEV_NAME")" || { echo "cannot resolve device profile: $DEV_NAME" >&2; exit 1; }
PIN="$(device_pin "$DEV_NAME")"
export DEV_SERIAL DEV_NAME PIN
source "$HERE/lib/common.sh"
source "$HERE/lib/device-ready.sh"

# --- target app: DenyList-checked during the scenario AND opened after it -----
TARGET_PKG="${3:-}"
if [ -z "$TARGET_PKG" ]; then
  # Ask for the namespace rather than keeping any client's package prefix in the repo.
  # It lives in this process only — nothing is written to disk. Using ${VAR+set} means an
  # exported TARGET_PREFIX (even an empty one) skips the question for non-interactive runs.
  if [ -z "${TARGET_PREFIX+set}" ]; then
    read -rp "target package prefix (blank = list all third-party apps): " TARGET_PREFIX || TARGET_PREFIX=""
    TARGET_PREFIX="${TARGET_PREFIX#"${TARGET_PREFIX%%[![:space:]]*}"}"   # trim both ends
    TARGET_PREFIX="${TARGET_PREFIX%"${TARGET_PREFIX##*[![:space:]]}"}"
    TARGET_PREFIX="${TARGET_PREFIX%\*}"                                  # tolerate "com.example*"
  fi
  export TARGET_PREFIX
  echo "== Installed target apps on $DEV_NAME${TARGET_PREFIX:+ ($TARGET_PREFIX*)} =="
  PACKAGES=()
  package_count=0
  # -3 lists third-party packages only, keeping the system apps out of the menu.
  if package_list="$(adbx shell pm list packages -3 --user current)"; then
    # Normalize Android line endings and keep the numbering stable.
    package_list="$(printf '%s\n' "$package_list" | tr -d '\r' | sed -n 's/^package:\([^[:space:]]*\)$/\1/p' | LC_ALL=C sort -u)"
    # Optional narrowing: set TARGET_PREFIX to the namespace of the app under test.
    if [ -n "${TARGET_PREFIX:-}" ]; then
      package_list="$(printf '%s\n' "$package_list" | grep "^$TARGET_PREFIX" || true)"
    fi
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      package_count=$((package_count + 1))
      PACKAGES[$package_count]="$pkg"
      printf '  %d) %s\n' "$package_count" "$pkg"
    done <<< "$package_list"
    [ "$package_count" -gt 0 ] || echo "  No third-party packages installed${TARGET_PREFIX:+ under '$TARGET_PREFIX'}."
  else
    echo '  WARN: could not list installed packages — enter a package id manually.' >&2
  fi
  echo
  while :; do
    if ! read -rp 'target app number or package id (RASP app under test, blank = none): ' choice; then
      echo 'No target selection received.' >&2
      exit 1
    fi
    case "$choice" in
      ''|-) TARGET_PKG=''; break ;;
      *[!0-9]*) TARGET_PKG="$choice"; break ;;
      *)
        # Compare menu labels as strings: never evaluate user input as a Bash subscript.
        for ((j=1; j<=package_count; j++)); do
          if [ "$choice" = "$j" ]; then TARGET_PKG="${PACKAGES[$j]}"; break; fi
        done
        if [ -n "$TARGET_PKG" ]; then break; fi
        echo "Invalid app number: $choice. Choose a listed number or enter a package id." >&2
        ;;
    esac
  done
fi
[ "$TARGET_PKG" = "-" ] && TARGET_PKG=""   # explicit skip token for non-interactive use
if [ -n "$TARGET_PKG" ] && [ -z "$(adbx shell pm path --user current "$TARGET_PKG" 2>/dev/null)" ]; then
  echo "WARN: '$TARGET_PKG' not found on device — will still try." >&2
fi
export TARGET_PKG                          # case scripts use it for the DenyList check
if [ -n "$TARGET_PKG" ]; then
  python3 "$HERE/lib/py/app-info.py" "$DEV_SERIAL" "$TARGET_PKG" \
    || echo 'WARN: app summary unavailable — continuing.' >&2
fi

# --- run ----------------------------------------------------------------------
ensure_device_unlocked || exit 1
echo
echo ">> running $(basename "$TARGET")  on  $DEV_NAME ($DEV_SERIAL)  target=${TARGET_PKG:-none}${DELAY_SCALE:+  delay_scale=$DELAY_SCALE}"
echo
# Each case opens TARGET_PKG itself as its final step (after going home).
bash "$TARGET"
