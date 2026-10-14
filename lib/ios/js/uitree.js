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

// EVERYTHING UIKIT RUNS ON THE MAIN THREAD.
//
// frida calls an rpc export on its own thread, and UIKit from any other thread is
// undefined behaviour: reading a view tree that way happened to work on the app under test
// and terminated TrollStore outright. ObjC.schedule puts the work on the main queue where
// UIKit expects it, and the Promise makes the caller wait for the answer — so an export
// reads exactly as before, one thread over.
function onMain(fn) {
  return new Promise((resolve, reject) => {
    ObjC.schedule(ObjC.mainQueue, () => {
      try { resolve(fn()); } catch (e) { reject(e); }
    });
  });
}

// READING AN IVAR.
// The bridge returns an ObjC.Object for a non-nil `id` ivar, null for a nil one, and a
// bare NativePointer for a SEL — and an ObjC.Object has no isNull(), so the obvious
// `!v || v.isNull()` guard throws on every value that is actually there. Inside a
// try/catch that silently became "skip this one", which is how the gesture route came to
// never fire anything. One reader, three shapes, no guesswork at the call sites.
function ivar(obj, name) {
  let value;
  try { value = obj.$ivars[name]; } catch (e) { return null; }
  if (value === null || typeof value === 'undefined') return null;
  if (value.handle !== undefined) return value;                 // already an ObjC.Object
  if (typeof value.isNull === 'function' && value.isNull()) return null;   // a nil pointer
  return value;                                                 // a SEL, or a raw pointer
}

function ptr_(value) {   // the NativePointer behind either shape
  return value !== null && value.handle !== undefined ? value.handle : value;
}

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
  if (!node.text && view.$className === 'UIShareGroupActivityCell') node.text = shareKind(view);
  try { node.enabled = view.isEnabled(); } catch (e) { /* not a control; assume usable */ }
  node.rect = rectOf(view);
  return node;
}

// iOS 16 draws a third-party app's name in the share sheet out of process (a CA "slot"),
// so the cell holds no text at all — "TrollStore" exists only as pixels. What the cell
// does hold is the kind of activity behind it, which tells "hand the file to an app" apart
// from a share extension. Which app it was is for the caller to confirm afterwards.
function shareKind(cell) {
  const proxy = ivar(cell, '_activityProxy');
  if (proxy === null) return '';
  if (ivar(proxy, '_activityIdentifierCopy') !== null || ivar(proxy, '_activityIdentifierOpen') !== null) {
    return 'Open in app';
  }
  return ivar(proxy, '_activityIdentifierShare') !== null ? 'Share extension' : '';
}

function onScreen(view) {
  try {
    if (view.isHidden()) return false;
    if (view.alpha() < 0.05) return false;
  } catch (e) { /* not a UIView */ }
  const r = rectOf(view);
  return !!(r && r.w > 0 && r.h > 0);
}

// --- accessibility elements --------------------------------------------------
// SwiftUI draws its text into private views that carry no label and expose the content as
// ACCESSIBILITY ELEMENTS instead: a List row arrives as a SwiftUI.AccessibilityNode
// labelled "Books, com.apple.iBooks, 9.0" — name, bundle id and version in one string.
// Those elements are not in subviews(), which is why a view-only walk saw 182 views on
// TrollFools' app list and only 17 of them said anything at all.
//
// accessibilityActivate() is what VoiceOver runs on a double tap, so the same elements
// that make the screen readable are also the way to tap it — and it is a public API, not
// an ivar that moves between iOS releases.
function axElements(view) {
  const out = [];
  let list = null;
  try { list = view.accessibilityElements(); } catch (e) { list = null; }
  if (list !== null && !list.isNull()) {
    for (let i = 0; i < list.count(); i++) out.push(list.objectAtIndex_(i));
  } else {
    let count = 0;
    try { count = Number(view.accessibilityElementCount()); } catch (e) { return out; }
    // Unsupported answers NSNotFound, which arrives as an astronomical count.
    if (!(count > 0) || count > 500) return out;
    for (let i = 0; i < count; i++) {
      try { out.push(view.accessibilityElementAtIndex_(i)); } catch (e) { /* skip */ }
    }
  }
  // An element that is itself a view is already in the walk; keeping both would make a
  // substring match ambiguous for no gain.
  return out.filter((e) => {
    try { return e !== null && !e.isNull() && !e.isKindOfClass_(ObjC.classes.UIView); }
    catch (err) { return false; }
  });
}

