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

# NOT a subshell. It used to be one, so that a PIN typed here could not escape — but
# cases 2 and 3 reboot the device, and the post-reboot unlock() reads $PIN with no way to
# ask for it, so the PIN had to be stored on disk for those cases to work at all. Keeping
# it in this process and exporting it is what lets the PIN be typed instead of stored.
# Input routing is common.sh's job: inp -> inpx -> has_su, which caches the one su probe
# this run needs. This function used to repeat that probe and shadow `inp` with a copy.
ensure_device_unlocked() {
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
    # Ask once, in this process only — a PIN is never written to disk and never read
     # from anywhere. The export carries it to the reboots in cases 2 and 3.
    if [ -t 0 ]; then
      read -rsp "  PIN for ${DEV_NAME:-$DEV_SERIAL} (digits; not stored): " PIN || PIN=""
      echo
      export PIN              # cases 2/3 reboot and unlock() needs it, with nobody to ask
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
  echo '!! Device is still locked or could not be verified. Unlock it by hand, then rerun.' >&2
  return 1
}
