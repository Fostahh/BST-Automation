#!/usr/bin/env bash
# build-wda.sh — build WebDriverAgent into an IPA that TrollStore can install permanently.
#
#   ./build-wda.sh [out.ipa]        (default: ./WebDriverAgent.ipa)
#
# WHY NOT JUST DOWNLOAD THE RELEASE ARTIFACT
# The prebuilt WebDriverAgentRunner-Runner.zip from GitHub links @rpath/XCTest.framework
# and does not embed it: XCTest normally arrives from the Developer Disk Image that
# xcodebuild mounts. That build also comes from a current Xcode, whose XCTest requires
# iOS 17. On an iOS 15/16 device it installs and then refuses to launch.
#
# WHY NOT JUST RUN IT WITH XCODEBUILD
# That works, but it needs a signing certificate and a running xcodebuild, and a free
# Apple ID certificate expires after seven days. TrollStore signs permanently, so the
# runner is installed once and keeps working — which is the point of having a jailbroken
# device in the first place.
#
# So: build unsigned with an Xcode old enough for the device, embed the XCTest frameworks
# from that same Xcode, strip the debug symbols TrollStore's ldid rejects, and package.
#
#   env: XCODE=<path to Xcode.app>   which Xcode to build with (default: xcode-select)
#        SCHEME=<name>               default WebDriverAgentRunner
#        WDA_SRC=<dir>               an existing WebDriverAgent checkout to build
#        WDA_REF=<tag|commit>        check that out instead of the default branch
set -euo pipefail

OUT="${1:-$PWD/WebDriverAgent.ipa}"
SCHEME="${SCHEME:-WebDriverAgentRunner}"

# --- which Xcode -------------------------------------------------------------
XCODE="${XCODE:-$(xcode-select -p 2>/dev/null | sed 's|/Contents/Developer$||')}"
[ -d "$XCODE" ] || { echo "!! no Xcode at: $XCODE" >&2; exit 1; }
DEV="$XCODE/Contents/Developer"
PLAT="$DEV/Platforms/iPhoneOS.platform/Developer"
XCB="$DEV/usr/bin/xcodebuild"
[ -x "$XCB" ] || { echo "!! no xcodebuild in $XCODE" >&2; exit 1; }

echo "== Xcode =="
"$XCB" -version | sed 's/^/  /'

# The one check that decides whether the result can run at all. XCTest from a current
# Xcode requires iOS 17, so building WDA for an iOS 16 phone with it produces something
# that installs and then dies in dyld. Fail here rather than three steps later.
XCTEST_PLIST="$PLAT/Library/Frameworks/XCTest.framework/Info.plist"
[ -f "$XCTEST_PLIST" ] || { echo "!! this Xcode has no device XCTest.framework" >&2; exit 1; }
MIN="$(plutil -p "$XCTEST_PLIST" | sed -n 's/.*"MinimumOSVersion" *=> *"\([^"]*\)".*/\1/p')"
echo "  XCTest minimum iOS: ${MIN:-unknown}"
case "${MIN%%.*}" in
  ''|*[!0-9]*) echo "  (could not read it — continuing)" >&2 ;;
  *) if [ "${MIN%%.*}" -ge 17 ]; then
       echo "!! This XCTest needs iOS ${MIN}. A device below that will install the result" >&2
       echo "   and then fail to launch. Use an older Xcode:  XCODE=/Applications/Xcode-14.3.1.app $0" >&2
       exit 1
     fi ;;
esac

# --- sources -----------------------------------------------------------------
WDA_REPO="${WDA_REPO:-https://github.com/appium/WebDriverAgent}"
SRC="${WDA_SRC:-}"
if [ -z "$SRC" ]; then
  # NOT a shared temp path. This used to default to $TMPDIR/WebDriverAgent and reuse any
  # directory that happened to have a .git in it. With TMPDIR unset that resolves to /tmp,
  # which is world-writable: anyone able to create /tmp/WebDriverAgent/.git would have had
  # this script build THEIR Xcode project — and an .xcodeproj runs arbitrary shell in its
  # build phases. The result is then packaged and installed on the test device as a
  # permanently-signed app with full accessibility access. Keep the checkout beside the
  # suite, where the permissions are the operator's own.
  SRC="$(cd "$(dirname "$0")" && pwd)/.wda-src"
fi

if [ -d "$SRC/.git" ]; then
  # Reusing a checkout is fine; reusing one that points somewhere else is not.
  HAVE="$(git -C "$SRC" remote get-url origin 2>/dev/null || true)"
  if [ "$HAVE" != "$WDA_REPO" ]; then
    echo "!! $SRC is a git checkout of:" >&2
    echo "     ${HAVE:-<no origin remote>}" >&2
    echo "   expected: $WDA_REPO" >&2
    echo "   Refusing to build it. Remove that directory, or set WDA_REPO if this is" >&2
    echo "   deliberate — xcodebuild runs whatever build phases the project declares." >&2
    exit 1
  fi
  echo "== reusing checkout: $SRC =="
  [ -n "${WDA_REF:-}" ] && git -C "$SRC" fetch --depth 1 origin "$WDA_REF" \
    && git -C "$SRC" checkout -q FETCH_HEAD
