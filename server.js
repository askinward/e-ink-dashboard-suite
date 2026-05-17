// ═══════════════════════════════════════════════════════════════════
//  Kobo Dashboard Server  ·  server.js
//  Run:  npm install && node server.js
//  Admin: http://localhost:5001
// ═══════════════════════════════════════════════════════════════════

'use strict';

const express = require('express');
const multer  = require('multer');
const fs      = require('fs');
const path    = require('path');
const os      = require('os');
const { spawn } = require('child_process');

const TEMPLATE_PATH = path.join(__dirname, 'template.json');
let refreshToken = 0;
let wifiEnabled = true;

const app     = express();
const PORT    = process.env.PORT || 5001;
const DATA    = path.join(__dirname, 'dashboard-data.json');
const IMG_DIR = path.join(__dirname, 'images');

if (!fs.existsSync(IMG_DIR)) fs.mkdirSync(IMG_DIR, { recursive: true });

// ── Default data ─────────────────────────────────────────────────────────────
const DEFAULTS = {
  quote: {
    text:   'The secret of getting ahead is getting started.',
    author: 'Mark Twain'
  },
  todos: [
    { id: 1, text: 'Review today\'s notes',      done: false },
    { id: 2, text: 'Prepare tomorrow\'s agenda',  done: false }
  ],
  events: [
    { id: 1, time: '09:00', title: 'Morning standup',   description: '' },
    { id: 2, time: '14:00', title: 'Deep work block',   description: 'No interruptions' }
  ],
  background: null,
  interval: 300,
  sshenabled: true,
  keepalive: 0,
  updated_at: new Date().toISOString()
};

// ── Persistence ───────────────────────────────────────────────────────────────
function load() {
  try   { return JSON.parse(fs.readFileSync(DATA, 'utf8')); }
  catch { return JSON.parse(JSON.stringify(DEFAULTS)); }
}

function save(d) {
  d.updated_at = new Date().toISOString();
  fs.writeFileSync(DATA, JSON.stringify(d, null, 2));
  return d;
}

// ── Network helpers ───────────────────────────────────────────────────────────
function localIPs() {
  return Object.values(os.networkInterfaces())
    .flat()
    .filter(n => n.family === 'IPv4' && !n.internal)
    .map(n => n.address);
}

