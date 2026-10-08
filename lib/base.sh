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
