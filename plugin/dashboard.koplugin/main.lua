local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local NetworkMgr      = require("ui/network/manager")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Device          = require("device")
local Screen          = Device.screen
local Geom            = require("ui/geometry")
local logger          = require("logger")
local _               = require("gettext")

local lfs do
    local ok, m = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, m = pcall(require, "lfs") end
    lfs = ok and m or nil
end

local json do
    local ok, m = pcall(require, "rapidjson")
    if not ok then ok, m = pcall(require, "dkjson") end
    json = ok and m or nil
end

local Dashboard = WidgetContainer:extend{
    name        = "dashboard",
    is_doc_only = false,

    SERVER_URL      = "http://10.0.0.198:5001",
    SYNC_INTERVAL   = 3600,
    WIFI_OFF_DELAY  = 3,

    BASE_DIR    = "/mnt/onboard/.adds/dashboard/",
    INDEX_HTML  = "/mnt/onboard/.adds/dashboard/index.html",
    CACHE_DIR   = "/mnt/onboard/.adds/dashboard/cache/",
    LOG_FILE    = "/mnt/onboard/.adds/dashboard/plugin.log",

    _webview         = nil,
    _sync_fn         = nil,
    _is_standalone   = false,
    _wifi_was_on     = false,
    _tick_fn         = nil,
}

function Dashboard:init()
    self:_ensureDirs()
    self.ui.menu:registerToMainMenu(self)
    self:_scheduleSyncTimer()
    -- Initial sync after a short delay so KOReader is fully ready
    UIManager:scheduleIn(5, function()
        self:sync(false)
    end)
    self:_log("Plugin initialised — server: " .. self.SERVER_URL)
end

function Dashboard:addToMainMenu(menu_items)
    menu_items.dashboard = {
        text          = _("Dashboard"),
        help_text     = _("Open the e-ink dashboard. Hold to change server URL."),
        callback      = function() self:launch() end,
        hold_callback = function() self:_showServerConfig() end,
    }
end

function Dashboard:launch()
    if self._webview then
        UIManager:show(self._webview)
        return
    end

    local w, h = Screen:getWidth(), Screen:getHeight()
    local data = self:_readCachedJSON()
    local html = self:_buildHTML(data, w, h)

    self._webview = ScrollHtmlWidget:new{
        html_body = html,
        css = self:_getCSS(),
        width  = w,
        height = h,
        dimen = Geom:new{ w = w, h = h },
        html_link_tapped_callback = function(link)
            self:_handleURL(link)
        end,
    }

    UIManager:show(self._webview)
    self:_startClockTick()
end

function Dashboard:_startClockTick()
    self:_stopClockTick()
    self._tick_fn = function()
        if not self._webview then return end
        self:_refreshView()
        UIManager:scheduleIn(60, self._tick_fn)
    end
    UIManager:scheduleIn(60, self._tick_fn)
end

function Dashboard:_stopClockTick()
    if self._tick_fn then
        UIManager:unschedule(self._tick_fn)
        self._tick_fn = nil
    end
end

