#!/usr/bin/env bash
# devices.sh — find the device to test, and work out which platform it is.
#
# There is no profile registry and nothing to configure. A BST session has one phone on
# the cable, so the device is whatever adb reports; with more than one attached the runner
# lists them and asks. Nothing about a device is written to disk — no serials, no PINs,
# no names — so there is nothing here to keep out of the repo.
#
# Platform comes from the same place: adb only ever sees Android, so any attached device
# means Android. iOS is looked for ONLY when no Android device is found, purely to give a
# useful message — a paired iPhone sitting in Xcode's device list must not start asking
# questions during an Android run.

# --- Android ------------------------------------------------------------------
# android_serials : attached serials in `device` state, one per line.
# `unauthorized` and `offline` are deliberately excluded — they cannot be driven, and
# naming them as choices only produces a failure three prompts later.
android_serials() {
  adb devices 2>/dev/null | tr -d '\r' | awk '$2=="device"{print $1}'
}

# android_label <serial> : a human line for the menu — model and release if adb will say,
# and an explicit tag for an emulator so one left running by case 8 is obvious in the list.
#
# </dev/null on every adb call. `adb shell` forwards stdin to the device, so calling this
# from inside a `while read` loop lets it swallow the lines the loop has not read yet:
# a two-device list printed one row while the header correctly said "2 attached".
android_label() {
  local model release tag=""
  model="$(adb -s "$1" shell getprop ro.product.model </dev/null 2>/dev/null | tr -d '\r')"
  release="$(adb -s "$1" shell getprop ro.build.version.release </dev/null 2>/dev/null | tr -d '\r')"
  case "$1" in emulator-*) tag="  [emulator]" ;; esac
  printf '%s%s' "${model:-unknown model}${release:+, Android $release}" "$tag"
}

# --- iOS (detection only; no scenarios implemented yet) -----------------------
# ios_devices : physical iPhones/iPads Xcode can currently reach, one "name" per line.
# devicectl takes about a second and lists every device ever paired, so filter on
# Reality=physical and a State that starts with "available". Absent Xcode is not an error.
ios_devices() {
  command -v xcrun >/dev/null 2>&1 || return 0
  # "unavailable" contains "available", so the state has to be matched with something in
  # front of it — a bare /available/ happily accepts every disconnected device Xcode
  # remembers.
  xcrun devicectl list devices 2>/dev/null | awk '
    /^-----/ { body = 1; next }
    body && NF {
      if ($0 ~ /physical[[:space:]]*$/ && $0 ~ /(^|[^[:alnum:]])available/) {
        # the Name column is everything before the run of spaces that precedes Hostname
        name = $0
        sub(/[[:space:]][[:space:]]+.*$/, "", name)
        if (name != "") print name
      }
    }'
}

# --- the one thing the runner calls ------------------------------------------
# pick_device : sets DEV_SERIAL, DEV_NAME and PLATFORM.
#   one Android device   -> selected silently
#   several              -> listed, and the runner is asked which
#   none, but an iPhone  -> says iOS is not implemented, leaves DEV_SERIAL empty
#   none at all          -> leaves DEV_SERIAL empty (only case 8's manual mode can run)
# Returns 0 even with no device: case 8 installs a local APK onto an emulator and needs
# no phone, so an absent device is not in itself a reason to stop the run.
pick_device() {
  local serials count i answer idx
  serials="$(android_serials)"
  count="$(printf '%s\n' "$serials" | grep -c . || true)"

  if [ "$count" = 0 ]; then
    DEV_SERIAL=""; DEV_NAME=""; PLATFORM=android
    local ios; ios="$(ios_devices)"
    if [ -n "$ios" ]; then
      echo "== Device =="
      printf '%s\n' "$ios" | sed 's/^/  iOS device found: /'
      echo "  iOS scenarios have not been developed yet — nothing to run against it."
    else
      echo "== Device =="
      echo "  No device attached."
    fi
    echo "  Only scenario 8 (emulator, manual APK) can run without one."
    return 0
  fi

  PLATFORM=android          # adb sees nothing else
  if [ "$count" = 1 ]; then
    DEV_SERIAL="$serials"
    DEV_NAME="$DEV_SERIAL"
    echo "== Device =="
    printf '  %s  (%s)\n' "$DEV_SERIAL" "$(android_label "$DEV_SERIAL")"
    return 0
  fi

  echo "== Device — $count attached, choose one =="
  # Collect first, print second. The collecting loop is fed from stdin, so nothing inside
  # it may read stdin; android_label does (via adb shell) and used to eat the rest of the
  # list. Printing happens afterwards, where stdin is nobody's business.
  i=0
  DEVICE_LIST=()
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    i=$((i + 1)); DEVICE_LIST[$i]="$s"
  done <<< "$serials"
  local n
  for (( n=1; n<=i; n++ )); do
    printf '  %d) %-22s %s\n' "$n" "${DEVICE_LIST[$n]}" "$(android_label "${DEVICE_LIST[$n]}")"
  done
  echo
  while :; do
    read -rp "device number: " answer || { echo "no device chosen." >&2; return 1; }
    if idx="$(pick_index "$i" "$answer")"; then
      DEV_SERIAL="${DEVICE_LIST[$idx]}"; DEV_NAME="$DEV_SERIAL"
      return 0
    fi
    echo "  choose 1-$i." >&2
  done
}
