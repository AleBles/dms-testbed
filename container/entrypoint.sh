#!/usr/bin/env bash
# dms-testbed entrypoint: start one compositor nested on the host Wayland display, with DMS inside.
#   entrypoint.sh <mango|niri|hyprland|sway|labwc|miracle>
set -euo pipefail

COMP=${1:?usage: entrypoint.sh <mango|niri|hyprland|sway|labwc|miracle>}
case "$COMP" in mango|niri|hyprland|sway|labwc|miracle) ;; *) echo "unknown compositor: $COMP" >&2; exit 2 ;; esac

log() { printf '[testbed] %s\n' "$*" >&2; }

# ---- runtime dir and host display --------------------------------------------------------------
[ -w "$XDG_RUNTIME_DIR" ] || { log "XDG_RUNTIME_DIR $XDG_RUNTIME_DIR is not writable (mount a tmpfs owned by uid 1000)"; exit 1; }
chmod 700 "$XDG_RUNTIME_DIR"
HOST_SOCK=/run/host-wayland/wayland-1
[ -S "$HOST_SOCK" ] || { log "host Wayland socket missing at $HOST_SOCK"; exit 1; }
# A relative name for the host display; the nested compositor creates its own wayland-N next to it.
ln -sfn "$HOST_SOCK" "$XDG_RUNTIME_DIR/wayland-host"

# Never let host compositor identity leak into the nested session (DMS falls back to these vars).
unset HYPRLAND_INSTANCE_SIGNATURE NIRI_SOCKET MANGO_INSTANCE_SIGNATURE SWAYSOCK I3SOCK MIRACLESOCK LABWC_PID DISPLAY \
      DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_ID WAYLAND_SOCKET || true

# ---- session bus at a fixed path so `docker exec` can find it ------------------------------------
dbus-daemon --session --fork --nopidfile --address="unix:path=$XDG_RUNTIME_DIR/bus"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# ---- plugins: host repos are bind-mounted read-only at ~/.config/DankMaterialShell/plugins/<dir> ------
PLUGDIR="$XDG_CONFIG_HOME/DankMaterialShell/plugins"
mkdir -p "$PLUGDIR"
find "$PLUGDIR" -maxdepth 1 -xtype l -delete 2>/dev/null || true       # links left by older testbed versions
shopt -s nullglob
for manifest in "$PLUGDIR"/*/plugin.json; do
    log "plugin: $(jq -r '.id // "?"' "$manifest") <- $(dirname "$manifest")"
done
shopt -u nullglob

# ---- first-run DMS setup (idempotent: existing configs are kept) ---------------------------------
# `dms setup headless` knows niri, Hyprland and Mango; sway, labwc and miracle get testbed-owned configs.
case "$COMP" in
mango|niri|hyprland)
    dms setup headless --compositor "$COMP" --terminal kitty --no-systemd --skip-existing \
        || log "dms setup headless returned $? (continuing with existing configs)"
    ;;
esac

# ---- testbed overlay: copied fresh every start, included from the DMS-owned main config once ------
OVL=/opt/testbed/overlays/$COMP
append_once() { grep -qxF -- "$2" "$1" 2>/dev/null || printf '\n%s\n' "$2" >> "$1"; }
case "$COMP" in
mango)
    CFG="$XDG_CONFIG_HOME/mango/config.conf"
    cp "$OVL/testbed.conf" "$XDG_CONFIG_HOME/mango/testbed.conf"
    append_once "$CFG" 'source=./testbed.conf'
    ;;
niri)
    CFG="$XDG_CONFIG_HOME/niri/config.kdl"
    cp "$OVL/testbed.kdl" "$XDG_CONFIG_HOME/niri/testbed.kdl"
    append_once "$CFG" 'include optional=true "testbed.kdl"'
    if ! niri validate -c "$CFG" >/dev/null 2>&1; then
        log "niri config invalid with the testbed binds block; retrying without binds (drive via testbed.sh ipc)"
        awk 'BEGIN{skip=0} /^binds \{/{skip=1} skip&&/^\}/{skip=0; next} !skip' "$OVL/testbed.kdl" \
            > "$XDG_CONFIG_HOME/niri/testbed.kdl"
        niri validate -c "$CFG" || { log "niri config still invalid:"; niri validate -c "$CFG" 2>&1 | head -20 >&2; }
    fi
    ;;
hyprland)
    CFG="$XDG_CONFIG_HOME/hypr/hyprland.lua"
    cp "$OVL/testbed.lua" "$XDG_CONFIG_HOME/hypr/testbed.lua"
    append_once "$CFG" 'require("testbed")'
    ;;
sway)
    # Whole config is testbed-owned (DMS has no sway generator); replaced on every start.
    mkdir -p "$XDG_CONFIG_HOME/sway"
    CFG="$XDG_CONFIG_HOME/sway/config"
    cp "$OVL/config" "$CFG"
    ;;
labwc)
    mkdir -p "$XDG_CONFIG_HOME/labwc"
    CFG="$XDG_CONFIG_HOME/labwc"
    cp "$OVL/rc.xml" "$OVL/autostart" "$CFG/"
    chmod +x "$CFG/autostart"
    ;;
miracle)
    mkdir -p "$XDG_CONFIG_HOME/miracle-wm"
    CFG="$XDG_CONFIG_HOME/miracle-wm/config.yaml"
    cp "$OVL/config.yaml" "$CFG"
    ;;
esac

# ---- environment for the nested compositor -----------------------------------------------------
export WAYLAND_DISPLAY=wayland-host
export DMS_LOG_FILE="$XDG_STATE_HOME/dms-testbed/dms-$COMP.log"
: > "$DMS_LOG_FILE"
if [ "${TESTBED_SOFTWARE:-0}" = "1" ]; then
    log "software rendering requested"
    export WLR_RENDERER_ALLOW_SOFTWARE=1 LIBGL_ALWAYS_SOFTWARE=1 QT_QUICK_BACKEND=software
fi

# ---- env file for `docker exec`: taken from the shell process once it runs ------------------------
ENVFILE="$XDG_RUNTIME_DIR/testbed.env"
printf 'DBUS_SESSION_BUS_ADDRESS=%s\n' "$DBUS_SESSION_BUS_ADDRESS" > "$ENVFILE"
(
    for _ in $(seq 1 120); do
        pid=$(pgrep -x qs | head -1 || true)
        if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
            {
                printf 'DBUS_SESSION_BUS_ADDRESS=%s\n' "$DBUS_SESSION_BUS_ADDRESS"
                tr '\0' '\n' < "/proc/$pid/environ" \
                    | grep -E '^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|NIRI_SOCKET|MANGO_INSTANCE_SIGNATURE|SWAYSOCK|I3SOCK|MIRACLESOCK|LABWC_PID|XDG_CURRENT_DESKTOP)=' || true
            } > "$ENVFILE.tmp" && mv "$ENVFILE.tmp" "$ENVFILE"
            log "shell is up (qs pid $pid); env for docker exec written"
            sleep 2
            (
                set -a; . "$ENVFILE"; set +a
                for manifest in "$PLUGDIR"/*/plugin.json; do
                    [ -f "$manifest" ] || continue
                    id=$(jq -r '.id // empty' "$manifest"); [ -n "$id" ] || continue
                    out=$(dms ipc call plugins enable "$id" 2>&1 || true)
                    log "plugin $id: ${out:-enabled}"
                done
            )
            exit 0
        fi
        sleep 1
    done
    log "shell did not start within 120s; check $DMS_LOG_FILE"
) &

