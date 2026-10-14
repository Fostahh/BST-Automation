#!/usr/bin/env bash
# base.sh — the primitives with no dependencies: repo paths, menu selection, int parsing.
#
# Sourced by run-scenarios.sh FIRST, and again (idempotently) by common.sh, because
# preflight.sh needs BST_ROOT before common.sh is in scope. Nothing here touches adb,
# so it is safe to source anywhere, in any order, as often as you like.

[ -n "${BST_BASE_SOURCED:-}" ] && return 0
BST_BASE_SOURCED=1

# --- where things are ---------------------------------------------------------
# One definition of the tree, instead of four spellings of "$dir/../..":
#   $BST_ROOT/Automation/      this suite (run-scenarios.sh, lib/, cases/)
#   $BST_ROOT/fridaenv/        the author's venv — frida, android-unpinner, aapt2
# A colleague running the generated bundle has no fridaenv at all; every lookup that
# uses it is already written to fall back to PATH, so an absent sibling is not an error.
BST_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # .../Automation/lib
BST_AUTOMATION="$(cd "$BST_LIB/.." && pwd)"                      # .../Automation
BST_ROOT="${BST_ROOT:-$(cd "$BST_AUTOMATION/.." && pwd)}"        # parent, holds fridaenv/
FRIDAENV="${FRIDAENV:-$BST_ROOT/fridaenv}"
export BST_ROOT

# --- menu selection -----------------------------------------------------------
# pick_index <count> <input> : echo the chosen 1-based index, or return 1.
#
# The input is compared as a STRING against each printed label and is never placed in
# an array subscript. Bash evaluates a subscript as an arithmetic expression, which
# means "${LIST[$input]}" mishandles exactly the input a menu receives most:
#   foo   -> under `set -u`, dies with bash's own "foo: unbound variable", so the
#            script's own "invalid selection" message is never reached
#   1+1   -> evaluates to 2 and silently selects an entry the user did not type
# Command substitution does NOT execute here (the arithmetic parser rejects it), so
# this is a correctness and diagnostics fix, not a shell-injection one.
pick_index() {
  local count="$1" input="$2" i
  case "$input" in ''|*[!0-9]*) return 1 ;; esac     # digits only, no sign, no spaces
  for (( i=1; i<=count; i++ )); do
    [ "$input" = "$i" ] && { printf '%s\n' "$i"; return 0; }
  done
  return 1                                            # in range of nothing printed
}

# --- paths a human typed -------------------------------------------------------
# clean_path <text> : a path as someone supplied it -> a path the filesystem accepts.
#
# Dragging a file into Terminal, or tab-completing one, pastes it SHELL-ESCAPED:
#   /path/My App_1.0.apk   arrives as   /path/My\ App_1.0.apk
# `read` performs none of that unescaping, so the backslash stays in the string and the
# open fails on a file that is plainly sitting there. Quotes arrive the same way, and
# `read` does not expand a leading ~ either.
clean_path() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"                    # leading whitespace
  s="${s%"${s##*[![:space:]]}"}"                    # trailing whitespace
  s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"   # one layer of matching quotes
  # ponytail: drops every backslash, so a path containing a literal one loses it. Those
  # do not happen on a Mac; pasted escapes happen constantly.
  case "$s" in *\\*) s="$(printf '%s' "$s" | sed 's/\\\(.\)/\1/g')" ;; esac
  case "$s" in "~") s="$HOME" ;; "~/"*) s="$HOME/${s#\~/}" ;; esac
  printf '%s' "$s"
}

# --- numeric knobs ------------------------------------------------------------
# _num_warn speaks up only when the caller names the knob, so an ordinary default is quiet
# while a value someone actually supplied gets told it was rejected.
_num_warn() {   # <bad value> <fallback> [name]
  [ -n "${3:-}" ] || return 0
  echo "  WARN: $3='$1' is not a number — using $2" >&2
}
# int_or <value> <fallback> [name] : echo <value> if it is a non-negative integer, else
# <fallback>.
#
# Env-supplied knobs are clamped with `[ "$X" -lt N ]`, and `test` fails on a non-number
# with an error that used to be swallowed by `2>/dev/null` — leaving the junk in place to
# blow up later inside arithmetic, killing the case under `set -e` with no explanation.
# Validating first means the clamp that follows can assume a number.
int_or() {
  case "$1" in
    ''|*[!0-9]*) _num_warn "$1" "$2" "${3:-}"; printf '%s' "$2" ;;
    *)           printf '%s' "$1" ;;
  esac
}
# num_or <value> <fallback> [name] : the same for a non-negative DECIMAL. The settle
# lengths and DELAY_SCALE are fractions, so they cannot go through int_or.
#
# These reach awk, which coerces a non-number to 0 — so DELAY_SCALE=abc used to floor
# every settle in every case to NAP_MIN and say nothing at all. The runner validated only
# the value it prompted for, never one arriving from the environment.
num_or() {
  case "$1" in
    ''|.|*[!0-9.]*|*.*.*) _num_warn "$1" "$2" "${3:-}"; printf '%s' "$2" ;;
    *)                    printf '%s' "$1" ;;
  esac
}