function Dashboard:_buildHTML(data, width, height)
    local now = os.date("*t")
    local day_names = {"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"}
    local month_names = {"January","February","March","April","May","June","July","August","September","October","November","December"}
    local day_str = day_names[now.wday] or ""
    local date_str = (month_names[now.month] or "") .. " " .. now.day .. ", " .. now.year
    local clock_str = string.format("%02d:%02d", now.hour, now.min)

    local events_html = ""
    if data and data.events and #data.events > 0 then
        for i = 1, math.min(#data.events, 4) do
            local e = data.events[i]
            local t = e.time or ""
            local title = e.title or ""
            events_html = events_html .. "<div class='event'>"
                .. "<span class='ev-time'>" .. self:_h(t) .. "</span>"
                .. "<span class='ev-bullet'> ◆ </span>"
                .. "<span class='ev-title'>" .. self:_h(title) .. "</span></div>"
        end
    else
        events_html = "<div class='hint'>No events today</div>"
    end

    local todos_html = ""
    if data and data.todos and #data.todos > 0 then
        for i = 1, math.min(#data.todos, 4) do
            local t = data.todos[i]
            local mark = t.done and string.char(226,156,147) or string.char(226,151,139)
            local cls = t.done and " todo-done" or ""
            local text = t.text or ""
            todos_html = todos_html .. "<div class='todo'>"
                .. "<span class='todo-mark'>" .. mark .. "</span>"
                .. "<span class='todo-text" .. cls .. "'>" .. self:_h(text) .. "</span></div>"
        end
    else
        todos_html = "<div class='hint'>No tasks</div>"
    end

    local quote_html = ""
    local quote_text = ""
    local quote_author = ""
    if data and data.quote then
        quote_text = data.quote.text or ""
        quote_author = data.quote.author or ""
    end
    if quote_text ~= "" then
        local ldq = string.char(226,128,156)
        local rdq = string.char(226,128,157)
        quote_html = "<div class='quote-text'>" .. ldq .. self:_h(quote_text) .. rdq .. "</div>"
    end
    if quote_author ~= "" then
        local emdash = string.char(226,128,148)
        quote_html = quote_html .. "<div class='quote-author'>" .. emdash .. " " .. self:_h(quote_author) .. "</div>"
    end

    local bg_img_html = ""
    local bg_path = "/mnt/onboard/.adds/dashboard/cache/bg.png"
    if data and data.background and lfs and lfs.attributes(bg_path) then
        bg_img_html = "<img class='bg-img' src='file://" .. bg_path .. "' alt='' />"
    end

    local scrim = ""
    if self._is_standalone then
        scrim = "<div class='standalone-badge'>STANDALONE</div>"
    end

    local html = "<div class='page'>"
        .. "<div class='masthead'>"
        .. "<span class='masthead-day'>" .. self:_h(day_str) .. "</span>"
        .. "<span class='masthead-date'>" .. self:_h(date_str) .. "</span></div>"
        .. "<div class='time-section'><div class='clock'>" .. clock_str .. "</div></div>"
        .. "<hr class='thick' />"
        .. "<div class='section'><div class='section-label'>TODAY</div><div class='events'>" .. events_html .. "</div></div>"
        .. "<hr class='thin' />"
        .. "<div class='section'><div class='section-label'>TASKS</div><div class='todos'>" .. todos_html .. "</div></div>"
        .. "<hr class='thick' />"
        .. bg_img_html
        .. "<div class='quote'>" .. quote_html .. "</div>"
        .. "<hr class='thick' />"
        .. "<div class='actions'>"
        .. "<a href='koreader://refresh' class='btn'>Refresh</a>"
        .. "<a href='koreader://wifi-toggle' class='btn'>WiFi</a>"
        .. "<a href='koreader://ssh-toggle' class='btn'>SSH</a>"
        .. "<a href='koreader://standalone-toggle' class='btn'>Standalone</a>"
        .. "<a href='koreader://exit' class='btn btn-exit'>Close Dashboard</a></div>"
        .. scrim
        .. "</div>"

    return html
end

function Dashboard:_getCSS()
    local px = function(v) return Screen:scaleBySize(v) end
    local css = "* { box-sizing: border-box; margin: 0; padding: 0; }"
        .. "body { font-family: Georgia, serif; color: #000; background: #fff; padding: " .. px(10) .. "px " .. px(20) .. "px; }"
        .. ".page { width: 100%; }"
        .. ".masthead { display: block; padding: " .. px(8) .. "px 0 " .. px(6) .. "px; border-bottom: 2px solid #000; text-align: justify; }"
        .. ".masthead-day { font-family: Helvetica, Arial, sans-serif; font-size: " .. px(10) .. "px; letter-spacing: " .. px(3) .. "px; text-transform: uppercase; }"
        .. ".masthead-date { font-family: Georgia, serif; font-size: " .. px(12) .. "px; color: #555; }"
        .. ".time-section { text-align: center; padding: " .. px(8) .. "px 0; }"
        .. ".clock { font-family: Georgia, serif; font-size: " .. px(60) .. "px; letter-spacing: -2px; color: #000; }"
        .. "hr.thick { border: none; border-top: 2px solid #000; margin: " .. px(2) .. "px 0; }"
        .. "hr.thin { border: none; border-top: 1px solid #ccc; margin: " .. px(2) .. "px 0; }"
        .. ".section { padding: " .. px(8) .. "px 0; }"
        .. ".section-label { font-family: Helvetica, Arial, sans-serif; font-size: " .. px(8) .. "px; letter-spacing: " .. px(3) .. "px; text-transform: uppercase; color: #999; margin-bottom: " .. px(6) .. "px; }"
        .. ".event { margin-bottom: " .. px(4) .. "px; }"
        .. ".ev-time { font-family: 'Courier New', monospace; font-size: " .. px(11) .. "px; color: #666; }"
        .. ".ev-bullet { font-size: " .. px(7) .. "px; color: #000; }"
        .. ".ev-title { font-family: Helvetica, Arial, sans-serif; font-size: " .. px(13) .. "px; color: #000; }"
        .. ".todo { margin-bottom: " .. px(4) .. "px; }"
        .. ".todo-mark { font-family: Georgia, serif; font-size: " .. px(12) .. "px; color: #444; }"
        .. ".todo-text { font-family: Helvetica, Arial, sans-serif; font-size: " .. px(13) .. "px; color: #000; }"
        .. ".todo-done { text-decoration: line-through; color: #aaa; }"
        .. ".quote { background: #000; color: #fff; padding: " .. px(10) .. "px " .. px(20) .. "px; text-align: center; }"
        .. ".quote-text { font-family: Georgia, serif; font-style: italic; font-size: " .. px(12) .. "px; color: #e0e0e0; }"
        .. ".quote-author { font-family: Helvetica, Arial, sans-serif; font-size: " .. px(9) .. "px; letter-spacing: 2px; text-transform: uppercase; color: #777; margin-top: " .. px(4) .. "px; }"
        .. ".actions { text-align: center; padding: " .. px(8) .. "px 0; }"
        .. ".btn { display: inline-block; font-family: Helvetica, Arial, sans-serif; font-size: " .. px(16) .. "px; color: #000; border: 2px solid #000; padding: " .. px(8) .. "px " .. px(14) .. "px; margin: " .. px(4) .. "px; text-decoration: none; }"
        .. ".btn-exit { background: #000; color: #fff; display: block; text-align: center; margin-top: " .. px(8) .. "px; }"
        .. ".standalone-badge { text-align: center; font-family: Helvetica, Arial, sans-serif; font-size: " .. px(8) .. "px; letter-spacing: " .. px(3) .. "px; text-transform: uppercase; color: #fff; background: #000; padding: " .. px(2) .. "px " .. px(8) .. "px; }"
        .. ".hint { font-family: Helvetica, Arial, sans-serif; font-size: " .. px(11) .. "px; color: #ccc; font-style: italic; }"
        .. ".bg-img { max-width: 100%; display: block; margin: " .. px(4) .. "px 0; }"
    return css
end

function Dashboard:_h(s)
    s = tostring(s)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    return s
end

function Dashboard:_handleURL(link)
    if not link then return end
    local uri = type(link) == "string" and link or link.uri
    if not uri then return end
    local action = uri:gsub("^koreader://", ""):gsub("/%s*$", "")
    self:_log("Action → " .. action)

    if     action == "exit"              then self:_close()
    elseif action == "refresh"           then self:sync(true)
    elseif action == "wifi-toggle"       then self:_toggleWifi()
    elseif action == "ssh-toggle"        then self:_toggleSsh()
    elseif action == "standalone-toggle" then self:_toggleStandalone()
    else   self:_log("Unknown action: " .. action)
    end
end

function Dashboard:onSuspend()
    self:_cancelSyncTimer()
    self:_log("Sync timer cancelled (suspend)")
    if self._webview then
        UIManager:close(self._webview)
        self._webview = nil
    end
end

function Dashboard:onResume()
    if not self._is_standalone then
        self:_scheduleSyncTimer()
        self:_log("Sync timer restarted (resume)")
    end
end

function Dashboard:_close()
    self:_stopClockTick()
    if self._webview then
        UIManager:close(self._webview)
        self._webview = nil
        self:_log("Dashboard closed")
    end
end

function Dashboard:sync(user_triggered)
    if self._is_standalone and not user_triggered then
        self:_log("Sync skipped (standalone mode)")
        return
    end

    self:_log("Sync start")
    self._wifi_was_on = NetworkMgr:isWifiOn()
    NetworkMgr:enableWifi(function()
        UIManager:scheduleIn(2, function()
            local ok, data = self:_fetchJSON(self.SERVER_URL .. "/dashboard.json")
            if ok and data then
                self:_cacheJSON(data)
                local bg = type(data) == "table" and data.background
                if bg then
                    self:_fetchBinary(self.SERVER_URL .. bg, self.CACHE_DIR .. "bg.png")
                end
                self:_log("Sync OK")
            else
                self:_log("Sync failed — retaining cached data")
            end
            self:_refreshView()
            local was_on = self._wifi_was_on
            self._wifi_was_on = false
            if not was_on then
                UIManager:scheduleIn(self.WIFI_OFF_DELAY, function()
                    NetworkMgr:disableWifi()
                    self:_log("Wi-Fi disabled after sync")
                end)
            else
                self:_log("Wi-Fi left on (was already on before sync)")
            end
        end)
    end)
end

function Dashboard:_refreshView()
    if self._webview then
        local data = self:_readCachedJSON()
        local html = self:_buildHTML(data, Screen:getWidth(), Screen:getHeight())
        self._webview.htmlbox_widget:setContent(html, self:_getCSS())
        UIManager:setDirty(self._webview, "ui")
    end
end

function Dashboard:_toggleWifi()
    if NetworkMgr:isWifiOn() then
        NetworkMgr:turnOffWifi()
        self:_log("Wi-Fi turned off")
    else
        NetworkMgr:turnOnWifi()
        self:_log("Wi-Fi turned on")
    end
end

function Dashboard:_toggleSsh()
    os.execute("pidof dropbear >/dev/null 2>&1 && killall dropbear 2>/dev/null || dropbear -R -p 2222 2>/dev/null")
    self:_log("SSH toggled")
end

function Dashboard:_toggleStandalone()
    self._is_standalone = not self._is_standalone
    if self._is_standalone then
        self:_cancelSyncTimer()
        NetworkMgr:disableWifi()
        self:_log("Standalone mode ON")
    else
        self:_scheduleSyncTimer()
        self:_log("Standalone mode OFF")
    end
    self:_refreshView()
end

function Dashboard:_scheduleSyncTimer()
    self:_cancelSyncTimer()
    self._sync_fn = function()
        self:sync(false)
        UIManager:scheduleIn(self.SYNC_INTERVAL, self._sync_fn)
    end
    UIManager:scheduleIn(self.SYNC_INTERVAL, self._sync_fn)
    self:_log("Sync timer armed: every " .. self.SYNC_INTERVAL .. "s")
end

function Dashboard:_cancelSyncTimer()
    if self._sync_fn then
        UIManager:unschedule(self._sync_fn)
        self._sync_fn = nil
    end
end

function Dashboard:_fetchJSON(url)
    local ok_h, http  = pcall(require, "socket.http")
    local ok_l, ltn12 = pcall(require, "ltn12")
    if not ok_h or not ok_l then
        self:_log("socket.http unavailable")
        return false, nil
    end
    local chunks = {}
    local result, code = http.request{
        url = url, sink = ltn12.sink.table(chunks), timeout = 10,
    }
    if result and code == 200 then
        local raw = table.concat(chunks)
        if json then
            local ok2, decoded = pcall(json.decode, raw)
            if ok2 and decoded then return true, decoded end
        end
        return true, raw
    end
    self:_log("HTTP " .. tostring(code) .. " ← " .. url)
    return false, nil
end

function Dashboard:_fetchBinary(url, dest)
    local ok_h, http  = pcall(require, "socket.http")
    local ok_l, ltn12 = pcall(require, "ltn12")
    if not ok_h or not ok_l then return end
    local chunks = {}
    local result, code = http.request{
        url = url, sink = ltn12.sink.table(chunks), timeout = 15,
    }
    if result and code == 200 then
        local f = io.open(dest, "wb")
        if f then
            f:write(table.concat(chunks))
            f:close()
            self:_log("Cached: " .. dest)
        end
    else
        self:_log("Binary fetch failed (" .. tostring(code) .. "): " .. url)
    end
end

function Dashboard:_cacheJSON(data)
    local dest = self.CACHE_DIR .. "dashboard.json"
    local f = io.open(dest, "w")
    if not f then self:_log("Cannot write: " .. dest) return end
    if json and type(data) == "table" then
        local ok, encoded = pcall(json.encode, data)
        if ok then f:write(encoded) end
    elseif type(data) == "string" then
        f:write(data)
    end
    f:close()
    self:_log("Cached → " .. dest)
end

function Dashboard:_readCachedJSON()
    local path = self.CACHE_DIR .. "dashboard.json"
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*all")
    f:close()
    if json then
        local ok, decoded = pcall(json.decode, raw)
        if ok then return decoded end
    end
    return raw
end

function Dashboard:_showServerConfig()
    local ok, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not ok then return end
    local dlg
    dlg = InputDialog:new{
        title = _("Dashboard Server URL"),
        input = self.SERVER_URL,
        input_hint = "http://192.168.x.x:3000",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true,
                callback = function()
                    local val = dlg:getInputText():match("^%s*(.-)%s*$")
                    if val and val ~= "" then
                        self.SERVER_URL = val
                        self:_log("Server URL: " .. val)
                    end
                    UIManager:close(dlg)
                end,
            },
        }},
    }
    UIManager:show(dlg)
end

function Dashboard:_ensureDirs()
    if lfs then
        lfs.mkdir(self.BASE_DIR)
        lfs.mkdir(self.CACHE_DIR)
    else
        os.execute("mkdir -p " .. self.CACHE_DIR)
    end
end

function Dashboard:_log(msg)
    logger.dbg("Dashboard: " .. tostring(msg))
    local f = io.open(self.LOG_FILE, "a")
    if f then
        f:write("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. tostring(msg) .. "\n")
        f:close()
    end
end

return Dashboard
