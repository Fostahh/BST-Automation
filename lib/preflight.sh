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

# _pf_ios_attached : is an iPhone/iPad on the USB bus at all?
#
# ioreg, not devicectl or idevice_id: it sees the hardware regardless of pairing, trust,
# developer mode or iOS version. That matters here — the iPhone XR these cases target is
# invisible to devicectl's device list (it shows only as an ECID row) yet ioreg reports it
# as an active IOUSBHostDevice. Used to decide whether the install offer below is relevant
# at all, so an Android-only run is never asked about iOS tooling.
_pf_ios_attached() {
  ioreg -p IOUSB -w 0 2>/dev/null | grep -qiE 'iPhone|iPad'
}

# iOS tooling. devicectl ships with Xcode but is the iOS 17+ CoreDevice interface and
# cannot read the app inventory on anything older — a jailbroken iOS 15/16 device answers
# CoreDeviceError 1014. libimobiledevice speaks the lockdown protocol those devices do
# support. Without either, the iOS cases still run as gated manual flows; they just cannot
# verify their own steps, which is the whole reason they are scripted.
_pf_ios() {
  if command -v ideviceinstaller >/dev/null 2>&1 && command -v ideviceinfo >/dev/null 2>&1; then
    _pf_row "ios tooling" "ok (libimobiledevice — covers iOS 15/16 and up)"
    return 0
  fi
  if command -v xcrun >/dev/null 2>&1; then
    _pf_row "ios tooling" "devicectl only — cannot read apps on iOS < 17"
  else
    _pf_row "ios tooling" "none — iOS cases would run unverified"
  fi

  # Only offer when it is actually relevant. The row above is free information; a prompt
  # in front of every Android run would not be.
  _pf_ios_attached || {
    echo "    (no iPhone/iPad on USB — install it when you need the iOS cases:" >&2
    echo "     brew install libimobiledevice ideviceinstaller)" >&2
    return 0
  }
  echo "    an iPhone/iPad is attached, so the iOS cases would run without verification."

  if ! command -v brew >/dev/null 2>&1; then
    echo "    !! Homebrew not found, so this cannot be installed for you. Either install" >&2
    echo "       Homebrew, or get libimobiledevice + ideviceinstaller another way." >&2
    return 0
  fi
  local ans="${ASSUME_YES:-}"
  if [ -z "$ans" ]; then
    read -rp "    install libimobiledevice + ideviceinstaller via Homebrew now? [Y/n]: " ans || ans=""
  fi
  case "$ans" in n|N) echo "    skipped — iOS cases will run without verification."; return 0;; esac

  # Unlike the uiautomator2 install this is not a private venv: brew writes into its own
  # prefix, system-wide. Hence the prompt, and hence saying so rather than just doing it.
  echo "    brew install libimobiledevice ideviceinstaller  (a minute or two) ..."
  if brew install libimobiledevice ideviceinstaller; then
    if command -v ideviceinstaller >/dev/null 2>&1 && command -v ideviceinfo >/dev/null 2>&1; then
      _pf_row "ios tooling" "installed (libimobiledevice)"
      echo "    tap \"Trust This Computer\" on the device if it asks — nothing has paired"
      echo "    with it over lockdown yet, and idevice_id -l stays empty until you do."
    else
      echo "    !! brew reported success but ideviceinstaller is not on PATH." >&2
    fi
  else
    echo "    !! install failed — iOS cases will run without verification." >&2
  fi
}

# Report what is on the cable. There is nothing to configure, so this is informational
# except when there is no device at all, which rules out every scenario but 8.
_pf_devices() {
  local n
  n="$(android_serials | grep -c . || true)"
  case "$n" in
    0) _pf_row "device" "none attached — only scenario 8 (manual APK) can run" ;;
    1) _pf_row "device" "1 attached" ;;
    *) _pf_row "device" "$n attached — the runner will ask which" ;;
  esac
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
  _pf_ios
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
