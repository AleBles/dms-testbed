-- dms-testbed overlay for Hyprland (Lua config). Copied in on every `testbed.sh run`; edit it in the repo.
-- The nested output is named WL-1 and is sized by the host window; DMS's outputs.lua already
-- applies a catch-all "preferred" mode, so no monitor rule here.

hl.on("hyprland.start", function()
	hl.exec_cmd("/opt/testbed/overlays/common/testbed-windows.sh")
end)

-- Host-safe binds: the host Hyprland owns SUPER combos and the host DMS owns ALT+space.
hl.bind("CTRL + ALT + space", hl.dsp.exec_cmd('dms ipc call spotlight toggleQuery "> "'))
hl.bind("CTRL + ALT + Return", hl.dsp.exec_cmd("foot"))
hl.bind("CTRL + ALT + 1", hl.dsp.focus({ workspace = "1" }))
hl.bind("CTRL + ALT + 2", hl.dsp.focus({ workspace = "2" }))
hl.bind("CTRL + ALT + 3", hl.dsp.focus({ workspace = "3" }))

-- Spread the test windows over workspaces. Wrapped in pcall: the rule key is the only form here
-- not taken from a DMS template, so a rename in Hyprland must not break the whole config.
pcall(function()
	hl.window_rule({ match = { class = "^(testbed-b)$" }, workspace = "2" })
	hl.window_rule({ match = { class = "^(testbed-c)$" }, workspace = "3" })
end)
