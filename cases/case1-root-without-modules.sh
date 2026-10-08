#!/usr/bin/env bash
# NAME: Case 1 — Root-Without Modules
# Target state: modules OFF, Enforce DenyList OFF, target NOT in denylist.
# The engine changes only what differs, reboots only if a module toggles, and
# rechecks via UI only after a reboot. Then it opens the target app.
#   env: TARGET_PKG=<pkg>   REBOOT=1   DL_SEARCH=<term>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
detect_size
: "${TARGET_PKG:?Case 1 needs TARGET_PKG}"

apply_state OFF OFF OFF "$TARGET_PKG" "${DL_SEARCH:-$TARGET_PKG}"
open_target
echo "case1 (Root-Without Modules) done on $DEV_SERIAL"
reopen_loop
verdict_exit
