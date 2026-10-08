#!/usr/bin/env bash
# run-scenarios.sh — the interactive runner. Takes NO arguments: every choice is asked.
#
#   ./run-scenarios.sh
#
# Order: intro + preflight -> platform -> scenario -> device -> target app -> run.
# Scenario is chosen before the device on purpose: case 8 can install a local APK onto
# an emulator with no phone attached, so it has to be able to skip the device prompt.
#   env: TARGET_PREFIX=<package prefix>  REQUIRED; asked until given if unset
#        DELAY_SCALE=<n>                 UI speed multiplier; asked at run time if unset
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Was DELAY_SCALE set by the user? Capture it BEFORE sourcing common.sh, which
# defaults it to 1 (otherwise the prompt below would always think it's preset).
DELAY_SCALE_PRESET="${DELAY_SCALE+set}"
source "$HERE/lib/base.sh"          # BST_ROOT, pick_index, int_or
source "$HERE/lib/devices.sh"
source "$HERE/lib/preflight.sh"

# --- 1) introduction ----------------------------------------------------------
intro() {
  cat <<'BANNER'

╔═══════════════════════════════════════════════════════════════════════╗
║   BST — RASP Verification Harness                                     ║
║   Mohammad Azri Khairuddin  ·  with Claude                            ║
╚═══════════════════════════════════════════════════════════════════════╝

  Builds the device states an attacker would use, launches the app under
  test, and lets the app's own RASP checks deliver the verdict. It does not
  attack the app — it makes the environment reproducible, so a result stops
  depending on who was holding the phone that day.

  Android   ready — 8 scenarios: plain root, Zygisk + LSPosed, Hide My
            Applist, Frida function hooking, debug android-unpinner,
            virtual-environment cloning, certificate tamper/re-sign APK, emulator.
  iOS       planned — jailbreak detection [palera1n, bootstrap], Frida hooking,
            re-signed IPA, dynamic lib injection. Not implemented yet.

  Recommended layout — keep this suite next to android-unpinner and your
  frida hooks, and both are found without configuring anything.

  Working from the repo:

    BST/
    ├── Automation/                this suite
    │   ├── run-scenarios.sh       <- you are here
    │   └── extracted/             APKs pulled or patched by cases 5, 7, 8
    └── fridaenv/                  python venv, sibling of Automation/
        ├── bin/android-unpinner   case 5 — also supplies aapt2
        └── Hooking/               your .js frida hooks — case 4

  Or running the handover bundle, which unpacks itself into a temp dir:

    your-work-folder/
    ├── bst-tools.sh               the bundle
    ├── bst-extracted/             APKs pulled or patched by cases 5, 7, 8
    ├── android-unpinner/          or anywhere on PATH
    └── Hooking/                   any folder of .js hooks beside the bundle

BANNER
}

intro
preflight || exit 1

# --- 2) platform --------------------------------------------------------------
# iOS is listed so the roadmap is visible, but there is nothing behind it yet: choosing
# it says so and carries on with Android rather than dead-ending the run.
choose_platform() {
  local ans
  echo "== Platform =="
  echo "  1) Android   ready"
  echo "  2) iOS       not implemented yet"
  while :; do
    read -rp "platform [1]: " ans || ans=""
    case "${ans:-1}" in
      1|android|Android|ANDROID) PLATFORM=android; return 0 ;;
      2|ios|iOS|IOS|iPadOS|ipados)
        echo "  iOS hasn't been developed yet — continuing with Android."
        PLATFORM=android; return 0 ;;
      *) echo "  choose 1 or 2." >&2 ;;
    esac
  done
}
choose_platform
echo

