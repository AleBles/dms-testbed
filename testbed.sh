#!/usr/bin/env bash
# dms-testbed host CLI: run DMS + a compositor nested in a Docker container, as a window on this desktop.
# Works from a plugin repo (the current directory is mounted when it has a plugin.json) or standalone.
#
#   dms-testbed pull | build [--no-cache]              # image: ghcr.io/alebles/dms-testbed (build tags it locally)
#   dms-testbed run <comp> [--sw] [--plugin DIR]...   # comp: mango|niri|hyprland|sway|labwc|miracle; --sw: software rendering (wlroots ones)
#   dms-testbed open <comp> [query]                    # open the launcher, optionally pre-filled ("> ")
#   dms-testbed ipc <comp> <target> <function> [args]  # e.g. ipc mango spotlight toggleQuery "> "
#   dms-testbed exec <comp> <command...>               # run a command inside the session (hyprctl, niri msg, mmsg, swaymsg)
#   dms-testbed switch <comp> <n>                      # focus workspace/tag/desktop n, whatever the compositor calls it
#   dms-testbed reload <comp> [pluginId]              # default pluginId: spotlightFocus
#   dms-testbed start <comp>|all                      # start a stopped container again (same mounts, no recreate)
#   dms-testbed restart-shell <comp>                  # restart DMS inside the running container (after adding plugin files)
#   dms-testbed shell <comp>                          # bash inside the session env
#   dms-testbed logs <comp> [--dms]                   # compositor log, or the DMS log
#   dms-testbed shot <comp> [out.png]                 # screenshot taken inside the nested compositor
#   dms-testbed status | stop <comp>|all | rm <comp>|all [--purge]
#
# Plugins mounted by `run` (read-only into ~/.config/dms/plugins/): every --plugin DIR; else the current directory if it has a plugin.json;
# else every $TESTBED_PLUGIN_ROOT/$TESTBED_PLUGIN_GLOB dir with one (defaults: parent dir, dms-*).
# Env overrides: TESTBED_IMAGE, TESTBED_PLUGIN_ROOT, TESTBED_PLUGIN_GLOB, TESTBED_HOST_WORKSPACES="9 10" (host
# Hyprland workspaces the nested windows are parked on, spread evenly; "" = leave them where they open),
# TESTBED_HOST_MONITOR=eDP-1 (create those workspaces on that monitor),
# TESTBED_HOST_TWEAKS=0 (no host Hyprland changes at all: no ANR ping tolerance, no window placement).
set -euo pipefail

IMAGE=${TESTBED_IMAGE:-ghcr.io/alebles/dms-testbed:latest}
PLUGIN_ROOT=${TESTBED_PLUGIN_ROOT:-$(dirname "$PWD")}
PLUGIN_GLOB=${TESTBED_PLUGIN_GLOB:-dms-*}
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

die() { printf 'testbed: %s\n' "$*" >&2; exit 1; }
ALL_COMPS="mango niri hyprland sway labwc miracle"
need_comp() {
    case " $ALL_COMPS " in *" ${1:-} "*) [ -n "${1:-}" ] ;; *) false ;; esac || die "compositor must be one of: $ALL_COMPS"
}
name_of() { printf 'dms-testbed-%s' "$1"; }
vol_of()  { printf 'dms-testbed-home-%s' "$1"; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]; }

check_host() {
    docker info >/dev/null 2>&1 || die "docker is not usable (daemon down or not in the docker group)"
    [ -n "${XDG_RUNTIME_DIR:-}" ] || die "XDG_RUNTIME_DIR is not set"
    [ -S "$XDG_RUNTIME_DIR/${WAYLAND_DISPLAY:-wayland-1}" ] || die "host Wayland socket $XDG_RUNTIME_DIR/${WAYLAND_DISPLAY:-} not found"
    [ -c /dev/dri/renderD128 ] || die "/dev/dri/renderD128 not found"
}

