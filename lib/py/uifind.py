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
# --print : xy (default, "<cx> <cy>") | checked ("true"/"false") | both ("<cx> <cy> <checked>")
#
# Zero-area nodes are skipped: some labels report bounds [0,0][0,0] and would tap (0,0).
# Prints the chosen node and exits 0; exits 1 if nothing matches.
import re
import sys

args = sys.argv[1:]
xml_path = args.pop(0)
near = None
printmode = "xy"
rest = []
i = 0
while i < len(args):
    if args[i] == "--near-text":
        near = args[i + 1]; i += 2; continue
    if args[i] == "--print":
        printmode = args[i + 1]; i += 2; continue
    rest.append(args[i]); i += 1
preds = dict(p.split("=", 1) for p in rest)

xml = open(xml_path, encoding="utf-8", errors="replace").read()
nodes = re.findall(r"<node[^>]*?>", xml)


def attr(node, key):
    m = re.search(key + r'="([^"]*)"', node)
    return m.group(1) if m else ""


def center(node):
    m = re.search(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", attr(node, "bounds"))
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    if (x2 - x1) * (y2 - y1) <= 0:          # zero-area: not tappable
        return None
    return (x1 + x2) // 2, (y1 + y2) // 2


_CHECKS = (
    ("textequals",   lambda n, v: attr(n, "text") == v),
    ("textcontains", lambda n, v: v in attr(n, "text")),
    ("textprefix",   lambda n, v: attr(n, "text").startswith(v)),
    ("desccontains", lambda n, v: v in attr(n, "content-desc")),
    ("res",          lambda n, v: attr(n, "resource-id").endswith(v)),
    ("cls",          lambda n, v: attr(n, "class").endswith(v)),
    ("checked",      lambda n, v: attr(n, "checked") == v),
    ("checkable",    lambda n, v: attr(n, "checkable") == v),
    ("clickable",    lambda n, v: attr(n, "clickable") == v),
)


def matches(node, cx, cy):
    for key, test in _CHECKS:
        if key in preds and not test(node, preds[key]):
            return False
    if "miny" in preds and cy < int(preds["miny"]):
        return False
    if "maxy" in preds and cy > int(preds["maxy"]):
        return False
    if "minx" in preds and cx < int(preds["minx"]):
        return False
    if "maxx" in preds and cx > int(preds["maxx"]):
        return False
    return True


# anchor row: centre-y of the node whose text == --near-text
anchor_y = None
if near is not None:
    for node in nodes:
        if attr(node, "text") == near:
            c = center(node)
            if c:
                anchor_y = c[1]
                break
    if anchor_y is None:
        sys.exit(1)

best = None  # (distance, cx, cy, checked)
for node in nodes:
    c = center(node)
    if not c:
        continue
    cx, cy = c
    if not matches(node, cx, cy):
        continue
    if anchor_y is None:
        best = (0, cx, cy, attr(node, "checked"))
        break
    dist = abs(cy - anchor_y)
    if best is None or dist < best[0]:
        best = (dist, cx, cy, attr(node, "checked"))

if best is None:
    sys.exit(1)
_, cx, cy, chk = best
if printmode == "checked":
    print(chk)
elif printmode == "both":
    print(cx, cy, chk)
else:
    print(cx, cy)