elif [ -e "$SRC" ]; then
  echo "!! $SRC exists but is not a git checkout. Remove it or set WDA_SRC." >&2
  exit 1
else
  echo "== cloning $WDA_REPO =="
  if [ -n "${WDA_REF:-}" ]; then
    git clone --depth 1 --branch "$WDA_REF" "$WDA_REPO" "$SRC"
  else
    git clone --depth 1 "$WDA_REPO" "$SRC"
  fi
fi

[ -f "$SRC/WebDriverAgent.xcodeproj/project.pbxproj" ] \
  || { echo "!! not a WebDriverAgent checkout: $SRC" >&2; exit 1; }

# Say what is about to be built. xcodebuild executes the project's build phases, so the
# exact commit is the thing being trusted — worth having in the log, and worth being able
# to pin with WDA_REF rather than silently tracking whatever HEAD is today.
echo "  source: $SRC"
echo "  commit: $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout')"

# --- build -------------------------------------------------------------------
# Unsigned on purpose: TrollStore fake-signs at install time, so no Apple ID, no team,
# no provisioning profile and nothing that expires in seven days.
BUILD="$SRC/build"
echo "== building $SCHEME (unsigned) =="
"$XCB" -project "$SRC/WebDriverAgent.xcodeproj" \
       -scheme "$SCHEME" \
       -sdk iphoneos -configuration Release \
       -derivedDataPath "$BUILD" \
       CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_BITCODE=NO \
       build-for-testing >/dev/null

APP="$(find "$BUILD/Build/Products" -maxdepth 2 -name "$SCHEME-Runner.app" -type d | head -1)"
[ -n "$APP" ] || { echo "!! build produced no $SCHEME-Runner.app" >&2; exit 1; }
echo "  built: $APP"

# --- embed the XCTest frameworks ---------------------------------------------
# The runner links @rpath/XCTest.framework/XCTest, and XCTest in turn needs XCTestCore,
# XCUnit and XCUIAutomation. xcodebuild supplies those from the Developer Disk Image at
# run time; a TrollStore-launched app has no DDI, so they have to travel with it. The
# runner already has @executable_path/Frameworks on its rpath.
echo "== embedding XCTest frameworks =="
mkdir -p "$APP/Frameworks"
for f in "$PLAT/Library/Frameworks/XCTest.framework" \
         "$PLAT/Library/PrivateFrameworks/XCTestCore.framework" \
         "$PLAT/Library/PrivateFrameworks/XCUnit.framework" \
         "$PLAT/Library/PrivateFrameworks/XCUIAutomation.framework" \
         "$PLAT/Library/PrivateFrameworks/XCTAutomationSupport.framework" \
         "$PLAT/Library/PrivateFrameworks/XCTestSupport.framework"; do
  [ -d "$f" ] || { echo "  skip (absent): $(basename "$f")"; continue; }
  cp -R "$f" "$APP/Frameworks/"
  echo "  + $(basename "$f")"
done
for d in "$PLAT/usr/lib/libXCTestSwiftSupport.dylib" \
         "$PLAT/usr/lib/libXCTestBundleInject.dylib"; do
  [ -f "$d" ] || continue
  cp "$d" "$APP/Frameworks/"
  echo "  + $(basename "$d")"
done

# --- strip what ldid refuses --------------------------------------------------
# TrollStore signs the bundle with `ldid -s <app>`, which walks every file and chokes on
# a dSYM: "ldid: Unsupported Mach-O type", surfacing as Install Error 175. Debug symbols
# are for symbolicating crash logs and are never loaded, so dropping them is free.
echo "== stripping debug symbols (Install Error 175) =="
find "$APP" -name '*.dSYM' -prune -exec rm -rf {} + 2>/dev/null || true
find "$APP" \( -name '*.bcsymbolmap' -o -name '.DS_Store' \) -delete 2>/dev/null || true

LEFT="$(find "$APP" -type f -exec file {} + 2>/dev/null | grep -ci 'dSYM companion' || true)"
[ "$LEFT" = 0 ] || { echo "!! $LEFT dSYM file(s) still present; ldid will reject the bundle" >&2; exit 1; }

# --- package ------------------------------------------------------------------
echo "== packaging =="
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
( cd "$STAGE" && zip -qr "$OUT" Payload -x '*.DS_Store' -x '__MACOSX/*' )

echo
echo "built: $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "Install it with TrollStore on the device:"
echo "  1. copy $(basename "$OUT") to the phone (AirDrop, or Finder > Files)"
echo "  2. TrollStore > + > Install IPA File > pick it"
echo "  3. tap WebDriverAgentRunner on the home screen to start it"
echo
echo "Then, from this Mac:"
echo "  iproxy 8100 8100 &            # USB"
echo "  curl http://localhost:8100/status"
echo "or over Wi-Fi, with no iproxy:"
echo "  curl http://<iphone-ip>:8100/status"