// Accessibility elements NEST, and only walking one level under each view misses most of
// them: TestFlight's app rows and a document picker's contents both hang several levels
// below the view that owns them. The view walk cannot reach these at all — an element is
// not a subview — so this is the only path to them.
function axWalk(view, depth, out, seen) {
  for (const element of axElements(view)) {
    let key;
    try { key = element.handle.toString(); } catch (e) { continue; }
    if (seen.has(key)) continue;            // an element may list itself, or be shared
    seen.add(key);
    out.push({ node: describeAx(element, depth), tap: () => tapElement(element) });
    if (depth < 24) axWalk(element, depth + 1, out, seen);
  }
}

function describeAx(element, depth) {
  const node = { depth, cls: element.$className, label: '', ident: '', text: '',
                 enabled: true, ax: true };
  try { node.label = str(element.accessibilityLabel()); } catch (e) { /* unnamed */ }
  try { node.text = str(element.accessibilityValue()); } catch (e) { /* no value */ }
  try { node.ident = str(element.accessibilityIdentifier()); } catch (e) { /* none */ }
  try {
    const f = element.accessibilityFrame();
    node.rect = { x: Math.round(f[0][0]), y: Math.round(f[0][1]),
                  w: Math.round(f[1][0]), h: Math.round(f[1][1]) };
  } catch (e) { node.rect = null; }
  return node;
}

// accessibilityActivate returns NO when there was nothing to activate, which is exactly
// the no-op this layer refuses to report as a tap.
function activate(element) {
  try {
    if (!element.respondsToSelector_(ObjC.selector('accessibilityActivate'))) return null;
    return element.accessibilityActivate() ? 'activate' : null;
  } catch (e) {
    return null;
  }
}

// --- menu entries -------------------------------------------------------------
// A UIMenu's entries are not views. TrollStore's + is a UIBarButtonItem carrying a UIMenu
// of two UIActions ("Install IPA File", "Install from URL"), and until the menu is on
// screen neither exists as anything a view walk can see. They are addressable all the
// same: the action's title is what the operator reads, and its handler is what a tap on
// that row runs. So they are collected next to the views and tapped by running it — which
// also means the menu never has to be opened first.

// The UIBarButtonItem behind a bar button view. The view's own registered target is a
// _UIButtonBarTargetAction wrapper; the item it holds is where the app put its target,
// action and menu.
function barItemOf(view) {
  let targets;
  try { targets = view.allTargets().allObjects(); } catch (e) { return null; }
  for (let i = 0; i < targets.count(); i++) {
    const item = ivar(targets.objectAtIndex_(i), '_barButtonItem');
    if (item !== null) return item;
  }
  return null;
}

function menuOf(view) {
  const item = barItemOf(view);
  for (const owner of [item, view]) {
    if (owner === null) continue;
    try {
      const menu = owner.menu();
      if (menu && !menu.isNull()) return menu;
    } catch (e) { /* does not carry a menu */ }
  }
  return null;
}

// UIMenuElementAttributesDisabled = 1. A disabled entry is listed but not tapped, the same
// rule the views follow.
function menuEntries(menu, depth, out) {
  let kids;
  try { kids = menu.children(); } catch (e) { return out; }
  if (kids === null || kids.isNull()) return out;
  for (let i = 0; i < kids.count(); i++) {
    const child = kids.objectAtIndex_(i);
    let nested = null;
    try { if (child.isKindOfClass_(ObjC.classes.UIMenu)) nested = child; } catch (e) { /* not */ }
    if (nested !== null) { menuEntries(nested, depth + 1, out); continue; }
    let enabled = true;
    try { enabled = (Number(child.attributes()) & 1) === 0; } catch (e) { /* assume usable */ }
    out.push({
      action: child,
      node: { depth, cls: child.$className, label: str(child.title()), text: '',
              ident: (() => { try { return str(child.accessibilityIdentifier()); } catch (e) { return ''; } })(),
              enabled, rect: null, menu: true },
    });
  }
  return out;
}

