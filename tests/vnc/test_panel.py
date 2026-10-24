#!/usr/bin/env python3
"""Tests for a running xfce4-panel in a VNC/X desktop (see run.sh).

Environment: DISPLAY (the test desktop), VNC_PANEL (path to vnc-panel.sh, used
as `exec` to run xfconf-query on the session's D-Bus), SESSION_LOG (panel log).
"""
import os
import subprocess
import sys
import time
import traceback

from Xlib import X, display
from Xlib.ext import xtest

VNC_PANEL = os.environ["VNC_PANEL"]
SESSION_LOG = os.environ["SESSION_LOG"]

d = display.Display()
root = d.screen().root
SCREEN_W, SCREEN_H = d.screen().width_in_pixels, d.screen().height_in_pixels


def xfconf(*args):
    return subprocess.run([VNC_PANEL, "exec", "xfconf-query", "-c", "xfce4-panel", *args],
                          check=True, capture_output=True, text=True).stdout.strip()


def xfconf_set(prop, value, typ="uint"):
    subprocess.run([VNC_PANEL, "exec", "xfconf-query", "-c", "xfce4-panel", "-p", prop,
                    "-n", "-t", typ, "-s", str(value)], check=True)
    # -n fails harmlessly if it exists with another type; also set plainly
    subprocess.run([VNC_PANEL, "exec", "xfconf-query", "-c", "xfce4-panel", "-p", prop,
                    "-s", str(value)], check=True)


def panel_window():
    """Largest top-level-ish window with WM_CLASS xfce4-panel, or None."""
    best, best_area = None, 0

    def walk(w):
        nonlocal best, best_area
        try:
            cls = w.get_wm_class()
            if cls and "xfce4-panel" in cls[0].lower():
                g = w.get_geometry()
                if g.width * g.height > best_area:
                    best, best_area = w, g.width * g.height
            for c in w.query_tree().children:
                walk(c)
        except Exception:
            pass

    walk(root)
    return best


def geometry(w):
    g = w.get_geometry()
    c = root.translate_coords(w, 0, 0)
    return (c.x, c.y, g.width, g.height)


def move(x, y):
    xtest.fake_input(d, X.MotionNotify, x=int(x), y=int(y))
    d.sync()


def wait_for(cond, timeout, step=0.1):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        v = cond()
        if v:
            return v
        time.sleep(step)
    return None


def panel_state():
    """Geometry of every viewable, wide xfce4-panel window (changes when it shows/hides)."""
    found = []

    def walk(w):
        try:
            cls = w.get_wm_class()
            if cls and "xfce4-panel" in cls[0].lower():
                g = w.get_geometry()
                if g.width >= 200 and w.get_attributes().map_state == X.IsViewable:
                    c = root.translate_coords(w, 0, 0)
                    found.append((c.x, c.y, g.width, g.height))
            for c in w.query_tree().children:
                walk(c)
        except Exception:
            pass

    walk(root)
    return tuple(sorted(found))


def edge_point():
    """Pointer position that reveals the panel: bottom screen edge (see xfce4-panel.xml)."""
    return (SCREEN_W // 2, SCREEN_H - 1)


def settled(quiet=1.5, timeout=15):
    """Wait until the panel state stops changing; return it."""
    last, since = None, time.monotonic()
    end = since + timeout
    while time.monotonic() < end:
        g = panel_state()
        if g != last:
            last, since = g, time.monotonic()
        elif time.monotonic() - since >= quiet:
            return g
        time.sleep(0.05)
    raise AssertionError("panel state never settled")


def measure_hide_ms():
    """Put the pointer on the panel, leave it, return ms until it starts to hide."""
    centre = (SCREEN_W // 2, SCREEN_H // 2)
    move(*centre)
    hidden = settled()
    # Autohide only starts once the pointer has been over the panel, so enter first.
    move(*edge_point())
    visible = settled()
    if visible == hidden:
        raise AssertionError("panel did not reveal when the pointer hit the screen edge")
    t0 = time.monotonic()
    move(*centre)
    deadline = t0 + 12
    while time.monotonic() < deadline:
        if panel_state() != visible:
            ms = (time.monotonic() - t0) * 1000
            settled(quiet=1.0, timeout=20)   # let it finish hiding before the next run
            return ms
        time.sleep(0.005)
    raise AssertionError("panel never hid after the pointer left")


# --- tests ---------------------------------------------------------------

def test_panel_window_appears():
    w = wait_for(lambda: (lambda p: p if p and geometry(p)[2] >= 200 and geometry(p)[3] >= 16 else None)(panel_window()), 30)
    assert w is not None, "no usable xfce4-panel window (missing/tiny): default config not loaded?"


def test_panel_process_alive_and_clean_log():
    pid = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "xfce4-panel"],
                         capture_output=True, text=True).stdout.split()
    assert pid, "xfce4-panel is not running"
    log = open(SESSION_LOG, errors="replace").read()
    for bad in ("has been removed from the configuration", "Segmentation fault", "core dumped"):
        assert bad not in log, f"session log contains {bad!r}"


def test_configured_plugins_kept():
    ids = xfconf("-p", "/panels/panel-1/plugin-ids").split("\n")
    ids = [i for i in ids if i.strip().isdigit()]
    assert ids, "panel-1 has no plugin-ids"
    for i in ids:
        name = xfconf("-p", f"/plugins/plugin-{i}")
        assert name, f"plugin-{i} has no type"


def test_popdown_properties_roundtrip():
    for prop, val in (("popdown-delay", 321), ("popdown-slow-multiplier", 7)):
        xfconf_set(f"/panels/panel-1/{prop}", val)
        assert xfconf("-p", f"/panels/panel-1/{prop}") == str(val), prop


def test_popdown_slow_multiplier_scales_hide_delay():
    # the seeded config (xfce4-panel.xml) starts the panel in Always autohide mode
    xfconf_set("/panels/panel-1/popdown-delay", 300)
    xfconf_set("/panels/panel-1/popdown-slow-multiplier", 1)
    time.sleep(1)
    t1 = measure_hide_ms()
    xfconf_set("/panels/panel-1/popdown-slow-multiplier", 4)
    time.sleep(1)
    t4 = measure_hide_ms()
    print(f"      hide started after {t1:.0f} ms (multiplier 1), {t4:.0f} ms (multiplier 4)")
    assert 150 <= t1 <= 2000, f"multiplier 1 hide delay out of range: {t1:.0f} ms"
    assert t4 - t1 >= 600, f"multiplier 4 not slower enough (expected ~+900 ms): {t1:.0f} -> {t4:.0f} ms"


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    # keep definition order (sorted() would reorder); use source order instead
    tests.sort(key=lambda t: t[1].__code__.co_firstlineno)
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS  {name}")
        except Exception as e:
            failed += 1
            print(f"FAIL  {name}: {e}")
            if not isinstance(e, AssertionError):
                traceback.print_exc()
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
