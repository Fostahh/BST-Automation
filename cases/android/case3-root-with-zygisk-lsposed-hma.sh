#!/usr/bin/env bash
# NAME: Case 3 — Root with Zygisk LSPosed HMA
# Target state: modules ON, Enforce DenyList ON, target IN denylist (all processes).
# Then open the LSPosed manager via the module "Action" button, and open the target app.
#   env: TARGET_PKG=<pkg>   REBOOT=1   DL_SEARCH=<term>
#        DL_SEARCH is what gets typed into the DenyList search box when the app's
#        display name differs from its package id (defaults to TARGET_PKG).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/android/common.sh"
detect_size
: "${TARGET_PKG:?Case 3 needs TARGET_PKG}"

apply_state ON ON ON "$TARGET_PKG" "${DL_SEARCH:-$TARGET_PKG}"

# open the LSPosed manager via the module "Action" button (located by id, not coords)
lsposed_action
fg="$(focus_now)"; echo "  foreground: $fg"
case "$fg" in *lsposed*) echo "  LSPosed manager opened ✓";; *) echo "  WARN: LSPosed not detected" >&2;; esac

open_target
echo "case3 (Root with Zygisk LSPosed HMA) done on $DEV_SERIAL"
reopen_loop
verdict_exit