// ── Multer (image uploads) ────────────────────────────────────────────────────
const upload = multer({
  storage: multer.diskStorage({
    destination: IMG_DIR,
    filename: (req, file, cb) => {
      const ext = path.extname(file.originalname).toLowerCase() || '.png';
      cb(null, 'background' + ext);
    }
  }),
  limits: { fileSize: 25 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => cb(null, /^image\//.test(file.mimetype))
});

// ── Middleware ────────────────────────────────────────────────────────────────
app.use(express.json());
app.use('/images', express.static(IMG_DIR));

// ── Routes — Kobo endpoints ──────────────────────────────────────────────────

// Primary data endpoint the Kobo plugin fetches
app.get('/dashboard.json', (_req, res) => res.json(load()));

// Serve the Kobo dashboard HTML so the plugin can cache it during sync
app.get('/kobo.html', (req, res) => {
  const htmlPath = path.join(__dirname, 'kobo-dashboard.html');
  if (fs.existsSync(htmlPath)) return res.sendFile(htmlPath);
  res.status(404).send('kobo-dashboard.html not found alongside server.js');
});

// Pre-rendered raw framebuffer (608×800, 8-bit grayscale)
app.get('/dashboard.raw', (req, res) => {
  const renderPy = path.join(__dirname, 'render_dashboard.py');
  const render = spawn('python3', [renderPy], { stdio: ['ignore', 'pipe', 'pipe'] });
  res.setHeader('Content-Type', 'application/octet-stream');
  render.stdout.pipe(res);
  render.stderr.on('data', d => process.stderr.write('[render] ' + d));
  render.on('error', () => { if (!res.headersSent) res.status(500).end(); });
});

// ── Routes — Admin API ────────────────────────────────────────────────────────

app.get('/api/data', (_req, res) => res.json(load()));

app.post('/api/data', (req, res) => {
  const d = load();
  const { quote, todos, events } = req.body;
  if (quote  !== undefined) d.quote  = quote;
  if (todos  !== undefined) d.todos  = todos;
  if (events !== undefined) d.events = events;
  refreshToken++;  // auto-notify Kobo on data change
  res.json(save(d));
});

app.post('/api/upload', upload.single('image'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No valid image file' });
  const ext = path.extname(req.file.originalname).toLowerCase() || '.png';
  const url = '/images/background' + ext;
  // Remove old background files with different extensions
  for (const old of fs.readdirSync(IMG_DIR)) {
    if (old.startsWith('background.') && old !== 'background' + ext) {
      fs.rmSync(path.join(IMG_DIR, old), { force: true });
    }
  }
  const d   = load();
  d.background = url;
  save(d);
  res.json({ ok: true, url });
});

app.delete('/api/background', (_req, res) => {
  const d = load();
  d.background = null;
  // Remove all background files
  for (const old of fs.readdirSync(IMG_DIR)) {
    if (old.startsWith('background.')) {
      fs.rmSync(path.join(IMG_DIR, old), { force: true });
    }
  }
  save(d);
  res.json({ ok: true });
});

// ── Template routes ────────────────────────────────────────────

function loadTemplate() {
  try { return JSON.parse(fs.readFileSync(TEMPLATE_PATH, 'utf8')); }
  catch { return null; }
}

function saveTemplate(t) {
  fs.writeFileSync(TEMPLATE_PATH, JSON.stringify(t, null, 2));
}

// Default template inline for reset
const DEFAULT_TEMPLATE = (() => {
  try { return JSON.parse(fs.readFileSync(TEMPLATE_PATH, 'utf8')); }
  catch { return { name: 'Default Dashboard', elements: [] }; }
})();

app.get('/api/template', (_req, res) => {
  const t = loadTemplate();
  if (t) return res.json(t);
  res.json(DEFAULT_TEMPLATE);
});

app.post('/api/template', (req, res) => {
  const t = req.body;
  if (!t || !t.elements) return res.status(400).json({ error: 'Invalid template' });
  saveTemplate(t);
  res.json({ ok: true });
});

app.post('/api/template/reset', (_req, res) => {
  saveTemplate(DEFAULT_TEMPLATE);
  res.json(DEFAULT_TEMPLATE);
});

app.get('/editor', (req, res) => {
  const editorPath = path.join(__dirname, 'editor.html');
  if (fs.existsSync(editorPath)) return res.sendFile(editorPath);
  res.status(404).send('editor.html not found');
});

// ── Refresh / Poll ──────────────────────────────────────────────

app.post('/api/refresh', (_req, res) => {
  refreshToken++;
  res.json({ ok: true, token: refreshToken });
});

app.get('/api/poll', (_req, res) => {
  const d = load();
  const interval = (d.interval && d.interval >= 60) ? d.interval : 300;
  const ssh = d.sshenabled === true;
  const keepalive = (d.keepalive && d.keepalive >= 0) ? d.keepalive : 0;
  res.json({ t: refreshToken, wifi: wifiEnabled, interval, ssh, keepalive });
});

app.post('/api/wifi/:state', (req, res) => {
  wifiEnabled = req.params.state === 'on';
  res.json({ ok: true, wifi: wifiEnabled });
});

app.post('/api/ssh/:state', (req, res) => {
  const d = load();
  d.sshenabled = req.params.state === 'on';
  save(d);
  res.json({ ok: true, ssh: d.sshenabled });
});

app.post('/api/keepalive', (req, res) => {
  const d = load();
  const n = parseInt(req.body.keepalive, 10);
  d.keepalive = (n && n >= 0) ? n : 0;
  save(d);
  res.json({ ok: true, keepalive: d.keepalive });
});

app.post('/api/interval', (req, res) => {
  const d = load();
  const n = parseInt(req.body.interval, 10);
  d.interval = (n && n >= 60) ? n : 300;
  refreshToken++;  // notify Kobo of interval change
  res.json(save(d));
});

// ── Admin UI ──────────────────────────────────────────────────────────────────
app.get('/', (_req, res) => {
  const ips = localIPs();
  const koboEndpoint = ips.length
    ? 'http://' + ips[0] + ':' + PORT + '/dashboard.json'
    : 'http://YOUR-PC-IP:' + PORT + '/dashboard.json';
  res.send(adminHtml(load(), koboEndpoint));
});

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  const ips = localIPs();
  console.log('\n  ◈  Kobo Dashboard Server');
  console.log('  ────────────────────────────────────────');
  console.log('  Admin UI  →  http://localhost:' + PORT);
  ips.forEach(ip => {
    console.log('  Kobo sync →  http://' + ip + ':' + PORT + '/dashboard.json');
  });
  console.log('  Edit SERVER_URL in main.lua to match your Kobo sync address.');
  console.log('');
});


