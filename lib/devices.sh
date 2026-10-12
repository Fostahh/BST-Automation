#!/usr/bin/env bash
# devices.sh — find the device to test, and work out which platform it is.
#
# There is no profile registry and nothing to configure. A BST session has one phone on
# the cable, so the device is whatever adb reports; with more than one attached the runner
# lists them and asks. Nothing about a device is written to disk — no serials, no PINs,
# no names — so there is nothing here to keep out of the repo.
#
# Platform comes from the same place. adb only ever sees Android and devicectl only ever
# sees iOS, so whichever one answers settles it. When BOTH answer the runner asks which,
# because that is the only genuinely ambiguous case — and it has to ask now that iOS
# scenarios exist: the old rule of "Android wins" would make an iOS run impossible
# whenever a phone happened to be plugged in alongside the iPhone.

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
# ios_udids : "<udid>\t<name>" for each iOS device reachable right now.
#
# idevice_id first. devicectl only lists a device it has CoreDevice access to, which means
# iOS 17+; an iPhone XR on iOS 15/16 appears as an ECID row with no UDID and no State and
# is therefore invisible to the parser below. libimobiledevice sees it over lockdown.
ios_udids() {
  local udid name
  if command -v idevice_id >/dev/null 2>&1; then
    while IFS= read -r udid; do
      [ -n "$udid" ] || continue
      name=""
      command -v ideviceinfo >/dev/null 2>&1 &&
        name="$(ideviceinfo -u "$udid" -k DeviceName 2>/dev/null | tr -d '\r')"
      printf '%s\t%s\n' "$udid" "${name:-iOS device}"
    done < <(idevice_id -l 2>/dev/null)
    return 0
  fi
  command -v xcrun >/dev/null 2>&1 || return 0
  xcrun devicectl list devices 2>/dev/null | awk '
    /^-----/ { body = 1; next }
    body && NF && $0 ~ /physical[[:space:]]*$/ && $0 ~ /(^|[^[:alnum:]])available/ {
      name = $0; sub(/[[:space:]][[:space:]]+.*$/, "", name)      # Name column
      udid = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]+$/) { udid = $i; break }
      if (udid != "") printf "%s\t%s\n", udid, (name == "" ? "unnamed iOS device" : name)
    }'
}

# ios_devices : just the names, for the "no Android device" message.
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
#
#   one Android device and no iPhone  -> android, selected silently
#   one iPhone and no Android device  -> ios, selected silently
#   several on one platform           -> listed, and the runner is asked which
#   both platforms present            -> asked which platform, then as above
#   none at all                       -> DEV_SERIAL empty; only Android scenario 8's
#                                        manual mode can run without a device
# Returns 0 even with nothing attached: case 8 installs a local APK onto an emulator, so
# an absent device is not by itself a reason to stop the run.
pick_device() {
  local a_serials i_pairs a_count i_count want
  a_serials="$(android_serials)"
  a_count="$(printf '%s\n' "$a_serials" | grep -c . || true)"
  i_pairs="$(ios_udids)"
  i_count="$(printf '%s\n' "$i_pairs" | grep -c . || true)"

  echo "== Device =="
  if [ "$a_count" = 0 ] && [ "$i_count" = 0 ]; then
    DEV_SERIAL=""; DEV_NAME=""; PLATFORM=android
    echo "  nothing attached."
    echo "  Only Android scenario 8 (emulator, manual APK) can run without a device."
    return 0
  fi

  want=""
  if [ "$a_count" -gt 0 ] && [ "$i_count" -gt 0 ]; then
    # Genuinely ambiguous, so ask. Everything else is inferred.
    printf '  Android: %s attached      iOS: %s attached\n' "$a_count" "$i_count"
    while :; do
      read -rp "platform — [a]ndroid or [i]os? [a/i]: " want \
        || { echo; echo "no platform chosen." >&2; return 1; }
      case "${want:-a}" in
        a|A|android|Android) want=android; break ;;
        i|I|ios|iOS|IOS)     want=ios; break ;;
        *) echo "  answer a or i." >&2 ;;
      esac
    done
  elif [ "$a_count" -gt 0 ]; then
    want=android
  else
    want=ios
  fi

  PLATFORM="$want"
  if [ "$want" = android ]; then
    _pick_from "$a_serials" android
  else
    _pick_from "$i_pairs" ios
  fi
}

# _pick_from <lines> <platform> : one line auto-selects, several are listed and chosen
# between. Android lines are bare serials; iOS lines are "<udid>\t<name>".
#
# Collect first, print second. The collecting loop is fed from stdin, so nothing inside it
# may read stdin — android_label does, via `adb shell`, which forwards stdin to the device
# and used to eat the rest of the list.
_pick_from() {
  local lines="$1" plat="$2" i=0 n s answer idx
  DEVICE_LIST=(); DEVICE_LABELS=()
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    i=$((i + 1))
    if [ "$plat" = ios ]; then
      DEVICE_LIST[$i]="${s%%	*}"
      DEVICE_LABELS[$i]="${s#*	}"
    else
      DEVICE_LIST[$i]="$s"
      DEVICE_LABELS[$i]=""
    fi
  done <<< "$lines"

  if [ "$i" = 1 ]; then
    DEV_SERIAL="${DEVICE_LIST[1]}"
    DEV_NAME="${DEVICE_LABELS[1]:-$DEV_SERIAL}"
    if [ "$plat" = ios ]; then
      printf '  %s  (%s, iOS)\n' "$DEV_NAME" "$DEV_SERIAL"
    else
      printf '  %s  (%s)\n' "$DEV_SERIAL" "$(android_label "$DEV_SERIAL")"
    fi
    return 0
  fi

  printf '  %s attached, choose one:\n' "$i"
  for (( n=1; n<=i; n++ )); do
    if [ "$plat" = ios ]; then
      printf '  %d) %-22s %s\n' "$n" "${DEVICE_LABELS[$n]}" "${DEVICE_LIST[$n]}"
    else
      printf '  %d) %-22s %s\n' "$n" "${DEVICE_LIST[$n]}" "$(android_label "${DEVICE_LIST[$n]}")"
    fi
  done
  echo
  while :; do
    read -rp "device number: " answer || { echo "no device chosen." >&2; return 1; }
    if idx="$(pick_index "$i" "$answer")"; then
      DEV_SERIAL="${DEVICE_LIST[$idx]}"
      DEV_NAME="${DEVICE_LABELS[$idx]:-$DEV_SERIAL}"
      return 0
    fi
    echo "  choose 1-$i." >&2
  done
}
