#!/usr/bin/env bash
# devices.sh — registry of test-device profiles (friendly name -> adb serial).
#
# Serials and PINs are deliberately NOT stored in this file, so it is safe to publish.
# Supply them per machine, either way:
#   1) lib/devices.local.sh — git-ignored; copy devices.local.sh.example and fill it in
#   2) the environment      — BST_SERIAL_<PROFILE> / BST_PIN_<PROFILE>, profile uppercased
#                             e.g. BST_SERIAL_DEVICE1=abc12345 BST_PIN_DEVICE1=1234
# With neither, a profile resolves to the only attached device, so a single-device setup
# needs no configuration at all, and a locked device is asked for its PIN at run time.

DEVICE_NAMES="${DEVICE_NAMES:-device1 device2 device3}"   # device1 = rooted (Magisk); device2 = stock, non-rooted

_DEV_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/devices.local.sh"
[ -f "$_DEV_LOCAL" ] && . "$_DEV_LOCAL"

_dev_var() {   # profile name -> env var suffix: "device2" becomes "DEVICE2"
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_'
}

device_serial() {
  case " $DEVICE_NAMES " in *" $1 "*) ;; *) return 1 ;; esac
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
