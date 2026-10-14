#!/usr/bin/env bash
# make-bundle.sh — pack the scenario suite into ONE self-extracting script to hand over.
#
#   ./make-bundle.sh [out.sh]        (default: ./bst-tools.sh)
#
# The bundle carries run-scenarios.sh + lib/ + cases/ only. It deliberately does NOT
# carry: the fridaenv venv (not portable — 414 MB of absolute paths), the frida .js
# hooks (case 4 reads them from $HOOK_DIR on the colleague's machine), or anything
# under extracted/ (pulled APKs).
#
# Note: a shell bundle is convenient, not secret — the payload is plain base64 and
# anyone holding the file can unpack it. Share it accordingly.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/bst-tools.sh}"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Automation"
cp "$HERE/run-scenarios.sh" "$STAGE/Automation/"
cp -R "$HERE/lib" "$HERE/cases" "$STAGE/Automation/"
# never ship local artefacts or backups (there is no machine-local config any more)
# node_modules is the frida-compile toolchain, tens of megabytes of it, and the bundle
# does not need it: lib/ios/js/uitree.bundle.js is the compiled script that actually runs.
rm -rf "$STAGE/Automation/extracted" "$STAGE/Automation"/lib/*/py/__pycache__ \
       "$STAGE/Automation/lib/ios/js/node_modules" "$STAGE/Automation/lib/ios/js/package-lock.json"
find "$STAGE/Automation" \( -name '*.bak' -o -name '.DS_Store' -o -name '*.apk' -o -name '*.apks' \) -delete

{
  # The marker is written split ("__PAY" "LOAD__") so this extractor line cannot
  # match itself when the finished script scans for the real marker below.
  cat <<'HDR'
#!/usr/bin/env bash
# bst-tools.sh — BST Android security-testing scenarios, self-contained (generated).
#
#   ./bst-tools.sh      interactive: every choice is prompted (no arguments)
#
# Needs on this Mac: adb, python3 (always); frida (case 4); android-unpinner
# (case 5, also supplies aapt2); Android emulator + an AVD (case 8).
# On every test device: MT Manager installed AND logged in.
# Attach the phone and run it: the device is taken from `adb devices`, nothing to configure.
# Case 4 needs your own .js frida hooks (none are bundled): keep a folder of them next
# to this file and it is found automatically, or set HOOK_DIR=/path/to/your/hooks.
# First run offers to install uiautomator2 into ~/.bst-tools/venv (makes UI steps ~8x faster).
set -euo pipefail
MARK="__PAY""LOAD__"
DIR="$(mktemp -d "${TMPDIR:-/tmp}/bst-tools.XXXXXX")"
trap 'rm -rf "$DIR"' EXIT
b64d() { if base64 --decode </dev/null >/dev/null 2>&1; then base64 --decode; else base64 -D; fi; }
awk -v m="$MARK" 'f{print} $0==m{f=1}' "$0" | b64d | tar xzf - -C "$DIR"
chmod +x "$DIR/Automation/run-scenarios.sh" 2>/dev/null || true
find "$DIR/Automation/lib" "$DIR/Automation/cases" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
# Retrieved/patched APKs must outlive the unpacked copy, which is deleted on exit.
export EXTRACTED_DIR="${EXTRACTED_DIR:-$PWD/bst-extracted}"
echo "APKs retrieved by cases 5/8 are kept in: $EXTRACTED_DIR"
# The unpacked copy lives in $TMPDIR, so the cases cannot infer where this file sits.
# Case 4 uses this to find a folder of .js frida hooks next to the bundle.
export BST_LAUNCH_DIR="${BST_LAUNCH_DIR:-$PWD}"
# Run (not exec) so the trap still cleans the unpacked copy up afterwards.
# run-scenarios.sh takes no arguments: it prompts for platform, scenario, device, target.
"$DIR/Automation/run-scenarios.sh"
exit $?
__PAYLOAD__
HDR
  tar czf - -C "$STAGE" Automation | base64
} > "$OUT"

chmod +x "$OUT"
printf 'built %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
printf 'contents: %s files\n' "$(tar tzf <(awk -v m='__PAYLOAD__' 'f{print} $0==m{f=1}' "$OUT" | { base64 --decode 2>/dev/null || base64 -D; }) 2>/dev/null | grep -c . || echo '?')"
