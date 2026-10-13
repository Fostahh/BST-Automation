// uitree.js — dump the on-screen view hierarchy of an iOS app, via frida.
//
// The iOS counterpart of `uiautomator dump`. XCUITest is the supported way to read an
// iOS UI, but it requires testmanagerd to authorise the process as a test runner, which
// only the `xcodebuild test` handshake grants — so a sideloaded WebDriverAgent can serve
// HTTP and press hardware buttons yet sees no application at all. On a jailbroken device
// frida is already inside the process and can read UIKit directly, with no certificate
// and no Apple tooling in the path.
//
//   frida -U -n <app> -l uitree.js --runtime=v8 -q -e 'dump()'
//
// Emits one JSON object per visible view: class, accessibility label, text, and the frame
// in screen coordinates — enough for the finder to locate an element by what it says and
// tap the centre of where it actually is, exactly as uifind.py does on Android.

function rectOf(view) {
  // Struct returns are the awkward part of the ObjC bridge, so go through a method that
  // hands back a CGRect the bridge understands, converted to window coordinates.
  try {
    const r = view.convertRect_toView_(view.bounds(), NULL);
    return {
      x: Math.round(r[0][0]), y: Math.round(r[0][1]),
      w: Math.round(r[1][0]), h: Math.round(r[1][1]),
    };
  } catch (e) {
    try {
      const f = view.frame();
      return {
        x: Math.round(f[0][0]), y: Math.round(f[0][1]),
        w: Math.round(f[1][0]), h: Math.round(f[1][1]),
      };
    } catch (e2) {
      return null;
    }
  }
}

function str(obj) {
  try {
    if (obj === null || obj.isNull()) return '';
    return obj.toString();
  } catch (e) {
    return '';
  }
}

function describe(view) {
  const out = { cls: view.$className };
  try { out.label = str(view.accessibilityLabel()); } catch (e) { out.label = ''; }
  try { out.ident = str(view.accessibilityIdentifier()); } catch (e) { out.ident = ''; }
  // Whatever the control shows: a title for buttons, text for labels and fields.
  try { if (view.respondsToSelector_(ObjC.selector('text'))) out.text = str(view.text()); } catch (e) {}
  try {
    if (!out.text && view.respondsToSelector_(ObjC.selector('titleForState:')))
      out.text = str(view.titleForState_(0));
  } catch (e) {}
  try { out.enabled = view.respondsToSelector_(ObjC.selector('isEnabled')) ? !!view.isEnabled() : true; }
  catch (e) { out.enabled = true; }
  out.rect = rectOf(view);
  return out;
}

function visible(view) {
  try {
    if (view.isHidden()) return false;
    if (view.alpha() < 0.05) return false;
  } catch (e) { /* not a UIView; let the caller decide on the rect */ }
  const r = rectOf(view);
  return !!(r && r.w > 0 && r.h > 0);
}

function walk(view, depth, out) {
  if (depth > 40) return;
  if (!visible(view)) return;
  const node = describe(view);
  node.depth = depth;
  out.push(node);
  let kids;
  try { kids = view.subviews(); } catch (e) { return; }
  if (!kids) return;
  const n = kids.count();
  for (let i = 0; i < n; i++) walk(kids.objectAtIndex_(i), depth + 1, out);
}

// dump() : every visible view in the key window, as JSON on stdout.
function dump() {  // eslint-disable-line no-unused-vars
  if (!ObjC.available) { console.log(JSON.stringify({ error: 'no ObjC runtime' })); return; }
  const app = ObjC.classes.UIApplication.sharedApplication();
  const windows = app.windows();
  const out = [];
  for (let i = 0; i < windows.count(); i++) {
    const w = windows.objectAtIndex_(i);
    try { if (w.isHidden()) continue; } catch (e) {}
    walk(w, 0, out);
  }
  console.log(JSON.stringify({ bundle: str(ObjC.classes.NSBundle.mainBundle().bundleIdentifier()),
                               views: out }));
}

rpc.exports = {
  dump: function () {
    const out = [];
    if (!ObjC.available) return { error: 'no ObjC runtime' };
    const app = ObjC.classes.UIApplication.sharedApplication();
    const windows = app.windows();
    for (let i = 0; i < windows.count(); i++) {
      const w = windows.objectAtIndex_(i);
      try { if (w.isHidden()) continue; } catch (e) {}
      walk(w, 0, out);
    }
    return { bundle: str(ObjC.classes.NSBundle.mainBundle().bundleIdentifier()), views: out };
  },
};
