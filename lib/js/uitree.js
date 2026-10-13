// uitree.js — read an iOS app's on-screen view hierarchy, and tap it. Via frida.
//
// The iOS counterpart of `uiautomator dump` plus `input tap`. XCUITest is Apple's way to
// do this, but it needs testmanagerd to authorise the process as a test runner, which only
// the `xcodebuild test` handshake grants — so a sideloaded WebDriverAgent serves HTTP and
// presses hardware buttons yet sees no application at all, and getting further means a
// signing certificate. On a jailbroken device frida is already inside the process and can
// read UIKit directly, with no certificate and no Apple tooling in the path.
//
// Compiled, not loaded raw: frida 17 removed the ObjC bridge from the script runtime, so
// it has to be bundled in.  npm run build  ->  uitree.bundle.js
//
// The model is deliberately the same as the Android layer: find an element by what it
// SAYS, then act on where it actually is. No fixed coordinates anywhere.
import ObjC from 'frida-objc-bridge';

const NSNotFound = 0x7fffffffffffffff;  // eslint-disable-line no-unused-vars

function str(obj) {
  try {
    if (obj === null || typeof obj === 'undefined' || obj.isNull()) return '';
    return obj.toString();
  } catch (e) {
    return '';
  }
}

// A CGRect in window coordinates. convertRect:toView:nil is what makes the numbers
// comparable across the whole screen rather than relative to each parent view.
function rectOf(view) {
  try {
    const r = view.convertRect_toView_(view.bounds(), NULL);
    return {
      x: Math.round(r[0][0]), y: Math.round(r[0][1]),
      w: Math.round(r[1][0]), h: Math.round(r[1][1]),
    };
  } catch (e) {
    return null;
  }
}

function describe(view, depth) {
  const node = { depth, cls: view.$className, label: '', ident: '', text: '', enabled: true };
  try { node.label = str(view.accessibilityLabel()); } catch (e) { /* not accessible */ }
  try { node.ident = str(view.accessibilityIdentifier()); } catch (e) { /* ditto */ }
  // Whatever the control actually shows: a field's text, a button's title, a label's text.
  try {
    if (view.respondsToSelector_(ObjC.selector('text:')) || view.text) node.text = str(view.text());
  } catch (e) { /* no text */ }
  if (!node.text) {
    try { node.text = str(view.titleForState_(0)); } catch (e) { /* not a button */ }
  }
  if (!node.text) {
    try { node.text = str(view.title()); } catch (e) { /* no title */ }
  }
  try { node.enabled = view.isEnabled(); } catch (e) { /* not a control; assume usable */ }
  node.rect = rectOf(view);
  return node;
}

function onScreen(view) {
  try {
    if (view.isHidden()) return false;
    if (view.alpha() < 0.05) return false;
  } catch (e) { /* not a UIView */ }
  const r = rectOf(view);
  return !!(r && r.w > 0 && r.h > 0);
}

function walk(view, depth, out) {
  if (depth > 60 || !onScreen(view)) return;
  out.push(describe(view, depth));
  let kids;
  try { kids = view.subviews(); } catch (e) { return; }
  if (kids === null) return;
  const n = kids.count();
  for (let i = 0; i < n; i++) walk(kids.objectAtIndex_(i), depth + 1, out);
}

function collect() {
  const app = ObjC.classes.UIApplication.sharedApplication();
  const windows = app.windows();
  const out = [];
  for (let i = 0; i < windows.count(); i++) {
    const w = windows.objectAtIndex_(i);
    try { if (w.isHidden()) continue; } catch (e) { /* keep it */ }
    walk(w, 0, out);
  }
  return out;
}

// Tapping. Three attempts, in order of how faithfully they imitate a finger.
//
// Synthesising a UITouch and sending it through the application's event queue is the
// textbook method, and it does not survive iOS 16: UITouch has no _view ivar any more
// (it is _responder), and UIApplication no longer answers _touchesEvent, so there is no
// event object to put a touch into. What remains is to invoke the same handler the touch
// would have reached.
//
// Every route reports which one fired, so a caller can tell a real action from a silent
// no-op — the failure that makes UI automation untrustworthy.

function fireGestures(view) {
  let recognisers;
  try { recognisers = view.gestureRecognizers(); } catch (e) { return null; }
  if (recognisers === null || recognisers.isNull()) return null;
  for (let i = 0; i < recognisers.count(); i++) {
    const g = recognisers.objectAtIndex_(i);
    try {
      if (!g.isEnabled()) continue;
      if (!g.isKindOfClass_(ObjC.classes.UITapGestureRecognizer)) continue;
      // A recogniser keeps its target/action pairs in _targets, each a
      // UIGestureRecognizerTarget holding _target and _action. Calling them is what
      // UIKit does the instant a tap is recognised.
      const targets = g.$ivars._targets;
      if (!targets || targets.isNull()) continue;
      for (let t = 0; t < targets.count(); t++) {
        const pair = targets.objectAtIndex_(t);
        const obj = pair.$ivars._target;
        const sel = pair.$ivars._action;
        if (obj && !obj.isNull()) {
          ObjC.Object(obj).performSelector_withObject_(sel, g);
        }
      }
      return 'gesture';
    } catch (e) { /* try the next recogniser */ }
  }
  return null;
}

