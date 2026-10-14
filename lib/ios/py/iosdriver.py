#!/usr/bin/env python3
# iosdriver.py [udid] — persistent frida driver for the iOS scenarios.
#
# The iOS counterpart of u2driver.py, and it exists for the same reason: injecting into an
# app costs a few seconds, a case makes many lookups against the same app, so this process
# holds the session open and serves commands over stdin/stdout. The shell pays the inject
# cost once per app rather than once per tap.
#
# Protocol (line-based, mirroring u2driver.py so the shell side reads the same):
#   stdin : open   <bundleid>  restart the app and inject uitree; replaces any session
#           launch <bundleid>  bring the app up WITHOUT injecting anything into it
#           running <bundleid> is it running? (its pid, or ERR) — nothing is injected
#           url <url>          open a URL on the device (prefs:, itms-beta:, …)
#           state              is the screen on and unlocked?
#           service <name|app> point find/tap/dump at another process, or back at the app
#           find   <text>      how many visible views say <text>
#           scroll down|up|top page the list; ERR when it did not move
#           tap    <text>      tap the first one that responds
#           dump   <path>      write the whole visible tree to <path>, for a failed lookup
#           quit / EOF         exit
#   stdout: READY once the device answers; then "OK <detail>" or "ERR <what>" per command.
#
# `launch` exists so a case can start the app under test with nothing of ours inside it.
# Injecting frida into the app being tested would make its own RASP report frida — a
# detection the tester caused, which is worse than no result at all. The tap layer drives
# the TOOLS (TrollStore, TrollFools, TrollDecrypt); the app under test is only launched.
#
# No JSON crosses the pipe: the shell would have to parse it, and everything it needs fits
# in one line. The JSON stays between here and the injected script.
import json
import os
import sys
import time

try:
    import frida
except ImportError:
    print("ERR frida is not installed in this python", flush=True)
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
# The COMPILED bundle, not uitree.js: frida 17 dropped the ObjC bridge from its script
# runtime, so the script carries its own copy.  cd lib/ios/js && npm run build
SCRIPT = os.path.join(HERE, os.pardir, "js", "uitree.bundle.js")


