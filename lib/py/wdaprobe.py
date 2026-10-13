#!/usr/bin/env python3
"""wdaprobe.py <bundleid> [...] — ask WebDriverAgent what it can see in an app.

This exists to answer one question before any iOS tap code gets written: do the apps
these scenarios drive — TrollStore, TrollDecrypt, TrollFools — label their controls?

An element with a label or name can be found the way the Android layer finds things, by
what it says. An element with neither can only be addressed by its position in the tree
("the third button"), which breaks the moment a list reorders or a row is added. That is
exactly the brittleness uifind.py was written to avoid, so it is worth knowing which
world we are in before building on it.

    ./wdaprobe.py                              read whatever is on screen now
    ./wdaprobe.py com.opa334.TrollStore        launch it first, then read

Prints every visible, enabled element with its type, label, name and rect, then a verdict
on how addressable the screen is.
"""
import json
import os
import sys
import urllib.error
import urllib.request

WDA = os.environ.get("WDA_URL", "http://localhost:8100").rstrip("/")
TIMEOUT = float(os.environ.get("WDA_TIMEOUT", "30"))


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        WDA + path, data=data, method=method,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode(errors="replace"))
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        try:
            return json.loads(body)
        except ValueError:
            raise SystemExit(f"wdaprobe: HTTP {error.code} from {path}: {body[:300]}")
    except (urllib.error.URLError, OSError) as error:
        raise SystemExit(
            f"wdaprobe: cannot reach WebDriverAgent at {WDA} ({error}).\n"
            f"  USB:   iproxy 8100 8100 &\n"
            f"  Wi-Fi: WDA_URL=http://<iphone-ip>:8100")


def open_session():
    """Start a session against whatever is on screen.

    Deliberately NOT `{"bundleId": ...}` in the capabilities. TrollStore, TrollDecrypt and
    TrollFools are registered as SYSTEM apps, and asking WDA to launch one that way hangs
    until the request times out. A bare session returns immediately, and the app can be
    brought up separately — or simply opened by hand, which is what the scenarios do."""
    reply = call("POST", "/session", {"capabilities": {"alwaysMatch": {}}})
    sid = reply.get("sessionId") or (reply.get("value") or {}).get("sessionId")
    if not sid:
        raise SystemExit(f"wdaprobe: no session: {json.dumps(reply)[:300]}")
    return sid


def launch(sid, bundle):
    """Bring an app to the foreground through WDA's own launch endpoint."""
    reply = call("POST", f"/session/{sid}/wda/apps/launch", {"bundleId": bundle})
    if reply.get("value") is not None and reply.get("status") not in (None, 0):
        raise SystemExit(f"wdaprobe: could not launch {bundle}: {json.dumps(reply)[:300]}")


def walk(node, depth=0, out=None):
    """Flatten the element tree, keeping only what a tap could actually land on."""
    out = [] if out is None else out
    if isinstance(node, dict):
        rect = node.get("rect") or {}
        visible = str(node.get("isVisible", node.get("visible", "1"))) in ("1", "true", "True")
        enabled = str(node.get("isEnabled", node.get("enabled", "1"))) in ("1", "true", "True")
        if visible and enabled and rect.get("width") and rect.get("height"):
            out.append({
                "depth": depth,
                "type": (node.get("type") or "?").replace("XCUIElementType", ""),
                "label": node.get("label") or "",
                "name": node.get("name") or "",
                "value": node.get("value") or "",
                "rect": rect,
            })
        for child in node.get("children") or []:
            walk(child, depth + 1, out)
    return out


def probe(bundle=None):
    title = bundle or "whatever is on screen"
    print(f"\n{'=' * 72}\n{title}\n{'=' * 72}")
    sid = open_session()
    try:
        if bundle:
            launch(sid, bundle)
        source = call("GET", f"/session/{sid}/source?format=json")
        tree = source.get("value")
        if isinstance(tree, str):
            raise SystemExit("wdaprobe: WDA returned XML, not JSON — append ?format=json")
        elements = walk(tree)
    finally:
        call("DELETE", f"/session/{sid}")

    if not elements:
        print("  nothing visible — is the app on screen and unlocked?")
        return

    print(f"  {'TYPE':<14} {'LABEL':<30} {'NAME':<24} RECT")
    for e in elements:
        r = e["rect"]
        if e["type"] in ("Application", "Window", "Other") and not (e["label"] or e["name"]):
            continue                                    # structural wrappers, not targets
        print(f"  {e['type']:<14} {e['label'][:29]:<30} {e['name'][:23]:<24} "
              f"{r['x']},{r['y']} {r['width']}x{r['height']}")

    # The verdict. Tappable types are the ones a scenario actually aims at.
    taps = [e for e in elements
            if e["type"] in ("Button", "Cell", "StaticText", "SwitchButton",
                             "TextField", "SecureTextField", "Link", "Image", "MenuItem")]
    named = [e for e in taps if e["label"] or e["name"]]
    print(f"\n  tappable elements: {len(taps)}")
    print(f"  with a label/name: {len(named)}")
    if not taps:
        print("  VERDICT: nothing tappable found on this screen.")
    elif len(named) == len(taps):
        print("  VERDICT: every tappable element is addressable by what it says.")
    elif len(named) >= len(taps) * 0.7:
        print("  VERDICT: mostly addressable; a few would need position-based matching.")
    else:
        print("  VERDICT: most controls are unlabelled — position-based matching only,")
        print("           which is the brittleness this suite avoids elsewhere.")


def main():
    status = call("GET", "/status").get("value", {})
    print(f"WebDriverAgent at {WDA}: ready={status.get('ready')} "
          f"iOS={(status.get('os') or {}).get('version')}")
    targets = sys.argv[1:]
    if not targets:
        probe()                      # no argument: read the current screen
    for bundle in targets:
        probe(bundle)


if __name__ == "__main__":
    main()
