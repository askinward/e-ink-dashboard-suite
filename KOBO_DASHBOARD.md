# Kobo Dashboard

A lightweight e-ink dashboard for **Kobo Mini** that displays time, events, todos, quotes, and a full-screen background image. Rendering is done **server-side** (Python + Pillow) — the Kobo simply downloads a pre-rendered raw framebuffer bitmap and writes it directly to `/dev/fb0`.

## Architecture

```
┌─────────────────────────┐       ┌─────────────────────────────┐
│  Admin Browser          │       │  Kobo Mini (e-ink)          │
│  http://10.0.0.198:5001 │       │  ─────────────────          │
│                         │       │                             │
│  ┌─────────────────┐    │       │  dashboard.lua (LuaJIT)     │
│  │ Admin UI (HTML) │    │       │  ┌─────────────────────┐   │
│  │  - Edit quote   │    │       │  │  wget dashboard.raw │   │
│  │  - Edit events  │────┼───────┼─▶│  ↓ /tmp/dashboard   │   │
│  │  - Edit todos   │    │       │  │  ↓ /dev/fb0         │   │
│  │  - Upload image │    │       │  │  ↓ FBInk clock      │   │
│  │  - Refresh Kobo │    │       │  └─────────────────────┘   │
│  │  - WiFi toggle  │    │       │                             │
│  └─────────────────┘    │       │  FBInk overlays clock      │
│                         │       │  at row 4 (64px) via       │
│  ┌─────────────────┐    │       │  NotoSerif 64pt            │
│  │  Node/Express    │    │       │                             │
│  │  server.js       │────┼───────┼─── /api/poll (60s)        │
│  │  ┌─────────────┐ │    │       │                             │
│  │  │ /dashboard.raw│ │    │       │  zForce IR touch          │
│  │  │  Python proc  │ │    │       │  /dev/input/event1        │
│  │  │  ↓ stdout     │ │    │       │  BTN_TOUCH (330)          │
│  │  └─────────────┘ │    │       │                             │
│  └─────────────────┘    │       └─────────────────────────────┘
│                         │
│  render_dashboard.py    │
│  ┌─────────────────┐    │
│  │  Pillow 600x800  │    │
│  │  8-bit grayscale │    │
│  │  padding→608/line│    │
│  │  486400 bytes    │    │
│  └─────────────────┘    │
│                         │
│  template.json          │
│  dashboard-data.json    │
│  images/background.jpg  │
└─────────────────────────┘
```

### Key Design Decision

**Why server-side rendering?** A full design freedom (any font, any layout, background images) with minimum device battery drain — one raw bitmap download, one write to `/dev/fb0`, one e-ink refresh per cycle. The Kobo does no text layout, no image processing, no HTML rendering.

---

## Component Details

### 1. Server — `server.js` (Node.js + Express)

| Endpoint | Method | Purpose |
|---|---|---|
| `/` | GET | Admin UI (inline HTML) |
| `/dashboard.raw` | GET | Spawns renderer, streams 486400 bytes |
| `/dashboard.json` | GET | Raw data for debugging |
| `/api/data` | GET/POST | Read/write `dashboard-data.json` |
| `/api/template` | GET/POST | Read/write `template.json` |
| `/api/template/reset` | POST | Restore default template |
| `/api/upload` | POST | Upload background image (Multer) |
| `/api/background` | DELETE | Remove background |
| `/api/refresh` | POST | Increment refresh token |
| `/api/poll` | GET | Return `{t: token, wifi: bool}` |
| `/api/wifi/:state` | POST | Set WiFi on/off flag |
| `/editor` | GET | Visual template editor |
| `/images/*` | GET | Static background images |

**Refresh mechanism**: A monotonically incrementing token. When admin clicks "Refresh Kobo Now" (`POST /api/refresh`), the token increments. The Kobo polls `GET /api/poll` every 60s and does a full redraw when the token changes.

