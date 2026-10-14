#!/usr/bin/env python3
# uifind.py — the single finder for a `uiautomator dump` XML (u2 produces the same format).
# Locates a node by text / resource-id / class instead of fixed coordinates, so taps and
# state reads survive layout and resolution changes.
#
#   uifind.py <dump.xml> [--near-text LABEL] [--print xy|checked|both] KEY=VAL ...
#
# Predicates (all must match):
#   textequals=<s>    text == s                desccontains=<s>  s in content-desc
#   textcontains=<s>  s in text                res=<s>           resource-id endswith s
#   textprefix=<s>    text startswith s        cls=<s>           class endswith s
#   checked=<bool>    checked == true/false    checkable=<bool>  checkable == true/false
#   clickable=<bool>  clickable == true/false
#   miny=<n> maxy=<n> centre-y within [miny, maxy]
#   minx=<n> maxx=<n> centre-x within [minx, maxx]
#
# --near-text LABEL : among the matches, pick the one whose centre-y is closest to the node
#   whose text == LABEL — i.e. the control sitting on that label's row (a switch next to
#   "Enforce DenyList", the value beside "Scheme", the checkbox beside a package name).
#   The match must be ON that row: its centre-y has to fall within twice the label's own
#   height. Without that cap the "nearest" match could be any distance away, so asking
#   for the switch beside "Zygisk Next" would happily return a DIFFERENT module's switch
#   hundreds of pixels down the list — reading, then toggling, the wrong row, with
#   nothing in the output to show it. Deriving the cap from the label's own height keeps
#   it resolution-independent; --near-max overrides it in pixels.
#   Every node whose text == LABEL is an anchor, so a label that appears twice cannot
#   pin the search to the wrong copy.
# --print : xy (default, "<cx> <cy>") | checked ("true"/"false") | both ("<cx> <cy> <checked>")
#           | text (the node's own text, decoded — for scraping a value off a dialog)
# --near-max N : override the --near-text row cap, in pixels.
#
# Zero-area nodes are skipped: some labels report bounds [0,0][0,0] and would tap (0,0).
# Prints the chosen node and exits 0; exits 1 if nothing matches.
#
# Parsed with ElementTree, not regex over the raw text, so attribute values arrive
# DECODED. A label the screen shows as `Tom & Jerry` is written `text="Tom &amp; Jerry"`
# in the dump: matching the raw form meant textequals='Tom & Jerry' could never hit, and
# any label containing & < > " was unreachable by the text the tester actually sees.
# A malformed dump (uiautomator can emit a truncated file off a busy screen) exits 1 with
# a note on stderr; every caller sits in a re-dump/retry loop, so that self-heals.
import re
import sys
import xml.etree.ElementTree as ET

BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def die(message):
    print(f"uifind: {message}", file=sys.stderr)
    sys.exit(1)


def parse_args(argv):
    if not argv:
        die("usage: uifind.py <dump.xml> [--near-text LABEL] [--print MODE] KEY=VAL ...")
    path = argv.pop(0)
    near = None
    near_max = None
    printmode = "xy"
    preds = {}
    index = 0
    while index < len(argv):
        token = argv[index]
        if token in ("--near-text", "--print", "--near-max"):
            if index + 1 >= len(argv):
                die(f"{token} needs a value")
            value = argv[index + 1]
            if token == "--near-text":
                near = value
            elif token == "--print":
                printmode = value
            else:
                try:
                    near_max = int(value)
                except ValueError:
                    die(f"--near-max must be an integer (got {value!r})")
            index += 2
            continue
        if "=" not in token:
            die(f"predicate {token!r} is not KEY=VALUE")
        key, value = token.split("=", 1)
        if key not in CHECKS and key not in RANGES:
            die(f"unknown predicate {key!r}")
        preds[key] = value
        index += 1
    if printmode not in ("xy", "checked", "both", "text"):
        die(f"--print must be xy, checked, both or text (got {printmode!r})")
    return path, near, near_max, printmode, preds


def box(node):
    """(x1, y1, x2, y2), or None for a missing or zero-area box (never tappable)."""
    found = BOUNDS.search(node.get("bounds", ""))
    if not found:
        return None
    x1, y1, x2, y2 = map(int, found.groups())
    if (x2 - x1) * (y2 - y1) <= 0:          # zero-area: not tappable
        return None
    return x1, y1, x2, y2


