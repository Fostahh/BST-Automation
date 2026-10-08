#!/usr/bin/env python3
"""Case 8: prepare an APK set while an Android Studio AVD starts, then install."""
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import zipfile

PYLIB = Path(__file__).resolve().parent        # Automation/lib/py
LIB = PYLIB.parent                            # Automation/lib (the .sh helpers)
# Same tree as lib/base.sh: BST_ROOT holds Automation/ and the author's fridaenv/.
# run-scenarios.sh exports it; the fallback keeps a direct `python3 emulator-case.py` working.
BST_ROOT = Path(os.environ.get("BST_ROOT") or LIB.parents[1])


def _nap(seconds):
    """Mirror common.sh nap(): scale by DELAY_SCALE, floor at NAP_MIN, cap only if
    NAP_MAX is set (it is unset by default — a capped settle lets the next UI read
    land on the previous screen)."""
    try:
        scale = float(os.environ.get("DELAY_SCALE", "1") or 1)
        lo = float(os.environ.get("NAP_MIN", "0.3") or 0.3)
        hi = float(os.environ.get("NAP_MAX", "") or 0)
    except ValueError:
        scale, lo, hi = 1.0, 0.3, 0.0
    value = max(seconds * scale, lo)
    return min(value, hi) if hi > 0 else value


def run(args, timeout=30):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        detail = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
        raise RuntimeError(detail or f"Command failed: {args[0]}")
    return result.stdout.strip()


def adb(serial, *args, timeout=30):
    return run(["adb", "-s", serial, *args], timeout)


def choose(items, prompt):
    for index, item in enumerate(items, 1):
        print(f"  {index}) {item}")
    while True:
        answer = input(prompt).strip()
        if answer.isdigit() and 1 <= int(answer) <= len(items):
            return items[int(answer) - 1]
        if answer in items:
            return answer
        print("Choose a listed number or name.")


def source_mode():
    if os.environ.get("APK"):
        return "manual"
    mode = os.environ.get("APK_SOURCE", "").lower()
    if mode:
        if mode not in ("manual", "auto"):
            raise RuntimeError("APK_SOURCE must be manual or auto.")
        return mode
    return {"Manual": "manual", "Automatic": "auto"}[
        choose(["Manual", "Automatic"], "APK/APKS source: ")]


def find_emulator():
    override = os.environ.get("EMULATOR")
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    candidates = ([override] if override else [
        shutil.which("emulator"),
        str(Path(sdk) / "emulator/emulator") if sdk else None,
        str(Path.home() / "Library/Android/sdk/emulator/emulator"),
    ])
    for path in candidates:
        if path and os.access(path, os.X_OK):
            return path
    raise RuntimeError("No Android emulator is installed. Case 8 stopped.")


def find_aapt():
    override = os.environ.get("AAPT2")
    platform = "darwin" if sys.platform == "darwin" else "linux"
    # android-unpinner ships aapt2 itself, so an installed copy means no Android SDK needed.
    try:
        import android_unpinner
        packaged = str(Path(android_unpinner.__file__).parent / f"vendor/build_tools/{platform}/aapt2")
    except Exception:
        packaged = None
    bundled = BST_ROOT / f"fridaenv/android-unpinner/android_unpinner/vendor/build_tools/{platform}/aapt2"
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
               or Path.home() / "Library/Android/sdk")
    candidates = ([override] if override else [shutil.which("aapt2"), packaged, str(bundled),
                  *[str(p) for p in sorted((sdk / "build-tools").glob("*/aapt2"), reverse=True)]])
    for path in candidates:
        if path and os.access(path, os.X_OK):
            return path
    raise RuntimeError("aapt2 is required to identify the APK package. Set AAPT2 to its path.")


def running_avd(name):
    for line in run(["adb", "devices"]).splitlines()[1:]:
        fields = line.split()
        if len(fields) < 2 or fields[1] != "device" or not fields[0].startswith("emulator-"):
            continue
        try:
            if adb(fields[0], "emu", "avd", "name").splitlines()[0] == name:
                return fields[0]
        except (RuntimeError, subprocess.TimeoutExpired):
            continue
    return None


def free_emulator_port():
    occupied = {line.split()[0] for line in run(["adb", "devices"]).splitlines()[1:] if line.split()}
    for port in range(5554, 5682, 2):
        if f"emulator-{port}" in occupied:
            continue
        sockets = []
        try:
            for number in (port, port + 1):
                sock = socket.socket()
                sockets.append(sock)
                sock.bind(("127.0.0.1", number))
            return port
        except OSError:
            continue
        finally:
            for sock in sockets:
                sock.close()
    raise RuntimeError("No free emulator console/ADB port pair was found.")


