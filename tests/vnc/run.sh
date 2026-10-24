#!/bin/bash
# Build xfce4-panel from scratch and test it in a dedicated TightVNC desktop.
#
# Runs entirely on the machine it is started on (intended: a shell on `dev`):
#   ~/xfce4-panel/tests/vnc/run.sh
#
# Steps: copy the tracked source files to a fresh work dir, ./autogen.sh,
# make, make install into a private prefix, start Xtightvnc + xfwm4 + the
# panel with a throwaway HOME and password (via vnc-panel.sh), then run
# tests/vnc/test_panel.py against that display. Exit status is the test
# result (0 = all passed).
#
# Environment:
#   TEST_DISPLAY  X display number for the test server (default 77)
#   WORK_DIR      work directory (default: new ~/panel-vnc-test.XXXXXX)
#   KEEP=1        leave the VNC desktop and work dir up afterwards, so you
#                 can connect and look (connection details are printed)
#   SKIP_BUILD=1  reuse WORK_DIR's existing build/install (needs WORK_DIR)
#   JOBS          make parallelism (default: nproc)
#
# Needs: the build dependencies in debian/control, plus tightvncserver,
# xfwm4, dbus-x11, xauth, python3-xlib.

set -eu

SRC_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TEST_DISPLAY=${TEST_DISPLAY:-77}
JOBS=${JOBS:-$(nproc)}
KEEP=${KEEP:-0}
SKIP_BUILD=${SKIP_BUILD:-0}

if [ -n "${WORK_DIR:-}" ]; then
    mkdir -p "$WORK_DIR"
else
    [ "$SKIP_BUILD" = 1 ] && { echo "SKIP_BUILD needs WORK_DIR" >&2; exit 2; }
    WORK_DIR=$(mktemp -d "$HOME/panel-vnc-test.XXXXXX")
fi
WORK_DIR=$(cd "$WORK_DIR" && pwd)
BUILD_SRC=$WORK_DIR/src
PREFIX=$WORK_DIR/prefix
TEST_HOME=$WORK_DIR/home
PASSWD_FILE=$WORK_DIR/vnc-passwd
RFB_PORT=$((5900 + TEST_DISPLAY))

step() { printf '\n==> %s\n' "$*"; }
die()  { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
    status=$?
    if [ "$KEEP" != 1 ]; then
        DISPLAY_NUM=$TEST_DISPLAY TEST_HOME=$TEST_HOME PASSWD_FILE=$PASSWD_FILE \
            PANEL_PREFIX=$PREFIX "$BUILD_SRC/vnc-panel.sh" stop >/dev/null 2>&1 || true
    fi
    exit $status
}
trap cleanup EXIT

command -v Xtightvnc >/dev/null || die "Xtightvnc not installed"
[ -e "/tmp/.X11-unix/X$TEST_DISPLAY" ] && die "display :$TEST_DISPLAY already in use (set TEST_DISPLAY)"

if [ "$SKIP_BUILD" != 1 ]; then
    step "Copying tracked source to $BUILD_SRC"
    rm -rf "$BUILD_SRC" "$PREFIX"
    mkdir -p "$BUILD_SRC"
    git -C "$SRC_DIR" ls-files -z | rsync -a0 --files-from=- "$SRC_DIR/" "$BUILD_SRC/"

    step "Building (log: $WORK_DIR/build.log)"
    (
        cd "$BUILD_SRC"
        ./autogen.sh --prefix="$PREFIX" --libdir="$PREFIX/lib" --sysconfdir="$PREFIX/etc"
        make -j"$JOBS"
        make install
    ) > "$WORK_DIR/build.log" 2>&1 || { tail -n 40 "$WORK_DIR/build.log" >&2; die "build failed (see $WORK_DIR/build.log)"; }
    echo "build ok"
else
    [ -x "$PREFIX/bin/xfce4-panel" ] || die "SKIP_BUILD set but $PREFIX/bin/xfce4-panel missing"
    # still refresh the helper scripts from the working tree
    cp "$SRC_DIR/vnc-panel.sh" "$BUILD_SRC/vnc-panel.sh"
    rm -rf "$TEST_HOME"
fi

step "Starting TightVNC desktop :$TEST_DISPLAY"
# Fixed single-panel layout of built-in plugins only, so results do not depend
# on the host's /etc/xdg default (which may name plugins that are not built here).
mkdir -p "$TEST_HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
cp "$SRC_DIR/tests/vnc/xfce4-panel.xml" "$TEST_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/"
VNC_PW=$(tr -dc 'a-z0-9' < /dev/urandom | head -c8)
printf '%s\n' "$VNC_PW" | tightvncpasswd -f > "$PASSWD_FILE"
chmod 600 "$PASSWD_FILE"
export DISPLAY_NUM=$TEST_DISPLAY TEST_HOME PASSWD_FILE PANEL_PREFIX=$PREFIX
"$BUILD_SRC/vnc-panel.sh" start
echo "VNC password: $VNC_PW   (view: ssh -L $RFB_PORT:localhost:$RFB_PORT <host>, vncviewer localhost::$RFB_PORT)"

step "Running tests"
set +e
DISPLAY=":$TEST_DISPLAY" VNC_PANEL="$BUILD_SRC/vnc-panel.sh" \
    SESSION_LOG="$TEST_HOME/run/session.log" \
    python3 -I "$SRC_DIR/tests/vnc/test_panel.py"
rc=$?
set -e

if [ "$KEEP" = 1 ]; then
    echo "KEEP=1: desktop :$TEST_DISPLAY left running; stop with:"
    echo "  DISPLAY_NUM=$TEST_DISPLAY TEST_HOME=$TEST_HOME PASSWD_FILE=$PASSWD_FILE PANEL_PREFIX=$PREFIX $BUILD_SRC/vnc-panel.sh stop"
else
    [ "$rc" = 0 ] && rm -rf "$WORK_DIR" || echo "work dir kept for inspection: $WORK_DIR"
fi
exit $rc
