#!/usr/bin/env bash
# Opens three terminals with distinct titles and app-ids so the window switcher has content.
sleep 3
foot -T "Test A: editor" -a testbed-a &
foot -T "Test B: logs"   -a testbed-b &
foot -T "Test C: shell"  -a testbed-c &
wait