function fireMenuAction(action) {
  const handler = ivar(action, '_handler');
  if (handler === null) return null;
  try {
    new ObjC.Block(ptr_(handler), { retType: 'void', argTypes: ['object'] })
      .implementation(action);
    return 'menu';
  } catch (e) {
    return null;
  }
}

// --- tapping ------------------------------------------------------------------
// Three attempts, in order of how faithfully they imitate a finger.
//
// Synthesising a UITouch and sending it through the application's event queue is the
// textbook method, and it does not survive iOS 16: UITouch has no _view ivar any more (it
// is _responder), and UIApplication no longer answers _touchesEvent, so there is no event
// object to put a touch into. What remains is to invoke the same handler the touch would
// have reached.
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
      const targets = ivar(g, '_targets');
      if (targets === null || targets.count() === 0) continue;
      let fired = 0;
      for (let t = 0; t < targets.count(); t++) {
        const pair = targets.objectAtIndex_(t);
        const target = ivar(pair, '_target');
        const action = ivar(pair, '_action');
        if (target === null || action === null) continue;
        target.performSelector_withObject_(ptr_(action), g);
        fired += 1;
      }
      if (fired === 0) continue;
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
        // Which segment this is, by position: UISegment is private and carries no index.
        let index = -1;
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

// Which event a tap on this control actually triggers. Sending the wrong one is the silent
// wrong tap: TrollStore's + is registered ONLY for PrimaryActionTriggered, so
// sendActionsForControlEvents:TouchUpInside returned happily and opened nothing. So ask
// the control what it is registered for, and send that.
const TAP_EVENTS = [
  [1 << 13, 'primary'],        // UIControlEventPrimaryActionTriggered — UIAction, bar buttons
  [1 << 6, 'touchUpInside'],   // UIControlEventTouchUpInside — the ordinary button
  [1 << 12, 'valueChanged'],   // UIControlEventValueChanged — switches, segments, sliders
];
function tapControl(control) {
  let registered;
  try {
    if (!control.isKindOfClass_(ObjC.classes.UIControl) || !control.isEnabled()) return null;
    registered = Number(control.allControlEvents());
  } catch (e) {
    return null;
  }
  // Nothing registered means nothing will run. Reporting that as a tap would be worse
  // than reporting a failure, because the caller would carry on to the next step.
  for (const [mask, name] of TAP_EVENTS) {
    if ((registered & mask) === 0) continue;
    try {
      control.sendActionsForControlEvents_(mask);
      return 'control:' + name;
    } catch (e) { /* try the next event */ }
  }
  return null;
}

// A bar button goes through its UIBarButtonItem, never through the view: the view's
// registered action is _UIButtonBarTargetAction's _invoke:forEvent:, which wants a real
// UIEvent and does nothing without one. sendActionsForControlEvents: therefore reports
// success and opens nothing at all.
function tapBarItem(item) {
  try {
    const action = item.action();
    const target = item.target();
    if (action && !action.isNull() && target && !target.isNull()) {
      target.performSelector_withObject_(action, item);
      return 'barbutton';
    }
  } catch (e) { /* no target/action pair */ }
  try {
    const primary = item.primaryAction();
    if (primary && !primary.isNull()) {
      const fired = fireMenuAction(primary);     // a UIAction, same handler shape
      if (fired !== null) return 'barbutton:action';
    }
  } catch (e) { /* no primaryAction */ }
  return null;
}

