// Life OS sync server — minimal, no dependencies
// Endpoints:
//   GET  /api/health           → { ok: true }
//   GET  /api/data             → { lastUpdated, data } (auth required)
//   PUT  /api/data             → save payload (auth required, last-write-wins)
const http = require('http');
const fs = require('fs');
const path = require('path');

const DATA_DIR = process.env.DATA_DIR || '/data';
const DATA_FILE = path.join(DATA_DIR, 'sync.json');
const TOKEN = process.env.SYNC_TOKEN || '';
const PORT = parseInt(process.env.PORT || '3001', 10);
const MAX_BODY = 10 * 1024 * 1024; // 10 MB safety cap

if (!TOKEN) {
  console.error('FATAL: SYNC_TOKEN env var must be set');
  process.exit(1);
}

fs.mkdirSync(DATA_DIR, { recursive: true });

function setCORS(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, PUT, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.setHeader('Access-Control-Max-Age', '86400');
}

function readData() {
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf-8')); }
  catch { return { lastUpdated: 0, data: {} }; }
}

function writeData(payload) {
  const tmp = DATA_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(payload));
  fs.renameSync(tmp, DATA_FILE);
}

function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

const server = http.createServer((req, res) => {
  setCORS(res);
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const url = new URL(req.url, 'http://x');

  if (url.pathname === '/api/health' && req.method === 'GET') {
    return json(res, 200, { ok: true, version: 1 });
  }

  const auth = req.headers.authorization || '';
  if (auth !== 'Bearer ' + TOKEN) {
    return json(res, 401, { error: 'unauthorized' });
  }

  if (url.pathname === '/api/data' && req.method === 'GET') {
    return json(res, 200, readData());
  }

  if (url.pathname === '/api/data' && req.method === 'PUT') {
    let body = '';
    let oversize = false;
    req.on('data', chunk => {
      body += chunk;
      if (body.length > MAX_BODY) { oversize = true; req.destroy(); }
    });
    req.on('end', () => {
      if (oversize) return json(res, 413, { error: 'payload too large' });
      let payload;
      try { payload = JSON.parse(body); }
      catch { return json(res, 400, { error: 'invalid json' }); }
      const existing = readData();
      const incoming = payload.lastUpdated || 0;
      const current = existing.lastUpdated || 0;
      if (incoming >= current) {
        writeData(payload);
        return json(res, 200, { ok: true, lastUpdated: incoming });
      }
      return json(res, 200, { ok: false, reason: 'stale', lastUpdated: current });
    });
    return;
  }

  json(res, 404, { error: 'not found' });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log('Life OS sync server listening on :' + PORT);
});
