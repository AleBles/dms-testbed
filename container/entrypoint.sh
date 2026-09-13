#!/usr/bin/env bash
# dms-testbed entrypoint: start one compositor nested on the host Wayland display, with DMS inside.
#   entrypoint.sh <mango|niri|hyprland>
set -euo pipefail

COMP=${1:?usage: entrypoint.sh <mango|niri|hyprland>}
case "$COMP" in mango|niri|hyprland) ;; *) echo "unknown compositor: $COMP" >&2; exit 2 ;; esac

log() { printf '[testbed] %s\n' "$*" >&2; }

# ---- runtime dir and host display --------------------------------------------------------------
[ -w "$XDG_RUNTIME_DIR" ] || { log "XDG_RUNTIME_DIR $XDG_RUNTIME_DIR is not writable (mount a tmpfs owned by uid 1000)"; exit 1; }
chmod 700 "$XDG_RUNTIME_DIR"
HOST_SOCK=/run/host-wayland/wayland-1
[ -S "$HOST_SOCK" ] || { log "host Wayland socket missing at $HOST_SOCK"; exit 1; }
# A relative name for the host display; the nested compositor creates its own wayland-N next to it.
ln -sfn "$HOST_SOCK" "$XDG_RUNTIME_DIR/wayland-host"

# Never let host compositor identity leak into the nested session (DMS falls back to these vars).
unset HYPRLAND_INSTANCE_SIGNATURE NIRI_SOCKET MANGO_INSTANCE_SIGNATURE DISPLAY \
      DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_ID WAYLAND_SOCKET || true

# ---- session bus at a fixed path so `docker exec` can find it ------------------------------------
dbus-daemon --session --fork --nopidfile --address="unix:path=$XDG_RUNTIME_DIR/bus"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# ---- plugins: /plugins/<dir> (host repos, read-only) -> ~/.config/DankMaterialShell/plugins/<dir>
PLUGDIR="$XDG_CONFIG_HOME/DankMaterialShell/plugins"
mkdir -p "$PLUGDIR"
find "$PLUGDIR" -maxdepth 1 -xtype l -delete 2>/dev/null || true       # dangling links
shopt -s nullglob
for manifest in /plugins/*/plugin.json; do
    dir=$(dirname "$manifest")
    ln -sfn "$dir" "$PLUGDIR/$(basename "$dir")"
    log "plugin: $(jq -r '.id // "?"' "$manifest") <- $dir"
done
shopt -u nullglob

# ---- first-run DMS setup (idempotent: existing configs are kept) ---------------------------------
dms setup headless --compositor "$COMP" --terminal kitty --no-systemd --skip-existing \
    || log "dms setup headless returned $? (continuing with existing configs)"

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
                    | grep -E '^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|NIRI_SOCKET|MANGO_INSTANCE_SIGNATURE|XDG_CURRENT_DESKTOP)=' || true
            } > "$ENVFILE.tmp" && mv "$ENVFILE.tmp" "$ENVFILE"
            log "shell is up (qs pid $pid); env for docker exec written"
            sleep 2
            (
                set -a; . "$ENVFILE"; set +a
                for manifest in /plugins/*/plugin.json; do
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
esac