// An alert button is a _UIAlertControllerActionView: a plain UIView with no action of its
// own, driven by the alert's own touch handling. The UIAlertAction behind it is in _action,
// and UIKit's sequence is to dismiss the alert and THEN run the handler — so doing only
// the handler would leave the alert on screen, blocking every step after it.
function tapAlertAction(view) {
  const action = ivar(view, '_action');
  if (action === null) return null;
  try { if (!action.isEnabled()) return null; } catch (e) { /* assume usable */ }
  const controller = ivar(view, '_alertController') || ivar(action, '__alertController');
  let did = null;
  if (controller !== null) {
    try {
      controller.dismissViewControllerAnimated_completion_(0, NULL);
      did = 'alert';                  // a Cancel with no handler IS just the dismissal
    } catch (e) { /* the handler still matters */ }
  }
  const handler = ivar(action, '_handler');
  if (handler !== null) {
    try {
      new ObjC.Block(ptr_(handler), { retType: 'void', argTypes: ['object'] })
        .implementation(action);
      did = 'alert';
    } catch (e) { /* leave did as it was */ }
  }
  return did;
}

// A table or collection row is not a control and carries no tap recogniser: the list
// handles the touch itself and tells its delegate. So ask the delegate, exactly as UIKit
// would — selecting the row first, so the screen looks like it was tapped.
function tapRow(view) {
  let table = false, collection = false;
  try { table = view.isKindOfClass_(ObjC.classes.UITableViewCell); } catch (e) { /* no */ }
  try { collection = view.isKindOfClass_(ObjC.classes.UICollectionViewCell); } catch (e) { /* no */ }
  if (!table && !collection) return null;
  let owner;
  try { owner = view.superview(); } catch (e) { return null; }
  // The cell's parent is the list in most layouts and a wrapper view in the rest.
  for (let i = 0; i < 4 && owner !== null && !owner.isNull(); i++) {
    try {
      const isList = table ? owner.isKindOfClass_(ObjC.classes.UITableView)
                           : owner.isKindOfClass_(ObjC.classes.UICollectionView);
      if (isList) {
        const path = owner.indexPathForCell_(view);
        const delegate = owner.delegate();
        if (path === null || path.isNull() || delegate === null || delegate.isNull()) return null;
        const selector = table ? 'tableView:didSelectRowAtIndexPath:'
                               : 'collectionView:didSelectItemAtIndexPath:';
        if (!delegate.respondsToSelector_(ObjC.selector(selector))) return null;
        if (table) {
          owner.selectRowAtIndexPath_animated_scrollPosition_(path, 0, 0);
          delegate.tableView_didSelectRowAtIndexPath_(owner, path);
        } else {
          delegate.collectionView_didSelectItemAtIndexPath_(owner, path);
        }
        return 'row';
      }
    } catch (e) { /* keep climbing */ }
    try { owner = owner.superview(); } catch (e) { break; }
  }
  return null;
}

// The view a finger would land on at this point. hitTest is UIKit's own answer to that
// question, so it respects hidden views, disabled interaction and z-order.
function viewAtPoint(x, y) {
  const windows = windowList();
  for (let i = windows.length - 1; i >= 0; i--) {      // topmost window first
    try {
      const hit = windows[i].hitTest_withEvent_([x, y], NULL);
      if (hit !== null && !hit.isNull()) return hit;
    } catch (e) { /* try the window below */ }
  }
  return null;
}

// An accessibility element is not a view, so it cannot be climbed. Three ways down to
// something that responds, in order of directness.
function tapElement(element) {
  const byActivate = activate(element);
  if (byActivate !== null) return byActivate;
  // Its owner. SwiftUI rows in a List answer here.
  try {
    const container = element.accessibilityContainer();
    if (container !== null && !container.isNull()
        && container.isKindOfClass_(ObjC.classes.UIView)) {
      const how = tapView(container);
      if (how !== null) return how + '(container)';
    }
  } catch (e) { /* no container */ }
  // Whatever is drawn where the element says it is. TestFlight's rows refuse to activate
  // and own nothing tappable, but something is under them — this is the closest thing to
  // putting a finger on the element without synthesising a touch.
  try {
    const frame = element.accessibilityFrame();
    const x = frame[0][0] + frame[1][0] / 2;
    const y = frame[0][1] + frame[1][1] / 2;
    if (frame[1][0] > 0 && frame[1][1] > 0) {
      const hit = viewAtPoint(x, y);
      if (hit !== null) {
        const how = tapView(hit);
        if (how !== null) return how + '(at point)';
      }
    }
  } catch (e) { /* no frame */ }
  return null;
}

