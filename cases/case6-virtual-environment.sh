#!/usr/bin/env bash
# NAME: Case 6 — Virtual Environment (clone target app)
# Guide cloning a target package through three virtual-environment apps:
# Super Clone, Parallel Space, and GBox. This is interactive — the runner does the
# in-app selections; the script opens each app, taps what it can (e.g. Start), and
# gates every stage with a Y/n prompt (n ends the script).
#   Uses DEV_SERIAL (+ TARGET_PKG) exported by run-scenarios.sh. Intended for the
#   Samsung device; input is routed through su only if the device is actually rooted.
#   env: SUPERCLONE_PKG  PARALLEL_PKG  GBOX_PKG
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"          # adbx(), launch(), focus_now(), LIB

SUPERCLONE_PKG="${SUPERCLONE_PKG:-com.polestar.super.clone}"   # label: "Super Clone"
PARALLEL_PKG="${PARALLEL_PKG:-com.lbe.parallel.intl}"          # label: "Parallel Space"
GBOX_PKG="${GBOX_PKG:-com.gbox.android}"                       # label: "GBox"

# inpx (root-aware input), wake, ui_dump and $UI_XML all come from common.sh.

# Tap a UI element by its on-screen text (uifind.py reads a uiautomator dump). rc=1 if absent.
# ui_dump + $UI_XML (one reusable temp, auto-removed on exit) come from common.sh.
ui_tap_text() {
  local xy
  ui_dump
  xy="$(python3 "$LIB/py/uifind.py" "$UI_XML" "$@")" || return 1
  inpx tap $xy
}

# gate "question" -> Y or empty continues; n ends the script.
gate() {
  local ans
  read -rp "$1 (Y/n): " ans
  case "$ans" in n|N) echo "   stopped by user."; exit 0;; esac
}

open_app() { echo "   opening $1 ..."; wake; launch "$1"; nap 2; }

# --- flow ---------------------------------------------------------------------
# 1) target package to clone
PKG="${TARGET_PKG:-}"
if [ -z "$PKG" ]; then read -rp "1) target app package id to clone: " PKG; fi
[ -n "$PKG" ] || { echo "package id required" >&2; exit 1; }
echo "1) cloning target: $PKG"

# ===== Super Clone ============================================================
echo
echo "== Super Clone =="
echo "2) opening Super Clone ($SUPERCLONE_PKG)"
open_app "$SUPERCLONE_PKG"
gate "3) Waiting for you to close every ads shown"
echo "4) In Super Clone, tap the + button (bottom-right) and select: $PKG"
gate "   Have you selected the target app"
echo "5) tapping the Start button ..."
ui_tap_text textequals=Start || ui_tap_text textcontains=Start \
  || echo "   (Start button not found automatically — tap it manually)"
gate "   Is it finished yet"

# ===== Parallel Space =========================================================
echo
echo "== Parallel Space =="
echo "6) opening Parallel Space ($PARALLEL_PKG)"
open_app "$PARALLEL_PKG"
gate "   Waiting for you to close every ads shown"
gate "7) Is the app already cloned"
gate "8) Is it finished yet"

# ===== GBox ===================================================================
echo
echo "== GBox =="
echo "9) opening GBox ($GBOX_PKG) — do the rest manually"
open_app "$GBOX_PKG"

echo "case6 (Virtual Environment) done on ${DEV_NAME:-$DEV_SERIAL}"
exit 0
