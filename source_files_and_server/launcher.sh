#!/bin/sh
# Launcher for Kobo Dashboard -- called from NickelMenu
# Kills Nickel and hindenburg to free the framebuffer, starts dashboard
killall nickel hindenburg 2>/dev/null
sleep 1
# Clear any 16-bit KOReader pixel noise from framebuffer
dd if=/dev/zero bs=608 count=800 2>/dev/null | tr '\000' '\377' > /dev/fb0 2>/dev/null
/mnt/onboard/fbink -s -f -q 2>/dev/null
sleep 1
/mnt/onboard/luajit /mnt/onboard/.adds/dashboard/dashboard.lua
