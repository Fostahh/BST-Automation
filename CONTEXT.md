# BST Tools Automation: Context

Last updated: 2026-10-29 · Contact: Mohammad Azri Khairuddin

## 1. What this is

A test harness that checks whether an **Android or iOS app detects a compromised
environment**. It does not attack the app. It builds the device state an attacker would use
(root, a hooking framework, a re-signed build, an injected dylib, an emulator), launches the
app, and lets **the app's own RASP checks give the verdict**.

Doing one state by hand takes about ten minutes of tapping, and it comes out slightly
different every time. Automating it makes the result reproducible no matter who is holding
the phone.

The apps belong to our clients, who gave written permission for security testing. Nothing
here is used outside that scope.

- **Run:** `./run-scenarios.sh`. It takes no arguments; every choice is prompted.
- **Full reference:** `README.md`, which has every environment variable, the requirements
  and the layout.
- **Hooks:** frida `.js` hooks are not in the repo. Bring your own for Android case 4: the
  case looks for folders of `.js` files and asks, or set `HOOK_DIR` to skip the question.
- **Bundle (optional):** `./make-bundle.sh` packs the runner, `lib/` and `cases/` into one
  `bst-tools.sh`, for someone who only needs to run it. It is not secret: anyone holding
  the file can unpack it.

## 2. Understanding

### 2.1 Scenarios

| Platform | # | Device state | Detection under test | Needs | Status |
|---|---|---|---|---|---|
| Android | 1 | Root present, all modules off, no hiding | Plain root | Root (Magisk) | Working |
| Android | 2 | Zygisk + LSPosed enabled | Xposed-family hooking | Root | Working |
| Android | 3 | Case 2 + Hide My Applist | Detection when the module list is hidden | Root | Working |
| Android | 4 | Version-matched frida-server + a chosen `.js` hook | Runtime instrumentation / anti-Frida | Root | Working |
| Android | 5 | `android-unpinner` rebuild (debuggable, pinning stripped) | Re-signed debuggable build, MITM | No root | Working |
| Android | 6 | App cloned into Super Clone / Parallel Space / GBox | App virtualisation | No root | **Todo** |
| Android | 7 | APK repackaged with a foreign certificate | Signature / integrity check | No root | Working |
| Android | 8 | Extracted APK/APKS on a clean emulator | Emulator detection | AVD (no phone needed in manual mode) | Working |
| iOS | 1 | Bootstrap + roothide | Jailbreak detection when jailbreak paths are randomised | Jailbreak (roothide Bootstrap) | **Todo** |
| iOS | 2 | Dopamine + vnodebypass | Jailbreak detection when jailbreak files are hidden | Jailbreak (Dopamine) | **Todo** |
| iOS | 3 | palera1n + Shadow | Jailbreak detection under Shadow's hiding | Jailbreak (palera1n) | **Todo** |
| iOS | 4 | TestFlight build decrypted with TrollDecrypt, reinstalled via TrollStore | Re-signed debuggable build | Jailbreak | Working end to end |
| iOS | 5 | A chosen dylib injected with TrollFools | Foreign dylib in the address space | Jailbreak | **In progress** |
| iOS | 6 | frida-server + a chosen `.js` hook | Runtime instrumentation / anti-Frida | Jailbreak | **Todo** |

- **Every Android device:** MT Manager must be installed and logged in.
- **iOS:** needs frida-server on the phone, a python that can `import frida`, and
  `libimobiledevice` on the Mac.
- **Test iPhone:** Dopamine jailbreak, iOS 16.0.

### 2.2 How a run flows

1. **Intro + preflight.** Prints a dependency report and offers to install what's missing
   (the uiautomator2 venv, the iOS tooling).
2. **Device → platform.** Nothing is asked that can be observed.
   - `adb` only sees Android, so an attached Android device settles the platform.
   - iOS is looked for only when no Android device is attached.
   - One device is selected silently; with several, the runner asks which.
3. **Scenario.** The menu lists `cases/<platform>/*.sh`, labelled from each file's
   `# NAME:` line.
4. **Speed.** Asks for `DELAY_SCALE`, or skips the question if it's already set.
5. **Case 8 branches off here.** It picks its own APK source and can run with no phone
   attached.