# One -v per plugin dir that has a plugin.json, bind-mounted straight into the DMS plugins dir.
# Args: explicit dirs; none = cwd or the sibling glob.
plugin_mounts() {
    local dirs=("$@") d
    if [ ${#dirs[@]} -eq 0 ]; then
        if [ -f "$PWD/plugin.json" ]; then dirs=("$PWD"); else dirs=("$PLUGIN_ROOT"/$PLUGIN_GLOB); fi
    fi
    for d in "${dirs[@]}"; do
        d=$(readlink -f "$d")
        [ -f "$d/plugin.json" ] || { echo "testbed: skipping $d (no plugin.json)" >&2; continue; }
        printf -- '-v\n%s:/home/tester/.config/dms/plugins/%s:ro\n' "$d" "$(basename "$d")"
    done
}

# Nested compositors stop answering xdg pings while their host window is hidden or during startup, and
# Hyprland's "not responding" dialog then offers to kill them. Raise the tolerance until the next config
# reload; permanent: hl.config({ misc = { anr_missed_pings = 60 } }) in hyprland.lua.
ANR_PINGS=60
host_anr_tolerance() {
    [ "${TESTBED_HOST_TWEAKS:-1}" = 1 ] || return 0
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null 2>&1 || return 0
    local cur; cur=$(hyprctl getoption misc:anr_missed_pings 2>/dev/null | awk '/int:/{print $2}')
    [ -n "$cur" ] || return 0
    [ "$cur" -ge "$ANR_PINGS" ] && return 0
    if hyprctl eval "hl.config({ misc = { anr_missed_pings = $ANR_PINGS } })" >/dev/null 2>&1 \
        || hyprctl keyword misc:anr_missed_pings "$ANR_PINGS" >/dev/null 2>&1; then
        echo "testbed: host Hyprland misc:anr_missed_pings raised $cur -> $ANR_PINGS until its next config reload (TESTBED_HOST_TWEAKS=0 to skip)" >&2
    fi
}

# A nested compositor window on a hidden host workspace gets no frame callbacks, so nothing inside it
# renders: grim (`shot`) waits forever, and DMS's Qt render threads block its main thread the first time
# it maps or unmaps a window, after which `dms ipc` hangs too. render_unfocused makes the host keep
# rendering those windows. Re-applied on every run/start: runtime rules are dropped on a config reload,
# and Hyprland applies a new rule to windows that are already open.
host_render_hidden() {
    [ "${TESTBED_HOST_TWEAKS:-1}" = 1 ] || return 0
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null 2>&1 || return 0
    hyprctl eval "hl.window_rule({ name = \"dms-testbed-render\", match = { class = \"$NESTED_CLASS_RE\" }, render_unfocused = true })" >/dev/null 2>&1 \
        || hyprctl keyword windowrule "renderunfocused, class:$NESTED_CLASS_RE" >/dev/null 2>&1 || true
}

# ---- host window placement (Hyprland host only) --------------------------------------------------
# Nested compositor windows would open on the active workspace; park them on TESTBED_HOST_WORKSPACES
# instead. A window rule sends new ones to the first workspace silently; after a container is ready,
# host_place_new moves the windows it created so the list stays evenly used.
HOST_WORKSPACES=${TESTBED_HOST_WORKSPACES-9 10}
HOST_MONITOR=${TESTBED_HOST_MONITOR:-}
NESTED_CLASS_RE='^(wlroots|niri|aquamarine|labwc|Hyprland)$'   # sway/mango: wlroots, nested Hyprland: aquamarine
host_hyprland() {
    [ "${TESTBED_HOST_TWEAKS:-1}" = 1 ] && [ -n "$HOST_WORKSPACES" ] && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null 2>&1
}
# Added on every run/start: a host config reload drops runtime rules, and a rule that is gone would let
# the next window open on whatever monitor has focus. Re-adding one that still exists is harmless.
# TESTBED_HOST_MONITOR (e.g. eDP-1) also pins those workspaces to one monitor, so they are never created
# on the monitor you are working on.
host_place_rule() {
    host_hyprland || return 0
    local first=${HOST_WORKSPACES%% *} ws
    if [ -n "$HOST_MONITOR" ]; then
        for ws in $HOST_WORKSPACES; do
            hyprctl eval "hl.workspace_rule({ workspace = \"$ws\", monitor = \"$HOST_MONITOR\" })" >/dev/null 2>&1 \
                || hyprctl keyword workspace "$ws, monitor:$HOST_MONITOR" >/dev/null 2>&1 || true
        done
    fi
    if hyprctl eval "hl.window_rule({ name = \"dms-testbed-place\", match = { class = \"$NESTED_CLASS_RE\" }, workspace = \"$first silent\" })" >/dev/null 2>&1 \
        || hyprctl keyword windowrule "workspace $first silent, class:$NESTED_CLASS_RE" >/dev/null 2>&1; then
        echo "testbed: host Hyprland rule: nested compositor windows open on workspace $first${HOST_MONITOR:+ on $HOST_MONITOR} (TESTBED_HOST_WORKSPACES${HOST_MONITOR:+, TESTBED_HOST_MONITOR})" >&2
    fi
}
# Addresses of nested compositor windows currently on the host, one per line.
host_snapshot() {
    host_hyprland || return 0
    hyprctl clients -j 2>/dev/null | jq -r --arg re "$NESTED_CLASS_RE" '.[] | select(.class|test($re)) | .address' 2>/dev/null || true
}
# Move windows that appeared since `before` to the target workspace holding the fewest nested windows.
host_place_new() {
    host_hyprland || return 0
    local before=$1 addr ws best bestcount count
    for addr in $(host_snapshot); do
        case "$before" in *"$addr"*) continue ;; esac
        best=""; bestcount=999
        for ws in $HOST_WORKSPACES; do
            count=$(hyprctl clients -j 2>/dev/null | jq -r --arg re "$NESTED_CLASS_RE" --argjson ws "$ws" '[.[] | select((.class|test($re)) and .workspace.id == $ws)] | length' 2>/dev/null || echo 0)
            [ "$count" -lt "$bestcount" ] && { best=$ws; bestcount=$count; }
        done
        [ -n "$best" ] || continue
        # Lua-config Hyprland first (follow=false keeps your view where it is), classic dispatcher as fallback.
        hyprctl dispatch "hl.dsp.window.move({ workspace = [[$best]], window = [[address:$addr]], follow = false })" >/dev/null 2>&1 \
            || hyprctl dispatch movetoworkspacesilent "$best,address:$addr" >/dev/null 2>&1 || true
    done
}

ensure_image() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 && return 0
    echo "testbed: image $IMAGE not present, pulling..." >&2
    docker pull "$IMAGE" >/dev/null || die "cannot pull $IMAGE; build it locally with: dms-testbed build"
}