function tapView(view) {
  const bySegment = tapSegment(view);
  if (bySegment !== null) return bySegment;

  // The view itself, then its ancestors: a label inside a button is what matched, but the
  // button is what responds.
  let node = view;
  for (let i = 0; i < 6 && node !== null && !node.isNull(); i++) {
    const byAlert = tapAlertAction(node);
    if (byAlert !== null) return i === 0 ? byAlert : 'alert(ancestor)';
    const item = barItemOf(node);
    if (item !== null) {
      // A bar button is only this item. If the item has nothing to run — the + button,
      // whose whole behaviour is its menu — then tapping the VIEW does nothing, and the
      // menu entry is the thing to tap instead. Saying so beats a false success.
      const byItem = tapBarItem(item);
      return byItem === null ? null : (i === 0 ? byItem : byItem + '(ancestor)');
    }
    const byControl = tapControl(node);
    if (byControl !== null) return i === 0 ? byControl : byControl + '(ancestor)';
    const byGesture = fireGestures(node);
    if (byGesture !== null) return i === 0 ? 'gesture' : 'gesture(ancestor)';
    const byRow = tapRow(node);
    if (byRow !== null) return i === 0 ? byRow : 'row(ancestor)';
    const byAx = activate(node);
    if (byAx !== null) return i === 0 ? byAx : 'activate(ancestor)';
    try { node = node.superview(); } catch (e) { break; }
  }
  return null;
}

// Every window, not just the ones the application admits to.
//
// UIApplication.windows() is not the whole truth. In a view-service extension — which is
// what a document picker is — the picker's own UI lives in a _UIHostedWindow that the
// application object never lists; windows() returns the keyboard and text-effects windows
// and nothing else, so a walk sees three views and no content at all.
//
// Every live window is on the heap. The application's own list goes first so an ordinary
// app keeps its z-order, and the heap scan adds whatever was being hidden.
// ponytail: chooseSync scans the malloc heap on every call. Measured fine here; if a big
// app's dumps get slow, gate the scan on the app list looking empty.
function windowList() {
  const out = [];
  const seen = new Set();
  const add = (win) => {
    try {
      const key = win.handle.toString();
      if (seen.has(key)) return;
      seen.add(key);
      if (win.isHidden()) return;
      out.push(win);
    } catch (e) { /* not usable */ }
  };
  try {
    const windows = ObjC.classes.UIApplication.sharedApplication().windows();
    for (let i = 0; i < windows.count(); i++) add(windows.objectAtIndex_(i));
  } catch (e) { /* no application object in this process */ }
  try {
    for (const win of ObjC.chooseSync(ObjC.classes.UIWindow)) add(win);
  } catch (e) { /* heap scan unavailable */ }
  return out;
}

// --- the walk -----------------------------------------------------------------
// One traversal behind all three exports, so what `find` can see is exactly what `tap`
// can reach. Each entry carries the description AND how to act on it.
function targets() {
  const out = [];
  const seen = new Set();          // one per walk: an element reachable twice is one thing
  for (const window of windowList()) {
    (function walk(view, depth) {
      if (depth > 60 || !onScreen(view)) return;
      out.push({ node: describe(view, depth), tap: () => tapView(view) });
      axWalk(view, depth + 1, out, seen);
      const menu = menuOf(view);
      if (menu !== null) {
        for (const entry of menuEntries(menu, depth + 1, [])) {
          out.push({ node: entry.node, tap: () => fireMenuAction(entry.action) });
        }
      }
      let kids;
      try { kids = view.subviews(); } catch (e) { return; }
      if (kids === null) return;
      for (let k = 0; k < kids.count(); k++) walk(kids.objectAtIndex_(k), depth + 1);
    })(window, 0);
  }
  return out;
}

