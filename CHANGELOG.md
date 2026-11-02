# Changelog

All notable changes to dms-testbed are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-09-17

### Added
- sway, labwc and Miracle WM containers next to Hyprland, niri and Mango, so every compositor DMS
  documents can be tested. Their whole compositor config is a testbed overlay (DMS has no generator
  for them): `container/overlays/{sway,labwc,miracle}`.
- `switch <comp> <n>`: focus workspace/tag/desktop `n` with whatever the compositor calls it
  (`hyprctl`, `niri msg`, `mmsg`, `swaymsg`, Miracle's i3 IPC, `wtype` for labwc).
- `start <comp>|all`: start stopped containers again with their mounts, without recreating them.
- `restart-shell <comp>`: restart DMS inside a running container. Needed after adding new files to a
  plugin, because Qt caches the directory listing at first load.
- Nested compositor windows are parked on host Hyprland workspaces `TESTBED_HOST_WORKSPACES` (default
  `9 10`), spread evenly, instead of opening on the active workspace.
- `CHANGELOG.md`.

### Changed
- Plugin repos are bind-mounted straight into `~/.config/dms/plugins/<dir>` instead of
  `/plugins/<dir>` plus a symlink.
- DankMaterialShell is now Dux Shell (DMS 2.0): the image installs from the `duxlabs/dms` and
  `duxlabs/dux-repo` COPRs instead of `avengemedia/dms` and `avengemedia/danklinux`, and plugins are
  mounted under `~/.config/dms/plugins/`, the directory 2.0 reads (`~/.config/DankMaterialShell/` is gone).
- Readiness waits for the shell's built-in `plugins` IPC target instead of the Spotlight Focus plugin's.
- Miracle WM runs on Mir's headless virtual output by default. Nested Mir crashed in its GL renderer on
  the render node and stalled its event loop with software buffers on the machine this was written on;
  `TESTBED_MIRACLE_NESTED=1 ./testbed.sh run miracle` tries nesting anyway. `container/overlays/miracle/launch.sh`
  starts DMS on Mir's own display (`wayland-mir`) with Mir's i3-compatible IPC socket exported.
- `shot` writes to a temp file first, so a failed capture never leaves a 0-byte screenshot.
- Fedora's sway binary has its `cap_sys_nice` file capability removed in the image; a container's
  bounding set lacks it and exec would fail with EPERM.
- `stop all` / `rm all` issue a single docker command for all containers; `start all` starts every
  container before waiting on any of them.

### Fixed
- The host parking rule is re-added on every `run`/`start`. It used to be added once per Hyprland
  instance behind a marker file, so after a host config reload new windows opened on the focused
  monitor until they were moved.
- `TESTBED_HOST_MONITOR` pins the parking workspaces to one host monitor.
- Nested compositor windows get Hyprland's `render_unfocused` on the host. Parked on a hidden
  workspace they received no frame callbacks: `shot` hung in grim, and DMS inside blocked its main
  thread the first time it mapped a window, so every later `dms ipc` call hung.
- `wait_ready` returns non-zero on timeout, so `run X && ...` chains stop on a shell that never came up.
- `restart-shell` waits for a new shell process instead of accepting the old one's log lines and IPC.
- `start all` continues with the next compositor when one container fails to start.
- The Miracle launcher waits for both Mir's display socket and its IPC socket.

## [0.1.0] - 2026-09-13

### Added
- Initial release: Hyprland, niri and Mango nested in Docker with DMS and mounted plugin repos.
