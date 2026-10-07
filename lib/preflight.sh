#!/usr/bin/env bash
# preflight.sh — confirm this Mac has what the scenarios need, and set up the one
# dependency we can install ourselves (uiautomator2, which makes UI dumps ~8x faster).
#
# Everything else is expected on PATH: adb + python3 (all cases), frida (case 4),
# android-unpinner (case 5), emulator (case 8). aapt2 (cases 7/8) ships inside the
# android-unpinner package, so installing that covers it.
#
#   env: SKIP_PREFLIGHT=1  skip these checks entirely
#        ASSUME_YES=1      install uiautomator2 without asking
#        BST_VENV=<dir>    where to put the private venv (default ~/.bst-tools/venv)
#        U2_PY=<python>    use this python for uiautomator2 and skip the search

BST_VENV="${BST_VENV:-$HOME/.bst-tools/venv}"

_pf_have() { command -v "$1" >/dev/null 2>&1; }
# frida / android-unpinner may live on PATH or inside a local fridaenv venv.
_pf_tool() {
  local t="$1" venv
  venv="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/fridaenv/bin"
  if command -v "$t" >/dev/null 2>&1; then echo "ok"; return 0; fi
  if [ -x "$venv/$t" ]; then echo "ok (fridaenv venv)"; return 0; fi
  return 1
}
_pf_row()  { printf "  %-17s %s\n" "$1" "$2"; }

# uiautomator2 is optional: without it ui_dump falls back to `uiautomator dump` (~2s
# instead of ~0.23s). Offer to install it into a private venv — Homebrew's python
# refuses `pip install` into the system environment (PEP 668), so a venv is the clean way.
_pf_find_u2() {            # self-contained: preflight runs before common.sh is sourced
  local c
  for c in "${U2_PY:-}" "$BST_VENV/bin/python" \
           "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/fridaenv/bin/python" \
           python3 python; do
    [ -n "$c" ] || continue
    { [ -x "$c" ] || command -v "$c" >/dev/null 2>&1; } || continue
    if "$c" -c 'import uiautomator2' >/dev/null 2>&1; then U2_PY="$c"; export U2_PY; return 0; fi
  done
  return 1
}

_pf_uiautomator2() {
  if _pf_find_u2; then _pf_row "uiautomator2" "ok ($U2_PY)"; return 0; fi
  _pf_row "uiautomator2" "missing — UI steps run ~8x slower without it"
  local ans="${ASSUME_YES:-}"
  if [ -z "$ans" ]; then
    read -rp "    install uiautomator2 now into $BST_VENV? [Y/n]: " ans || ans=""
  fi
  case "$ans" in n|N) echo "    skipped — using the slower legacy dumps."; return 0;; esac

  local py; py="$(command -v python3 || command -v python || true)"
  [ -n "$py" ] || { echo "    !! no python found; cannot install." >&2; return 0; }
  if [ ! -x "$BST_VENV/bin/python" ]; then
    echo "    creating venv ..."
    "$py" -m venv "$BST_VENV" || { echo "    !! could not create $BST_VENV" >&2; return 0; }
  fi
  echo "    installing uiautomator2 (first run only) ..."
  if "$BST_VENV/bin/python" -m pip install -q --disable-pip-version-check uiautomator2; then
    U2_PY="$BST_VENV/bin/python"; export U2_PY
    _pf_row "uiautomator2" "installed ($U2_PY)"
  else
    echo "    !! install failed — continuing with the slower legacy dumps." >&2
  fi
}

preflight() {
  [ "${SKIP_PREFLIGHT:-}" = 1 ] && return 0
  echo "== preflight =="
  local missing=0 t
  for t in adb python3; do
    _pf_have "$t" && _pf_row "$t" "ok" || { _pf_row "$t" "MISSING — required by every case"; missing=1; }
  done
  local w
  w="$(_pf_tool frida)"            && _pf_row "frida" "$w"            || _pf_row "frida" "missing — case 4 only"
  w="$(_pf_tool android-unpinner)" && _pf_row "android-unpinner" "$w" || _pf_row "android-unpinner" "missing — case 5 only (also provides aapt2)"
  _pf_have emulator         && _pf_row "emulator" "ok"         || _pf_row "emulator" "missing — case 8 only"
  _pf_uiautomator2
  [ -n "${HOOK_DIR:-}" ] && _pf_row "HOOK_DIR" "$HOOK_DIR" \
    || _pf_row "HOOK_DIR" "unset — case 4 looks for a .js hooks folder next to itself"
  if [ "$missing" != 0 ]; then
    echo "!! install the tools marked MISSING above, then re-run." >&2
    return 1
  fi
  echo
}
