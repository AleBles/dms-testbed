# dms-testbed

A Docker image with [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) and three compositors, Hyprland, niri and Mango (mangowc), for testing DMS plugins on compositors you do not run yourself. The chosen compositor starts **nested** against your host Wayland display, so it shows up as a normal window on your desktop. DMS runs inside it with your plugin repos mounted, and you drive the shell from the host with `dms ipc` through `docker exec`.

## Host requirements

- Fedora or any Linux with Docker, your user in the `docker` group
- A Wayland session (`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` must exist)
- A GPU render node at `/dev/dri/renderD128`
- A plugin repo with a `plugin.json`, or sibling repos matching `dms-*` (override with `TESTBED_PLUGIN_ROOT` and `TESTBED_PLUGIN_GLOB`)

## Using it from a plugin repo

The image is published to `ghcr.io/alebles/dms-testbed` by the workflow in this repo, so a plugin repo only needs the CLI. Add this repo as a git devDependency and call the `dms-testbed` bin from `package.json` scripts:

```json
{
  "devDependencies": { "dms-testbed": "github:AleBles/dms-testbed" },
  "scripts": {
    "test:mango": "dms-testbed run mango && dms-testbed open mango '> '",
    "test:niri": "dms-testbed run niri && dms-testbed open niri '> '",
    "test:hyprland": "dms-testbed run hyprland && dms-testbed open hyprland '> '",
    "test:stop": "dms-testbed stop all"
  }
}
```

`bun install` (or `npm install`) links the bin. `run` mounts the current directory when it has a `plugin.json`, pulls the image when it is not present locally, and `pull` fetches a newer one. Nothing in the image is needed at plugin runtime.

## Quick start (standalone)

```sh
./testbed.sh pull             # or: ./testbed.sh build   (Fedora 44 image: dms, quickshell-git, hyprland, niri, mangowm)
./testbed.sh run mango        # a Mango window appears; DMS starts inside with your plugins
./testbed.sh open mango "> "  # open the launcher pre-filled with a plugin trigger
./testbed.sh ipc mango spotlight toggleQuery "> "
./testbed.sh exec mango mmsg dispatch view,2   # any command inside the nested session
./testbed.sh reload mango spotlightFocus
./testbed.sh shot mango launcher.png   # screenshot from inside the nested compositor
./testbed.sh logs mango --dms
./testbed.sh stop mango
```

`run niri` and `run hyprland` work the same. All three can run at once; each has its own container and home volume. Standalone, `run` mounts every sibling directory matching `dms-*` that has a `plugin.json`; `--plugin DIR` picks explicit ones.

## What happens on `run`

1. The container gets a private tmpfs `XDG_RUNTIME_DIR`, the host Wayland socket at `/run/host-wayland/wayland-1`, the GPU render node, a named volume for `/home/tester`, and the plugin repos read-only under `/plugins/`.
2. The entrypoint starts a session D-Bus, links the plugins into `~/.config/DankMaterialShell/plugins/`, runs `dms setup headless --compositor <comp> --terminal kitty --no-systemd --skip-existing` on first run, and copies the testbed overlay from `container/overlays/<comp>/` into the compositor config.
3. The compositor starts nested with `WAYLAND_DISPLAY=wayland-host`. Its DMS-generated config starts `dms run`, and the overlay opens three `foot` terminals so the window switcher has content.
4. Once the shell runs, its environment is captured into `/run/user/1000/testbed.env`, which `testbed.sh ipc` and `shell` source so `dms ipc` reaches the right instance.

## Keys inside the nested window

The host compositor owns Super combos and the host DMS owns Alt+Space, so the overlays bind Ctrl+Alt:

| Keys | Action |
|---|---|
| Ctrl+Alt+Space | open the launcher with the Spotlight Focus trigger |
| Ctrl+Alt+Return | new `foot` terminal |
| Ctrl+Alt+1..3 | workspace or tag 1..3 |
| Ctrl+Alt+Q | close window (Mango, niri) |

Click into the nested window first so it has keyboard focus. If keys do not arrive, use `./testbed.sh ipc` instead.

## Per-compositor expectations

| | Mango | niri | Hyprland |
|---|---|---|---|
| Nesting | wlroots Wayland backend | winit window | Aquamarine Wayland backend, needs GPU |
| Live window previews | no, icons (quickshell 0.3 captures toplevels only via hyprland-toplevel-export) | no, icons | yes |
| Software rendering (`--sw`) | yes | yes, slow | no |
| Nested output name | `WL-1` | `winit` | `WAYLAND-1` |
| Workspaces | tags per monitor | named workspaces `logs` and `shell` from the overlay | numbered; overlay window rules put Test B on 2 and Test C on 3 |

## Editing plugins

Edit the plugin on the host as usual, then `./testbed.sh reload <comp> <pluginId>`. The DMS log is at `~/.local/state/dms-testbed/dms-<comp>.log` inside the volume (`logs <comp> --dms`).

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| No window appears | `./testbed.sh logs <comp>` | Hyprland cannot fall back to software rendering; try `run mango --sw` to rule out GPU access |
| DMS never reports "Detected ..." | `logs <comp> --dms` | `shell <comp>` then `WAYLAND_DISPLAY=wayland-host wayland-info \| head` to confirm the host socket works |
| Output never activates, `Swapchain for output ... failed test` in the log | a monitor rule with a custom mode in the overlay | remove it; the host window sizes the nested output |
| Host screenshot shows the wrong container | the nested windows overlap or sit on other host workspaces | use `./testbed.sh shot <comp>` |
| Hotkeys do nothing | | the host grabbed them; use `ipc` |
| Stale state after image changes | | `./testbed.sh rm <comp> --purge` recreates the home volume |
| Window vanished after a host compositor restart | | `./testbed.sh run <comp>` again; the mounted socket went stale |
| Host Hyprland shows "niri is not responding" (Terminate kills the container) | nested compositors miss xdg pings while their window is hidden or starting | `run` raises `misc:anr_missed_pings` to 60 until the next Hyprland config reload; make it permanent with `hl.config({ misc = { anr_missed_pings = 60 } })`, or set `TESTBED_HOST_TWEAKS=0` to leave the host alone |

## Publishing the image

`.github/workflows/publish.yml` builds the Containerfile and pushes `ghcr.io/<owner>/dms-testbed:latest` plus a commit-sha tag on every push to `main` that touches the image, weekly, and on manual dispatch. It uses the repository's `GITHUB_TOKEN`; make the package public once in the GitHub package settings so plugin repos can pull without logging in. `TESTBED_IMAGE` overrides the image name on the client side.