6. **Target app.**
   - `TARGET_PREFIX` is required. That's what keeps client package names out of the repo.
   - Installed apps matching the prefix are listed, and you pick one.
7. **Run the case.**
   - Android refuses to run against a locked screen.
   - The PIN is asked for in-process and never written to disk.
8. **Reopen loop.** Every case ends with `open <pkg> again? [y/N]`.
   - Detection can depend on a cold start or on what the app cached, and relaunching is far
     cheaper than re-running the scenario.
   - Android case 4 can also replay the hook.

### 2.3 Code map

| Path | Responsibility |
|---|---|
| `run-scenarios.sh` | The interactive runner |
| `make-bundle.sh` | Packs everything into the self-extracting `bst-tools.sh` |
| `lib/base.sh` | Paths, menu parsing, number validation, and the shared timing (`nap`, `DELAY_SCALE`, `NAP_*`, `TAP_RETRIES`) |
| `lib/devices.sh` | Device and platform detection |
| `lib/preflight.sh` | The dependency report |
| `lib/android/common.sh` | adb wrappers, the UI layer (`ui_dump`, `ui_find`, `ui_tap*`), the Magisk state engine |
| `lib/android/mtmanager.sh` | MT Manager helpers (cases 4, 5, 7, 8) |
| `lib/android/device-ready.sh` | Keyguard / PIN |
| `lib/android/emulator-extract.sh` | Case 8's extraction step |
| `lib/android/py/` | `uifind.py` (element lookup), `u2driver.py` (persistent uiautomator2 agent), `emulator-case.py`, `app-info.py` |
| `lib/ios/device.sh` | App inventory, install/uninstall, launch, the opening checks (`ios_general_rules`) |
| `lib/ios/ui.sh` | The iOS tap layer (`ios_tap_req`, `ios_find`, `ios_use_picker`, …) |
| `lib/ios/py/iosdriver.py` | Persistent frida driver; one process, commands over stdin |
| `lib/ios/js/uitree.js` | Reads and taps the iOS view tree. The compiled `uitree.bundle.js` is what ships. |
| `cases/android/`, `cases/ios/` | One script per scenario. To add a case, drop in a file with a `# NAME:` line. |

The split follows the device interface: nothing in `lib/android` knows about frida, and
nothing in `lib/ios` knows about adb.

### 2.4 Key mechanisms

| Mechanism | What it does | Where |
|---|---|---|
| Magisk state engine | Cases 1–3 are declarative: `apply_state <modules> <enforce-denylist> <target-in-denylist>`. It reads the current state, changes only what differs, reboots only if a module toggled, then re-verifies. The exit code is the verdict. | `common.sh` |
| uiautomator2 agent | A persistent agent on the device. A hierarchy dump takes ~0.23s instead of ~2s. | `u2driver.py` |
| Element lookup | Finds elements by `text`, `resource-id` or `content-desc` and taps them at their own bounds, so screen size and density need no tuning. A `--near-text` match must land on that label's own row. | `uifind.py` |
| Four Android tap helpers | They differ only in what happens on a miss:<br>• `ui_tap` uses the existing snapshot<br>• `ui_tap_fresh` dumps first<br>• `ui_tap_when` retries, then gives up quietly<br>• `ui_tap_req` retries, then fails loudly | `common.sh` |
| One timing model | `nap` = max(`NAP_MIN`, seconds × `DELAY_SCALE`), the same on both platforms. `NAP_MAX` is off by default. | `base.sh` |
| iOS taps through frida | XCUITest/WebDriverAgent can't drive another app on a sideloaded setup, so frida reads UIKit inside the *tool* app (TrollDecrypt, TrollStore, TrollFools). Each tap calls the handler a real touch would have reached and reports which route fired: control, bar button, menu, alert, table/collection row, segmented control, tap recogniser, or SwiftUI accessibility. A view with no handler counts as a failure. | `uitree.js` |
| iOS permission pre-grant | A hidden copy of Settings, started by path, grants every permission the app declares. No permission alert ever reaches SpringBoard, and the app under test is never injected. | `iosdriver.py` `grant` |
| iOS file picker | The picker runs in its own process (`com.apple.DocumentManager.Service`). The driver attaches there, lists the `.dylib` files, ticks one, taps Open, and checks that the picker closed. | `ui.sh` `ios_use_picker`, iOS case 5 |
| iOS evidence instead of questions | Model and iOS version come over lockdown. The installed build comes from the inventory (checked against `EXPECT_VERSION`). Launch is confirmed from the process list. The TrollFools log is printed into the run output. | `device.sh` |

