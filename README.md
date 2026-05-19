# Kobo Dashboard

A lightweight e-ink dashboard for **Kobo Mini** that displays time, events, todos, quotes, and a full-screen background image. Rendering is done **server-side** (Python + Pillow) — the Kobo simply downloads a pre-rendered raw framebuffer bitmap and writes it directly to `/dev/fb0`.

## Features

*   **Server-Side Rendering:** All visual elements are rendered on a host machine, minimizing battery drain on the Kobo.
*   **Dynamic Content:** Displays time, custom quotes, events, and to-do lists.
*   **Customizable Background:** Supports custom grayscale background images.
*   **Template Editor:** A web-based visual editor allows for easy customization of layout, fonts, and content.
*   **Kobo Client:** A minimal LuaJIT script on the Kobo handles touch input, server polling, image downloads, and framebuffer updates.
*   **WiFi & SSH Management:** Control Kobo's WiFi and SSH status via the web UI.

## Architecture

The system operates on a client-server model:

```
┌─────────────────────────┐       ┌─────────────────────────────┐
│  Admin Browser          │       │  Kobo Mini (e-ink)          │
│  http://your-ip:5001    │       │  ─────────────────          │
│                         │       │                             │
│  ┌─────────────────┐    │       │  dashboard.lua (LuaJIT)     │
│  │ Admin UI (HTML) │    │       │  ┌─────────────────────┐   │
│  │  - Edit data    │    │       │  │  wget dashboard.raw │   │
│  │  - Upload image │────┼───────┼─▶│  ↓ /tmp/dashboard   │   │
│  │  - Refresh Kobo │    │       │  │  ↓ /dev/fb0         │   │
│  │  - WiFi/SSH     │    │       │  │  ↓ FBInk clock      │   │
│  └─────────────────┘    │       │  └─────────────────────┘   │
│                         │       │                             │
│  ┌─────────────────┐    │       │  FBInk overlays clock      │
│  │  Node/Express   │    │       │  using exact coordinates   │
│  │  server.js      │────┼───────┼─── /api/poll (interval)   │
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

**Key Design Decision:** Server-side rendering provides full design freedom with minimal device battery drain. The Kobo only downloads a raw bitmap and writes it to the framebuffer, avoiding complex on-device rendering.

---

## Components

### 1. Server (`server.js`) - Node.js + Express

The server manages data, serves the admin UI, handles image uploads, and spawns the rendering process.

*   **Admin UI:** Accessible via a web browser, allows editing quotes, events, to-dos, background images, and controlling Kobo's WiFi/SSH.
*   **API Endpoints:**
    *   `/dashboard.raw` (GET): Streams the rendered 608x800 grayscale bitmap.
    *   `/api/data` (GET/POST): Manages `dashboard-data.json`.
    *   `/api/template` (GET/POST): Manages `template.json`.
    *   `/api/upload` (POST): Handles background image uploads.
    *   `/api/poll` (GET): Kobo polls this for refresh tokens and settings.
    *   `/api/wifi/:state`, `/api/ssh/:state`: Control Kobo's network status.
*   **Refresh Mechanism:** Uses a `refreshToken`. Kobo polls `/api/poll`, and a redraw occurs when the token changes.

### 2. Renderer (`render_dashboard.py`) - Python + Pillow

Generates the raw framebuffer image based on `template.json` and `dashboard-data.json`.

*   **Input:** `template.json` (layout), `dashboard-data.json` (content), `images/` (background).
*   **Output:** 486400 bytes (608x800, 8-bit grayscale) to stdout.
*   **Features:** Supports text, lists, and background images with dynamic variable substitution and custom fonts. **Crucially, it skips rendering the clock**, which is handled by the Kobo client for precise overlay control.

### 3. Kobo Client (`dashboard.lua`) - LuaJIT + FBInk

Runs on the Kobo Mini, handling user interaction and display updates.

*   **Main Loop:** Periodically polls the server, downloads `/dashboard.raw`, writes to `/dev/fb0`, and uses FBInk for text overlays (clock).
*   **Touch Handling:** Detects taps to trigger refreshes or exit.
*   **Clock Rendering:** Uses FBInk to draw the time with precise coordinates, font size, and background restoration for transparency. Includes a halo effect for improved legibility.
*   **WiFi/SSH Control:** Manages Kobo's network based on server settings.

### 4. Template (`template.json`)

Defines the layout of elements on the dashboard, including text, lists, and the clock's position and styling.

---

## Data Flow

1.  **Admin Interaction:** User modifies data (quote, events, etc.) via the Admin UI in a browser.
2.  **Server Signals Kobo:** Admin actions like "Refresh Kobo" or data changes increment `refreshToken`.
3.  **Kobo Polls Server:** The Kobo client polls `/api/poll` at intervals.
4.  **Kobo Fetches Data:** If the token changes, Kobo downloads `/dashboard.raw` and updates `/dev/fb0`.
5.  **Server Renders Image:** `render_dashboard.py` generates the bitmap, *excluding* the clock.
6.  **Kobo Draws Clock:** `dashboard.lua` uses FBInk to draw the time over the downloaded background, ensuring perfect alignment and transparency.

---

## Setup

### Prerequisites

**Server (Host Machine):**
*   Node.js & npm
*   Python 3 & pip
*   Pillow library (`pip install Pillow`)

**Kobo Device:**
*   KOReader with FBInk and LuaJIT installed.
*   Configured WiFi (wpa_supplicant + dhcpcd).

### Configuration

1.  **Server URL:** Edit `SERVER_URL` in `dashboard.lua` on the Kobo to match your server's IP address.
2.  **Start Server:** Navigate to the `source_files_and_server` directory and run `node server.js`.
3.  **Start on Kobo:** SSH into your Kobo and run `/mnt/onboard/luajit /mnt/onboard/.adds/dashboard/dashboard.lua &`.
4.  **Auto-Start on Boot:** Add the dashboard startup command to `/etc/init.d/rcS` on the Kobo.

--- 

## Display Specs

*   **Resolution:** 600 × 800 pixels
*   **Framebuffer Stride:** 608 bytes/line
*   **FBInk Model:** Kobo Mini (340)

--- 

## Files

*   **Server:** `server.js`, `render_dashboard.py`, `template.json`, `dashboard-data.json`, `editor.html`, `images/`
*   **Kobo Client:** `/mnt/onboard/.adds/dashboard/dashboard.lua`
*   **Logs:** `/mnt/onboard/.adds/dashboard/dashboard.log` (Kobo), server logs (console)

--- 

## Notes & Troubleshooting

*   **Clock Ghosting:** Ensure server-side clock rendering is disabled in `render_dashboard.py`.
*   **Font Legibility:** The clock uses a halo effect for improved contrast.
*   **Connection Issues:** Verify Kobo's IP address and ensure SSH/WiFi are active. Use `ifconfig eth0` on Kobo to check WiFi status.
*   **FBInk Errors:** Check `/tmp/dash_err.log` or `/mnt/onboard/.adds/dashboard/dashboard.log` on the Kobo for detailed error messages.