// A row that has not been realised yet exists in no form at all — not as a view, not as an
// accessibility element — so finding one app among forty-six means moving the list. The
// biggest scroll view on screen is the list in every case here; the small ones are the
// search bar's and the segmented control's.
// The scroll view a scroll should move. "Biggest" is the obvious answer and the wrong
// one: a share sheet's action list sits on top of the app's own table, which is larger,
// so paging the sheet paged the screen behind it instead.
//
// Walk order is back-to-front, so the LAST candidate is the one in front. Size still
// matters — a segmented control and a search bar are scroll views too — so a candidate
// has to cover a reasonable part of the screen before it beats what is behind it.
function scrollTarget() {
  const candidates = [];
  for (const window of windowList()) {
    (function walk(view, depth) {
      if (depth > 60 || !onScreen(view)) return;
      try {
        if (view.isKindOfClass_(ObjC.classes.UIScrollView)) {
          const r = rectOf(view);
          if (r !== null && r.w > 0 && r.h > 0) candidates.push({ view, area: r.w * r.h });
        }
      } catch (e) { /* not a scroll view */ }
      let kids;
      try { kids = view.subviews(); } catch (e) { return; }
      if (kids === null) return;
      for (let k = 0; k < kids.count(); k++) walk(kids.objectAtIndex_(k), depth + 1);
    })(window, 0);
  }
  if (candidates.length === 0) return null;
  const biggest = candidates.reduce((a, b) => (b.area > a.area ? b : a));
  for (let i = candidates.length - 1; i >= 0; i--) {
    if (candidates[i].area >= biggest.area * 0.2) return candidates[i].view;
  }
  return biggest.view;
}

// Whitespace is normalised on BOTH sides before comparing. iOS labels are full of
// characters that look like a space and are not — TestFlight writes "App, Version 1.0"
// with U+00A0 after the comma, so a lookup for ", Version " matched nothing at all while
// the dump printed something indistinguishable from the needle. \s covers them in JS.
function flat(text) {
  return String(text).replace(/\s+/g, ' ').trim();
}

function matches(node, want) {
  const hay = [node.label, node.ident, node.text].filter((h) => h).map(flat);
  if (want.equals !== undefined) {
    const needle = flat(want.equals);
    return hay.some((h) => h === needle);
  }
  if (want.contains !== undefined) {
    const needle = flat(want.contains).toLowerCase();
    return hay.some((h) => h.toLowerCase().indexOf(needle) !== -1);
  }
  return false;
}

// --- permissions, granted before the app under test launches ----------------
// A permission alert is drawn by SpringBoard, not by the app, so nothing here can tap it —
// and it lands mid-step: TrollDecrypt launches the app to decrypt it, and the app opened
// Bluetooth, then Notifications, on top of the decrypt. So the alerts are never raised:
// every permission the app declares a usage string for is granted ahead of time.
//
// Called inside a hidden copy of Settings (see iosdriver.py grant), which holds the
// entitlements to change ANOTHER app's permissions. The app under test is never touched.
const TCC_FOR_KEY = {
  NSBluetoothAlwaysUsageDescription: 'kTCCServiceBluetoothAlways',
  NSBluetoothPeripheralUsageDescription: 'kTCCServiceBluetoothAlways',
  NSCameraUsageDescription: 'kTCCServiceCamera',
  NSMicrophoneUsageDescription: 'kTCCServiceMicrophone',
  NSPhotoLibraryUsageDescription: 'kTCCServicePhotos',
  NSPhotoLibraryAddUsageDescription: 'kTCCServicePhotosAdd',
  NSContactsUsageDescription: 'kTCCServiceAddressBook',
  NSCalendarsUsageDescription: 'kTCCServiceCalendar',
  NSRemindersUsageDescription: 'kTCCServiceReminders',
  NSMotionUsageDescription: 'kTCCServiceMotion',
  NSAppleMusicUsageDescription: 'kTCCServiceMediaLibrary',
  NSSpeechRecognitionUsageDescription: 'kTCCServiceSpeechRecognition',
  NSUserTrackingUsageDescription: 'kTCCServiceUserTracking',
  NSFaceIDUsageDescription: 'kTCCServiceFaceID',
  NSHomeKitUsageDescription: 'kTCCServiceWillow',
};
const LOCATION_WHEN_IN_USE = 4;     // kCLAuthorizationStatusAuthorizedWhenInUse
const NOTIFICATIONS_ALLOWED = 2;    // UNAuthorizationStatusAuthorized