def center(node):
    found = box(node)
    if found is None:
        return None
    x1, y1, x2, y2 = found
    return (x1 + x2) // 2, (y1 + y2) // 2


def text_of(node, attribute):
    return node.get(attribute) or ""


CHECKS = {
    "textequals":   lambda n, v: text_of(n, "text") == v,
    "textcontains": lambda n, v: v in text_of(n, "text"),
    "textprefix":   lambda n, v: text_of(n, "text").startswith(v),
    "desccontains": lambda n, v: v in text_of(n, "content-desc"),
    "res":          lambda n, v: text_of(n, "resource-id").endswith(v),
    "cls":          lambda n, v: text_of(n, "class").endswith(v),
    "checked":      lambda n, v: text_of(n, "checked") == v,
    "checkable":    lambda n, v: text_of(n, "checkable") == v,
    "clickable":    lambda n, v: text_of(n, "clickable") == v,
}
# centre-point windows, used to disambiguate panes and to keep a match off the title bar
RANGES = {"minx": ("x", min), "maxx": ("x", max),
          "miny": ("y", min), "maxy": ("y", max)}


def matches(node, cx, cy, preds):
    for key, test in CHECKS.items():
        if key in preds and not test(node, preds[key]):
            return False
    for key, (axis, kind) in RANGES.items():
        if key not in preds:
            continue
        try:
            bound = int(preds[key])
        except ValueError:
            die(f"{key} must be an integer (got {preds[key]!r})")
        value = cx if axis == "x" else cy
        if kind is min and value < bound:
            return False
        if kind is max and value > bound:
            return False
    return True


def load_nodes(path):
    """Parse the dump into a list of <node> elements.

    A uiautomator hierarchy has no DTD: the framework serialises the view tree itself
    and escapes every attribute value, so an app can place text on screen but cannot
    inject document structure. Refusing a DOCTYPE outright keeps it that way, and costs
    nothing — it closes entity expansion (XXE, billion laughs) without pulling in
    defusedxml, which would become this suite's only non-optional dependency.
    """
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as error:
        die(f"unreadable dump {path}: {error}")
    if re.search(rb"<!\s*(DOCTYPE|ENTITY)", raw, re.I):
        die(f"refusing a dump carrying a DTD: {path}")
    try:
        return list(ET.fromstring(raw).iter("node"))
    except ET.ParseError as error:
        die(f"malformed dump {path}: {error}")


def row_distance(cy, anchors, near_max):
    """Distance to the nearest anchor row this node actually sits on, else None."""
    best = None
    for anchor_cy, anchor_height in anchors:
        cap = near_max if near_max is not None else max(anchor_height * 2, 1)
        gap = abs(cy - anchor_cy)
        if gap <= cap and (best is None or gap < best):
            best = gap
    return best


def main():
    path, near, near_max, printmode, preds = parse_args(sys.argv[1:])
    nodes = load_nodes(path)

    # Every node whose text == --near-text is an anchor, each carrying its own height so
    # the row cap scales with the layout instead of a fixed pixel count.
    anchors = []
    if near is not None:
        for node in nodes:
            found = box(node)
            if found and text_of(node, "text") == near:
                _, y1, _, y2 = found
                anchors.append(((y1 + y2) // 2, y2 - y1))
        if not anchors:
            sys.exit(1)

    best = None                                  # (distance, cx, cy, checked, text)
    for node in nodes:
        point = center(node)
        if not point:
            continue
        cx, cy = point
        if not matches(node, cx, cy, preds):
            continue
        row = (cx, cy, text_of(node, "checked"), text_of(node, "text"))
        if not anchors:                          # no anchor: first match in document order
            best = (0, *row)
            break
        distance = row_distance(cy, anchors, near_max)
        if distance is None:                     # matches the predicates, but not on the row
            continue
        if best is None or distance < best[0]:
            best = (distance, *row)

    if best is None:
        sys.exit(1)
    _, cx, cy, checked, text = best
    if printmode == "checked":
        print(checked)
    elif printmode == "text":
        print(text)
    elif printmode == "both":
        print(cx, cy, checked)
    else:
        print(cx, cy)


if __name__ == "__main__":
    main()