# Run a command inside the session env of the container (WAYLAND_DISPLAY, DBUS, compositor sockets).
in_session() {
    local name=$1; shift
    docker exec -i "$name" sh -c 'set -a; [ -f /run/user/1000/testbed.env ] && . /run/user/1000/testbed.env; set +a; exec "$@"' sh "$@"
}

cmd_build() {
    local extra=()
    [ "${1:-}" = "--no-cache" ] && extra+=(--no-cache)
    [ -f "$HERE/Containerfile" ] || die "no Containerfile next to this script; use: dms-testbed pull"
    docker build "${extra[@]}" -t "$IMAGE" -f "$HERE/Containerfile" "$HERE"
    docker run --rm --entrypoint cat "$IMAGE" /etc/dms-testbed.version
}

cmd_pull() { docker pull "$IMAGE"; }

cmd_run() {
    local comp=$1; shift; need_comp "$comp"
    local sw=0 plugins=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --sw) sw=1 ;;
            --plugin) shift; [ -n "${1:-}" ] || die "--plugin needs a directory"; plugins+=("$1") ;;
            *) die "unknown option $1" ;;
        esac
        shift
    done
    check_host
    ensure_image
    host_anr_tolerance
    host_render_hidden
    host_place_rule
    local before; before=$(host_snapshot)
    local name; name=$(name_of "$comp")
    docker rm -f "$name" >/dev/null 2>&1 || true

    local mounts=()
    while IFS= read -r line; do mounts+=("$line"); done < <(plugin_mounts "${plugins[@]}")
    [ ${#mounts[@]} -gt 0 ] || echo "testbed: no plugin dirs with plugin.json found" >&2

    docker run -d --init --name "$name" --hostname "$name" \
        --security-opt label=disable \
        --device /dev/dri/renderD128 \
        --shm-size=1g \
        --tmpfs /run/user/1000:rw,mode=0700,uid=1000,gid=1000,size=256m \
        -v "$XDG_RUNTIME_DIR/${WAYLAND_DISPLAY:-wayland-1}:/run/host-wayland/wayland-1" \
        -v "$(vol_of "$comp"):/home/tester" \
        "${mounts[@]}" \
        -e "TESTBED_SOFTWARE=$sw" \
        -e "TESTBED_MIRACLE_NESTED=${TESTBED_MIRACLE_NESTED:-0}" \
        "$IMAGE" "$comp" >/dev/null

    echo "testbed: started $name; waiting for DMS to detect the compositor..."
    wait_ready "$comp"; local rc=$?
    host_place_new "$before"
    return $rc
}

# A fresh container: wait for DMS's compositor detection line (the entrypoint truncates the log at
# start, so it is always this boot's), then for the shell's IPC. Returns 1 when either never comes.
wait_ready() {
    local comp=$1 name; name=$(name_of "$comp")
    local i log=/home/tester/.local/state/dms-testbed/dms-$comp.log
    for i in $(seq 1 40); do
        running "$name" || { docker logs "$name" 2>&1 | tail -30; echo "testbed: $name exited" >&2; return 1; }
        if docker exec "$name" sh -c "grep -m1 'Detected' $log 2>/dev/null"; then break; fi
        sleep 1
    done
    wait_ipc "$comp"
}

# The shell registers its IPC targets a little after it starts; wait for the built-in plugins target.
wait_ipc() {
    local comp=$1 name; name=$(name_of "$comp")
    local i targets
    for i in $(seq 1 90); do
        running "$name" || { echo "testbed: $name exited" >&2; return 1; }
        # Capture instead of piping into grep -q: an early pipe close would fail under pipefail.
        targets=$(in_session "$name" dms ipc show 2>/dev/null || true)
        if [ "${targets#*target plugins}" != "$targets" ]; then
            echo "testbed: ready. Try: dms-testbed switch $comp 2   or   dms-testbed open $comp '> '"
            return 0
        fi
        sleep 1
    done
    echo "testbed: shell IPC not ready after waiting; check: dms-testbed logs $comp --dms" >&2
    return 1
}

cmd_ipc() {
    local comp=$1; shift; need_comp "$comp"
    local name; name=$(name_of "$comp")
    running "$name" || die "$name is not running"
    in_session "$name" dms ipc call "$@"
}

cmd_open() {
    local comp=$1; shift; need_comp "$comp"
    if [ $# -gt 0 ]; then cmd_ipc "$comp" spotlight openQuery "$1"; else cmd_ipc "$comp" spotlight open; fi
}

cmd_exec() {
    local comp=$1; shift; need_comp "$comp"
    local name; name=$(name_of "$comp")
    running "$name" || die "$name is not running"
    in_session "$name" "$@"
}

# Focus workspace n with whatever the compositor calls it (workspace, tag, desktop). labwc has no
# command IPC for this, so it gets the Ctrl+Alt+n keybind from the overlay typed over the
# virtual-keyboard protocol.
# The overlays bind Ctrl+Alt+1..3 on every compositor; typed over the virtual-keyboard protocol.
type_ctrl_alt() { cmd_exec "$1" wtype -M ctrl -M alt -k "$2" -m alt -m ctrl; }

cmd_switch() {
    local comp=$1; shift; need_comp "$comp"
    local n=${1:-}; case "$n" in ''|*[!0-9]*) die "switch needs a workspace number" ;; esac
    case "$comp" in
        hyprland) cmd_exec "$comp" hyprctl dispatch "hl.dsp.focus({ workspace = [[$n]] })" ;;
        niri)     cmd_exec "$comp" niri msg action focus-workspace "$n" ;;
        mango)    cmd_exec "$comp" mmsg dispatch "view,$n" ;;
        sway)     cmd_exec "$comp" swaymsg workspace number "$n" ;;
        miracle)  cmd_exec "$comp" sh -c '[ -n "$MIRACLESOCK" ] || { echo "MIRACLESOCK not set in the session" >&2; exit 1; }; swaymsg -s "$MIRACLESOCK" workspace "$1"' sh "$n" ;;   # no "number": miracle takes it literally
        labwc)    [ "$n" -ge 1 ] && [ "$n" -le 3 ] || die "labwc overlay binds desktops 1..3 only"; type_ctrl_alt "$comp" "$n" ;;
    esac
}