# ---- launch (exec: the compositor becomes the container's main process) --------------------------
log "starting $COMP nested on the host display; DMS log: $DMS_LOG_FILE"
case "$COMP" in
mango)
    export WLR_BACKENDS=wayland WLR_WL_OUTPUTS=1
    exec mango -c "$CFG"                       # DMS starts from exec-once in config.conf
    ;;
niri)
    exec niri -c "$CFG"                        # no --session when nested; spawn-at-startup runs dms
    ;;
hyprland)
    exec Hyprland -c "$CFG"                    # no DRM card in the container -> Aquamarine Wayland backend
    ;;
sway)
    export WLR_BACKENDS=wayland
    exec sway -c "$CFG"                        # config execs dms run and the test windows
    ;;
labwc)
    export WLR_BACKENDS=wayland
    exec labwc -C "$CFG"                       # autostart runs dms run and the test windows
    ;;
miracle)
    # Mir nested on the host display: --wayland-host is the display Mir runs on, WAYLAND_DISPLAY the one it
    # creates (with wayland-host in WAYLAND_DISPLAY it tries to bind over the host symlink and silently ends
    # up with no client socket). launch.sh waits for wayland-mir and starts dms + the test windows on it;
    # startup_apps would inherit the wrong display. X11 off: Xwayland only adds noise here.
    /opt/testbed/overlays/miracle/launch.sh &
    export WAYLAND_DISPLAY=wayland-mir
    # all extensions: virtual keyboard (wtype for `switch`), screencopy (grim for `shot`), foreign toplevels (DMS)
    if [ "${TESTBED_MIRACLE_NESTED:-0}" = 1 ]; then
        # Mir's nested Wayland platform: crashes in GLRenderer on the render node here and stalls its event
        # loop with software buffers, so it is opt-in. Default below is a headless virtual output instead.
        exec miracle-wm --wayland-host=wayland-host --enable-x11=0 --add-wayland-extensions=all
    fi
    log "miracle: headless virtual output (no host window); use TESTBED_MIRACLE_NESTED=1 to try nesting"
    exec miracle-wm --platform-display-libs=mir:virtual --virtual-output=1600x900 --enable-x11=0 --add-wayland-extensions=all
    ;;
esac