# --- timing, shared by Android and iOS ----------------------------------------
# Moved here verbatim from lib/android/common.sh so both platforms wait the same way: one
# DELAY_SCALE, the same settle lengths, the same retry count.
# Every knob is validated HERE, where all paths meet, rather than at the prompt that asks
# for one of them. The runner used to check only the DELAY_SCALE it had just read from the
# keyboard, so DELAY_SCALE=abc in the environment sailed through to awk, coerced to 0, and
# floored every settle in every case to NAP_MIN without a word. num_or/int_or (base.sh)
# substitute the documented default and say which knob was rejected.
DELAY_SCALE="$(num_or "${DELAY_SCALE:-1}" 1 DELAY_SCALE)"          # global nap multiplier
NAP_MIN="$(num_or "${NAP_MIN:-0.3}" 0.3 NAP_MIN)"                  # floor: no settle is shorter
NAP_MAX="${NAP_MAX:-}"                   # OPTIONAL cap per settle (empty = none). See nap().
[ -z "$NAP_MAX" ] || NAP_MAX="$(num_or "$NAP_MAX" "" NAP_MAX)"     # junk cap = no cap
NAP_SHORT="$(num_or "${NAP_SHORT:-0.8}" 0.8 NAP_SHORT)"            # after a tap / minor settle
NAP_MED="$(num_or "${NAP_MED:-1.2}" 1.2 NAP_MED)"                  # after typing / toggle / dialog
NAP_NAV="$(num_or "${NAP_NAV:-1.5}" 1.5 NAP_NAV)"                  # after a screen change
NAP_SCROLL="$(num_or "${NAP_SCROLL:-0.6}" 0.6 NAP_SCROLL)"         # after a scroll swipe
TAP_RETRIES="$(int_or "${TAP_RETRIES:-10}" 10 TAP_RETRIES)";   [ "$TAP_RETRIES"     -lt 3  ] && TAP_RETRIES=3

# nap <seconds> : the standard UI settle — max(NAP_MIN, <seconds>*DELAY_SCALE).
# NAP_MAX can cap it, but it is OFF by default and should stay off for the Magisk
# cases: a settle that is too short makes the NEXT ui_dump snapshot the PREVIOUS
# screen, and the state readers (ui_checked/read_modules) then decide on stale data.
# Retrying a tap cannot detect that, so speed here comes from DELAY_SCALE, knowingly.
#
# The arithmetic needs awk (bash has no floats), but DELAY_SCALE/NAP_MIN/NAP_MAX are
# fixed for the whole run and only ~19 distinct lengths are ever asked for, so each is
# computed once and reused. bash 3.2 ships on macOS and has no associative arrays, hence
# a string cache.
#
# _scale_into assigns to $_SCALED rather than echoing, because "$(_scaled ...)" would run
# it in a subshell and throw every cache write away with it — a memo that silently never
# memoises. Nothing calls nap inside a command substitution, so the cache persists.
_NAP_CACHE=""
_SCALED=""
_scale_into() {   # _scale_into <seconds> <cap:1|0>  ->  sets $_SCALED
  local key="$2:$1"
  case "$_NAP_CACHE" in
    *" $key="*) _SCALED="${_NAP_CACHE#*" $key="}"; _SCALED="${_SCALED%% *}"; return 0 ;;
  esac
  _SCALED=$(awk -v s="$1" -v scale="$DELAY_SCALE" -v lo="$NAP_MIN" -v cap="$NAP_MAX" -v docap="$2" \
    'BEGIN{v=s*scale; if(v<lo)v=lo; c=cap+0; if(docap&&c>0&&v>c)v=c; printf "%.3f", v}')
  _NAP_CACHE="$_NAP_CACHE $key=$_SCALED"
}
nap() { _scale_into "$1" 1; sleep "$_SCALED"; }
# nap_long <seconds> : for waits that are NOT a UI settle and must not be capped —
# a reboot handshake, keyguard coming back, another app's manager starting up.
nap_long() { _scale_into "$1" 0; sleep "$_SCALED"; }