// ═════════════════════════════════════════════════════════════════════════════
//  Admin HTML  (single-file, no build step)
// ═════════════════════════════════════════════════════════════════════════════
function adminHtml(data, koboEndpoint) {
  // Embed data safely via JSON, read in-page with no template-literal gymnastics
  const safeData = JSON.stringify(data).replace(/</g, '\\u003c');
  const safeMeta = JSON.stringify({ koboEndpoint }).replace(/</g, '\\u003c');

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Kobo Dashboard — Control</title>
<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

:root {
  --bg:         #0a0a0a;
  --surf:       #141414;
  --surf2:      #1c1c1c;
  --surf3:      #242424;
  --border:     #2a2a2a;
  --border2:    #363636;
  --text:       #e6e6e6;
  --muted:      #7a7a7a;
  --dim:        #444;
  --accent:     #f0f0f0;
  --success:    #5a9e72;
  --warn:       #9e7a5a;
  --r:          3px;
  --sidebar:    210px;
}

html, body { height: 100%; background: var(--bg); color: var(--text); font-family: 'Georgia', serif; font-size: 14px; line-height: 1.5; }

/* ── Layout ── */
.shell   { display: flex; height: 100vh; overflow: hidden; }
.sidebar { width: var(--sidebar); background: var(--surf); border-right: 1px solid var(--border); display: flex; flex-direction: column; flex-shrink: 0; }
.main    { flex: 1; overflow-y: auto; padding: 40px 48px; }

/* ── Sidebar ── */
.brand {
  padding: 22px 20px 18px;
  border-bottom: 1px solid var(--border);
  font-size: 11px;
  letter-spacing: 3px;
  text-transform: uppercase;
  color: var(--accent);
  font-family: 'Helvetica Neue', Arial, sans-serif;
}
.brand small { display: block; font-size: 9px; letter-spacing: 1px; color: var(--dim); margin-top: 3px; font-family: 'Courier New', monospace; }

.nav { flex: 1; padding: 10px 0; }
.nav-link {
  display: flex; align-items: center; gap: 11px;
  padding: 10px 20px;
  font-size: 12px;
  font-family: 'Helvetica Neue', Arial, sans-serif;
  color: var(--muted);
  cursor: pointer;
  border-left: 2px solid transparent;
  letter-spacing: 0.3px;
  user-select: none;
}
.nav-link:hover   { color: var(--text); background: var(--surf2); }
.nav-link.on      { color: var(--accent); border-left-color: var(--accent); background: var(--surf2); }
.nav-icon         { font-size: 14px; width: 16px; text-align: center; flex-shrink: 0; }

.sidebar-foot {
  padding: 14px 18px;
  border-top: 1px solid var(--border);
  font-size: 10px;
  color: var(--dim);
  font-family: 'Helvetica Neue', Arial, sans-serif;
  line-height: 1.7;
}
.endpoint { font-family: 'Courier New', monospace; font-size: 9px; color: var(--muted); word-break: break-all; margin-top: 3px; }

/* ── Sections ── */
.sec { display: none; max-width: 640px; }
.sec.on { display: block; }

.sec-title { font-size: 22px; font-weight: 400; color: var(--accent); margin-bottom: 4px; letter-spacing: -0.3px; }
.sec-sub   { font-size: 12px; color: var(--muted); margin-bottom: 30px; font-family: 'Helvetica Neue', Arial, sans-serif; }

/* ── Cards ── */
.card {
  background: var(--surf);
  border: 1px solid var(--border);
  border-radius: var(--r);
  padding: 22px 26px;
  margin-bottom: 14px;
}

/* ── Form ── */
.field       { margin-bottom: 18px; }
.field:last-child { margin-bottom: 0; }
label, .lbl  { display: block; font-size: 10px; letter-spacing: 2px; text-transform: uppercase; color: var(--muted); margin-bottom: 7px; font-family: 'Helvetica Neue', Arial, sans-serif; }
input[type=text], textarea, input[type=time] {
  width: 100%; background: var(--surf2); border: 1px solid var(--border);
  border-radius: var(--r); padding: 9px 12px; color: var(--text);
  font-family: Georgia, serif; font-size: 13px; outline: none;
}
input[type=text]:focus, textarea:focus, input[type=time]:focus { border-color: var(--border2); }
textarea { resize: vertical; min-height: 80px; line-height: 1.6; }
input[type=time] { width: 120px; font-family: 'Courier New', monospace; }
input[type=checkbox] { width: 14px; height: 14px; accent-color: var(--accent); cursor: pointer; flex-shrink: 0; }

/* ── Buttons ── */
.btn {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 9px 20px; font-size: 12px; font-family: 'Helvetica Neue', Arial, sans-serif;
  border: 1px solid var(--border2); border-radius: var(--r);
  background: var(--surf2); color: var(--text); cursor: pointer;
  letter-spacing: 0.5px; white-space: nowrap;
}
.btn:hover       { border-color: #555; }
.btn-pri         { background: var(--accent); color: #000; border-color: var(--accent); font-weight: 600; }
.btn-pri:hover   { background: #d0d0d0; }
.btn-del         { background: none; border: none; color: var(--dim); cursor: pointer; font-size: 15px; line-height: 1; padding: 4px 8px; }
.btn-del:hover   { color: var(--warn); }
.row-btns        { display: flex; gap: 10px; margin-top: 22px; align-items: center; }

/* ── List items (events/todos) ── */
.item-list   { display: flex; flex-direction: column; gap: 10px; margin-bottom: 4px; }
.list-item   { background: var(--surf2); border: 1px solid var(--border); border-radius: var(--r); padding: 14px 16px; display: flex; gap: 12px; align-items: flex-start; }
.item-body   { flex: 1; display: flex; flex-direction: column; gap: 9px; }
.item-row    { display: flex; gap: 10px; align-items: center; }
.no-items    { color: var(--dim); font-size: 12px; font-family: 'Helvetica Neue', Arial, sans-serif; padding: 8px 0; }

/* ── Image upload ── */
.dropzone {
  border: 1px dashed var(--border2); border-radius: var(--r);
  padding: 44px 20px; text-align: center; cursor: pointer;
}
.dropzone:hover, .dropzone.over { border-color: #666; background: var(--surf2); }
.dz-icon { font-size: 28px; opacity: 0.4; margin-bottom: 10px; }
.dz-text { font-size: 13px; color: var(--muted); }
.dz-hint { font-size: 11px; color: var(--dim); margin-top: 4px; font-family: 'Helvetica Neue', Arial, sans-serif; }

.img-preview { display: none; border: 1px solid var(--border); border-radius: var(--r); overflow: hidden; margin-bottom: 14px; }
.img-preview img { width: 100%; max-height: 260px; object-fit: contain; display: block; background: #000; filter: grayscale(1); }
.img-bar { padding: 10px 14px; background: var(--surf); display: flex; justify-content: space-between; align-items: center; font-size: 11px; color: var(--muted); font-family: 'Helvetica Neue', Arial, sans-serif; }
.img-badge { font-size: 9px; letter-spacing: 1px; border: 1px solid var(--border); padding: 2px 7px; border-radius: 2px; color: var(--dim); }

/* ── Toast ── */
.toasts { position: fixed; bottom: 22px; right: 22px; display: flex; flex-direction: column; gap: 8px; z-index: 999; }
.toast {
  background: var(--surf); border: 1px solid var(--border);
  padding: 10px 16px; border-radius: var(--r);
  font-size: 12px; font-family: 'Helvetica Neue', Arial, sans-serif;
  display: flex; align-items: center; gap: 9px;
  animation: tin .15s ease;
}
.toast.ok  { border-color: var(--success); }
.toast.err { border-color: var(--warn); }
.toast-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; background: var(--muted); }
.toast.ok  .toast-dot { background: var(--success); }
.toast.err .toast-dot { background: var(--warn); }
@keyframes tin { from { opacity:0; transform: translateY(6px); } to { opacity:1; transform: none; } }
</style>
</head>
<body>

<script id="__data__" type="application/json">${safeData}</script>
<script id="__meta__" type="application/json">${safeMeta}</script>

<div class="shell">

  <!-- Sidebar -->
  <nav class="sidebar">
    <div class="brand">
      Kobo Dashboard
      <small>CONTROL PANEL</small>
    </div>
    <div class="nav">
      <div class="nav-link on"  data-sec="quote">      <span class="nav-icon">❝</span> Quote      </div>
      <div class="nav-link"     data-sec="events">     <span class="nav-icon">◷</span> Events     </div>
      <div class="nav-link"     data-sec="todos">      <span class="nav-icon">○</span> Tasks      </div>
      <div class="nav-link"     data-sec="background"> <span class="nav-icon">▦</span> Background </div>
      <a href="/editor" style="text-decoration:none">
        <div class="nav-link" style="margin-top:8px;color:var(--dim);border-left-color:var(--surf3)"> <span class="nav-icon">✎</span> Template Editor </div>
      </a>
    </div>
    <div class="sidebar-foot">
      <div style="display:flex;gap:6px;margin-bottom:4px">
        <button class="btn btn-pri" onclick="triggerRefresh()" style="flex:1;padding:8px 0;font-size:11px">⟳ Refresh</button>
        <button class="btn" id="wifi-btn" onclick="toggleWifi()" style="flex:1;padding:8px 0;font-size:11px">WiFi ◉</button>
      </div>
      <div style="display:flex;gap:6px;margin-bottom:8px">
        <button class="btn" id="ssh-btn" onclick="toggleSsh()" style="flex:1;padding:8px 0;font-size:11px;opacity:0.6">SSH ◉</button>
      </div>
      <div style="margin-bottom:8px">
        <label style="font-size:9px;letter-spacing:1px">WiFi keep-alive</label>
        <select id="keepalive-sel" onchange="setKeepalive(this)" style="width:100%;background:var(--surf2);border:1px solid var(--border);border-radius:var(--r);padding:5px 8px;color:var(--text);font-size:11px;font-family:'Helvetica Neue',Arial,sans-serif;outline:none;margin-top:3px">
          <option value="0">Off immediately</option>
          <option value="30">30 seconds</option>
          <option value="60">1 minute</option>
          <option value="300">5 minutes</option>
          <option value="900">15 minutes</option>
          <option value="1800">30 minutes</option>
          <option value="3600">1 hour</option>
        </select>
      </div>
      <div style="margin-bottom:8px">
        <label style="font-size:9px;letter-spacing:1px">Auto-refresh</label>
        <select id="interval-sel" onchange="setInterval_s(this)" style="width:100%;background:var(--surf2);border:1px solid var(--border);border-radius:var(--r);padding:5px 8px;color:var(--text);font-size:11px;font-family:'Helvetica Neue',Arial,sans-serif;outline:none;margin-top:3px">
          <option value="60">Every 1 min</option>
          <option value="300" selected>Every 5 min</option>
          <option value="900">Every 15 min</option>
          <option value="1800">Every 30 min</option>
          <option value="3600">Every 1 hour</option>
          <option value="21600">Every 6 hours</option>
          <option value="43200">Every 12 hours</option>
          <option value="86400">Every 24 hours</option>
        </select>
      </div>
      Kobo sync endpoint:
      <div class="endpoint" id="endpoint-display"></div>
    </div>
  </nav>

  <!-- Main -->
  <main class="main">

    <!-- Quote -->
    <div class="sec on" id="sec-quote">
      <div class="sec-title">Quote</div>
      <div class="sec-sub">Shown in the footer strip of the dashboard. Keep it pithy.</div>
      <div class="card">
        <div class="field">
          <label>Text</label>
          <textarea id="q-text" rows="3"></textarea>
        </div>
        <div class="field">
          <label>Author</label>
          <input type="text" id="q-author">
        </div>
      </div>
      <div class="row-btns">
        <button class="btn btn-pri" onclick="saveQuote()">Save Quote</button>
      </div>
    </div>

    <!-- Events -->
    <div class="sec" id="sec-events">
      <div class="sec-title">Events</div>
      <div class="sec-sub">Today's schedule. Time and title appear on the device.</div>
      <div id="events-list" class="item-list"></div>
      <div class="row-btns">
        <button class="btn" onclick="addEvent()">+ Add Event</button>
        <button class="btn btn-pri" onclick="saveEvents()">Save Events</button>
      </div>
    </div>

    <!-- Todos -->
    <div class="sec" id="sec-todos">
      <div class="sec-title">Tasks</div>
      <div class="sec-sub">Your to-do list. Checked items appear with strikethrough.</div>
      <div id="todos-list" class="item-list"></div>
      <div class="row-btns">
        <button class="btn" onclick="addTodo()">+ Add Task</button>
        <button class="btn btn-pri" onclick="saveTodos()">Save Tasks</button>
      </div>
    </div>

    <!-- Background -->
    <div class="sec" id="sec-background">
      <div class="sec-title">Background Image</div>
      <div class="sec-sub">Displayed as a grayscale field behind the quote strip. High-contrast images work best on e-ink.</div>
      <div class="img-preview" id="img-preview">
        <img id="preview-img" src="" alt="Background preview">
        <div class="img-bar">
          <span>Current background</span>
          <span class="img-badge">GRAYSCALE PREVIEW</span>
        </div>
      </div>
      <div class="card">
        <div class="dropzone" id="dropzone" onclick="document.getElementById('file-in').click()">
          <div class="dz-icon">▦</div>
          <div class="dz-text">Drop image here or click to browse</div>
          <div class="dz-hint">PNG · JPG · WebP · max 25 MB · Device will render in grayscale</div>
        </div>
        <input type="file" id="file-in" accept="image/*" style="display:none">
      </div>
      <div class="row-btns" id="bg-remove-row" style="display:none">
        <button class="btn" style="color:var(--muted)" onclick="removeBackground()">Remove background</button>
      </div>
    </div>

  </main>
</div>

<div class="toasts" id="toasts"></div>

<script>
(function () {
  'use strict';

  var state = JSON.parse(document.getElementById('__data__').textContent);
  var meta  = JSON.parse(document.getElementById('__meta__').textContent);

  document.getElementById('endpoint-display').textContent = meta.koboEndpoint;

  // ── Nav ────────────────────────────────────────────────────────
  document.querySelectorAll('.nav-link').forEach(function (link) {
    link.addEventListener('click', function () {
      document.querySelectorAll('.nav-link').forEach(function (n) { n.classList.remove('on'); });
      document.querySelectorAll('.sec').forEach(function (s) { s.classList.remove('on'); });
      link.classList.add('on');
      document.getElementById('sec-' + link.dataset.sec).classList.add('on');
    });
  });

  // ── Keepalive ──────────────────────────────────────────────────
  window.setKeepalive = function (sel) {
    fetch('/api/keepalive', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ keepalive: parseInt(sel.value, 10) })
    }).then(function (r) { return r.json(); }).then(function (d) {
      if (d.ok) toast('WiFi keep-alive: ' + d.keepalive + 's', 'ok');
    }).catch(function () { toast('Failed to set keepalive', 'err'); });
  };

  // ── Interval ───────────────────────────────────────────────────
  window.setInterval_s = function (sel) {
    fetch('/api/interval', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ interval: parseInt(sel.value, 10) })
    }).then(function (r) { return r.json(); }).then(function (d) {
      if (d.interval) toast('Auto-refresh interval set to ' + d.interval + 's', 'ok');
    }).catch(function () { toast('Failed to set interval', 'err'); });
  };

  // ── Refresh ────────────────────────────────────────────────────
  window.triggerRefresh = function () {
    fetch('/api/refresh', { method: 'POST' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (d.ok) toast('Refresh signal sent — Kobo will pick up within 60s', 'ok');
        else toast('Refresh failed', 'err');
      })
      .catch(function () { toast('Network error', 'err'); });
  };

  // ── WiFi ───────────────────────────────────────────────────────
  window.toggleWifi = function () {
    fetch('/api/poll').then(function (r) { return r.json(); }).then(function (p) {
      var nextState = p.wifi ? 'off' : 'on';
      fetch('/api/wifi/' + nextState, { method: 'POST' })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          if (d.ok) {
            document.getElementById('wifi-btn').textContent = d.wifi ? 'WiFi ◉' : 'WiFi ⊙';
            toast('WiFi ' + (d.wifi ? 'enabled' : 'disabled') + ' — Kobo picks up within 60s', 'ok');
          }
        });
    }).catch(function () { toast('Network error', 'err'); });
  };
  // Init WiFi button
  fetch('/api/poll').then(function (r) { return r.json(); }).then(function (p) {
    document.getElementById('wifi-btn').textContent = p.wifi ? 'WiFi ◉' : 'WiFi ⊙';
  });

  // ── SSH ────────────────────────────────────────────────────────
  window.toggleSsh = function () {
    fetch('/api/poll').then(function (r) { return r.json(); }).then(function (p) {
      var nextState = p.ssh ? 'off' : 'on';
      fetch('/api/ssh/' + nextState, { method: 'POST' })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          if (d.ok) {
            document.getElementById('ssh-btn').textContent = d.ssh ? 'SSH ◉' : 'SSH ⊙';
            document.getElementById('ssh-btn').style.opacity = d.ssh ? '1' : '0.6';
            toast('SSH keepalive ' + (d.ssh ? 'enabled' : 'disabled'), 'ok');
          }
        });
    }).catch(function () { toast('Network error', 'err'); });
  };
  // Init SSH button
  fetch('/api/poll').then(function (r) { return r.json(); }).then(function (p) {
    document.getElementById('ssh-btn').textContent = p.ssh ? 'SSH ◉' : 'SSH ⊙';
    document.getElementById('ssh-btn').style.opacity = p.ssh ? '1' : '0.6';
  });

  // ── Quote ──────────────────────────────────────────────────────
  function initQuote() {
    document.getElementById('q-text').value   = state.quote.text   || '';
    document.getElementById('q-author').value = state.quote.author || '';
  }

  window.saveQuote = function () {
    var text   = document.getElementById('q-text').value.trim();
    var author = document.getElementById('q-author').value.trim();
    if (!text) { toast('Quote text cannot be empty', 'err'); return; }
    apiPost('/api/data', { quote: { text: text, author: author } }, function () {
      state.quote = { text: text, author: author };
      toast('Quote saved');
    });
  };

  // ── Events ─────────────────────────────────────────────────────
  var evtId = 100;

  function renderEvents() {
    var list = document.getElementById('events-list');
    if (!state.events.length) {
      list.innerHTML = '<div class="no-items">No events — add one below.</div>';
      return;
    }
    list.innerHTML = '';
    state.events.forEach(function (e, i) {
      var item = document.createElement('div');
      item.className = 'list-item';

      var body = document.createElement('div');
      body.className = 'item-body';

      var row1 = document.createElement('div');
      row1.className = 'item-row';

      var timeIn = document.createElement('input');
      timeIn.type  = 'time';
      timeIn.value = e.time || '09:00';
      timeIn.addEventListener('input', function () { state.events[i].time = timeIn.value; });

      var titleIn = document.createElement('input');
      titleIn.type        = 'text';
      titleIn.placeholder = 'Event title';
      titleIn.value       = e.title || '';
      titleIn.style.flex  = '1';
      titleIn.addEventListener('input', function () { state.events[i].title = titleIn.value; });

      row1.appendChild(timeIn);
      row1.appendChild(titleIn);

      var row2 = document.createElement('div');
      row2.className = 'item-row';

      var descIn = document.createElement('input');
      descIn.type        = 'text';
      descIn.placeholder = 'Description (optional)';
      descIn.value       = e.description || '';
      descIn.style.flex  = '1';
      descIn.style.fontSize = '12px';
      descIn.style.color    = 'var(--muted)';
      descIn.addEventListener('input', function () { state.events[i].description = descIn.value; });

      row2.appendChild(descIn);
      body.appendChild(row1);
      body.appendChild(row2);

      var del = document.createElement('button');
      del.className   = 'btn-del';
      del.textContent = '×';
      del.title       = 'Remove';
      del.addEventListener('click', function () {
        state.events.splice(i, 1);
        renderEvents();
      });

      item.appendChild(body);
      item.appendChild(del);
      list.appendChild(item);
    });
  }

  window.addEvent = function () {
    state.events.push({ id: evtId++, time: '09:00', title: '', description: '' });
    renderEvents();
  };

  window.saveEvents = function () {
    apiPost('/api/data', { events: state.events }, function () { toast('Events saved'); });
  };

  // ── Todos ──────────────────────────────────────────────────────
  var todoId = 200;

  function renderTodos() {
    var list = document.getElementById('todos-list');
    if (!state.todos.length) {
      list.innerHTML = '<div class="no-items">No tasks — add one below.</div>';
      return;
    }
    list.innerHTML = '';
    state.todos.forEach(function (t, i) {
      var item = document.createElement('div');
      item.className = 'list-item';

      var body = document.createElement('div');
      body.className = 'item-body';

      var row = document.createElement('div');
      row.className = 'item-row';

      var chk = document.createElement('input');
      chk.type    = 'checkbox';
      chk.checked = !!t.done;
      chk.addEventListener('change', function () {
        state.todos[i].done = chk.checked;
        textIn.style.textDecoration = chk.checked ? 'line-through' : 'none';
        textIn.style.color          = chk.checked ? 'var(--dim)' : 'var(--text)';
      });

      var textIn = document.createElement('input');
      textIn.type        = 'text';
      textIn.placeholder = 'Task description';
      textIn.value       = t.text || '';
      textIn.style.flex  = '1';
      textIn.style.textDecoration = t.done ? 'line-through' : 'none';
      textIn.style.color          = t.done ? 'var(--dim)' : 'var(--text)';
      textIn.addEventListener('input', function () { state.todos[i].text = textIn.value; });

      row.appendChild(chk);
      row.appendChild(textIn);
      body.appendChild(row);

      var del = document.createElement('button');
      del.className   = 'btn-del';
      del.textContent = '×';
      del.addEventListener('click', function () {
        state.todos.splice(i, 1);
        renderTodos();
      });

      item.appendChild(body);
      item.appendChild(del);
      list.appendChild(item);
    });
  }

  window.addTodo = function () {
    state.todos.push({ id: todoId++, text: '', done: false });
    renderTodos();
  };

  window.saveTodos = function () {
    apiPost('/api/data', { todos: state.todos }, function () { toast('Tasks saved'); });
  };

  // ── Background ─────────────────────────────────────────────────
  function showPreview(url) {
    var p = document.getElementById('img-preview');
    document.getElementById('preview-img').src = url;
    p.style.display = 'block';
    document.getElementById('bg-remove-row').style.display = 'flex';
  }

  document.getElementById('file-in').addEventListener('change', function () {
    if (this.files[0]) uploadFile(this.files[0]);
  });

  var dz = document.getElementById('dropzone');
  dz.addEventListener('dragover',  function (e) { e.preventDefault(); dz.classList.add('over'); });
  dz.addEventListener('dragleave', function ()  { dz.classList.remove('over'); });
  dz.addEventListener('drop', function (e) {
    e.preventDefault();
    dz.classList.remove('over');
    var f = e.dataTransfer.files[0];
    if (f && f.type.startsWith('image/')) uploadFile(f);
  });

  function uploadFile(file) {
    var fd = new FormData();
    fd.append('image', file);
    fetch('/api/upload', { method: 'POST', body: fd })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (d.ok) {
          state.background = d.url;
          showPreview(d.url + '?t=' + Date.now());
          toast('Background updated');
        } else {
          toast('Upload failed', 'err');
        }
      })
      .catch(function () { toast('Upload error', 'err'); });
  }

  window.removeBackground = function () {
    fetch('/api/background', { method: 'DELETE' })
      .then(function () {
        state.background = null;
        document.getElementById('img-preview').style.display = 'none';
        document.getElementById('bg-remove-row').style.display = 'none';
        toast('Background removed');
      });
  };

  // ── API helper ─────────────────────────────────────────────────
  function apiPost(url, body, onOk) {
    fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (d && d.updated_at) onOk(d);
      else toast('Save failed', 'err');
    })
    .catch(function () { toast('Network error', 'err'); });
  }

  // ── Toast ──────────────────────────────────────────────────────
  window.toast = function (msg, type) {
    var t = document.createElement('div');
    t.className = 'toast' + (type ? ' ' + type : ' ok');
    var dot = document.createElement('span');
    dot.className = 'toast-dot';
    t.appendChild(dot);
    t.appendChild(document.createTextNode(msg));
    document.getElementById('toasts').appendChild(t);
    setTimeout(function () { t.remove(); }, 2800);
  };

  // ── Init ───────────────────────────────────────────────────────
  initQuote();
  renderEvents();
  renderTodos();
  if (state.background) showPreview(state.background);
  // Init interval selector from loaded data
  var intSel = document.getElementById('interval-sel');
  if (state.interval) {
    for (var i = 0; i < intSel.options.length; i++) {
      if (parseInt(intSel.options[i].value, 10) === state.interval) {
        intSel.selectedIndex = i; break;
      }
    }
  }
  // Init keepalive selector from loaded data
  var kaSel = document.getElementById('keepalive-sel');
  if (state.keepalive !== undefined) {
    for (var i = 0; i < kaSel.options.length; i++) {
      if (parseInt(kaSel.options[i].value, 10) === state.keepalive) {
        kaSel.selectedIndex = i; break;
      }
    }
  }

})();
</script>
</body>
</html>`;
}