function grantAll(bundle) {
  const granted = [], failed = [];
  const id = ObjC.classes.NSString.stringWithString_(bundle);
  const proxy = ObjC.classes.LSApplicationProxy.applicationProxyForIdentifier_(id);
  const url = proxy.bundleURL();
  if (url === null || url.isNull()) return { error: bundle + ' is not installed' };
  const info = ObjC.classes.NSDictionary.dictionaryWithContentsOfURL_(
    url.URLByAppendingPathComponent_('Info.plist'));
  if (info === null || info.isNull()) return { error: 'cannot read the Info.plist of ' + bundle };
  const keys = [];
  const all = info.allKeys();
  for (let i = 0; i < all.count(); i++) keys.push(all.objectAtIndex_(i).toString());

  const tcc = Process.findModuleByName('TCC')
           || Module.load('/System/Library/PrivateFrameworks/TCC.framework/TCC');
  const setTcc = new NativeFunction(tcc.getExportByName('TCCAccessSetForBundleId'),
                                    'bool', ['pointer', 'pointer', 'bool']);
  const services = new Set(keys.map((k) => TCC_FOR_KEY[k]).filter((v) => v));
  for (const service of services) {
    const name = service.replace('kTCCService', '');
    const ok = setTcc(ObjC.classes.NSString.stringWithString_(service), id, 1);
    (ok ? granted : failed).push(name);
  }

  if (keys.some((k) => /^NSLocation.*UsageDescription$/.test(k))) {
    try {
      if (Process.findModuleByName('CoreLocation') === null) {
        Module.load('/System/Library/Frameworks/CoreLocation.framework/CoreLocation');
      }
      ObjC.classes.CLLocationManager.setAuthorizationStatusByType_forBundleIdentifier_(
        LOCATION_WHEN_IN_USE, id);
      granted.push('Location');
    } catch (e) { failed.push('Location (' + e.message + ')'); }
  }

  // Notifications need no usage string, so every app may ask. The section exists from
  // install time; one that is missing means the app was never registered with the
  // notification system, and is reported rather than invented.
  try {
    if (Process.findModuleByName('BulletinBoard') === null) {
      Module.load('/System/Library/PrivateFrameworks/BulletinBoard.framework/BulletinBoard');
    }
    const gateway = ObjC.classes.BBSettingsGateway.alloc().init();
    let section = gateway.sectionInfoForSectionID_(id);
    if (section === null || section.isNull()) {
      // A fresh install that has never asked has no section yet; make the one asking
      // would have made.
      section = ObjC.classes.BBSectionInfo.alloc().init();
      section.setSectionID_(id);
    }
    section.setAuthorizationStatus_(NOTIFICATIONS_ALLOWED);
    section.setAllowsNotifications_(1);
    gateway.setSectionInfo_forSectionID_(section, id);
    const check = gateway.sectionInfoForSectionID_(id);
    if (check !== null && !check.isNull() && Number(check.authorizationStatus()) === NOTIFICATIONS_ALLOWED) {
      granted.push('Notifications');
    } else {
      failed.push('Notifications (did not stick)');
    }
  } catch (e) { failed.push('Notifications (' + e.message + ')'); }

  return { granted, failed };
}

