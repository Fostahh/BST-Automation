#!/usr/bin/env bash
# Pre-scenario keyguard check. Source after common.sh, which supplies device_lock_state,
# ask_pin_or_manual, detect_size and the input helpers.

# NOT a subshell. It used to be one, so that a PIN typed here could not escape — but
# cases 2 and 3 reboot the device, and the post-reboot unlock() reads $PIN with no way to
# ask for it, so the PIN had to be stored on disk for those cases to work at all. Keeping
# it in this process and exporting it is what lets the PIN be typed instead of stored.
# Input routing is common.sh's job: inp -> inpx -> has_su, which caches the one su probe
# this run needs. This function used to repeat that probe and shadow `inp` with a copy.
ensure_device_unlocked() {
  local state attempt
  state="$(device_lock_state)" || {
    echo "!! Cannot determine the lock state of $DEV_SERIAL; scenario not started." >&2
    return 1
  }
  if [ "$state" = unlocked ]; then
    echo "  $DEV_SERIAL is already unlocked — starting scenario."
    return 0
  fi

  echo "  $DEV_SERIAL is locked — unlocking ..."
  case "${PIN:-}" in
    *[!0-9]*) echo '!! PIN must contain only digits.' >&2; return 1 ;;
  esac
  detect_size || return 1
  case "$W:$H" in
    *[!0-9:]*|:*|*:) echo '!! Cannot determine device screen size.' >&2; return 1 ;;
  esac
  inp keyevent 224 || return 1
  nap 0.8
  swipr 0.5 0.80 0.5 0.25 200 || return 1
  nap 1.0

  # A swipe or a trusted unlock may already have dismissed the keyguard. Never type a PIN
  # into an app.
  state="$(device_lock_state)" || {
    echo '!! Cannot verify keyguard after waking the device; scenario not started.' >&2
    return 1
  }
  if [ "$state" = unlocked ]; then
    echo '  Device unlocked.'
    return 0
  fi

  # Ask for the PIN, or accept a blank answer meaning "I unlocked it by hand" — which
  # re-reads the keyguard and asks again if it is still up, rather than ending the run.
  ask_pin_or_manual || return 1
  if [ -z "${PIN:-}" ]; then
    echo '  Device unlocked by hand — continuing.'
    return 0
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
