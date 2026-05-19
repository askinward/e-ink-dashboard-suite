#!/mnt/onboard/luajit

package.path = "/mnt/onboard/common/?.lua;" .. package.path
package.cpath = "/mnt/onboard/common/?.so;" .. package.cpath

local FBINK = "/mnt/onboard/fbink"
local SERVER_URL = "http://10.100.145.133:5001"
local LOG_FILE = "/mnt/onboard/.adds/dashboard/dashboard.log"
local F = {
    serif = "/mnt/onboard/fonts/noto/NotoSerif-Regular.ttf",
    serif_i = "/mnt/onboard/fonts/noto/NotoSerif-Italic.ttf",
    sans = "/mnt/onboard/fonts/noto/NotoSans-Regular.ttf",
    sans_b = "/mnt/onboard/fonts/noto/NotoSans-Bold.ttf",
}

local TOUCH_DEVICES = {"/dev/input/event1", "/dev/input/event0"}
local SIGNAL_FILE = "/tmp/dashboard-refresh"
local CLOCK_TICK = 60

-- State
local refreshInterval = 300
local lastToken = -1
local serverWifiOn = true
local serverSshOn = false
local clockX, clockY, clockW, clockH, clockSize, clockInverted = 300, 50, 320, 105, 64, false

-- Helpers
local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end