def out(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def one_line(text):
    return " ".join(str(text).split())


# Launching an app, without putting anything inside SpringBoard.
#
# frida's own spawn() inserts a dylib before the process starts, which AMFI refuses for a
# TrollStore-installed app — the process is killed the moment it resumes. Attaching to a
# RUNNING app is fine, so the only problem is getting it running and foregrounded.
#
# frida is NEVER injected into SpringBoard. Measured 2026-10-14: after frida detaches, the
# process keeps a stale exception-unwinding hook into frida's unmapped code, so the next
# ObjC exception thrown there — even one the code would have caught, like accessibility's
# safeValueForKey: — jumps into nothing and crashes it. In SpringBoard that is a respring
# minutes after the script has gone, and two of those is Safe Mode. Settings crashed the
# same way. No script is small enough to be safe there.
#
# uiopen is the jailbreak's own command for this — part of uikittools, on every Procursus
# bootstrap — and frida-server runs as root, so it can simply be executed. Nothing is
# injected anywhere: a separate short-lived process asks SpringBoard to open the app
# through the supported path.
# Settings' own executable, spawned by path for `grant` — see Driver.grant.
PREFERENCES = "/Applications/Preferences.app/Preferences"

UIOPEN_PATHS = ("/var/jb/usr/bin/uiopen", "/usr/bin/uiopen", "/var/jb/usr/local/bin/uiopen")



class Driver:
    def __init__(self, udid):
        self.device = (frida.get_device(udid, timeout=10) if udid
                       else frida.get_usb_device(timeout=10))
        self.session = None
        self.script = None
        self.bundle = None
        self.service = None                  # a second UI process, e.g. the file picker
        self.service_session = None
        self.target = None                   # whichever of the two find/tap act on
        self._uiopen = None                  # the uiopen path, False once it is ruled out

    def close(self):
        if self.session is not None:
            try:
                self.session.detach()
            except Exception:
                pass
        self.session = self.script = None

    def app_pid(self, bundle):
        """The app's pid, 0 when installed but not running, None when not installed."""
        for app in self.device.enumerate_applications():
            if app.identifier == bundle:
                return app.pid or 0
        return None

    def _run_uiopen(self, args):
        if self._uiopen is False:
            return False
        for path in ([self._uiopen] if self._uiopen else UIOPEN_PATHS):
            try:
                self.device.resume(self.device.spawn([path] + args))
                self._uiopen = path
                return True
            except Exception:
                continue
        self._uiopen = False                 # no bootstrap uiopen
        return False

    def uiopen(self, bundle):
        """Ask the jailbreak to open the app. True when it did; nothing is injected."""
        return self._run_uiopen(["--bundleid", bundle])

    def _open_url(self, target):
        return self._run_uiopen([target])

    def launch(self, bundle, restart=False):
        """Foreground the app. rc is its pid. Nothing of ours goes inside it."""
        pid = self.app_pid(bundle)
        if pid is None:
            raise RuntimeError("%s is not installed on this device" % bundle)
        if restart and pid:
            try:
                self.device.kill(pid)
            except Exception:
                pass
            # Wait for it to actually go. SpringBoard refuses to launch an app whose
            # previous instance is still terminating, and answers 3 — which looked like a
            # missing app and was really just a race against the kill.
            for _ in range(20):
                if not self.app_pid(bundle):
                    break
                time.sleep(0.25)
        if not self.uiopen(bundle):
            raise RuntimeError("uiopen is not on this bootstrap (apt install uikittools)")
        for _ in range(30):                  # it is in the process list within a second
            time.sleep(0.5)
            pid = self.app_pid(bundle)
            if pid:
                return pid
        raise RuntimeError("%s did not come up after the launch request" % bundle)

    def open(self, bundle, restart=True):
        self.close()
        self.target = None                   # a picker from a previous app is not ours
        if restart:
            # Restart rather than foreground: a tool left on some sub-screen from an
            # earlier run would answer the first lookup from the wrong screen.
            pid = self.launch(bundle, restart=True)
        else:
            # `attach`: something else brought the app up — a share sheet handing it a
            # file — and a restart would throw away the very screen that hand-off opened.
            # Wait for it to be IN FRONT, not merely running: TrollStore sat suspended in
            # the background while the share sheet copied a 42 MB IPA into it, and an
            # injection into a suspended app never completes — the attach just hung.
            pid = 0
            for _ in range(60):
                front = self.device.get_frontmost_application()
                if front is not None and front.identifier == bundle:
                    pid = front.pid
                    break
                time.sleep(0.5)
            if not pid:
                raise RuntimeError("%s did not come to the front within 30s" % bundle)
        self.session = self.device.attach(pid)
        with open(SCRIPT) as handle:
            self.script = self.session.create_script(handle.read(), runtime="v8")
        self.script.load()
        self.bundle = bundle
        # Probe, so an app that dies on injection says so HERE. Without it the failure
        # surfaces as a mystery at the first tap, several steps later.
        try:
            views = len(self.call("dump").get("views", []))
        except frida.InvalidOperationError:
            self.close()
            raise RuntimeError("%s terminated when frida injected into it" % bundle)
        return "OK pid=%d views=%d" % (pid, views)

    # A file picker is not part of the app that opened it: it runs in
    # com.apple.DocumentManager.Service, and nothing inside the app can see or touch it —
    # the app holds only an empty _UIRemoteView. Attaching to that process directly makes
    # it an ordinary target: same walk, same tap routes. `service app` points back.
    def use_service(self, name):
        if name in ("app", "none", "-"):
            self.target = None
            if self.service is not None:
                try:
                    self.service_session.detach()
                except Exception:
                    pass
                self.service = self.service_session = None
            return "OK app"
        procs = [p for p in self.device.enumerate_processes() if p.name == name]
        if not procs:
            raise RuntimeError("%s is not running - is that screen actually open?" % name)
        session = self.device.attach(procs[-1].pid)
        with open(SCRIPT) as handle:
            script = session.create_script(handle.read(), runtime="v8")
        script.load()
        self.service_session = session
        self.service = self.target = script
        views = len(script.exports_sync.dump().get("views", []))
        return "OK pid=%d views=%d" % (procs[-1].pid, views)

    def call(self, name, *args):
        script = self.target or self.script
        if script is None:
            raise RuntimeError("no app open - send `open <bundleid>` first")
        result = getattr(script.exports_sync, name)(*args)
        if isinstance(result, dict) and result.get("error"):
            raise RuntimeError(result["error"])
        return result

    # Exact match first, then a substring match ONLY when it is unambiguous.
    #
    # A substring is what makes a lookup survive a row labelled
    # "JbDetector, 1.0 • com.example.app", and it is also how a short needle taps the
    # wrong thing: "OK" is inside half the strings on an alert. So a substring that
    # matches two DIFFERENT things on screen is an error, not a guess — the silent wrong
    # tap is the failure that makes UI automation worthless.
    #
    # Different things, not different nodes: a table row matches as the cell, as its
    # accessibility element and again as the label inside it. Those are one target drawn
    # at one place, and the walk returns the outermost first, so a match sitting inside
    # the first match's rectangle is the same thing seen again.
    @staticmethod
    def _inside(outer, inner):
        if not outer or not inner:
            return False
        return (inner["x"] >= outer["x"] - 1 and inner["y"] >= outer["y"] - 1
                and inner["x"] + inner["w"] <= outer["x"] + outer["w"] + 1
                and inner["y"] + inner["h"] <= outer["y"] + outer["h"] + 1)

    def resolve(self, needle):
        hits = self.call("find", {"equals": needle}).get("matches", [])
        if hits:
            return {"equals": needle}, hits, "exact"
        hits = self.call("find", {"contains": needle}).get("matches", [])
        if hits:
            elsewhere = [h for h in hits[1:]
                         if not self._inside(hits[0].get("rect"), h.get("rect"))]
            if not elsewhere:
                return {"contains": needle}, hits, "substring"
            others = sorted({one_line(self.said(h)) for h in [hits[0]] + elsewhere})
            raise RuntimeError("'%s' matches %d different things - be more specific: %s"
                               % (needle, len(others), "; ".join(others[:4])))
        raise RuntimeError("nothing on screen says '%s'" % needle)

    @staticmethod
    def said(node):
        return (node.get("label") or node.get("text") or node.get("ident")
                or node.get("cls", ""))

    def find(self, needle):
        """Is it on screen at all. Ambiguity is a TAP's problem — waiting for "any row of
        this list" must succeed precisely because there are many."""
        for mode in ("equals", "contains"):
            hits = self.call("find", {mode: needle}).get("matches", [])
            if hits:
                return "OK %d %s" % (len(hits), "exact" if mode == "equals" else "substring")
        raise RuntimeError("nothing on screen says '%s'" % needle)

    def tap(self, needle):
        want, hits, mode = self.resolve(needle)
        result = self.call("tap", want)
        if not result.get("tapped"):
            raise RuntimeError(result.get("reason", "nothing responded to the tap"))
        node = result.get("node", hits[0])
        # `how` names which route fired - control, gesture, segment, or an ancestor of the
        # matched view. A caller that logs it can tell a real action from a no-op.
        return "OK %s %s %s" % (result.get("how", "?"), mode, one_line(self.said(node)))

    def url(self, target):
        """Open a URL on the device. prefs:root=General&path=About puts Settings on the
        About pane — the same screen a tester would walk to, opened by the phone itself."""
        if not self._open_url(target):
            raise RuntimeError("uiopen is not on this bootstrap, so a URL cannot be opened")
        return "OK %s" % target

    def grant(self, bundle):
        """Grant <bundle> every permission it declares, from a HIDDEN copy of Settings.

        Settings holds the entitlements to change another app's permissions. Spawned by
        path — posix_spawn, not a launch through SpringBoard — it never gets a scene, and
        `hold` parks it before UIApplicationMain, so nothing appears and the app in front
        stays in front. Killed when done: the real Settings is never touched, and nothing
        frida leaves behind outlives this call."""
        pid = self.device.spawn([PREFERENCES])
        result = {}
        try:
            session = self.device.attach(pid)
            with open(SCRIPT) as handle:
                script = session.create_script(handle.read(), runtime="v8")
            script.load()
            script.exports_sync.hold()
            self.device.resume(pid)
            for _ in range(20):              # its frameworks are up within a moment
                time.sleep(0.5)
                result = script.exports_sync.grant(bundle)
                if not result.get("notReady"):
                    break
        finally:
            try:
                self.device.kill(pid)
            except Exception:
                pass
        if result.get("notReady"):
            raise RuntimeError("the hidden Settings never finished starting")
        if result.get("error"):
            raise RuntimeError(result["error"])
        if result.get("failed"):
            raise RuntimeError("granted %s; could not grant %s" % (
                ", ".join(result.get("granted", [])) or "nothing",
                ", ".join(result["failed"])))
        return "OK %s" % (", ".join(result.get("granted", [])) or "nothing declared")

    def front(self, bundle):
        """OK when <bundle> is the app on screen. Read from the device, nothing injected."""
        app = self.device.get_frontmost_application()
        if app is None or app.identifier != bundle:
            raise RuntimeError("%s is in front, not %s"
                               % (app.identifier if app else "nothing", bundle))
        return "OK pid=%d" % app.pid

    def running(self, bundle):
        pid = self.app_pid(bundle)
        if pid is None:
            raise RuntimeError("%s is not installed on this device" % bundle)
        if not pid:
            raise RuntimeError("%s is installed but not running" % bundle)
        return "OK pid=%d" % pid

    def scroll(self, direction):
        result = self.call("scroll", direction)
        if not result.get("scrolled"):
            raise RuntimeError(result.get("reason")
                               or "the list did not move - already at the %s"
                               % ("top" if direction == "up" else "end"))
        return "OK y=%s end=%s" % (result.get("y"), result.get("end"))

    def dump(self, path):
        result = self.call("dump")
        views = result.get("views", [])
        with open(path, "w") as handle:
            handle.write("# %s - %d visible views\n" % (result.get("bundle", "?"), len(views)))
            for view in views:
                rect = view.get("rect") or {}
                said = view.get("label") or view.get("text") or view.get("ident") or ""
                handle.write("%s%-34s %-38s %s,%s %sx%s\n" % (
                    "  " * min(view.get("depth", 0), 12), view.get("cls", "?")[:34],
                    one_line(said)[:38], rect.get("x"), rect.get("y"),
                    rect.get("w"), rect.get("h")))
        return "OK %d" % len(views)


def main():
    udid = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        driver = Driver(udid)
    except Exception as error:
        out("ERR cannot reach the device: %s" % one_line(error))
        return 1
    out("READY")

    verbs = {"open": driver.open, "attach": lambda b: driver.open(b, restart=False),
             "find": driver.find, "tap": driver.tap,
             "dump": driver.dump, "scroll": driver.scroll,
             "running": driver.running, "front": driver.front, "grant": driver.grant, "url": driver.url,
             "service": driver.use_service,
             "launch": lambda b: "OK pid=%d" % driver.launch(b)}
    # readline(), not `for line in sys.stdin`: the iterator protocol reads ahead, and the
    # first command after startup intermittently went unseen. u2driver.py uses the same
    # idiom for the same reason.
    while True:
        line = sys.stdin.readline()
        if not line:                         # EOF
            break
        line = line.strip()
        if not line or line == "quit":
            break
        verb, _, rest = line.partition(" ")
        try:
            if verb not in verbs:
                raise RuntimeError("unknown command: %s" % verb)
            rest = rest.strip()
            if not rest:
                raise RuntimeError("%s needs an argument" % verb)
            out(verbs[verb](rest))
        except Exception as error:
            # Never exit on a bad command. The shell reads ERR as a failed step and falls
            # back to asking the operator; a dead driver would end the whole scenario.
            out("ERR %s" % one_line(error))

    driver.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
