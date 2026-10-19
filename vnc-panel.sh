#!/bin/bash
# Run xfce4-panel inside a VNC desktop (Xtightvnc + xfwm4) on a build host.
#
# Usage: vnc-panel.sh start|stop|restart|status|exec <command...>
#   exec runs a command inside the running session (same DISPLAY, HOME and
#   D-Bus bus), e.g. exec xfconf-query -c xfce4-panel -l -v
#
# Runs on the host that built the panel (default prefix ~/panel-test, from
#   ./configure --prefix=$HOME/panel-test --libdir=$HOME/panel-test/lib
#   make install). Override with PANEL_PREFIX.
#
# Connect with an SSH tunnel, then point a VNC viewer at localhost:5907:
#   ssh -L 5907:localhost:5907 dev
#
# Needs: tightvncserver, tightvncpasswd, xfwm4, dbus-x11, x11-xserver-utils.
#
# Isolation: Xtightvnc listens on localhost only and needs the ~/.vnc/passwd
# password. The session gets its own HOME, XDG dirs and D-Bus session bus, so
# it never touches the real desktop's config. The test HOME persists between
# runs so xfconf settings survive a restart; delete it to start clean.

set -eu

PANEL_PREFIX=${PANEL_PREFIX:-$HOME/panel-test}
DISPLAY_NUM=${DISPLAY_NUM:-7}
RFB_PORT=$((5900 + DISPLAY_NUM))
GEOMETRY=${GEOMETRY:-1280x800}
TEST_HOME=${TEST_HOME:-$HOME/panel-test-home}
PASSWD_FILE=${PASSWD_FILE:-$HOME/.vnc/passwd}
RUN_DIR=$TEST_HOME/run

xvnc_pid()    { pgrep -u "$(id -u)" -f "^Xtightvnc :$DISPLAY_NUM " || true; }
session_pid() { cat "$RUN_DIR/session.pid" 2>/dev/null || true; }

start() {
    if [ -n "$(xvnc_pid)" ]; then
        echo "Xtightvnc :$DISPLAY_NUM already running (pid $(xvnc_pid))" >&2
        exit 1
    fi
    [ -r "$PASSWD_FILE" ] || { echo "No VNC password file at $PASSWD_FILE (run vncpasswd)" >&2; exit 1; }
    [ -x "$PANEL_PREFIX/bin/xfce4-panel" ] || { echo "No panel in $PANEL_PREFIX (make install first)" >&2; exit 1; }

    mkdir -p "$RUN_DIR" "$TEST_HOME/.config" "$TEST_HOME/.cache" "$TEST_HOME/.local/share"
    chmod 700 "$RUN_DIR"

    setsid Xtightvnc ":$DISPLAY_NUM" -rfbport "$RFB_PORT" -localhost \
        -rfbauth "$PASSWD_FILE" -desktop "xfce4-panel test" \
        -geometry "$GEOMETRY" -depth 24 -alwaysshared \
        > "$RUN_DIR/xvnc.log" 2>&1 &

    for _ in $(seq 1 50); do
        [ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ] && break
        sleep 0.1
    done
    [ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ] || { echo "Xtightvnc did not start; see $RUN_DIR/xvnc.log" >&2; exit 1; }

    # Same DPI the Xephyr helper uses, so panel sizing matches (override with DPI=...).
    printf 'Xft.dpi: %s\n' "${DPI:-65}" | DISPLAY=":$DISPLAY_NUM" xrdb -merge

    setsid env -i \
        HOME="$TEST_HOME" \
        PATH="$PANEL_PREFIX/bin:$PATH" \
        LD_LIBRARY_PATH="$PANEL_PREFIX/lib" \
        DISPLAY=":$DISPLAY_NUM" \
        XDG_CONFIG_HOME="$TEST_HOME/.config" \
        XDG_CACHE_HOME="$TEST_HOME/.cache" \
        XDG_DATA_HOME="$TEST_HOME/.local/share" \
        XDG_DATA_DIRS="$PANEL_PREFIX/share:/usr/local/share:/usr/share" \
        XDG_CONFIG_DIRS="$PANEL_PREFIX/etc/xdg:/etc/xdg" \
        XDG_RUNTIME_DIR="$RUN_DIR" \
        dbus-run-session -- sh -c 'xfwm4 --compositor=off & exec xfce4-panel' \
        > "$RUN_DIR/session.log" 2>&1 &
    echo $! > "$RUN_DIR/session.pid"

    echo "Xtightvnc :$DISPLAY_NUM ready on localhost:$RFB_PORT ($GEOMETRY), HOME=$TEST_HOME"
    echo "Tunnel with: ssh -L $RFB_PORT:localhost:$RFB_PORT <host>"
}

stop() {
    local pid
    pid=$(session_pid)
    # Signal the session's process group (dbus, xfwm4, panel), then Xtightvnc.
    [ -n "$pid" ] && kill -- "-$pid" 2>/dev/null || true
    pid=$(xvnc_pid)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$RUN_DIR/session.pid"
    echo "stopped"
}

status() {
    echo "Xtightvnc :$DISPLAY_NUM pid: $(xvnc_pid)"
    echo "session pid: $(session_pid)"
    echo "panel:  $(pgrep -u "$(id -u)" -x xfce4-panel | tr '\n' ' ')"
    echo "xfwm4:  $(pgrep -u "$(id -u)" -x xfwm4 | tr '\n' ' ')"
}

session_exec() {
    local pid env_file
    pid=$(pgrep -u "$(id -u)" -x xfce4-panel | head -n1)
    [ -n "$pid" ] || { echo "panel is not running" >&2; exit 1; }
    env_file=/proc/$pid/environ
    exec env -i \
        HOME="$TEST_HOME" PATH="$PANEL_PREFIX/bin:$PATH" LD_LIBRARY_PATH="$PANEL_PREFIX/lib" \
        DISPLAY=":$DISPLAY_NUM" \
        DBUS_SESSION_BUS_ADDRESS="$(tr '\0' '\n' < "$env_file" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')" \
        XDG_CONFIG_HOME="$TEST_HOME/.config" XDG_CACHE_HOME="$TEST_HOME/.cache" \
        XDG_DATA_HOME="$TEST_HOME/.local/share" XDG_RUNTIME_DIR="$RUN_DIR" \
        "$@"
}

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    exec)    shift; [ "$#" -gt 0 ] || { echo "Usage: $0 exec <command...>" >&2; exit 2; }; session_exec "$@" ;;
    *)       echo "Usage: $0 start|stop|restart|status|exec <command...>" >&2; exit 2 ;;
esac