def start_emulator(executable, name):
    serial = running_avd(name)
    if serial:
        print(f"Using running emulator: {name} ({serial})")
        return serial, None, None
    port = free_emulator_port()
    fd, log = tempfile.mkstemp(prefix="bst-emulator-", suffix=".log")
    with os.fdopen(fd, "w") as stream:
        process = subprocess.Popen([executable, "-avd", name, "-port", str(port)],
                                   stdout=stream, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
    print(f"Starting {name} (emulator-{port}) in parallel with APK preparation.")
    print(f"Emulator log: {log}")
    return f"emulator-{port}", process, log


def wait_for_emulator(serial, name, process, log, timeout):
    deadline = time.monotonic() + timeout
    print(f"Waiting for {name} to finish booting ...")
    while time.monotonic() < deadline:
        if process and process.poll() is not None:
            raise RuntimeError(f"Emulator exited before installation. See {log}")
        try:
            if adb(serial, "shell", "getprop", "sys.boot_completed", timeout=10) == "1":
                actual = adb(serial, "emu", "avd", "name", timeout=10).splitlines()[0]
                if actual != name:
                    raise RuntimeError(f"Emulator identity changed: expected {name}, found {actual}.")
                if adb(serial, "shell", "pm", "path", "--user", "current", "android", timeout=10).startswith("package:"):
                    print(f"Emulator ready: {serial}")
                    return
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        time.sleep(_nap(2))
    raise RuntimeError(f"Emulator boot timed out after {timeout}s. Log: {log or 'existing emulator'}")


def attached_phones():
    """Physical Android serials in `device` state. The emulator this case starts shows up
    in `adb devices` too, so exclude anything named emulator-*."""
    found = []
    for line in run(["adb", "devices"]).splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "device" and not fields[0].startswith("emulator-"):
            found.append(fields[0])
    return found


def auto_source(directory):
    # The runner picks the device and exports DEV_SERIAL; this used to source devices.sh
    # through two separate `bash -c` calls to resolve a profile name that no longer exists.
    serial = os.environ.get("DEV_SERIAL", "")
    if serial.startswith("emulator-"):
        raise RuntimeError("Automatic source needs a physical phone, not an emulator.")
    if not serial:
        phones = attached_phones()
        if not phones:
            raise RuntimeError("Automatic source needs a phone attached; none is. "
                               "Use manual mode with a local APK instead.")
        serial = phones[0] if len(phones) == 1 else choose(phones, "Source phone: ")
    if adb(serial, "get-state") != "device":
        raise RuntimeError(f"Source phone {serial} is not connected.")
    name = serial
    package = os.environ.get("TARGET_PKG", "")
    if package in ("", "-"):
        # -3 lists third-party packages only; TARGET_PREFIX narrows that to one namespace.
        # An unscoped list can enumerate restricted work/secure profiles (e.g. user 150),
        # so match the foreground Android user whose MT Manager UI performs extraction.
        # Asked at run time so no client namespace has to live in the repo; an exported
        # TARGET_PREFIX (even empty) skips the question.
        prefix = os.environ.get("TARGET_PREFIX")
        if prefix is None:
            prefix = input("Target package prefix (blank = all third-party apps): ").strip().rstrip("*")
        prefix = "package:" + prefix
        packages = sorted({line[8:] for line in adb(serial, "shell", "pm", "list", "packages", "-3", "--user", "current").splitlines()
                           if line.startswith(prefix)})
        for index, item in enumerate(packages, 1):
            print(f"  {index}) {item}")
        while True:
            package = input("Target app number or package id: ").strip()
            if package.isdigit():
                if 1 <= int(package) <= len(packages):
                    package = packages[int(package) - 1]
                    break
                print("Invalid app number.")
            elif re.fullmatch(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+", package):
                break
    if not re.fullmatch(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+", package):
        raise RuntimeError("Invalid target package id.")
    if not adb(serial, "shell", "pm", "path", "--user", "current", package).startswith("package:"):
        raise RuntimeError(f"{package} is not installed on {name}.")
    subprocess.run([sys.executable, str(PYLIB / "app-info.py"), serial, package], check=True)
    subprocess.run(["bash", str(LIB / "emulator-extract.sh"), serial, package, str(directory)],
                   check=True, timeout=600)
    return Path((directory / "source-path.txt").read_text().strip()), package


def prepare_apks(source, directory):
    if source.suffix.lower() == ".apk":
        return [source]
    if source.suffix.lower() != ".apks":
        raise RuntimeError("Choose an .apk or .apks file.")
    print("Unzipping APKS ...")
    files = []
    with zipfile.ZipFile(source) as archive:
        entries = [entry for entry in archive.infolist()
                   if not entry.is_dir() and entry.filename.lower().endswith(".apk")]
        if not entries:
            raise RuntimeError("APKS archive contains no APK files.")
        if sum(entry.file_size for entry in entries) > 8 * 1024 ** 3:
            raise RuntimeError("APKS extracted size exceeds 8 GiB.")
        # Flatten into fresh filenames: archive paths cannot escape the temporary directory.
        for index, entry in enumerate(entries):
            dest = directory / f"split-{index:04d}.apk"
            with archive.open(entry) as reader, dest.open("wb") as writer:
                shutil.copyfileobj(reader, writer)
            files.append(dest)
    return files


def inspect_apks(aapt, files):
    records = []
    for path in files:
        badging = run([aapt, "dump", "badging", path])
        line = next((line for line in badging.splitlines() if line.startswith("package:")), "")
        fields = dict(re.findall(r"(\w+)='([^']*)'", line))
        if not re.fullmatch(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+", fields.get("name", "")) or not fields.get("versionCode", "").isdigit():
            raise RuntimeError(f"Cannot identify APK: {path.name}")
        native = re.search(r"(?m)^native-code:(.*)$", badging)
        records.append((path, fields, set(re.findall(r"'([^']+)'", native[1])) if native else set()))
    packages = {(fields["name"], fields["versionCode"]) for _, fields, _ in records}
    bases = [r for r in records if not r[1].get("split")]
    splits = [r[1]["split"] for r in records if r[1].get("split")]
    if len(packages) != 1 or len(bases) != 1 or len(splits) != len(set(splits)):
        raise RuntimeError("APKS must contain one compatible base/split set for the same package/version; mixed variants are unsupported.")
    ordered = bases + [r for r in records if r[1].get("split")]
    fields = bases[0][1]
    return [r[0] for r in ordered], fields, set().union(*(r[2] for r in records))


def install_and_launch(serial, files, info, is_bundle, native):
    supported = set(adb(serial, "shell", "getprop", "ro.product.cpu.abilist").split(","))
    if native and not native.intersection(supported):
        raise RuntimeError(f"APK ABI {sorted(native)} does not match emulator {sorted(supported)}. Existing app was not uninstalled.")
    package = info["name"]
    installed = adb(serial, "shell", "pm", "list", "packages", "--user", "current", package).splitlines()
    if f"package:{package}" in installed:
        print(f"Uninstalling {package} from {serial} (clears emulator app data) ...")
        result = adb(serial, "uninstall", package, timeout=120)
        if "Success" not in result or f"package:{package}" in adb(serial, "shell", "pm", "list", "packages", "--user", "current", package).splitlines():
            raise RuntimeError(f"Could not uninstall {package} from the emulator.")
    operation = "install-multiple" if is_bundle else "install"
    print(f"Installing on {serial} using adb {operation} ...")
    result = adb(serial, operation, "--no-incremental", *map(str, files), timeout=600)
    if "Success" not in result:
        raise RuntimeError(f"Installation did not report success: {result}")
    if not adb(serial, "shell", "pm", "path", "--user", "current", package).startswith("package:"):
        raise RuntimeError("Installed package could not be verified.")
    adb(serial, "shell", "input", "keyevent", "224")
    adb(serial, "shell", "wm", "dismiss-keyguard")
    print(f"Launching {package} inside {serial} ...")
    adb(serial, "shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1")
    print("Case 8 complete: clean install and launch requested. Emulator left running.")


def main():
    mode = source_mode()
    emulator = find_emulator()
    avds = [line for line in run([emulator, "-list-avds"]).splitlines() if line.strip()]
    if not avds:
        raise RuntimeError("No configured Android virtual devices. Case 8 stopped.")
    name = os.environ.get("AVD") or (avds[0] if len(avds) == 1 else choose(avds, "Emulator: "))
    if name not in avds:
        raise RuntimeError(f"AVD {name!r} is not configured. Available: {', '.join(avds)}")
    timeout = int(os.environ.get("BOOT_TIMEOUT", "300"))
    if timeout <= 0:
        raise RuntimeError("BOOT_TIMEOUT must be positive.")
    aapt = find_aapt()
    serial, process, log = start_emulator(emulator, name)
    with tempfile.TemporaryDirectory(prefix="bst-case8-") as directory:
        directory = Path(directory)
        expected = None
        if mode == "manual":
            value = os.environ.get("APK") or input("Local APK/APKS path on this Mac: ").strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            source = Path(value).expanduser().resolve()
            if not source.is_file():
                raise RuntimeError(f"APK/APKS file not found: {source}")
        else:
            source, expected = auto_source(directory)
        files = prepare_apks(source, directory)
        files, info, native = inspect_apks(aapt, files)
        if expected and info["name"] != expected:
            raise RuntimeError("Extracted APK package differs from the selected source package.")
        print(f"[{info['name']}] {info.get('versionName', 'unknown')} ({info['versionCode']})")
        wait_for_emulator(serial, name, process, log, timeout)
        install_and_launch(serial, files, info, source.suffix.lower() == ".apks", native)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, zipfile.BadZipFile, subprocess.SubprocessError, EOFError) as error:
        print(f"!! Case 8 stopped: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nCase 8 interrupted. Any started emulator remains open.", file=sys.stderr)
        sys.exit(130)
