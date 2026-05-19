# KOReader Plugin Development Notes

## Device Info
- **Device**: Kobo Mini
- **SSH**: `ssh -p 2222 root@10.0.0.153` (no password)
- **KOReader version**: v2026.03

## Plugin Directory Structure
- **Active plugin directory**: `/mnt/onboard/plugins/` (this is `DEFAULT_PLUGIN_PATH`)
- **Secondary plugin directory**: `/mnt/onboard/.adds/koreader/plugins/` (loaded via `extra_plugin_paths`)
- **Plugin format**: `pluginname.koplugin/` directory containing at minimum:
  - `_meta.lua` — metadata (name, fullname, description, version, author)
  - `main.lua` — plugin code

## Plugin Loading
- Plugins are loaded by `frontend/pluginloader.lua`
- `DEFAULT_PLUGIN_PATH = "plugins"` (relative to KOReader root)
- KOReader scans `plugins/` directory for `*.koplugin` directories
- Plugin is loaded via `dofile(mainfile)` — the returned table becomes the plugin module
- `_meta.lua` fields are merged into the plugin module after loading
- Event handlers (`on*` methods) are wrapped in a `HandlerSandbox` for error tracing

## Menu System

### Key Files
- **Menu order**: `frontend/ui/elements/filemanager_menu_order.lua` — defines menu structure and item ordering
- **Menu sorter**: `frontend/ui/menusorter.lua` — merges `menu_items` with `order` to build the menu
- **File manager menu**: `frontend/apps/filemanager/filemanagermenu.lua` — builds the main menu (wrench icon)
- **Settings**: `settings.reader.lua` — user settings

### Menu Registration Flow
1. Plugin `init()` is called during KOReader startup
2. Plugin must call `self.ui.menu:registerToMainMenu(self)` to register itself
3. When the user opens the main menu, `addToMainMenu(menu_items)` is called on each registered widget
4. `menusorter.lua` merges `menu_items` with the `order` table from `filemanager_menu_order.lua`

### Critical: Menu Item Keys Must Exist in Order File
- The KEY you use in `menu_items` (e.g., `menu_items.dashboard = {...}`) **MUST** exist as a key in `filemanager_menu_order.lua`
- If the key exists in a submenu (e.g., `more_tools = { ..., "dashboard", ... }`), the item appears in that submenu
- If the key does NOT exist in the order file, it becomes an "orphan" and appears with a "NEW: " prefix in the first menu
- Built-in plugin keys in `more_tools`: `auto_frontlight`, `battery_statistics`, `book_shortcuts`, `synchronize_time`, `keep_alive`, `doc_setting_tweak`, `terminal`, `plugin_management`, `patch_management`, `advanced_settings`, `developer_options`

### Adding a Custom Menu Entry
To add a new entry to "More Tools":
1. Add the key to `more_tools` section in `frontend/ui/elements/filemanager_menu_order.lua`:
   ```lua
   more_tools = {
       ...
       "dashboard",
       "plugin_management",
       ...
   }
   ```
2. In the plugin's `addToMainMenu`, use that same key:
   ```lua
   function Plugin:addToMainMenu(menu_items)
       menu_items.dashboard = {
           text = _("Dashboard"),
           callback = function() self:show_dashboard() end,
       }
   end
   ```

### Minimal Working Plugin Example
```lua
-- _meta.lua
local _ = require("gettext")
return {
    name = "myplugin",
    fullname = _("My Plugin"),
    description = "Description",
    version = "1.0",
    author = "Author",
}

-- main.lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local MyPlugin = WidgetContainer:extend{
    name = "myplugin",
    is_doc_only = false,
}

function MyPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function MyPlugin:addToMainMenu(menu_items)
    menu_items.my_plugin_key = {  -- key must exist in filemanager_menu_order.lua
        text = _("My Plugin"),
        callback = function()
            -- action here
        end,
    }
end

return MyPlugin
```

## Debugging
- **Log file**: `/mnt/onboard/crash.log`
- **Enable debug logging**: KOReader settings → Developer options → Enable debug logging
- **Plugin load errors**: Look for `Failed to initialize ... plugin:` in crash.log
- **Menu registration**: Look for `addToMainMenu called` in logs
- **Common errors**:
  - `attempt to call a nil value` — usually `self.ui` is nil in `init()` (plugin loaded before UI is ready)
  - `attempt to index global 'X' (a nil value)` — typo or missing require
  - Plugin appears in Plugin Management but not in menu — `registerToMainMenu` not called or menu key not in order file

## Useful Paths
| Path | Purpose |
|------|---------|
| `/mnt/onboard/plugins/` | Active plugin directory |
| `/mnt/onboard/frontend/ui/elements/filemanager_menu_order.lua` | Menu structure definition |
| `/mnt/onboard/frontend/ui/menusorter.lua` | Menu sorting logic |
| `/mnt/onboard/frontend/pluginloader.lua` | Plugin loading logic |
| `/mnt/onboard/settings.reader.lua` | KOReader settings |
| `/mnt/onboard/crash.log` | Log file |
| `/mnt/onboard/settings/` | Plugin settings directory |

## Notes
- `is_doc_only = false` means the plugin loads in both file manager and reader views
- `is_doc_only = true` means the plugin only loads when a document is open
- Menu items support: `text`, `text_func`, `callback`, `checked_func`, `enabled_func`, `sub_item_table`, `keep_menu_open`, `hold_callback`, `help_text`, `separator`, `radio`
- The `more_tools` submenu is nested inside the `tools` tab in the file manager menu