cmd_reload() {
    local comp=$1; shift; need_comp "$comp"
    cmd_ipc "$comp" plugins reload "${1:-spotlightFocus}"
}

# Start an existing, stopped container again (keeps its mounts and home volume; `run` would recreate it).
cmd_start() {
    check_host; host_anr_tolerance; host_render_hidden; host_place_rule
    local before; before=$(host_snapshot)
    local c name started=() rc=0
    for c in $(each_comp "${1:-}"); do
        name=$(name_of "$c")
        docker inspect "$name" >/dev/null 2>&1 || { echo "testbed: $name does not exist; use: dms-testbed run $c" >&2; rc=1; continue; }
        running "$name" && { echo "$name already running"; continue; }
        if docker start "$name" >/dev/null; then echo "started $name"; started+=("$c")
        else echo "testbed: could not start $name (a stale host Wayland socket? then: dms-testbed run $c)" >&2; rc=1; fi
    done
    # Boots are independent; wait only after every container is starting.
    for c in "${started[@]}"; do wait_ready "$c" || rc=1; done
    host_place_new "$before"
    return $rc
}

# Restart the shell inside the session. Needed after adding *new* files to a plugin: Qt caches the
# directory listing at first load, so `reload` alone reports "File name case mismatch" for them.
cmd_restart_shell() {
    local comp=$1; need_comp "$comp"
    local name; name=$(name_of "$comp")
    running "$name" || die "$name is not running"
    local old; old=$(docker exec "$name" pgrep -x qs 2>/dev/null | head -1 || true)
    [ -n "$old" ] || die "no shell process (qs) in $name; check: dms-testbed logs $comp --dms"
    in_session "$name" dms restart >/dev/null || die "dms restart failed in $name"
    # The old shell answers IPC and its log lines are still there until it is gone: wait for a new qs pid.
    local i new
    for i in $(seq 1 60); do
        new=$(docker exec "$name" pgrep -x qs 2>/dev/null | head -1 || true)
        [ -n "$new" ] && [ "$new" != "$old" ] && break
        sleep 1
    done
    [ -n "$new" ] && [ "$new" != "$old" ] || die "shell did not come back within 60s; check: dms-testbed logs $comp --dms"
    wait_ipc "$comp"
}