**WiFi management**: Server stores a `wifiEnabled` boolean. Kobo polls it alongside the refresh token and turns `ifconfig eth0 up/down` accordingly — saves battery when WiFi is off.

### 2. Renderer — `render_dashboard.py` (Python + Pillow)

```
Input:  template.json + dashboard-data.json + images/background.*
Output: 608 bytes/line × 800 lines = 486400 bytes raw 8-bit grayscale to stdout
```

**Canvas**: 600×800 pixels, 8-bit grayscale ("L" mode), white (255) background.

**Background image**: Loaded from `dashboard-data.json["background"]` URL, converted to grayscale, resized to 600×800 with LANCZOS, pasted as base layer.

**Elements** (from `template.json`):

| Type | Description |
|---|---|
| `text` | Static or variable text. Variable substitution: `{day_name}`, `{date}`, `{battery}`, `{quote_text}`, `{quote_author}`, `{updated_at}`. Supports left/center/right alignment, word-wrap. |
| `list` | Data-driven list from `data_source` (e.g., `events`, `todos`). Uses `item_template` for formatting. Todos get `{mark}` → `[x]` or `[ ]`. |
| `clock_space` | Draws a white rectangle at clock position (140,50, 320×105) so FBInk text is readable. |

**Font mapping**: Liberation fonts (Sans, Serif, Mono) in Regular, Bold, Italic, Bold Italic. Sized dynamically per element.

