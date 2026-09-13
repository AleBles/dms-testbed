#!/usr/bin/env bash
# dms-testbed launcher for Miracle WM. The entrypoint starts Mir with WAYLAND_DISPLAY=wayland-mir (the
# display Mir creates) and --wayland-host=wayland-host (the one it runs on). Wait for that socket, then
# start DMS and the test windows on it. Started in the background by the entrypoint before miracle-wm.
set -u
export WAYLAND_DISPLAY=wayland-mir
for _ in $(seq 1 120); do
    if [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
        # Mir exports its i3-compatible IPC socket only to apps it launches itself; DMS (Quickshell.I3) and
        # swaymsg need it in the environment.
        for sock in "$XDG_RUNTIME_DIR"/miracle-wm-ipc.*.sock; do
            [ -S "$sock" ] && export MIRACLESOCK="$sock" SWAYSOCK="$sock" I3SOCK="$sock"
        done
        printf '[testbed] miracle: Mir display %s is up (ipc %s), starting dms\n' "$WAYLAND_DISPLAY" "${MIRACLESOCK:-none}" >&2
        dms run &
        /opt/testbed/overlays/common/testbed-windows.sh &
        wait
        exit 0
    fi
    sleep 0.5
done
printf '[testbed] miracle: Mir never created %s; dms not started\n' "$WAYLAND_DISPLAY" >&2
exit 1
