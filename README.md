# BST Tools — Automation

A test harness for checking whether an Android app detects a compromised environment.

It does not attack the app. It automates building the **device states** an attacker would
use, launches the app, and lets the app's own RASP checks give the verdict. Done by hand,
each state takes about ten minutes of tapping and comes out slightly different every time —
which is exactly what makes manual results hard to trust.

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
paired to Xcode must not interrupt an Android run — and reports that no iOS scenarios
exist yet.

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

Every case ends by offering to launch the app again (`open <pkg> again? [y/N]`), as
often as you like. Detection can hinge on a cold start or on what the app cached last
run, and relaunching is far cheaper than re-running the scenario, which would re-apply
the device state and may reboot. Case 4 has its own richer version of this — it replays
the chosen frida hook without restarting the server.

Retrieved and patched APKs land in `extracted/` (or `$EXTRACTED_DIR`).

## Layout

```
run-scenarios.sh    intro + preflight, then platform / scenario / device / target
cases/              one script per scenario
lib/                base.sh (paths, menu + number parsing — sourced first by everything),
                    common.sh (UI layer, Magisk state engine), mtmanager.sh, preflight.sh,
                    devices.sh (device + platform detection), device-ready.sh (keyguard)
lib/py/             uifind.py (element lookup), u2driver.py (persistent uiautomator2 agent),
                    emulator-case.py (case 8), app-info.py
make-bundle.sh      packs everything into a single self-extracting bst-tools.sh
```

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

Driving the real UI is deliberate. A shortcut over `adb shell` could leave an artefact the
app distinguishes from the real thing — and then the shortcut gets tested, not the defence.

To hand the suite to a colleague, run `./make-bundle.sh` and share the resulting
`bst-tools.sh`. It carries `run-scenarios.sh`, `lib/` and `cases/` only — no venv, no hooks,
no extracted APKs.
