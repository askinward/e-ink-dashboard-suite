#!/bin/sh
# Launcher for Kobo Dashboard -- called from NickelMenu
# Kills Nickel and hindenburg to free the framebuffer, starts dashboard
killall nickel hindenburg 2>/dev/null
sleep 1
/mnt/onboard/luajit /mnt/onboard/.adds/dashboard/dashboard.lua