**Output padding**: Each 600-pixel row is padded to 608 bytes (the Kobo's framebuffer line stride).

### 3. Kobo Client — `dashboard.lua` (LuaJIT + FBInk)

**Constants**:
- `SERVER_URL = "http://10.0.0.198:5001"`
- Fonts: NotoSerif-Regular, NotoSerif-Italic, NotoSans-Regular, NotoSans-Bold at `/mnt/onboard/fonts/noto/`
- Touch devices: `/dev/input/event1` (zForce IR), `/dev/input/event0` (buttons)
- Signal file: `/tmp/dashboard-refresh`

**Main loop** (runs every ~60s):

```
1. waitForTouch(60)
   └─ Blocks up to 60s reading /dev/input/event1
   └─ Reads 50 events (16 bytes each = 800 bytes)
   └─ Parses each for EV_KEY(1) + BTN_TOUCH(330) + value=1
   └─ If found → force_refresh = true

2. killKOReader()
   └─ Kills any running reader.lua/koreader.sh processes

3. Check signal file /tmp/dashboard-refresh
   └─ If exists → force_refresh = true

4. checkServerRefresh()
   └─ GET /api/poll, compare token with last known
   └─ If changed → force_refresh = true
   └─ Also reads wifi flag, toggles interface if changed

5. If force_refresh OR cycle % 5 == 0:
   └─ drawDashboard()
       ├─ wget /dashboard.raw → /tmp/dashboard.raw
       ├─ cat /tmp/dashboard.raw > /dev/fb0
       ├─ FBInk -s -f (full-screen flash refresh)
       └─ FBInk ttf (NotoSerif 64pt, y=4): clock "14:32"

   Else:
   └─ FBInk ttf: clock "14:32" (only clock update, no full redraw)
   └─ Colon blinks (":" vs " ") every cycle as live indicator
```

**Touch event format** (zForce IR touch):

```
Byte offset  Field       Size
0-3          tv_sec      4 bytes (time_t)
4-7          tv_usec     4 bytes (suseconds_t)
8-9          type        __u16  (3=EV_ABS, 1=EV_KEY)
10-11        code        __u16  (0=ABS_X, 1=ABS_Y, 330=BTN_TOUCH)
12-15        value       __s32  (0 or 1)
```

A single tap generates 5 events in order:
```
ABS_Y (type=3, code=1, val=Y)
ABS_X (type=3, code=0, val=X)
width (type=3, code=24, val=size)
BTN_TOUCH (type=1, code=330, val=1)  ← our detection target
SYN (type=0, code=0, val=0)
```

Each tap also generates a release sequence (BTN_TOUCH=0) which is ignored.

### 4. Template — `template.json`

11 elements defining the default layout:

| Element | Type | Position | Content |
|---|---|---|---|
| `masthead-day` | text | (20, 10) | `{day_name}` — Sans Bold 11px |
| `masthead-date-bat` | text | (580, 10), right | `{date} Bat {battery}` — Sans Regular 11px |
| `clock-space` | clock_space | (140, 50), 320×105 | White rectangle for FBInk clock |
| `today-header` | text | (20, 200) | "TODAY" — Sans Bold 12px |
| `events` | list | (24, 220) | `{time} {title}`, max 3, Serif Regular 11px |
| `tasks-header` | text | (20, 270) | "TASKS" — Sans Bold 12px |
| `todos` | list | (24, 290) | `{mark} {text}`, max 3, Serif Regular 11px |
| `quote-header` | text | (20, 340) | "QUOTE" — Sans Bold 12px |
| `quote-text` | text | (24, 360) | `{quote_text}`, wrap 540px, Serif Italic 11px |
| `quote-author` | text | (24, 380) | `{quote_author}`, prefix "— ", Serif Regular 11px, #505050 |
| `footer` | text | (300, 780), center | `Refresh every 60s | {updated_at}`, Sans Regular 9px, #787878 |

### 5. Data — `dashboard-data.json`

Persisted data store with fields: `quote` (text + author), `todos` (id + text + done), `events` (id + time + title + description), `background` (URL path), `updated_at` (ISO timestamp).

### 6. Editor — `editor.html`

Standalone visual template editor accessed at `/editor`. Features:
- Live 600×800 CSS-scaled preview of the rendered dashboard
- Sidebar element list with click-to-select
- Property panel: text content, font family, font style, size, x/y position, color, alignment, visibility, wrap width
- Save / Reset template buttons
- Refresh Kobo button
- WiFi toggle

---

## Data Flow

```
Admin edits data in browser
        │
        ▼
POST /api/data → dashboard-data.json updated
        │
        ▼
POST /api/refresh → refreshToken++
        │
        ▼
Kobo polls GET /api/poll (every ~60s)
        │
        ├─ Token changed? → refresh
        └─ WiFi flag changed? → toggle interface
                │
                ▼
Kobo: wget /dashboard.raw → /tmp/dashboard.raw
        │
        ▼
Server: spawns python3 render_dashboard.py → stdout
        │
        ├─ Reads template.json (layout)
        ├─ Reads dashboard-data.json (content)
        ├─ Loads background image (if configured)
        ├─ Renders 600×800 grayscale via Pillow
        └─ Outputs 608×800 = 486400 bytes raw
        │
        ▼
Kobo: cat /tmp/dashboard.raw > /dev/fb0
        │
        ▼
FBInk: -s -f (full-screen flash refresh)
        │
        ▼
FBInk: ttf NotoSerif 64pt at row 4 → clock overlay
```

---

## Files

### Server (runs on PC/laptop)

| File | Purpose |
|---|---|
| `server.js` | Node.js Express server — all API endpoints + admin UI |
| `render_dashboard.py` | Python Pillow renderer — 600×800 grayscale bitmap |
| `template.json` | Template definition — 11 layout elements |
| `dashboard-data.json` | Persistent data — quote, todos, events, background |
| `editor.html` | Visual template editor (507 lines, standalone) |
| `kobo-dashboard.html` | Kobo web view (legacy, not actively used) |
| `package.json` | Node.js dependencies (express, multer) |
| `images/` | Background image files stored here |

### Kobo (runs on device)

| File | Purpose |
|---|---|
| `/mnt/onboard/.adds/dashboard/dashboard.lua` | Main Lua script — touch, fetch, render, loop |
| `/mnt/onboard/.adds/dashboard/dashboard.log` | Runtime log |
| `/tmp/dashboard.raw` | Downloaded framebuffer image |
| `/tmp/dashboard-refresh` | Signal file — touch this for immediate refresh |

### System (Kobo)

| Path | Purpose |
|---|---|
| `/dev/fb0` | Framebuffer — 608 bytes/line, 800 lines, 8bpp Y8 |
| `/dev/input/event1` | zForce IR touchscreen (BTN_TOUCH = code 330) |
| `/dev/input/event0` | Power slider / buttons (mxckpd) |
| `/mnt/onboard/fbink` | FBInk binary — framebuffer text overlay |
| `/mnt/onboard/fonts/noto/` | Noto fonts (Serif Regular/Italic, Sans Regular/Bold) |
| `/usr/share/fonts/liberation/` | Server-side Liberation fonts |
| `/sys/power/state-extended` | Sleep control (0 = awake) |
| `/etc/init.d/rcS` | Init script — boot sequence |
| `/sys/devices/platform/pmic_battery.1/power_supply/mc13892_bat/capacity` | Battery percentage |

---

## Setup

### Prerequisites

**Server** (Ubuntu/Debian):
```sh
sudo apt install nodejs npm python3 python3-pip
pip install Pillow
cd source_files_and_server
npm install
```

**Kobo**: Must have [FBInk](https://github.com/NiLuJe/FBInk) and LuaJIT installed. WiFi must be configured (wpa_supplicant + dhcpcd).

### Configure Server URL

Edit `dashboard.lua` to match your server's IP:
```lua
local SERVER_URL = "http://10.0.0.198:5001"
```

### Start Server

```sh
cd source_files_and_server
node server.js
```

You'll see output:
```
  ◈  Kobo Dashboard Server
  ────────────────────────────────────────
  Admin UI  →  http://localhost:5001
  Kobo sync →  http://10.0.0.198:5001/dashboard.json
```

### Manual Start on Kobo

SSH into the Kobo and run:
```sh
ssh -p 2222 root@10.0.0.153
/mnt/onboard/luajit /mnt/onboard/.adds/dashboard/dashboard.lua &
```

The dashboard will start immediately. Check the log:
```sh
tail -f /mnt/onboard/.adds/dashboard/dashboard.log
```

### Auto-Start on Boot

Add this line to `/etc/init.d/rcS`:
```sh
echo 'sleep 15 && /mnt/onboard/luajit /mnt/onboard/.adds/dashboard/dashboard.lua &' >> /etc/init.d/rcS
```

This appends a startup line that runs the dashboard 15 seconds after boot (giving kernel/udev time to initialize). To apply immediately:
```sh
ssh -p 2222 root@10.0.0.153
echo 'sleep 15 && /mnt/onboard/luajit /mnt/onboard/.adds/dashboard/dashboard.lua &' >> /etc/init.d/rcS
```

**Note**: This persists across normal reboots but will be overwritten by a firmware update.

### Kill / Restart Dashboard

```sh
ssh -p 2222 root@10.0.0.153
killall luajit
# Wait a moment, then restart:
/mnt/onboard/luajit /mnt/onboard/.adds/dashboard/dashboard.lua &
```

### Trigger Immediate Refresh

```sh
# From server machine:
curl -X POST http://localhost:5001/api/refresh

# From Kobo:
touch /tmp/dashboard-refresh
```

---

## Display Specs

| Property | Value |
|---|---|
| Resolution | 600 × 800 pixels |
| Rotation | 3 (270° counter-clockwise) |
| Color depth | 8 bpp (Y8 grayscale) |
| Framebuffer stride | 608 bytes/line |
| Total framebuffer size | 486400 bytes (608 × 800) |
| FBInk detected model | Kobo Mini (340 → Pixie @ Mark 4) |
| EPDC | No explicit wakeup support |
| DPI | 200 |