local function extractNum(raw, key)
    local p = raw:find('"' .. key .. '":')
    if not p then return nil end
    local val = raw:sub(p + #key + 3)
    local n = 0
    local neg = false
    local started = false
    for i = 1, #val do
        local b = val:byte(i)
        if b == 45 and not started then
            neg = true
            started = true
        elseif b >= 48 and b <= 57 then
            n = n * 10 + (b - 48)
            started = true
        else
            break
        end
    end
    if not started then return nil end
    if neg then n = -n end
    return n
end

local function killKOReader()
    local f = io.popen("pidof reader.lua 2>/dev/null", "r")
    if f then
        local pids = f:read("*a")
        f:close()
        if pids and #pids > 0 then
            os.execute("kill " .. pids .. " 2>/dev/null")
            log("Killed KOReader: " .. pids)
        end
    end
    os.execute("killall koreader.sh nickel hindenburg 2>/dev/null")
end

local function fb(args)
    os.execute(FBINK .. " -q " .. args)
end

-- Restore a rectangular region of the framebuffer from the cached raw image
local function restoreBackground(left, top, w, h)
    local fin = io.open("/tmp/dashboard.raw", "rb")
    local fout = io.open("/dev/fb0", "r+b")
    if fin and fout then
        for i = 0, h - 1 do
            local off = (top + i) * 608 + left
            fin:seek("set", off)
            fout:seek("set", off)
            local data = fin:read(w)
            if data then fout:write(data) end
        end
        fin:close()
        fout:close()
    end
end

local function ttf(font, size, x, y, text, w, h)
    text = text:gsub("'", "'\\''")
    local inv = clockInverted and " -h" or ""
    -- For the shadow/halo, we use the opposite of the main text's inversion
    local shadowInv = clockInverted and "" or " -h"
    
    if w and h then
        local left = x - math.floor(w / 2)
        local top = y
        local right = 600 - (left + w)
        local bottom = 800 - (top + h)

        -- 1. Erase old time by restoring background pixels for the ENTIRE area
        restoreBackground(left, top, w, h)

        -- 2. Draw shadow/halo (8 positions for a thick 2px-ish look)
        -- This ensures legibility on any background
        local offsets = {
            {2,0}, {-2,0}, {0,2}, {0,-2},
            {2,2}, {2,-2}, {-2,2}, {-2,-2}
        }
        for _, off in ipairs(offsets) do
            local ox, oy = off[1], off[2]
            fb("-t regular=" .. font .. ",px=" .. size .. ",top=" .. (top+oy) .. ",left=" .. (left+ox) .. ",right=" .. (right-ox) .. ",bottom=" .. (bottom-oy) .. " -m -M -O" .. shadowInv .. " -b '" .. text .. "'")
        end

        -- 3. Draw the main text centered in that EXACT region with transparency (-O)
        fb("-t regular=" .. font .. ",px=" .. size .. ",top=" .. top .. ",left=" .. left .. ",right=" .. right .. ",bottom=" .. bottom .. " -m -M -O" .. inv .. " '" .. text .. "'")
    else
        fb("-t regular=" .. font .. ",px=" .. size .. " -x " .. (x or 0) .. " -y " .. (y or 0) .. " -O" .. inv .. " '" .. text .. "'")
    end
end

-- Status message at bottom of screen (inverted, temporary)
local function showStatus(msg)
    msg = msg:gsub('"', '\\"')
    fb("-t regular=" .. F.sans_b .. ",size=18 -y -1 -h '" .. msg .. "'")
end

-- Clear status message area at bottom of screen
local function clearStatus()
    -- Restore from background instead of clearing to white
    restoreBackground(0, 775, 600, 25)
    fb("-s top=775,left=0,width=600,height=25")
end

-- WiFi
local function wifiIsUp()
    local f = io.popen("ifconfig eth0 2>/dev/null | grep -c 'inet addr'", "r")
    if not f then return false end
    local n = tonumber(f:read("*a")) or 0
    f:close()
    return n > 0
end

local function wifiOn()
    os.execute("killall dhcpcd 2>/dev/null")
    os.execute("ifconfig eth0 up 2>/dev/null")
    if wifiIsUp() then return true end
    os.execute("dhcpcd eth0 2>/dev/null &")
    for i = 1, 15 do
        os.execute("sleep 1")
        if wifiIsUp() then
            log("WiFi got IP after " .. i .. "s")
            return true
        end
    end
    log("WiFi failed to get IP after 15s")
    return false
end

local function wifiOff()
    os.execute("ifconfig eth0 down 2>/dev/null")
end

-- Read battery percentage from sysfs
local BATTERY_PATH = "/sys/devices/platform/pmic_battery.1/power_supply/mc13892_bat/capacity"
local function readBattery()
    local f = io.open(BATTERY_PATH, "r")
    if not f then return nil end
    local val = f:read("*a")
    f:close()
    val = tonumber(val)
    if val and val >= 0 and val <= 100 then
        return val
    end
    return nil
end

local function sshIsUp()
    local f = io.popen("ps 2>/dev/null | grep -c -e '[d]ropbear' -e '[s]shd'", "r")
    if not f then return false end
    local n = tonumber(f:read("*a")) or 0
    f:close()
    return n > 0
end

-- Draw full dashboard from server (caller must ensure WiFi is up)
local function drawDashboard()
    showStatus("Downloading...")
    os.execute('wget -q "' .. SERVER_URL .. '/dashboard.raw" -O /tmp/dashboard.raw -T 15 2>/tmp/wget_err.log')
    local ok = os.execute('test -s /tmp/dashboard.raw')
    if ok ~= 0 then
        local ef = io.open("/tmp/wget_err.log", "r")
        local err = (ef and ef:read("*a")) or "unknown"
        if ef then ef:close() end
        log("Download failed: " .. err:gsub("\n", " "))
        showStatus("Download failed")
        -- Fill screen white so it's not black
        local fb = io.open("/dev/fb0", "r+b")
        if fb then
            for i = 1, 608 * 800 do
                fb:write(string.char(255))
            end
            fb:close()
        end
        os.execute(FBINK .. " -s -f -q")
        ttf(F.serif, clockSize, clockX, clockY, os.date("%H:%M"), clockW, clockH)
        os.execute("rm -f /tmp/wget_err.log /tmp/dashboard.raw")
        return false
    end
    os.execute("rm -f /tmp/wget_err.log")
    os.execute('cat /tmp/dashboard.raw > /dev/fb0 2>/dev/null')
    os.execute(FBINK .. " -s -f -q")
    return true
end

local function parseInputEvent(data, off)
    if not data or off + 15 > #data then return nil end
    local b = {string.byte(data, off + 1, off + 16)}
    local typ   = b[9]  + b[10] * 256
    local code  = b[11] + b[12] * 256
    local v_lo  = b[13] + b[14] * 256
    local v_hi  = b[15] + b[16] * 256
    local value = v_lo + v_hi * 65536
    if value >= 2147483648 then value = value - 4294967296 end
    return typ, code, value
end

-- Wait up to timeout_sec for a touch. Returns touched, x, y.
-- Exit zone: physical touch coordinates (landscape 800×600, y=0 at bottom)
local EXIT_X1, EXIT_Y1 = 600, 0
local EXIT_X2, EXIT_Y2 = 800, 150
local function waitForTouch(timeout_sec)
    local found = false
    for idx, dev in ipairs(TOUCH_DEVICES) do
        local f = io.open(dev, "rb")
        if f then
            found = true
            f:close()
            local wait = idx == 1 and timeout_sec or 1
            os.execute('timeout ' .. wait .. ' dd if=' .. dev .. ' bs=16 count=50 of=/tmp/touch-ev 2>/dev/null')
            local ef = io.open("/tmp/touch-ev", "rb")
            if ef then
                local data = ef:read("*a")
                ef:close()
                os.execute("rm -f /tmp/touch-ev")
                if data and #data >= 16 then
                    local tapX, tapY = -1, -1
                    for off = 0, #data - 16, 16 do
                        local typ, code, value = parseInputEvent(data, off)
                        if typ == 3 then
                            if code == 0 then tapX = value
                            elseif code == 1 then tapY = value end
                        elseif typ == 1 and code == 330 and value == 1 then
                            return true, tapX, tapY
                        end
                    end
                end
            end
        end
    end
    if not found then
        os.execute("sleep " .. timeout_sec)
    end
    return false, -1, -1
end

-- Enforce server-side WiFi/SSH settings after a poll sync
local function enforceSettings()
    if serverWifiOn == true then
        if not wifiIsUp() then wifiOn() end
    elseif serverWifiOn == false then
        if wifiIsUp() then wifiOff() end
    end
    if serverSshOn == true then
        if not sshIsUp() then
            os.execute("dropbear -R -p 2222 2>/dev/null")
        end
    elseif serverSshOn == false then
        if sshIsUp() then
            os.execute("killall dropbear 2>/dev/null")
        end
    end
end

-- Poll server. Returns true if Kobo should redraw.
-- Caller must ensure WiFi is up before calling.
local function checkServer()
    showStatus("Checking server...")
    local bat = readBattery() or ""
    local wu = wifiIsUp() and 1 or 0
    local su = sshIsUp() and 1 or 0
    local f = io.popen('wget -q -O - -T 10 "' .. SERVER_URL .. '/api/poll?battery=' .. bat .. '&wifiUp=' .. wu .. '&sshUp=' .. su .. '" 2>/dev/null', "r")
    if not f then return false end
    local raw = f:read("*a")
    f:close()
    if not raw or #raw == 0 then return false end

    local shouldRedraw = false

    local token = extractNum(raw, "t")
    if token then
        local t = token
        if lastToken < 0 then
            lastToken = t
        elseif t ~= lastToken then
            lastToken = t
            shouldRedraw = true
        end
    end

    do
        local w = raw:match('"wifi":true')
        if w then serverWifiOn = true
        else
            w = raw:match('"wifi":false')
            if w then serverWifiOn = false end
        end
    end

    local intv = extractNum(raw, "interval")
    if intv and intv >= 60 then
        refreshInterval = intv
    end

    do
        local s = raw:match('"ssh":true')
        if s then serverSshOn = true
        else
            s = raw:match('"ssh":false')
            if s then serverSshOn = false end
        end
    end

    local cx = extractNum(raw, "clockX")
    if cx then clockX = cx end
    local cy = extractNum(raw, "clockY")
    if cy then clockY = cy end
    local cw = extractNum(raw, "clockW")
    if cw then clockW = cw end
    local ch = extractNum(raw, "clockH")
    if ch then clockH = ch end
    local cs = extractNum(raw, "clockSize")
    if cs then clockSize = cs end
    do
        local inv = raw:match('"clockInverted":true')
        if inv then clockInverted = true
        else
            inv = raw:match('"clockInverted":false')
            if inv then clockInverted = false end
        end
    end

    return shouldRedraw
end

-- Startup
killKOReader()
log("Dashboard starting")
local startupBat = readBattery()
if startupBat then log("Battery at startup: " .. startupBat .. "%") end
if not wifiIsUp() then wifiOn() end
drawDashboard()
log("Dashboard drawn")
os.execute("rm -f " .. SIGNAL_FILE)

-- Initial poll to get settings before main loop starts
if wifiIsUp() then
    log("Startup poll: WiFi is up")
    local f = io.popen('wget -q -O - -T 5 "' .. SERVER_URL .. '/api/poll" 2>/dev/null', "r")
    if f then
        local raw = f:read("*a")
        f:close()
        log("Startup poll response: " .. (raw and raw:sub(1, 100) or "nil"))
        if raw and #raw > 0 then
            local intv = extractNum(raw, "interval")
            if intv and intv >= 60 then refreshInterval = intv end
            if raw:match('"ssh":true') then serverSshOn = true
            elseif raw:match('"ssh":false') then serverSshOn = false end
            if raw:match('"wifi":true') then serverWifiOn = true
            elseif raw:match('"wifi":false') then serverWifiOn = false end
            local cx = extractNum(raw, "clockX")
            if cx then clockX = cx end
            local cy = extractNum(raw, "clockY")
            if cy then clockY = cy end
            local cw = extractNum(raw, "clockW")
            if cw then clockW = cw end
            local ch = extractNum(raw, "clockH")
            if ch then clockH = ch end
            local cs = extractNum(raw, "clockSize")
            if cs then clockSize = cs end
            do
                local inv = raw:match('"clockInverted":true')
                if inv then clockInverted = true
                elseif raw:match('"clockInverted":false') then clockInverted = false end
            end
            log("Startup poll: clock at " .. clockX .. "," .. clockY .. " size " .. clockW .. "x" .. clockH .. " font " .. clockSize .. " inv=" .. tostring(clockInverted))
        end
    else
        log("Startup poll: popen failed")
    end
else
    log("Startup poll: WiFi is down")
end
enforceSettings()
log("Startup complete")

-- Main loop
local cycle = 0
local tickCount = 0
local lastLoopTime = os.time()

local running = true
while running do
    local ok, err = pcall(function()
    local touched, tapX, tapY = waitForTouch(CLOCK_TICK)

    -- Detect sleep/wake: if more than tick+10s elapsed, device was asleep
    local now = os.time()
    local elapsed = now - lastLoopTime
    lastLoopTime = now
    if elapsed > CLOCK_TICK + 10 then
        log("Wake from sleep (+" .. elapsed .. "s gap)")
        showStatus("Waking up...")
        -- Re-download full dashboard (framebuffer may be lost during sleep)
        if wifiIsUp() or wifiOn() then
            os.execute('wget -q "' .. SERVER_URL .. '/dashboard.raw" -O /tmp/dashboard.raw -T 15 2>/dev/null')
            os.execute('test -s /tmp/dashboard.raw && cat /tmp/dashboard.raw > /dev/fb0 2>/dev/null')
        end
        fb("-s -f -q")
        tickCount = 0 -- Reset tick count on wake to align with current time
        os.execute("sleep 2")
    end

    cycle = cycle + 1
    killKOReader()

    if touched then
        log("Touch at " .. tapX .. "," .. tapY)
        -- Reject unset coordinates (spurious init events)
        if tapX < 0 or tapY < 0 then
            touched = false
            log("Touch rejected: unset coordinates")
        end
    end

    if touched and tapX >= EXIT_X1 and tapX < EXIT_X2 and tapY >= EXIT_Y1 and tapY < EXIT_Y2 then
        log("Exit tap at " .. tapX .. "," .. tapY)
        showStatus("Exiting to KOReader...")
        os.execute("sleep 1")
        os.execute("rm -f " .. SIGNAL_FILE)
        os.execute("rm -f /tmp/touch-ev")
        os.execute("/mnt/onboard/.adds/restart_koreader.sh &")
        running = false; return
    end

    -- 1. Update clock locally every minute
    ttf(F.serif, clockSize, clockX, clockY, os.date("%H:%M"), clockW, clockH)
    clearStatus()

    -- 2. Check if we need to poll the server for data/refresh
    local needsServer = false

    if touched then
        needsServer = true
        showStatus("Refreshing...")
        log("Touch refresh triggered")
    end

    local sf = io.open(SIGNAL_FILE, "r")
    if sf then
        sf:close()
        os.execute("rm -f " .. SIGNAL_FILE)
        needsServer = true
        showStatus("Refreshing...")
        log("Signal file refresh triggered")
    end

    -- Interval check: tickCount is in minutes (CLOCK_TICK=60)
    -- refreshInterval is in seconds (e.g., 300 for 5 min)
    if tickCount * CLOCK_TICK >= refreshInterval then
        needsServer = true
        tickCount = 0
        log("Scheduled server check (interval=" .. refreshInterval .. "s)")
    else
        tickCount = tickCount + 1
    end

    if needsServer then
        local wifiOk = true
        if not wifiIsUp() then
            log("WiFi was down, reconnecting")
            showStatus("WiFi connecting...")
            wifiOk = wifiOn()
        end
        if wifiOk then
            local shouldRedraw = checkServer()
            if shouldRedraw or touched then
                drawDashboard()
                -- Redraw clock after dashboard to ensure it's on top
                ttf(F.serif, clockSize, clockX, clockY, os.date("%H:%M"), clockW, clockH)
            end
            enforceSettings()
            clearStatus()
        else
            showStatus("WiFi failed")
            log("needsServer: wifiOn failed, skipping refresh")
        end
    end

    -- Periodic full refresh to prevent e-ink ghosting (every 30 cycles = 30min)
    if cycle > 0 and math.fmod(cycle, 30) == 0 then
        fb("-s -f -q")
        ttf(F.serif, clockSize, clockX, clockY, os.date("%H:%M"), clockW, clockH)
    end
    end)  -- pcall
    if not ok then
        local ef = io.open("/tmp/dash_err.log", "a")
        if ef then ef:write(os.date("%H:%M:%S") .. " CRASH: " .. tostring(err) .. "\n"); ef:close() end
        log("CRASH: " .. tostring(err))
        showStatus("Error, restarting...")
        os.execute("sleep 5")
    end
end
