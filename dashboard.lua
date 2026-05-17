#!/mnt/onboard/luajit

package.path = "/mnt/onboard/common/?.lua;" .. package.path
package.cpath = "/mnt/onboard/common/?.so;" .. package.cpath

local FBINK = "/mnt/onboard/fbink"
local SERVER_URL = "http://10.0.0.198:5001"
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
local keepWiFiOn = false
local lastToken = -1
local wifiWasUp = false
local sshKeepalive = false
local wifiKeepAliveTicks = 0
local wifiOffCounter = 0

-- Helpers
local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
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

local function ttf(font, size, x, y, text)
    text = text:gsub('"', '\\"')
    local xarg = ""
    if x then xarg = " -X " .. x end
    fb("-t regular=" .. font .. ",size=" .. size .. " -y " .. y .. xarg .. ' "' .. text .. '"')
end

-- Status message at bottom of screen (inverted, temporary)
local function showStatus(msg)
    msg = msg:gsub('"', '\\"')
    fb("-t regular=" .. F.sans_b .. ",size=18 -y -1 -h '" .. msg .. "'")
end

-- WiFi
local function wifiOn()
    os.execute("ifconfig eth0 up 2>/dev/null")
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

local function wifiIsUp()
    local f = io.popen("ifconfig eth0 2>/dev/null | grep -c 'inet addr'", "r")
    if not f then return false end
    local n = tonumber(f:read("*a") or "0")
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
        os.execute("rm -f /tmp/wget_err.log /tmp/dashboard.raw")
        return false
    end
    os.execute("rm -f /tmp/wget_err.log")
    os.execute('cat /tmp/dashboard.raw > /dev/fb0 2>/dev/null')
    os.execute(FBINK .. " -s -f -q")
    ttf(F.sans, 12, 0, 0, "EXIT ←")
    local now = os.date("*t")
    local clock = string.format("%02d:%02d", now.hour, now.min)
    ttf(F.serif, 64, 0, 4, clock)
    return true
end

-- Parse input_event
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
local EXIT_ZONE = 60  -- pixels from top-left corner for exit tap
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

-- Poll server. Returns true if Kobo should redraw.
-- Caller must ensure WiFi is up before calling.
local function checkServer()
    showStatus("Checking server...")
    local f = io.popen('wget -q -O - -T 10 "' .. SERVER_URL .. '/api/poll" 2>/dev/null', "r")
    if not f then return false end
    local raw = f:read("*a")
    f:close()
    if not raw or #raw == 0 then return false end

    local shouldRedraw = false

    local _, _, token = raw:match('"t":(%d+)')
    if token then
        local t = tonumber(token)
        if lastToken < 0 then
            lastToken = t
        elseif t ~= lastToken then
            lastToken = t
            shouldRedraw = true
        end
    end

    local _, _, keepOn = raw:match('"wifi":(true|false)')
    if keepOn then
        keepWiFiOn = (keepOn == "true")
    end

    local _, _, intv = raw:match('"interval":(%d+)')
    if intv then
        local n = tonumber(intv)
        if n and n >= 60 then
            refreshInterval = n
        end
    end

    local _, _, ssh = raw:match('"ssh":(true|false)')
    if ssh then
        sshKeepalive = (ssh == "true")
    end

    local _, _, ka = raw:match('"keepalive":(%d+)')
    if ka then
        local n = tonumber(ka)
        if n and n >= 0 then
            wifiKeepAliveTicks = math.max(0, math.floor(n / CLOCK_TICK))
        end
    end

    return shouldRedraw
end

-- Draw WiFi indicator symbol
local function drawWifiIcon(up)
    if up then
        fb("-t regular=" .. F.sans .. ",size=14 -y 0 -X 90 \"\226\151\137\"")
    else
        fb("-c -p -x 88 -y 0 -w 12 -h 1")
    end
end

-- Startup
killKOReader()
log("Dashboard starting")
if not wifiIsUp() then wifiOn() end
drawDashboard()
log("Dashboard drawn")
os.execute("rm -f " .. SIGNAL_FILE)

-- Main loop
local cycle = 0
local tickCount = 0
local lastLoopTime = os.time()

ttf(F.sans, 12, 0, 0, "EXIT ←")

while true do
    local touched, tapX, tapY = waitForTouch(CLOCK_TICK)

    -- Detect sleep/wake: if more than tick+10s elapsed, device was asleep
    local now = os.time()
    local elapsed = now - lastLoopTime
    lastLoopTime = now
    if elapsed > CLOCK_TICK + 10 then
        log("Wake from sleep (+" .. elapsed .. "s gap)")
        showStatus("Waking up...")
        fb("-s -f -q")
        ttf(F.serif, 64, 0, 4, os.date("%H:%M"))
        ttf(F.sans, 12, 0, 0, "EXIT ←")
        wifiWasUp = false  -- WiFi was reset during sleep, force indicator clear
        os.execute("sleep 2")
    end

    cycle = cycle + 1
    tickCount = tickCount + 1
    killKOReader()

    if touched and tapX >= 0 and tapX < EXIT_ZONE and tapY >= 0 and tapY < EXIT_ZONE then
        log("Exit tap at " .. tapX .. "," .. tapY)
        showStatus("Exiting to Nickel...")
        os.execute("/usr/local/Kobo/hindenburg &")
        os.execute("rm -f " .. SIGNAL_FILE)
        os.execute("rm -f /tmp/touch-ev")
        break
    end

    local needsData = false

    if touched then
        needsData = true
        showStatus("Refreshing...")
        log("Touch refresh at " .. (tapX or -1) .. "," .. (tapY or -1))
        wifiOffCounter = wifiKeepAliveTicks  -- postpone WiFi shutdown on activity
    end

    local sf = io.open(SIGNAL_FILE, "r")
    if sf then
        sf:close()
        os.execute("rm -f " .. SIGNAL_FILE)
        needsData = true
        showStatus("Refreshing...")
        log("Signal file refresh triggered")
    end

    if tickCount * CLOCK_TICK >= refreshInterval then
        needsData = true
        tickCount = 0
        log("Scheduled refresh (interval=" .. refreshInterval .. "s)")
    end

    if needsData then
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
            end
        else
            showStatus("WiFi failed")
            log("needsData: wifiOn failed, skipping refresh")
        end
        if not keepWiFiOn and not sshKeepalive then
            if wifiKeepAliveTicks > 0 then
                wifiOffCounter = wifiKeepAliveTicks
            else
                wifiOff()
            end
        end
    else
        -- No needsData this cycle — countdown to WiFi shutdown
        if wifiOffCounter > 0 then
            wifiOffCounter = wifiOffCounter - 1
            if wifiOffCounter <= 0 then
                log("WiFi keepalive expired, shutting down")
                wifiOff()
            end
        end
    end

    -- Clock (blinks colon on even minutes) and WiFi indicator
    local now = os.date("*t")
    local colon = (now.min % 2 == 0) and " " or ":"
    local clock = string.format("%02d" .. colon .. "%02d", now.hour, now.min)
    ttf(F.serif, 64, 0, 4, clock)

    local wifiUp = wifiIsUp()
    if wifiUp ~= wifiWasUp then
        drawWifiIcon(wifiUp)
        wifiWasUp = wifiUp
    elseif not wifiUp and math.fmod(cycle, 15) == 0 then
        -- Periodically re-clear indicator area in case of display artifacts
        fb("-c -p -x 88 -y 0 -w 12 -h 1")
    end
end
