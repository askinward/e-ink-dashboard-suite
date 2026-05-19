-- ═══════════════════════════════════════════════════════════════
--  dashboard.koplugin / _meta.lua
--  KOReader plugin metadata
-- ═══════════════════════════════════════════════════════════════

local _ = require("gettext")

return {
    name        = "dashboard",
    fullname    = _("Kobo Dashboard"),
    description = _("Low-power e-ink dashboard: clock, events, todos, quotes. "
                  .."Syncs hourly, keeps Wi-Fi off between syncs."),
    version     = "1.0",
    author      = "dashboard",
}
