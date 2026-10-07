#!/usr/bin/env bash
# devices.sh — registry of the fixed test devices (friendly name -> adb serial).

DEVICE_NAMES="device1 device2"

device_serial() {
  case "$1" in
    device1)    echo "d283ab4c";;      # Xiaomi DEVICE1 X3 (M2007J20CG), rooted MIUI, 1080x2400
    device2) echo "RR8RB04V0LJ";;     # Samsung Galaxy S20 FE, non-rooted
    *) return 1;;
  esac
}

# Lock-screen PIN per device (empty = no secure PIN). Used before scenarios and after reboot.
device_pin() {
  case "$1" in
    device1)    echo "0000";;          # press 0 four times, then enter
    device2) echo "secret";;          # Secret
    *) echo "";;
  esac
}