**Rebuilding the iOS bundle:** after editing `uitree.js`, run
`cd lib/ios/js && npm run build` to regenerate `uitree.bundle.js`.

### 2.5 Known limits

| Limit | Why | Workaround |
|---|---|---|
| English-only UI strings | Every match is an English UI string | Keep test devices in English |
| `resource-id`s belong to Magisk, MT Manager and the system installer | An update to those apps can rename them | Fix the id in the lib or case. For module titles, set `MOD_ZNEXT` / `MOD_LSPOSED`. |
| iOS cannot synthesise a touch | iOS 16 removed the internals that needed (`UITouch._view`, `_touchesEvent`) | Call the handler directly; the route is reported |
| iOS share sheet | It draws third-party app names out of process | Case 4 taps the cell by what it does, then confirms TrollStore came to the front |
| SpringBoard is off-limits | Injecting it leads to Safe Mode (rule 3.1) | Pre-grant permissions from the hidden Settings copy; leave anything else to the operator |
| `devicectl` only sees iOS 17+ | Older iPhones don't appear in it | `libimobiledevice` over lockdown is used first |

## 3. Rules

### 3.1 Hard rules: never break these

| Rule | Why | What happens if broken |
|---|---|---|
| **Never inject frida into SpringBoard.** Not to read, not to tap, not "just once". | After frida detaches, the process keeps a stale exception hook pointing into frida's unmapped memory. The next ObjC exception, even one the code catches, crashes the process. | SpringBoard crashes minutes later and the phone goes into **Safe Mode**. Measured twice. |
| **The tap layer never injects frida into the app under test.** The only exception is the Hook scenarios (Android 4, iOS 6), where the injection *is* the state being tested. | Its RASP would report our tooling | The result tests frida, not the app's defence |
| **Ask before touching any system process.** | The same crash-after-detach applies to every process (Settings crashed 3 times) | Tool apps can take it because they get restarted; system processes can't |
| **No client identifiers, serials, PINs or device names in the repo** | `TARGET_PREFIX` is asked at run time; the PIN lives only in the running process | Client data leaks through git history or the shared bundle |
| **Never read a missing row as "off"** | An absent switch looks exactly like an "off" one, and "off" is case 1's target state | A false PASS without the module ever being seen. This has happened. |
| **Drive the real UI; no `adb shell` shortcuts to build a state** | A shortcut can leave an artefact the app can tell apart from the real thing | You end up testing the shortcut, not the defence |

### 3.2 Conventions

| Rule | Why | How to apply |
|---|---|---|
| **iOS mirrors Android** | One set of knobs and behaviours for both platforms | Before writing any iOS wait, poll or prompt, find the Android version and copy its shape and variable names (`nap`, `NAP_*`, `TAP_RETRIES`, `INSTALL_TIMEOUT` polled every 2s). Only diverge where iOS can't do the same, and say why in one line. |
| **The app is installed before the run** | The runner installs the target app first, on both platforms | "Not installed" is an error with a clear message, never a step. No TestFlight / Play Store flows inside a case. Checking it's the *right* build (`EXPECT_VERSION`) is still the harness's job. |
| **Guard destructive steps with `ui_tap_req` / `ios_tap_req`** | A missed tap has to stop the case, not carry on against the wrong screen | Use `ui_tap_when` only where a control being absent is itself a valid state |
| **Get speed from `DELAY_SCALE`, not shorter settles** | The state readers decide from a snapshot; too short a settle reads the previous screen | Don't trim `NAP_*`, and don't set `NAP_MAX` for the Magisk cases |
| **Don't ask what can be observed** | If the operator answers, the result depends on who is reading | Read it (lockdown, inventory, process list), or print the evidence into the log |
| **A tap must prove it landed** | Some taps report OK and do nothing (the file picker did this) | Check the effect: the screen changed, the picker closed, the app came to the front |

## 4. To-do

