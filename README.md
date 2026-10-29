# BST Tools — Automation

A test harness for checking whether an **Android or iOS** app detects a compromised
environment.

It does not attack the app. It automates building the **device states** an attacker would
use, launches the app, and lets the app's own RASP checks give the verdict. Done by hand,
each state takes about ten minutes of tapping and comes out slightly different every time —
which is exactly what makes manual results hard to trust.

Each scenario's current status, the open work and the rules behind the design are in
[CONTEXT.md](CONTEXT.md).

## Authorization

The apps tested here belong to our **clients**, who have given us written permission to
security-test them. The engagement is authorized; automating it is my own initiative, to
make the results reproducible instead of depending on who held the phone that day.

Nothing here is used outside that scope.

## Scenarios

Each case puts the device into one adversarial state and opens the target app.

| # | State | Detection under test |
|---|-------|----------------------|
| 1 | Root present, all modules off, no hiding | plain root |
| 2 | Zygisk + LSPosed enabled | Xposed-family hooking frameworks |
| 3 | Case 2 plus Hide My Applist | detection when the module list is hidden |
| 4 | Version-matched frida-server + a chosen `.js` hook | runtime instrumentation / anti-Frida |
| 5 | `android-unpinner` rebuild (debuggable, SSL pinning stripped) | re-signed debuggable build, MITM exposure |
| 6 | App cloned into Super Clone / Parallel Space / GBox | app-level virtualisation (works unrooted) |
| 7 | APK repackaged with a foreign signing certificate | signature / integrity verification |
| 8 | Extracted APK/APKS installed on a clean emulator | emulator detection |

### iOS

Two scenarios, on a jailbroken device. The taps are real: frida reads and drives the UI
from inside the tool it is driving.

| # | State | Detection under test |
|---|-------|----------------------|
| 4 | TestFlight build decrypted with TrollDecrypt, re-installed through TrollStore | re-signed debuggable build |
| 5 | a dylib of your choice injected into the bundle with TrollFools | foreign dylib in the address space |

Needs a jailbroken iPhone running frida-server, a python that can `import frida`, and
`libimobiledevice` for the app inventory (`brew install libimobiledevice ideviceinstaller`).
Timing and retries are Android's own code (`nap`, `DELAY_SCALE`, `NAP_*`, `TAP_RETRIES`
in `lib/base.sh`), and a tap that never lands stops the case the way `ui_tap_req` does.

Nothing an iOS case can read is asked about. The model and iOS version arrive over
lockdown, the installed build is read from the inventory (and checked against
`EXPECT_VERSION` when you set it), a launch is confirmed against the process list, and
TrollFools' injection log is printed into the run output rather than put to the operator as
"does this look right?". The only question left in a healthy run is case 5's file picker,
which belongs to another process — see below.

Cases 1–3 are declarative — `apply_state <modules> <enforce-denylist> <target-in-denylist>`.
A shared engine reads the current Magisk state, changes only what differs, reboots only when
a module actually toggled, and re-verifies afterwards. The exit code carries the verdict.

The engine refuses to guess. It pages down the Modules list looking for both module titles,
and if either one is not there it stops rather than reading an absent row as "switch off" —
that reading is indistinguishable from a real one, and it is exactly case 1's target state,
so it used to produce a PASS without having seen the module. Set `MOD_ZNEXT` / `MOD_LSPOSED`
if your Magisk build labels them differently.

## Requirements

On the Mac: `adb`, `python3`, plus `frida` (case 4), `android-unpinner` (case 5, also supplies
`aapt2`), and the Android emulator with an AVD (case 8). `uiautomator2` is installed
automatically into a private venv on first run.

On every test device: MT Manager installed and logged in. Cases 1–4 need root (Magisk);
cases 5–8 do not.

## Setup

None. The device is whatever `adb` reports — one attached phone is selected silently, and
with several the runner lists them and asks which. No serials, names or PINs are stored
anywhere, so there is nothing to configure and nothing to keep out of this repo.