// A segmented control does not act on a touch to one of its segments; it changes its
// selection and announces it. UISegment is a private subview, so the index has to be
// recovered from the parent before the control will agree it moved.
function tapSegment(view) {
  try {
    if (!/UISegment/.test(view.$className)) return null;
    let control = view.superview();
    for (let i = 0; i < 4 && control !== null && !control.isNull(); i++) {
      if (control.isKindOfClass_(ObjC.classes.UISegmentedControl)) {
        const subs = control.subviews();
        const wanted = view.$ivars ? null : null;   // index comes from geometry below
        let index = -1, seen = 0;
        const items = [];
        for (let k = 0; k < subs.count(); k++) {
          const sv = subs.objectAtIndex_(k);
          if (/UISegment$/.test(sv.$className)) items.push(sv);
        }
        items.sort((a, b) => a.frame()[0][0] - b.frame()[0][0]);
        for (let k = 0; k < items.length; k++) {
          if (items[k].handle.equals(view.handle)) { index = k; break; }
        }
        if (index < 0) return null;
        control.setSelectedSegmentIndex_(index);
        control.sendActionsForControlEvents_(1 << 12);   // UIControlEventValueChanged
        return 'segment';
      }
      control = control.superview();
    }
  } catch (e) { /* not a segment after all */ }
  return null;
}

function tapView(view, node) {
  const bySegment = tapSegment(view);
  if (bySegment !== null) return bySegment;

  // The view itself, then its ancestors: a label inside a button is what matched, but the
  // button is what responds.
  let node_ = view;
  for (let i = 0; i < 6 && node_ !== null && !node_.isNull(); i++) {
    try {
      if (node_.isKindOfClass_(ObjC.classes.UIControl) && node_.isEnabled()) {
        node_.sendActionsForControlEvents_(1 << 6);      // UIControlEventTouchUpInside
        return i === 0 ? 'control' : 'control(ancestor)';
      }
    } catch (e) { /* keep climbing */ }
    const byGesture = fireGestures(node_);
    if (byGesture !== null) return i === 0 ? 'gesture' : 'gesture(ancestor)';
    try { node_ = node_.superview(); } catch (e) { break; }
  }
  return null;
}

function matches(node, want) {
  const hay = [node.label, node.ident, node.text];
  if (want.equals !== undefined) return hay.some((h) => h === want.equals);
  if (want.contains !== undefined) {
    const needle = want.contains.toLowerCase();
    return hay.some((h) => h && h.toLowerCase().indexOf(needle) !== -1);
  }
  return false;
}

rpc.exports = {
  // dump : every visible view, for the probe and for debugging a failed lookup.
  dump: function () {
    if (!ObjC.available) return { error: 'no ObjC runtime in this process' };
    return {
      bundle: str(ObjC.classes.NSBundle.mainBundle().bundleIdentifier()),
      views: collect(),
    };
  },

  // find : the visible views matching {equals|contains}, nearest-first by tree order.
  find: function (want) {
    if (!ObjC.available) return { error: 'no ObjC runtime in this process' };
    return { matches: collect().filter((n) => matches(n, want)) };
  },

  // tap : act on the first match. Returns how it was tapped, so a caller can tell a real
  // action from a silent no-op — the failure mode that makes UI automation untrustworthy.
  tap: function (want) {
    if (!ObjC.available) return { error: 'no ObjC runtime in this process' };
    const app = ObjC.classes.UIApplication.sharedApplication();
    const windows = app.windows();
    for (let i = 0; i < windows.count(); i++) {
      const found = [];
      walk(windows.objectAtIndex_(i), 0, found);
      // walk() records descriptions, not views, so re-walk holding the objects themselves.
      const hits = [];
      (function rewalk(view, depth) {
        if (depth > 60 || !onScreen(view)) return;
        const node = describe(view, depth);
        if (matches(node, want)) hits.push({ view, node });
        let kids;
        try { kids = view.subviews(); } catch (e) { return; }
        if (kids === null) return;
        for (let k = 0; k < kids.count(); k++) rewalk(kids.objectAtIndex_(k), depth + 1);
      })(windows.objectAtIndex_(i), 0);

      for (const hit of hits) {
        if (!hit.node.enabled) continue;
        const how = tapView(hit.view, hit.node);
        if (how !== null) return { tapped: true, how, node: hit.node };
      }
      if (hits.length > 0) {
        return { tapped: false, reason: 'found but nothing responded to a tap',
                 node: hits[0].node };
      }
    }
    return { tapped: false, reason: 'no match' };
  },
};
