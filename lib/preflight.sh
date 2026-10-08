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

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/base.sh"   # BST_ROOT, FRIDAENV
BST_VENV="${BST_VENV:-$HOME/.bst-tools/venv}"

_pf_have() { command -v "$1" >/dev/null 2>&1; }
_pf_row()  { printf "  %-17s %s\n" "$1" "$2"; }

# A tool can exist, carry the exec bit, and still not run. Moving a python venv leaves
# every script it generated pointing at an interpreter path that no longer exists, so
# `[ -x ]` reported "ok (fridaenv venv)" for a frida that died the instant a case called
# it — after case 5 had already pulled a 100 MB APK off the device. So run the thing.
_PF_BROKEN=0
_pf_runs() { "$1" --version >/dev/null 2>&1 || "$1" --help >/dev/null 2>&1; }

# frida / android-unpinner may live on PATH or inside a local fridaenv venv.
_pf_tool() {
  local t="$1" venv="$FRIDAENV/bin/$1"
  if command -v "$t" >/dev/null 2>&1; then
    if _pf_runs "$t"; then echo "ok"; return 0; fi
    _PF_BROKEN=1; echo "BROKEN — on PATH but will not run"; return 0
  fi
  if [ -x "$venv" ]; then
    if _pf_runs "$venv"; then echo "ok (fridaenv venv)"; return 0; fi
    _PF_BROKEN=1; echo "BROKEN — present but will not run: $venv"; return 0
  fi
  return 1
}

# Warn about device setup here, before a scenario is chosen and time is spent, rather
# than only at the device prompt. Silent when a single attached device already covers it.
_pf_devices() {
  local total=0 ok=0 name attached
  for name in $DEVICE_NAMES; do
    total=$((total + 1))
    device_serial "$name" >/dev/null 2>&1 && ok=$((ok + 1))
  done
  attached="$(adb devices 2>/dev/null | tr -d '\r' | awk '$2=="device"{c++} END{print c+0}')"
  if [ "$ok" -gt 0 ]; then
    _pf_row "device profiles" "$ok/$total resolve · $attached attached"
    return 0
  fi
  _pf_row "device profiles" "none resolve · $attached attached"
  echo "    name your phones and their serials in lib/devices.local.sh:" >&2
  echo "      cp lib/devices.local.sh.example lib/devices.local.sh" >&2
  echo "    or attach one device and any profile name resolves to it; the device prompt" >&2
  echo "    also accepts a raw adb serial." >&2
}

# The same failure seen from the other side: cases 4 and 5 offer to `source` the venv's
# activate script, and a moved venv leaves that pointing at the old tree — so answering
# "yes" puts a directory that does not exist on PATH and the case dies looking for frida.
# activate writes the path single-quoted; -F keeps any regex metacharacter in it literal.
_pf_venv() {
  local act="$FRIDAENV/bin/activate"
  [ -f "$act" ] || return 0                     # no venv beside Automation/: nothing to check
  if grep -Fq "VIRTUAL_ENV='$FRIDAENV'" "$act"; then
    _pf_row "fridaenv venv" "ok ($FRIDAENV)"
    return 0
  fi
  _PF_BROKEN=1
  _pf_row "fridaenv venv" "STALE — bin/activate points elsewhere"
  echo "    the venv was moved; its scripts still name the old path. Repair with:" >&2
  echo "      $FRIDAENV/bin/python3 -m pip install --force-reinstall --no-deps frida frida-tools" >&2
  echo "      and rewrite the old path in $FRIDAENV/bin/activate*" >&2
  echo "    do NOT run 'venv --clear' — it deletes everything else in that folder." >&2
}

# uiautomator2 is optional: without it ui_dump falls back to `uiautomator dump` (~2s
# instead of ~0.23s). Offer to install it into a private venv — Homebrew's python
# refuses `pip install` into the system environment (PEP 668), so a venv is the clean way.
_pf_find_u2() {            # self-contained: preflight runs before common.sh is sourced
  local c
  for c in "${U2_PY:-}" "$BST_VENV/bin/python" "$FRIDAENV/bin/python" \
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
  # _pf_tool runs inside "$( )", so a flag it sets dies with that subshell — the BROKEN
  # verdict has to travel back in the string itself.
  local w
  w="$(_pf_tool frida)"            && _pf_row "frida" "$w"            || _pf_row "frida" "missing — case 4 only"
  case "$w" in BROKEN*) _PF_BROKEN=1 ;; esac
  w="$(_pf_tool android-unpinner)" && _pf_row "android-unpinner" "$w" || _pf_row "android-unpinner" "missing — case 5 only (also provides aapt2)"
  case "$w" in BROKEN*) _PF_BROKEN=1 ;; esac
  _pf_have emulator         && _pf_row "emulator" "ok"         || _pf_row "emulator" "missing — case 8 only"
  _pf_uiautomator2
  _pf_venv
  _pf_devices
  [ -n "${HOOK_DIR:-}" ] && _pf_row "HOOK_DIR" "$HOOK_DIR" \
    || _pf_row "HOOK_DIR" "unset — case 4 looks for a .js hooks folder next to itself"
  if [ "$missing" != 0 ]; then
    echo "!! install the tools marked MISSING above, then re-run." >&2
    return 1
  fi
  # Not fatal: cases 1-3 need none of these. But a tool that exists and cannot run is
  # worse than one that is absent, because the run starts believing it works.
  if [ "$_PF_BROKEN" != 0 ]; then
    echo "!! something above is present but not runnable — the case that needs it will" >&2
    echo "   fail partway through, not at startup. Fix it before running cases 4-8." >&2
  fi
  echo
}
