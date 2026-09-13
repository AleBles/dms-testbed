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
# Plugins mounted by `run` (read-only into ~/.config/DankMaterialShell/plugins/): every --plugin DIR; else the current directory if it has a plugin.json;
# else every $TESTBED_PLUGIN_ROOT/$TESTBED_PLUGIN_GLOB dir with one (defaults: parent dir, dms-*).
# Env overrides: TESTBED_IMAGE, TESTBED_PLUGIN_ROOT, TESTBED_PLUGIN_GLOB, TESTBED_HOST_TWEAKS=0 (do not
# raise the host Hyprland ANR ping tolerance; nested compositors miss pings while their window is hidden).
set -euo pipefail

IMAGE=${TESTBED_IMAGE:-ghcr.io/alebles/dms-testbed:latest}
PLUGIN_ROOT=${TESTBED_PLUGIN_ROOT:-$(dirname "$PWD")}
PLUGIN_GLOB=${TESTBED_PLUGIN_GLOB:-dms-*}
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

die() { printf 'testbed: %s\n' "$*" >&2; exit 1; }
ALL_COMPS="mango niri hyprland sway labwc miracle"
need_comp() {
    case "${1:-}" in mango|niri|hyprland|sway|labwc|miracle) ;; *) die "compositor must be one of: $ALL_COMPS" ;; esac
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
        printf -- '-v\n%s:/home/tester/.config/DankMaterialShell/plugins/%s:ro\n' "$d" "$(basename "$d")"
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
        "$IMAGE" "$comp" >/dev/null

    echo "testbed: started $name; waiting for DMS to detect the compositor..."
    wait_ready "$comp"
}

# Wait until the shell in the container answers IPC (the built-in plugins target).
wait_ready() {
    local comp=$1 name; name=$(name_of "$comp")
    local i
    for i in $(seq 1 40); do
        running "$name" || { docker logs "$name" 2>&1 | tail -30; die "$name exited"; }
        if docker exec "$name" sh -c "grep -q 'Detected' /home/tester/.local/state/dms-testbed/dms-$comp.log 2>/dev/null"; then
            docker exec "$name" sh -c "grep -m1 'Detected' /home/tester/.local/state/dms-testbed/dms-$comp.log"
            break
        fi
        sleep 1
    done
    # The shell registers its IPC targets a little after it starts; wait for the built-in plugins target.
    local targets
    for i in $(seq 1 90); do
        # Capture instead of piping into grep -q: an early pipe close would fail under pipefail.
        targets=$(in_session "$name" dms ipc show 2>/dev/null || true)
        if [ "${targets#*target plugins}" != "$targets" ]; then
            echo "testbed: ready. Try: dms-testbed switch $comp 2   or   dms-testbed open $comp '> '"
            return 0
        fi
        sleep 1
    done
    echo "testbed: shell IPC not ready after waiting; check: dms-testbed logs $comp --dms" >&2
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
cmd_switch() {
    local comp=$1; shift; need_comp "$comp"
    local n=${1:-}; [ -n "$n" ] || die "switch needs a workspace number"
    case "$comp" in
        hyprland) cmd_exec "$comp" hyprctl dispatch "hl.dsp.focus({ workspace = [[$n]] })" ;;
        niri)     cmd_exec "$comp" niri msg action focus-workspace "$n" ;;
        mango)    cmd_exec "$comp" mmsg dispatch "view,$n" ;;
        sway)     cmd_exec "$comp" swaymsg workspace number "$n" ;;
        miracle)  cmd_exec "$comp" sh -c 'swaymsg -s "$MIRACLESOCK" workspace "$1" 2>/dev/null || wtype -M ctrl -M alt -k "$1" -m alt -m ctrl' sh "$n" ;;   # no "number": miracle takes it literally
        labwc)    cmd_exec "$comp" wtype -M ctrl -M alt -k "$n" -m alt -m ctrl ;;
    esac
}

cmd_reload() {
    local comp=$1; shift; need_comp "$comp"
    cmd_ipc "$comp" plugins reload "${1:-spotlightFocus}"
}

# Start an existing, stopped container again (keeps its mounts and home volume; `run` would recreate it).
cmd_start() {
    local c name; for c in $(each_comp "${1:-}"); do
        name=$(name_of "$c")
        docker inspect "$name" >/dev/null 2>&1 || { echo "testbed: $name does not exist; use: dms-testbed run $c" >&2; continue; }
        running "$name" && { echo "$name already running"; continue; }
        check_host; host_anr_tolerance
        docker start "$name" >/dev/null && echo "started $name" && wait_ready "$c"
    done
}

# Restart the shell inside the session. Needed after adding *new* files to a plugin: Qt caches the
# directory listing at first load, so `reload` alone reports "File name case mismatch" for them.
cmd_restart_shell() {
    local comp=$1; need_comp "$comp"
    local name; name=$(name_of "$comp")
    running "$name" || die "$name is not running"
    in_session "$name" dms restart >/dev/null 2>&1 || true
    wait_ready "$comp"
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
    local c; for c in $(each_comp "${1:-}"); do docker stop -t 5 "$(name_of "$c")" >/dev/null 2>&1 && echo "stopped $(name_of "$c")" || true; done
}

cmd_rm() {
    local target=${1:-}; shift || true
    local purge=0; [ "${1:-}" = "--purge" ] && purge=1
    local c; for c in $(each_comp "$target"); do
        docker rm -f "$(name_of "$c")" >/dev/null 2>&1 && echo "removed $(name_of "$c")" || true
        if [ "$purge" = 1 ]; then
            docker volume rm "$(vol_of "$c")" >/dev/null 2>&1 && echo "removed volume $(vol_of "$c")" || true
        fi
    done
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
    ""|-h|--help|help) sed -n '2,22p' "$0" ;;
    *) die "unknown subcommand: $sub (try --help)" ;;
esac