| Item | Status | Next step |
|---|---|---|
| iOS case 5: choosing the dylib in the file picker | **In progress, not committed.** The file gets ticked, but the picker stays open after Open, so the file never reaches TrollFools. | Debug on the phone: confirm the tick registers in the picker's selection before Open is tapped |
| Commit case 5, the `iosdriver.py` `list` command, the `uitree.js` fix and the README row | Waiting on the item above | Commit once a full case 5 run passes |
| **Android case 6: Virtual Environment** | **Todo.** Not working at all; don't use it yet. The script still appears in the runner's menu. | Find out where it fails, then fix it |
| **iOS case 1: Bootstrap + roothide** | **Todo** | • Confirm frida-server runs under roothide, because the tap layer depends on it<br>• Decide what the case *sets* and what it only *verifies*, following Android 1–3: read the state, change what differs, re-verify |
| **iOS case 2: Dopamine + vnodebypass** | **Todo** | **vnodebypass blocks every frida injection** (measured), so nothing frida-driven can run once it's on. Order: grant permissions (`ios_grant`) → turn on vnodebypass last → launch the app. The reopen loop must not need frida. The case should end by telling the operator to turn vnodebypass off. |
| **iOS case 3: palera1n + Shadow** | **Todo** | Confirm frida-server runs on palera1n; decide what to set vs. verify, same as case 1 |
| **iOS case 6: Hook** | **Todo** | • Mirror Android case 4: `HOOK_DIR`, `MODE` spawn/attach, and replaying the hook without restarting the server<br>• Caveat: after frida detaches, the app can crash on its next ObjC exception. That crash comes from frida, **not from RASP**, so kill the app and relaunch it cleanly before reading a verdict. |
| **Screen-record every run to the Mac** | **Todo** | • Start recording just before `bash "$TARGET"` in `run-scenarios.sh` and stop when the case returns, after the reopen loop. Save to `recordings/<date>_<platform>-case<N>_<pkg>.mp4`, kept out of git like `extracted/`.<br>• Android: scrcpy (new install). iOS: capture over USB the way QuickTime does (needs a small helper; ffmpeg is already installed).<br>• **Check first:** the client app's screens may record as black (secure screens on Android, blanking while captured on iOS). Android: `adb shell screenrecord --time-limit 10 /sdcard/t.mp4`. iOS: QuickTime → New Movie Recording → choose the iPhone.<br>• Make it opt-in (`RECORD=1`) and print `recording: on`, because the app can detect recording (Android 15, `UIScreen.isCaptured` on iOS), which could change the verdict.<br>• Android cases 2 and 3 reboot, which cuts the recording, so expect 2 files. Case 8 `exec`s away and would need to stop doing that. |
| Which device runs which jailbreak | Open | Probably one phone per jailbreak: Dopamine is the current test iPhone (iOS 16.0), and palera1n only runs on checkm8 devices (A11 or older) |
| `lib/base.sh:56`: `clean_path` drops every backslash | Known shortcut | Fix only if a path with a real backslash ever shows up |
| `lib/ios/js/uitree.js:534`: the window list scans the heap on every call | Known shortcut | If dumps get slow on a big app, only scan when the app's own window list looks empty |

## 5. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| frida fails on **every** app at once ("refused to load frida-agent"), the crash report says `KERN_CODESIGN_ERROR`, but `/var/jb` binaries still spawn | **vnodebypass is on**, for example left on after iOS case 2 | Turn vnodebypass off. Check this **first**. |
| iPhone is in Safe Mode after a run | Something injected SpringBoard | See rule 3.1; find what attached to SpringBoard |
| A tool app (Settings, TrollFools) crashes a while after a run | Same stale hook left by a frida detach | Expected for tool apps; restart the app |
| Cases 1–3 stop with "module not found" | Your Magisk build labels the modules differently | Set `MOD_ZNEXT` / `MOD_LSPOSED` |
| Magisk state is read wrong, or results are flaky | Settles too short for this device | Set `DELAY_SCALE=2` and leave `NAP_MAX` unset |
| "No third-party package matches" | Wrong `TARGET_PREFIX`, or the app isn't installed | Check the prefix; install the app first |
| iOS prints `verify: UNAVAILABLE` | No libimobiledevice, or devicectl on iOS < 17 | `brew install libimobiledevice ideviceinstaller` |
| iOS case 5: "the picker's folder has no .dylib" | The dylib isn't in the folder the picker opens | Put it there and run again |
| Buttons not found on some device | The device isn't in English | Switch the device language to English |