cmd_shell() {
    local comp=$1; need_comp "$comp"
    local name; name=$(name_of "$comp")
    running "$name" || die "$name is not running"
    docker exec -it "$name" bash -c 'set -a; [ -f /run/user/1000/testbed.env ] && . /run/user/1000/testbed.env; set +a; exec bash'
}

cmd_logs() {
    local comp=$1; shift; need_comp "$comp"
    local name; name=$(name_of "$comp")
    if [ "${1:-}" = "--dms" ]; then
        docker exec -i "$name" tail -n 200 -f "/home/tester/.local/state/dms-testbed/dms-$comp.log"
    else
        docker logs -f "$name"
    fi
}

cmd_shot() {
    local comp=$1; shift; need_comp "$comp"
    local out=${1:-./testbed-$comp-$(date +%H%M%S).png}
    local name; name=$(name_of "$comp")
    running "$name" || die "$name is not running"
    mkdir -p "$(dirname "$out")"
    # Write to a temp file first so a failed capture never leaves a 0-byte screenshot behind.
    local tmp="$out.part"
    if in_session "$name" sh -c 'grim -t png - ' > "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$out" && echo "$out"
    else
        rm -f "$tmp"; die "screenshot failed on $comp (grim needs wlr-screencopy and a mapped output)"
    fi
}

cmd_status() {
    docker ps -a --filter name='^dms-testbed-' --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    docker volume ls --filter name='^dms-testbed-home-' --format 'volume {{.Name}}'
}

each_comp() { if [ "${1:-}" = "all" ]; then echo "$ALL_COMPS"; else need_comp "${1:-}"; echo "$1"; fi; }

cmd_stop() {
    local c names=(); for c in $(each_comp "${1:-}"); do running "$(name_of "$c")" && names+=("$(name_of "$c")"); done
    [ ${#names[@]} -gt 0 ] || { echo "nothing running"; return 0; }
    docker stop -t 5 "${names[@]}" 2>/dev/null | sed 's/^/stopped /'
}

cmd_rm() {
    local target=${1:-}; shift || true
    local purge=0; [ "${1:-}" = "--purge" ] && purge=1
    local c names=() vols=()
    for c in $(each_comp "$target"); do names+=("$(name_of "$c")"); vols+=("$(vol_of "$c")"); done
    docker rm -f "${names[@]}" 2>/dev/null | sed 's/^/removed /' || true
    [ "$purge" = 1 ] && { docker volume rm "${vols[@]}" 2>/dev/null | sed 's/^/removed volume /' || true; }
    return 0
}

sub=${1:-}; shift || true
case "$sub" in
    build)  cmd_build "$@" ;;
    pull)   cmd_pull ;;
    run)    cmd_run "$@" ;;
    open)   cmd_open "$@" ;;
    ipc)    cmd_ipc "$@" ;;
    exec)   cmd_exec "$@" ;;
    switch) cmd_switch "$@" ;;
    reload) cmd_reload "$@" ;;
    start)  cmd_start "$@" ;;
    restart-shell) cmd_restart_shell "$@" ;;
    shell)  cmd_shell "$@" ;;
    logs)   cmd_logs "$@" ;;
    shot)   cmd_shot "$@" ;;
    status) cmd_status ;;
    stop)   cmd_stop "$@" ;;
    rm)     cmd_rm "$@" ;;
    ""|-h|--help|help) awk 'NR>1 { if ($0 !~ /^#/) exit; print }' "$0" ;;
    *) die "unknown subcommand: $sub (try --help)" ;;
esac
