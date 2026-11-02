#!/usr/bin/env bash
# dms-testbed launcher for Miracle WM. The entrypoint starts Mir with WAYLAND_DISPLAY=wayland-mir (the
# display Mir creates) and --wayland-host=wayland-host (the one it runs on). Wait for that socket and for
# Mir's i3-compatible IPC socket, then start DMS and the test windows on them. Started in the background
# by the entrypoint before miracle-wm.
set -u
shopt -s nullglob
export WAYLAND_DISPLAY=wayland-mir
for _ in $(seq 1 240); do
    ipc=""
    for sock in "$XDG_RUNTIME_DIR"/miracle-wm-ipc.*.sock; do [ -S "$sock" ] && ipc=$sock; done
    if [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && [ -n "$ipc" ]; then
        # Mir exports the IPC socket only to apps it launches itself; DMS (Quickshell.I3) and swaymsg need it.
        export MIRACLESOCK="$ipc" SWAYSOCK="$ipc" I3SOCK="$ipc"
        printf '[testbed] miracle: Mir display %s and IPC %s are up, starting dms\n' "$WAYLAND_DISPLAY" "$ipc" >&2
        dms run &
        /opt/testbed/overlays/common/testbed-windows.sh &
        wait
        exit 0
    fi
    sleep 0.5
done
printf '[testbed] miracle: Mir did not create %s and an IPC socket within 120s; dms not started\n' "$WAYLAND_DISPLAY" >&2
exit 1