A locked device is asked for its PIN when the scenario starts, and asked again if the
reboot in case 2 or 3 brings the keyguard back. It lives in that process only and is
never written to disk.

The platform is derived rather than asked: `adb` only ever sees Android, so an attached
device settles it. iOS is looked for only when no Android device is found — an iPhone
paired to Xcode must not interrupt an Android run — and the scenario list is filtered by
the `# PLATFORM:` header each case declares.

## Usage

```bash
./run-scenarios.sh      # no arguments; every choice is prompted
```

It opens with the project header, a preflight report and the recommended folder layout,
then detects the **device** and the platform it implies, and asks for a **scenario** and
the **target app**.

Case 8 still works with no phone attached at all: its manual mode installs a local APK
onto an emulator, so the scenario is chosen before the device becomes a requirement.

Useful environment variables:

| Variable | Effect |
|----------|--------|
| `HOOK_DIR` | folder of `.js` frida hooks for case 4 (otherwise auto-detected, then prompted) |
| `DELAY_SCALE` | UI speed multiplier for **every** case — asked after the scenario; `2` = more patient. Set it in the environment to skip the prompt |
| `NAP_MAX` | optional cap per settle; **unset by default** — capping it makes the Magisk screens get read before they finish changing |
| `MODE` | `spawn` (default) or `attach` for case 4 |
| `TARGET_PREFIX` | **required** package namespace for the app list — asked until given, so no client prefix lives in the repo. The run stops if nothing matches it |
| `MOD_ZNEXT` / `MOD_LSPOSED` | the module titles as the Modules screen shows them, for cases 1–3 |
| `SKIP_PREFLIGHT` | skip the dependency checks |
| `TAP_RETRIES` | attempts before a required tap gives up, on **both** platforms (default 10, `NAP_SHORT` apart) |
| `IOS_PY` | a python that can `import frida`, if the search for one misses it |
| `TROLLFOOLS_SCOPE` | which TrollFools tab lists the app under test: `All`, `User`, `TrollStore`, `System` |
| `EXPECT_VERSION` | the build an iOS case is meant to test — the run stops if the phone holds another one |
| `INSTALL_TIMEOUT` | seconds an iOS case waits for a decrypt or an install (checked every 2s, like Android case 7). Default 600 |

Every case ends by offering to launch the app again (`open <pkg> again? [y/N]`), as
often as you like. Detection can hinge on a cold start or on what the app cached last
run, and relaunching is far cheaper than re-running the scenario, which would re-apply
the device state and may reboot. Case 4 has its own richer version of this — it replays
the chosen frida hook without restarting the server.

Retrieved and patched APKs land in `extracted/` (or `$EXTRACTED_DIR`).

## Layout

```
run-scenarios.sh        intro + preflight, then device / scenario / target
make-bundle.sh          packs everything into a single self-extracting bst-tools.sh

cases/android/          the 8 Android scenarios, one script each
cases/ios/              the 2 iOS scenarios

lib/base.sh             paths, menu + number parsing — sourced first by everything
lib/devices.sh          device and platform detection, for both
lib/preflight.sh        the dependency report

lib/android/common.sh   the UI layer and the Magisk state engine
lib/android/mtmanager.sh   MT Manager helpers (cases 4, 5, 7, 8)
lib/android/device-ready.sh   keyguard
lib/android/emulator-extract.sh   case 8's extraction step
lib/android/py/         uifind.py (element lookup), u2driver.py (persistent uiautomator2
                        agent), emulator-case.py (case 8), app-info.py

lib/ios/device.sh       app inventory, install/uninstall, launch, the verdicts
lib/ios/ui.sh           the tap layer
lib/ios/py/iosdriver.py persistent frida driver
lib/ios/js/             uitree.js — reads and taps an iOS view tree; uitree.bundle.js is
                        the compiled form that ships, so running it needs no node
```

