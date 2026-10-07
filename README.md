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

## Requirements

On the Mac: `adb`, `python3`, plus `frida` (case 4), `android-unpinner` (case 5, also supplies
`aapt2`), and the Android emulator with an AVD (case 8). `uiautomator2` is installed
automatically into a private venv on first run.

On every test device: MT Manager installed and logged in. Cases 1–4 need root (Magisk);
cases 5–8 do not.

## Usage

```bash
./run-scenarios.sh                            # interactive: device, scenario, target app
./run-scenarios.sh device1 1 com.example.app     # device profile, scenario number, package
./run-scenarios.sh device1 1 -                   # run the scenario, open nothing
```

Useful environment variables:

| Variable | Effect |
|----------|--------|
| `HOOK_DIR` | folder of `.js` frida hooks for case 4 (otherwise auto-detected, then prompted) |
| `DELAY_SCALE` | UI delay multiplier for cases 1–3 (`0.5` = faster; a floor always applies) |
| `MODE` | `spawn` (default) or `attach` for case 4 |
| `TARGET_PREFIX` | narrow the interactive app list to one package namespace |
| `SKIP_PREFLIGHT` | skip the dependency checks |

Retrieved and patched APKs land in `extracted/` (or `$EXTRACTED_DIR`).

## Layout

```
run-scenarios.sh    device + scenario picker, target app selection
cases/              one script per scenario
lib/                common.sh (UI layer, Magisk state engine), mtmanager.sh, preflight.sh
lib/py/             uifind.py (element lookup), u2driver.py (persistent uiautomator2 agent),
                    emulator-case.py (case 8), app-info.py
make-bundle.sh      packs everything into a single self-extracting bst-tools.sh
```

## Notes

UI steps run through **uiautomator2**, which keeps a persistent agent on the device —
hierarchy dumps take ~0.23s instead of ~2s per call. Elements are located by `text`,
`resource-id` or `content-desc`, never by coordinates, so the same script runs on any
screen size without per-device tuning.

Driving the real UI is deliberate. A shortcut over `adb shell` could leave an artefact the
app distinguishes from the real thing — and then the shortcut gets tested, not the defence.

To hand the suite to a colleague, run `./make-bundle.sh` and share the resulting
`bst-tools.sh`. It carries `run-scenarios.sh`, `lib/` and `cases/` only — no venv, no hooks,
no extracted APKs.
