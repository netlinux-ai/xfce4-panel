#!/bin/bash
# Run xfce4-panel inside a nested Xephyr window at 960x540.
#
# Usage: xephyr-panel.sh [command...]
#   Default command is the panel binary built in /Data/xfce4-panel
#   (override with PANEL_BIN). Any arguments replace the command.
#
# Isolation: the nested session gets its own HOME, XDG dirs and D-Bus
# session bus, so it cannot read or write the real desktop's config or
# attach to running single-instance apps. Only the Xephyr and session
# PIDs started here are signalled on exit.

set -eu

SIZE=960x540
PANEL_BIN=${PANEL_BIN:-/Data/xfce4-panel/panel/xfce4-panel}

# Pick the first spare display number from :6 upward.
DISPLAY_NUM=6
while [ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ] || [ -e "/tmp/.X$DISPLAY_NUM-lock" ]; do
    DISPLAY_NUM=$((DISPLAY_NUM + 1))
done
TEST_DISPLAY=":$DISPLAY_NUM"

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/xephyr-panel-home.XXXXXX")
XEPHYR_PID=""
SESSION_PID=""

cleanup() {
    [ -n "$SESSION_PID" ] && kill "$SESSION_PID" 2>/dev/null || true
    [ -n "$XEPHYR_PID" ] && kill "$XEPHYR_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$TEST_HOME"
}
trap cleanup EXIT INT TERM

if [ "$#" -gt 0 ]; then
    CMD=("$@")
else
    CMD=("$PANEL_BIN")
fi

# DPI for the nested screen, matching xfce4's Xft/DPI on :0 (override with DPI=...).
DPI=${DPI:-65}
DPI_ARGS=(-dpi "$DPI")

# Nested X server, started in its own session so it has its own process group.
setsid Xephyr "$TEST_DISPLAY" -screen "$SIZE" -ac -br -noreset -resizeable -retro "${DPI_ARGS[@]}" &
XEPHYR_PID=$!

for _ in $(seq 1 50); do
    [ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ] && break
    sleep 0.1
done
if [ ! -e "/tmp/.X11-unix/X$DISPLAY_NUM" ]; then
    echo "Xephyr did not start on $TEST_DISPLAY" >&2
    exit 1
fi

# GTK takes its font DPI from Xft.dpi in the server's resources, not the screen size,
# so load it into the nested server (not the real display) before the command runs.
printf 'Xft.dpi: %s\n' "$DPI" | DISPLAY="$TEST_DISPLAY" xrdb -merge

echo "Xephyr $TEST_DISPLAY at $SIZE, DPI $DPI (pid $XEPHYR_PID), HOME=$TEST_HOME"

# Run the command inside the nested display with isolated HOME/XDG/D-Bus.
setsid env -i \
    HOME="$TEST_HOME" \
    PATH="$PATH" \
    DISPLAY="$TEST_DISPLAY" \
    XDG_CONFIG_HOME="$TEST_HOME/.config" \
    XDG_CACHE_HOME="$TEST_HOME/.cache" \
    XDG_DATA_HOME="$TEST_HOME/.local/share" \
    XDG_RUNTIME_DIR="$TEST_HOME" \
    dbus-run-session -- "${CMD[@]}" &
SESSION_PID=$!

wait "$SESSION_PID" || true
