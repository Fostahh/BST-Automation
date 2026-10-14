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
  iOS       2 scenarios on a jailbroken device: decrypt + re-sign through
            TrollStore, dylib injection through TrollFools. The taps are real
            — frida reads and drives the UI, since XCUITest would need a
            signing certificate. Jailbreak detection and Frida hooking: not
            implemented yet.

  iOS needs   a jailbroken iPhone with frida-server running, a python that
              can `import frida`, and libimobiledevice for the app inventory
              (brew install libimobiledevice ideviceinstaller). Without the
              frida side the cases still run and ask you to tap.

  Recommended layout — keep this suite next to android-unpinner and your
  frida hooks, and both are found without configuring anything.

  Working from the repo:

    BST/
    ├── Automation/                this suite
    │   ├── run-scenarios.sh       <- you are here
    │   ├── cases/android/         the 8 Android scenarios
    │   ├── cases/ios/             the 2 iOS scenarios
    │   ├── lib/                   base.sh, devices.sh, preflight.sh — shared
    │   │   ├── android/           adb + uiautomator layer, and its python
    │   │   └── ios/               libimobiledevice + frida layer, its python and js
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

# --- 2) device, and the platform it implies -----------------------------------
# Nothing is asked that can be observed. adb only ever sees Android, so an attached
# device settles the platform; a single one is selected silently and several are listed
# to choose from. iOS is looked for only when no Android device is found — an iPhone
# paired to Xcode must not start asking questions in the middle of an Android run.
pick_device || exit 1
echo

# --- 3) scenario --------------------------------------------------------------
# The folder decides the platform: cases/android/ and cases/ios/ are listed by the
# platform the device settled, so dropping a case in is all it takes to register it.
# Each case's menu label is the "# NAME:" line in its header.
echo "== Scenarios ($PLATFORM) =="
i=0
CASES=()
for f in "$HERE/cases/$PLATFORM"/*.sh; do
  [ -e "$f" ] || continue
  i=$((i+1)); CASES[$i]="$f"
  name="$(grep -m1 '^# NAME:' "$f" 2>/dev/null | sed 's/^# NAME:[[:space:]]*//' || true)"
  printf "  %d) %s\n" "$i" "${name:-$(basename "$f")}"
done
[ "$i" -gt 0 ] || { echo "no scenarios in cases/$PLATFORM/" >&2; exit 1; }
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
# lib/android/py/emulator-case.py asks for the source phone and the package itself.
if [ "$(basename "$TARGET")" = case8-emulator.sh ]; then
  # Hand over the device if one is attached (its automatic mode extracts from a phone);
  # manual mode installs a local APK and needs none, which is why it runs before the
  # device requirement below.
  [ -n "$DEV_SERIAL" ] && export DEV_SERIAL DEV_NAME
  echo
  echo ">> running $(basename "$TARGET")  (chooses its own APK source)"
  echo
  exec bash "$TARGET"
fi

# --- 4) the device picked above has to exist for cases 1–7 --------------------
# No PIN is read from anywhere. device-ready.sh asks for one if the screen is locked when
# the scenario starts, and common.sh's unlock() asks again if a reboot brings the keyguard
# back — both in this process only, never written to disk.
[ -n "$DEV_SERIAL" ] || {
  echo "!! $(basename "$TARGET") needs a device attached; none is." >&2
  exit 1
}
export DEV_SERIAL DEV_NAME PLATFORM
# Two different layers, because the device interfaces have nothing in common: lib/android
# is adb and uiautomator throughout, lib/ios is libimobiledevice and frida. Sourcing the
# wrong one fails immediately — common.sh would try to adb an iOS udid.
if [ "$PLATFORM" = ios ]; then
  source "$HERE/lib/ios/device.sh"
else
  source "$HERE/lib/android/common.sh"
  source "$HERE/lib/android/device-ready.sh"
fi

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
echo "== Installed target apps on ${DEV_NAME:-$DEV_SERIAL} ($TARGET_PREFIX*) =="
PACKAGES=()
package_count=0
# Android: `pm list packages -3` (third-party only, so system apps stay out of the menu).
# iOS: devicectl's app inventory, which has no equivalent of -3 — the prefix does that job.
# `listed` separates "the device answered and nothing matched" from "the query failed",
# which are different problems with different advice.
listed=0
if [ "$PLATFORM" = ios ]; then
  if package_list="$(ios_apps 2>/dev/null)"; then
    package_list="$(printf '%s\n' "$package_list" | cut -f1 | LC_ALL=C sort -u | grep "^$TARGET_PREFIX" || true)"
    listed=1
  fi
elif package_list="$(adbx shell pm list packages -3 --user current)"; then
  # Normalize Android line endings, narrow to the namespace, keep the numbering stable.
  package_list="$(printf '%s\n' "$package_list" | tr -d '\r' | sed -n 's/^package:\([^[:space:]]*\)$/\1/p' \
                  | LC_ALL=C sort -u | grep "^$TARGET_PREFIX" || true)"
  listed=1
fi
if [ "$listed" = 1 ]; then
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
    echo "!! No third-party package matches '$TARGET_PREFIX*' on $DEV_SERIAL." >&2
    echo "   Check the prefix, or install the app under test on the device first." >&2
    exit 1
  fi
else
  # A failed listing is a different problem from an empty one — the query itself did not
  # work. The prompt below still accepts a bundle/package id typed in full.
  echo '  WARN: could not list installed apps — enter the id manually.' >&2
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
if [ -n "$TARGET_PKG" ]; then
  if [ "$PLATFORM" = ios ]; then
    ios_installed "$TARGET_PKG" \
      || echo "WARN: '$TARGET_PKG' is not installed on this device — will still try." >&2
  elif [ -z "$(adbx shell pm path --user current "$TARGET_PKG" 2>/dev/null)" ]; then
    echo "WARN: '$TARGET_PKG' not found on device — will still try." >&2
  fi
fi
export TARGET_PKG                          # case scripts use it for the DenyList check
if [ -n "$TARGET_PKG" ]; then
  if [ "$PLATFORM" = ios ]; then
    printf '[%s] %s\n' "$TARGET_PKG" "$(ios_version "$TARGET_PKG" || echo 'version unknown')"
  else
    python3 "$HERE/lib/android/py/app-info.py" "$DEV_SERIAL" "$TARGET_PKG" \
      || echo 'WARN: app summary unavailable — continuing.' >&2
  fi
fi

# --- 6) run -------------------------------------------------------------------
# Keyguard handling is an Android concern; iOS cases are driven by hand on an unlocked
# phone, and there is no way to read or dismiss the iOS lock screen from here anyway.
if [ "$PLATFORM" != ios ]; then
  ensure_device_unlocked || exit 1
fi
echo
echo ">> running $(basename "$TARGET")  on  ${DEV_NAME:-$DEV_SERIAL}  target=${TARGET_PKG:-none}"
echo
# Each case opens TARGET_PKG itself as its final step (after going home).
bash "$TARGET"
