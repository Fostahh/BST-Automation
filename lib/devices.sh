#!/usr/bin/env bash
# devices.sh — registry of test-device profiles (friendly name -> adb serial).
#
# Profile names, serials and PINs are deliberately NOT stored in this file, so it is safe
# to publish. A profile name is just a label you choose; the names below are placeholders.
# Supply the real ones per machine, either way:
#   1) lib/devices.local.sh — git-ignored; copy devices.local.sh.example and fill it in.
#      It can set DEVICE_NAMES too, which replaces the placeholder list entirely.
#   2) the environment      — BST_SERIAL_<PROFILE> / BST_PIN_<PROFILE>, profile uppercased
#                             e.g. BST_SERIAL_DEVICE1=abc12345 BST_PIN_DEVICE1=1234
# PRECEDENCE: the local file is sourced below with plain assignments, so a profile it
# defines OVERWRITES the same variable from the environment. Comment the profile out of
# the file if you want to override that profile per run.
# With neither, a profile resolves to the only attached device, so a single-device setup
# needs no configuration at all, and a locked device is asked for its PIN at run time.

DEVICE_NAMES="${DEVICE_NAMES:-device1 device2 device3}"   # placeholders; rename in devices.local.sh

_DEV_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/devices.local.sh"
[ -f "$_DEV_LOCAL" ] && . "$_DEV_LOCAL"

_dev_var() {   # profile name -> env var suffix: "galaxyA54" becomes "GALAXYA54"
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_'
}

# _dev_attached <serial> : exit 0 if that exact serial is attached and in `device` state.
_dev_attached() {
  [ -n "${1:-}" ] || return 1
  adb devices 2>/dev/null | tr -d '\r' | awk -v s="$1" '$2=="device" && $1==s{f=1} END{exit f?0:1}'
}

# device_serial <profile-or-serial> : resolve to an adb serial, or return 1.
device_serial() {
  case " $DEVICE_NAMES " in
    *" $1 "*) ;;
    *) # Not a configured profile. Accept it if it is a serial that is actually attached:
       # the runner prints the attached list immediately above the prompt, so someone with
       # no profiles set up can use what they can see rather than guess at a label that
       # means nothing on their machine. Checked only on this path, so a known profile
       # still costs no extra adb call.
       _dev_attached "$1" && { printf '%s\n' "$1"; return 0; }
       return 1 ;;
  esac
  local v s list n
  v="BST_SERIAL_$(_dev_var "$1")"
  s="${!v:-}"
  if [ -z "$s" ]; then
    # Exactly one device attached means there is nothing to disambiguate.
    list="$(adb devices 2>/dev/null | awk '$2=="device"{print $1}')"
    n="$(printf '%s\n' "$list" | grep -c . || true)"       # grep exits 1 on none: guard set -e
    if [ "$n" = 1 ]; then s="$list"; fi
  fi
  if [ -z "$s" ]; then
    echo "no serial for profile '$1' — set $v, or add it to lib/devices.local.sh" >&2
    return 1
  fi
  printf '%s\n' "$s"
}

# Lock-screen PIN per device. Empty is normal: device-ready.sh then asks for it once,
# in-process, or you unlock the device by hand.
device_pin() {
  local v="BST_PIN_$(_dev_var "$1")"
  printf '%s\n' "${!v:-}"
}
