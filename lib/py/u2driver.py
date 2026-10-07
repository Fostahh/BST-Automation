#!/usr/bin/env python3
# u2driver.py <serial> — persistent uiautomator2 driver for the scenario scripts.
#
# Reading the UI tree with `uiautomator dump` costs ~2s (a fresh JVM each call).
# uiautomator2 keeps a server running on the device, so a hierarchy dump is ~0.2s.
# This process connects ONCE and then serves many dumps over stdin/stdout, so the
# bash scripts pay the connect cost only once per run.
#
# We use u2 ONLY for reads (dump). Taps stay on the shell side (`su -c input`),
# because MIUI blocks the agent's INJECT_EVENTS permission.
#
# Protocol (line-based):
#   stdin : "dump <path>"  -> write the current hierarchy XML to <path>
#           "quit" / EOF    -> exit
#   stdout: "READY" once, after a successful connect+probe;
#           then "OK" or "ERR <what>" for each command.
import sys

import uiautomator2 as u2


def out(s):
    sys.stdout.write(s + "\n")
    sys.stdout.flush()


serial = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None


def connect():
    return u2.connect(serial) if serial else u2.connect()


try:
    d = connect()
    d.dump_hierarchy()          # probe: confirms the agent actually serves dumps
except Exception as e:
    out("ERR connect %s" % type(e).__name__)
    sys.exit(1)
out("READY")

while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.rstrip("\n")
    if line in ("quit", ""):
        break
    if line.startswith("dump "):
        path = line[5:]
        xml = None
        for _ in range(3):                 # retry + reconnect on a transient u2 hiccup
            try:
                xml = d.dump_hierarchy()
                break
            except Exception:
                try:
                    d = connect()
                except Exception:
                    pass
        if xml is None:
            out("ERR dump")
            continue
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(xml)
            out("OK")
        except Exception:
            out("ERR write")
    else:
        out("ERR unknown")
