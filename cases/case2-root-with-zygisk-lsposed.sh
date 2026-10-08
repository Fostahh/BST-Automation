#!/usr/bin/env bash
# NAME: Case 2 — Root with Zygisk and LSPosed
# Target state: modules ON, Enforce DenyList OFF, target NOT in denylist.
# Coming from Case 1 (modules OFF) this toggles modules ON, reboots, rechecks the
# modules, then ensures the denylist is OFF. Then it opens the target app.
#   env: TARGET_PKG=<pkg>   REBOOT=1   DL_SEARCH=<term>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
detect_size
: "${TARGET_PKG:?Case 2 needs TARGET_PKG}"

apply_state ON OFF OFF "$TARGET_PKG" "${DL_SEARCH:-$TARGET_PKG}"
open_target
echo "case2 (Root with Zygisk and LSPosed) done on $DEV_SERIAL"
reopen_loop
verdict_exit