# --- 3) scenario --------------------------------------------------------------
# A case may declare "# PLATFORM: ios" in its header. No header means android, so the
# eight existing cases need no edit and an iOS case can simply be dropped into cases/.
echo "== Scenarios ($PLATFORM) =="
i=0
CASES=()
for f in "$HERE"/cases/*.sh; do
  [ -e "$f" ] || continue
  plat="$(grep -m1 '^# PLATFORM:' "$f" 2>/dev/null | sed 's/^# PLATFORM:[[:space:]]*//' \
          | tr '[:upper:]' '[:lower:]' || true)"
  [ -n "$plat" ] || plat=android
  [ "$plat" = "$PLATFORM" ] || continue
  i=$((i+1)); CASES[$i]="$f"
  name="$(grep -m1 '^# NAME:' "$f" 2>/dev/null | sed 's/^# NAME:[[:space:]]*//' || true)"
  printf "  %d) %s\n" "$i" "${name:-$(basename "$f")}"
done
[ "$i" -gt 0 ] || { echo "no $PLATFORM scenarios in cases/" >&2; exit 1; }
echo

read -rp "scenario number: " SEL || SEL=""
# pick_index compares the answer as a string. "${CASES[$SEL]}" evaluated it as an
# arithmetic subscript instead, so "foo" died with bash's own "unbound variable" before
# reaching the message below, and "1+1" quietly ran case 2.
SEL_IDX="$(pick_index "$i" "$SEL")" \
  || { echo "invalid scenario: ${SEL:-<blank>} — choose 1-$i" >&2; exit 1; }
TARGET="${CASES[$SEL_IDX]}"

# --- speed: one multiplier, applied to every scenario -------------------------
# Every settle in every case is DELAY_SCALE-aware. 1 = the timings these flows were
# tuned with; below ~0.5 the Magisk screens start being read before they have finished
# changing. Asked here, ahead of the case 8 branch below, because case 8 execs away and
# reads DELAY_SCALE for itself. Skipped when DELAY_SCALE is already in the environment.
if [ -z "$DELAY_SCALE_PRESET" ]; then
  read -rp "UI delay scale — 1=normal, 0.5=faster, 2=slower/flaky device [1]: " DELAY_SCALE || DELAY_SCALE=""
  DELAY_SCALE="${DELAY_SCALE:-1}"
  case "$DELAY_SCALE" in ''|*[!0-9.]*) echo "  '$DELAY_SCALE' is not a number — using 1"; DELAY_SCALE=1;; esac
fi
# Export unconditionally. A DELAY_SCALE set as a plain shell variable rather than an
# exported one still satisfies ${DELAY_SCALE+set} above, so the prompt is skipped — and
# the export used to live inside that branch, leaving the cases on the default 1 while
# the operator believed their value had taken effect.
export DELAY_SCALE

# Case 8 owns its own source selection: manual mode installs a local APK onto the
# emulator and needs no phone, so it must not pass through the device prompt below.
# lib/py/emulator-case.py asks for the source phone and the package itself.
if [ "$(basename "$TARGET")" = case8-emulator.sh ]; then
  echo
  echo ">> running $(basename "$TARGET")  (chooses its own APK source)"
  echo
  exec bash "$TARGET"
fi

# --- 4) device (cases 1–7) ----------------------------------------------------
echo "== Connected (adb) =="
adb devices | sed '1d;/^$/d' || true
echo
echo "== Device profiles =="
resolved=0
for n in $DEVICE_NAMES; do
  s="$(device_serial "$n" 2>/dev/null || true)"
  [ -n "$s" ] && resolved=$((resolved + 1))
  printf "  %-10s %s\n" "$n" "${s:-(not configured)}"
done
# Only explain the setup when it is actually needed. One attached device resolves any
# profile name on its own, so nagging about devices.local.sh in that case is noise.
if [ "$resolved" = 0 ]; then
  echo
  echo "  Nothing resolves. Either paste an adb serial from the list above, or name your"
  echo "  phones in lib/devices.local.sh:  cp lib/devices.local.sh.example lib/devices.local.sh"
fi
echo
read -rp "device profile or adb serial: " DEV_NAME || DEV_NAME=""
DEV_SERIAL="$(device_serial "$DEV_NAME")" \
  || { echo "not a known profile, and not an attached serial: ${DEV_NAME:-<blank>}" >&2; exit 1; }
