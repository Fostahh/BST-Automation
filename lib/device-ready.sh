#!/usr/bin/env bash
# Pre-scenario keyguard check. Source after common.sh and the selected device profile.

device_lock_state() {
  local policy
  policy="$(adbx shell dumpsys window policy)" || return 1
  # Ignore showingAndNotOccluded/inputRestricted: neither alone proves a lock.
  printf '%s\n' "$policy" | tr -d '\r' | awk '
    /^[[:space:]]*(showing|mIsShowing|mKeyguardShowing|isStatusBarKeyguard|mShowingLockscreen)=(true|false)([[:space:]]|$)/ {
      seen=1
      if ($0 ~ /=(true)([[:space:]]|$)/) locked=1
    }
    END {
      if (!seen) exit 1
      print locked ? "locked" : "unlocked"
    }'
}

# Runs in a subshell so a PIN read here stays in this process and never leaks into the
# scenario's environment. Input routing is common.sh's job: inp -> inpx -> has_su, which
# caches the one su probe this run needs. This function used to repeat that probe and
# shadow `inp` with a byte-identical copy.
ensure_device_unlocked() (
  local state attempt
  state="$(device_lock_state)" || {
    echo "!! Cannot determine the lock state of ${DEV_NAME:-$DEV_SERIAL}; scenario not started." >&2
    return 1
  }
  if [ "$state" = unlocked ]; then
    echo "  ${DEV_NAME:-$DEV_SERIAL} is already unlocked — starting scenario."
    return 0
  fi

  echo "  ${DEV_NAME:-$DEV_SERIAL} is locked — unlocking ..."
  case "${PIN:-}" in
    *[!0-9]*) echo '!! Device profile PIN must contain only digits.' >&2; return 1 ;;
  esac
  detect_size || return 1
  case "$W:$H" in
    *[!0-9:]*|:*|*:) echo '!! Cannot determine device screen size.' >&2; return 1 ;;
  esac
  inp keyevent 224 || return 1
  nap 0.8
  swipr 0.5 0.80 0.5 0.25 200 || return 1
  nap 1.0

  # A swipe or trusted unlock may already dismiss keyguard. Never type a PIN into an app.
  state="$(device_lock_state)" || {
    echo '!! Cannot verify keyguard after waking the device; scenario not started.' >&2
    return 1
  }
  if [ "$state" = unlocked ]; then
    echo '  Device unlocked.'
    return 0
  fi
  if [ -z "${PIN:-}" ]; then
    # No PIN configured: ask once, in this process only — nothing is written to disk.
    # BST_PIN_<PROFILE> or lib/devices.local.sh can supply it for unattended runs.
    if [ -t 0 ]; then
      read -rsp "  PIN for ${DEV_NAME:-$DEV_SERIAL} (digits; not stored): " PIN || PIN=""
      echo
    fi
    case "${PIN:-}" in
      ''|*[!0-9]*)
        echo '!! Device is still locked and no numeric PIN was given — unlock it manually, then rerun.' >&2
        return 1 ;;
    esac
  fi

  # One PIN attempt only; a failed PIN must not repeatedly trigger lockout penalties.
  enter_pin "$PIN" || return 1
  nap 0.4
  inp keyevent 66 || return 1
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    nap 0.5
    if state="$(device_lock_state)" && [ "$state" = unlocked ]; then
      echo '  Device unlocked.'
      return 0
    fi
  done
  echo '!! Device is still locked or could not be verified. Check its profile PIN or unlock manually; scenario not started.' >&2
  return 1
)