The split is along the device interface, not along the feature: nothing in `lib/android`
knows about frida or bundle ids, nothing in `lib/ios` knows about adb, and the three files
left in `lib/` are the ones both sides actually share. The platform a case belongs to is
its folder — `cases/$PLATFORM/*.sh` is what the menu lists, so adding a case is dropping a
file in, with a `# NAME:` line for its label.

## Notes

UI steps run through **uiautomator2**, which keeps a persistent agent on the device —
hierarchy dumps take ~0.23s instead of ~2s per call. Four tap helpers differ only in what
happens on a miss, which is the thing worth getting right: `ui_tap` taps from the caller's
existing snapshot, `ui_tap_fresh` dumps first, `ui_tap_when` retries and then shrugs
(cases 1–3 walk screens where a control's absence is itself a state), and `ui_tap_req`
retries and then fails loudly. Guard anything destructive with `ui_tap_req`.

The settles still matter: the state readers (`ui_checked`, `read_modules`) decide from a
snapshot, so a settle that is too short makes them read the screen the device has not
finished leaving. Speed comes from `DELAY_SCALE`, which is a knowing trade, not from
shortening settles behind your back.

Elements are located by `text`, `resource-id` or `content-desc` and tapped at their own
reported bounds, so **screen size and density need no tuning** — the few remaining
position filters are fractions of width/height, not pixel counts. A `--near-text` lookup
must land on that label's row, within twice its height, so it cannot silently grab a
different row's switch. Two couplings are not solved by any of that: every match is an
**English** UI string, and the `resource-id`s belong to Magisk, MT Manager and the system
installer, so a non-English device or an app update can still break a flow.

### The iOS tap layer

XCUITest is Apple's way to drive an app, and it needs testmanagerd to authorise the process
as a test runner — which only the `xcodebuild test` handshake grants. A sideloaded
WebDriverAgent therefore serves HTTP, presses hardware buttons, and sees no application at
all (`XCTDaemonErrorDomain 41`); TrollStore solves signing, not that authorisation. On a
jailbroken device frida is already inside the process, so `lib/ios/js/uitree.js` reads UIKit
directly — no certificate, no Apple tooling, nobody else's signing identity.

It does not synthesise a touch. iOS 16 removed what that needs (`UITouch` has no `_view`
any more, `UIApplication` no longer answers `_touchesEvent`), so each tap invokes the
handler the touch would have reached, and **reports which route fired** — so a caller can
tell a real action from a silent no-op. Routes, all proven on hardware: a `UIControl`
through the event it is actually registered for, a `UIBarButtonItem` through its own
target/action, a `UIMenu` entry through its handler (addressable before the menu is even
open), a `UIAlertController` button, a table or collection row through its delegate, a
segmented control through its selection, a tap recogniser, and anything SwiftUI through
`accessibilityActivate`. A view with nothing registered is a failure, not a tap.

SwiftUI needs that last route: its text is drawn into private views that carry no label and
exposed as accessibility elements instead, so a view-only walk saw TrollFools' app list as
182 views of which 17 said anything. The elements say `"Name, bundle.id, version"`, which is
how a row is found by bundle id rather than by display name.

Three limits are real. A file picker is a `UIDocumentPickerViewController` — a remote view
belonging to another process — so nothing inside the app can touch it; those steps ask for
the tap and say why. A share sheet draws a third-party app's name out of process, so
"TrollStore" is never text the app holds: case 4 taps the cell by what it does (hand the
file to an app) and then confirms TrollStore is the app that came to the front. And the
app under test is only ever **launched**, never injected into:
frida inside it would make its own RASP report the tester's tooling, which is worse than no
result at all.

Driving the real UI is deliberate. A shortcut over `adb shell` could leave an artefact the
app distinguishes from the real thing — and then the shortcut gets tested, not the defence.

To hand the suite to a colleague, run `./make-bundle.sh` and share the resulting
`bst-tools.sh`. It carries `run-scenarios.sh`, `lib/` and `cases/` only — no venv, no hooks,
no extracted APKs.