PIN="$(device_pin "$DEV_NAME")"
export DEV_SERIAL DEV_NAME PIN
source "$HERE/lib/common.sh"
source "$HERE/lib/device-ready.sh"

# --- 5) target app: DenyList-checked during the scenario AND opened after it ---
TARGET_PKG=""
trim_prefix() {   # strip surrounding whitespace and a trailing glob star
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s%\*}"                                 # tolerate "com.example*"
}
# The prefix is REQUIRED, and asked until it is given. Two reasons it cannot be blank:
# it is what keeps any client's package namespace out of this repo, and an unscoped -3
# listing on a device with a work or secure profile enumerates apps from Android users
# the scenario will never touch. An exported TARGET_PREFIX skips the question; an
# exported empty one is rejected exactly like a blank answer.
TARGET_PREFIX="$(trim_prefix "${TARGET_PREFIX:-}")"
while [ -z "$TARGET_PREFIX" ]; do
  # Exit on a failed read, never loop on it: at EOF (a closed stdin, or piped answers
  # that ran out) read keeps returning non-zero with an empty value, and re-asking would
  # spin forever instead of ending the run.
  if ! read -rp "target package prefix (required, e.g. com.example): " TARGET_PREFIX; then
    echo >&2
    echo "!! no package prefix given — it is required." >&2
    exit 1
  fi
  TARGET_PREFIX="$(trim_prefix "$TARGET_PREFIX")"
  [ -n "$TARGET_PREFIX" ] || echo "  a package prefix is required — it cannot be blank." >&2
done
export TARGET_PREFIX
echo "== Installed target apps on $DEV_NAME ($TARGET_PREFIX*) =="
PACKAGES=()
package_count=0
# -3 lists third-party packages only, keeping the system apps out of the menu.
if package_list="$(adbx shell pm list packages -3 --user current)"; then
  # Normalize Android line endings, narrow to the namespace, keep the numbering stable.
  package_list="$(printf '%s\n' "$package_list" | tr -d '\r' | sed -n 's/^package:\([^[:space:]]*\)$/\1/p' \
                  | LC_ALL=C sort -u | grep "^$TARGET_PREFIX" || true)"
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    package_count=$((package_count + 1))
    PACKAGES[$package_count]="$pkg"
    printf '  %d) %s\n' "$package_count" "$pkg"
  done <<< "$package_list"
  # Nothing matched: there is no app under test, so every scenario below would build a
  # device state and then have nothing to launch. Stop here instead of asking.
  if [ "$package_count" -eq 0 ]; then
    echo >&2
    echo "!! No third-party package matches '$TARGET_PREFIX*' on $DEV_NAME." >&2
    echo "   Check the prefix, or install the app under test on the device first." >&2
    exit 1
  fi
else
  # A failed listing is a different problem from an empty one — the device answered, just
  # not usefully. The prompt below still accepts a package id typed in full.
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
      # Menu labels are compared as strings; user input never reaches a subscript.
      if pkg_idx="$(pick_index "$package_count" "$choice")"; then
        TARGET_PKG="${PACKAGES[$pkg_idx]}"; break
      fi
      echo "Invalid app number: $choice. Choose a listed number or enter a package id." >&2
      ;;
  esac
done
if [ -n "$TARGET_PKG" ] && [ -z "$(adbx shell pm path --user current "$TARGET_PKG" 2>/dev/null)" ]; then
  echo "WARN: '$TARGET_PKG' not found on device — will still try." >&2
fi
export TARGET_PKG                          # case scripts use it for the DenyList check
if [ -n "$TARGET_PKG" ]; then
  python3 "$HERE/lib/py/app-info.py" "$DEV_SERIAL" "$TARGET_PKG" \
    || echo 'WARN: app summary unavailable — continuing.' >&2
fi

# --- 6) run -------------------------------------------------------------------
ensure_device_unlocked || exit 1
echo
echo ">> running $(basename "$TARGET")  on  $DEV_NAME ($DEV_SERIAL)  target=${TARGET_PKG:-none}"
echo
# Each case opens TARGET_PKG itself as its final step (after going home).
bash "$TARGET"
