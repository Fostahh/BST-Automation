#!/usr/bin/env python3
"""Print [package_id] versionName (versionCode) from the selected device."""
import re
import subprocess
import sys


def output(args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=30).stdout


def package_section(dump, package):
    # Avoid a historical/hidden package block or a component's metadata.
    match = re.search(r"(?m)^([ \t]*)Package \[" + re.escape(package) + r"\].*$", dump)
    if not match:
        return dump
    tail = dump[match.end():]
    end = re.search(r"(?m)^" + re.escape(match[1]) + r"\S", tail)
    return tail[:end.start()] if end else tail


def versions(dump, package):
    section = package_section(dump, package)
    name = re.search(r"(?m)^\s*versionName=([^\r\n]+)", section)
    code = re.search(r"(?m)^\s*versionCode=(\d+)", section)
    return (name[1].strip() if name else "unknown",
            code[1] if code else "unknown")


def main():
    serial, package = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+", package):
        print("WARN: invalid package id; app summary unavailable.", file=sys.stderr)
        return
    adb = ["adb", "-s", serial]
    name = code = "unknown"
    try:
        dump = output(adb + ["shell", "dumpsys", "package", package]).decode(errors="replace")
        name, code = versions(dump, package)
    except (OSError, subprocess.SubprocessError):
        pass
    # Metadata is informational: an unavailable field must not prevent the scenario.
    print(f"[{package}] {name} ({code})")


if __name__ == "__main__":
    main()