rpc.exports = {
  grant: function (bundle) {
    if (!ObjC.available || !ObjC.classes.LSApplicationProxy) return { notReady: true };
    try { return grantAll(bundle); } catch (e) { return { error: e.message }; }
  },

  // hold : for the hidden Settings. Its main thread is parked in a run loop instead of
  // UIApplicationMain, so every framework comes up and nothing ever tries to draw.
  hold: function () {
    const park = () => {
      const sym = Module.findGlobalExportByName('UIApplicationMain');
      if (sym === null) return false;
      const run = new NativeFunction(Module.getGlobalExportByName('CFRunLoopRun'), 'void', []);
      Interceptor.replace(sym, new NativeCallback(() => { run(); return 0; },
                                                  'int', ['int', 'pointer', 'pointer', 'pointer']));
      return true;
    };
    if (park()) return 'parked';
    const observer = Process.attachModuleObserver({
      onAdded(module) { if (module.name === 'UIKitCore' && park()) observer.detach(); },
    });
    return 'waiting for UIKit';
  },

  // dump : everything addressable on screen, for the probe and for a failed lookup.
  dump: function () {
    return onMain(() => {
      if (!ObjC.available) return { error: 'no ObjC runtime in this process' };
      return {
        bundle: str(ObjC.classes.NSBundle.mainBundle().bundleIdentifier()),
        views: targets().map((t) => t.node),
      };
    });
  },

  // find : what matches {equals|contains}, in tree order.
  find: function (want) {
    return onMain(() => {
      if (!ObjC.available) return { error: 'no ObjC runtime in this process' };
      return { matches: targets().filter((t) => matches(t.node, want)).map((t) => t.node) };
    });
  },

  // scroll : page the list. Reports whether it actually moved, so a caller looking for
  // something can stop at the end instead of looping forever.
  scroll: function (direction) {
    return onMain(() => {
      if (!ObjC.available) return { error: 'no ObjC runtime in this process' };
      const view = scrollTarget();
      if (view === null) return { scrolled: false, reason: 'nothing scrollable on screen' };
      const offset = view.contentOffset();
      const height = view.bounds()[1][1];
      const content = view.contentSize()[1];
      let top = 0, bottom = 0;
      try {
        const inset = view.adjustedContentInset();
        top = inset[0]; bottom = inset[2];
      } catch (e) { /* older layout, no adjusted inset */ }
      const page = height * 0.8;
      const limit = Math.max(-top, content - height + bottom);
      let y = direction === 'up' ? offset[1] - page
            : direction === 'top' ? -top
            : offset[1] + page;
      y = Math.max(-top, Math.min(y, limit));
      // Animated: the list slides like a swipe instead of jumping a page, and a lazy list
      // (TestFlight's SwiftUI one) loads its next rows as it passes them. The offset read
      // back now would still be the start, so "moved" is judged by where it is heading —
      // the caller's NAP_SCROLL lets the slide finish before the next look.
      view.setContentOffset_animated_([offset[0], y], 1);
      return { scrolled: Math.abs(y - offset[1]) > 1,
               y: Math.round(y), end: Math.round(limit), cls: view.$className };
    });
  },

  // touch : a real digitizer event at a point. Off the main queue deliberately — the gap
  // between the down and the up is only a gap if the main thread is free to process them.
  touch: function (x, y, route) {
    if (!ObjC.available) return { error: 'no ObjC runtime in this process' };
    HID_ROUTE = route || null;
    return hidTouch(x, y);
  },

  // tap : act on the first match that responds. Returns WHICH route fired, so a caller
  // can tell a real action from a silent no-op.
  tap: function (want) {
    return onMain(() => {
      if (!ObjC.available) return { error: 'no ObjC runtime in this process' };
      const hits = targets().filter((t) => matches(t.node, want));
      for (const hit of hits) {
        if (!hit.node.enabled) continue;
        const how = hit.tap();
        if (how !== null) return { tapped: true, how, node: hit.node };
      }
      if (hits.length > 0) {
        const rect = hits[0].node.rect;
        const point = (rect && rect.w > 0 && rect.h > 0)
          ? { x: rect.x + rect.w / 2, y: rect.y + rect.h / 2 } : null;
        return { tapped: false, reason: 'found but nothing responded to a tap',
                 node: hits[0].node, point };
      }
      return { tapped: false, reason: 'no match' };
    });
  },
};
