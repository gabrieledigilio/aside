#!/usr/bin/env node
// Gist brain, Mac host. Runs the shared core (lens/gist-core.js), talks to the model API with
// the key in key.txt, and serves the lens. Zero dependencies. Node 20+.
//
//   node brain/brain.mjs serve [--mock]        http://localhost:8787
//   node brain/brain.mjs replay <file>         feed a transcript to the running server, like live speech
//
// Config: key.txt holds the API key (the key alone). Optional .env overrides:
//   MODEL_BASE_URL=https://api.meta.ai/v1
//   FAST_MODEL=muse-ember-1.0   FAST_EFFORT=low
//   DEEP_MODEL=muse-wonder-1.0  DEEP_EFFORT=minimal   (muse-spark-1.3 costs about a third as much)

import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import '../lens/gist-core.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LENS_DIR = path.join(ROOT, 'lens');
const DATA_DIR = path.join(ROOT, 'data');
const PORT = Number(process.env.PORT || 8787);
const { GistCore } = globalThis;

// ---------- config (re-read on every call, so pasting the key needs no restart) ----------
function cfg() {
  const env = { ...process.env };
  const file = path.join(ROOT, '.env');
  if (fs.existsSync(file)) {
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m && m[2] && env[m[1]] === undefined) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
  let key = env.MODEL_API_KEY || '';
  const keyFile = path.join(ROOT, 'key.txt');
  if (!key && fs.existsSync(keyFile)) {
    const k = fs.readFileSync(keyFile, 'utf8').trim();
    if (k && !/\s/.test(k) && !k.startsWith('PASTE')) key = k;
  }
  return {
    key,
    base: (env.MODEL_BASE_URL || 'https://api.meta.ai/v1').replace(/\/$/, ''),
    fast: { model: env.FAST_MODEL || 'muse-ember-1.0', effort: env.FAST_EFFORT || 'low' },
    deep: { model: env.DEEP_MODEL || 'muse-wonder-1.0', effort: env.DEEP_EFFORT || 'minimal' },
  };
}

// ---------- transports ----------
// Real: one POST to the chat-completions endpoint. The core handles retries and parsing.
async function sendReal(body) {
  const c = cfg();
  const res = await fetch(`${c.base}/chat/completions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${c.key}` },
    body: JSON.stringify(body),
  });
  return { status: res.status, text: await res.text() };
}

// Scripted: answers from samples/mock-script.json, picked by how far the conversation has got,
// so the preview works with no key and looks the same every time.
function sendMock(body) {
  const script = JSON.parse(fs.readFileSync(path.join(ROOT, 'samples', 'mock-script.json'), 'utf8'));
  const name = body.response_format?.json_schema?.name || '';
  const user = body.messages?.[1]?.content;
  const text = typeof user === 'string' ? user : (user?.[0]?.text || '');
  const convo = (text.split(/TRANSCRIPT SO FAR:|CONVERSATION SO FAR:/)[1] || '').split(/\n\n(NEWEST WORDS|PREVIOUS|WHAT IS BEING SAID|THEY JUST ASKED)/)[0];
  const sentences = Math.max(1, (convo.match(/[.!?]+(\s|$)/g) || []).length);
  const pick = (arr) => arr[Math.min(sentences, arr.length) - 1];
  const out =
    name === 'gist_fast' ? pick(script.fast)
    : name === 'gist_deep' ? pick(script.deep)
    : name === 'gist_recap' ? script.recap
    : name === 'gist_brief' ? script.brief
    : name === 'gist_look' ? script.look
    : name === 'gist_turn' ? script.turn
    : {};
  const delay = name === 'gist_fast' ? 250 : 900;      // feel like a network call, so the thinking state is visible
  return new Promise((resolve) => setTimeout(() => resolve({
    status: 200,
    text: JSON.stringify({ choices: [{ message: { content: JSON.stringify(out) }, finish_reason: 'stop' }], usage: null }),
  }), delay));
}

// ---------- server ----------
function serve({ mock }) {
  const isMock = () => mock || !cfg().key;
  let waiters = [];                                   // long-poll responses waiting for a change

  const memoryFile = path.join(DATA_DIR, 'memory.json');
  const core = GistCore.create({
    send: (body) => (isMock() ? sendMock(body) : sendReal(body)),
    onChange: () => { const w = waiters; waiters = []; w.forEach((fn) => fn()); },
    onMemory: (m) => {
      try { fs.mkdirSync(DATA_DIR, { recursive: true }); fs.writeFileSync(memoryFile, JSON.stringify(m, null, 1)); } catch { /* best effort */ }
    },
    // This Mac has no camera on the wearer's face. When the brain wants a look, it says so in
    // the state, and a phone that is relaying for the glasses takes the photo and posts it to /look.
    requestLook: () => { core.setHost({ lookWanted: Date.now() }); },
    silenceEndMs: Number(process.env.SILENCE_END_MS || 30000),
  });

  // The link code. Requests that arrive through the public tunnel must carry it; requests from
  // this Mac itself do not need it. Kept between restarts so a phone or glasses stay linked.
  const linkFile = path.join(DATA_DIR, 'link.json');
  let LINK = '';
  try { LINK = JSON.parse(fs.readFileSync(linkFile, 'utf8')).code || ''; } catch { /* first run */ }
  if (!/^[\w-]{10,}$/.test(LINK)) {
    LINK = crypto.randomBytes(12).toString('base64url');
    try { fs.mkdirSync(DATA_DIR, { recursive: true }); fs.writeFileSync(linkFile, JSON.stringify({ code: LINK })); } catch { /* best effort */ }
  }
  const viaTunnel = (req) => !!(req.headers['cf-connecting-ip'] || req.headers['cf-ray'] || req.headers['x-forwarded-for'] || req.headers['x-forwarded-host']);
  const hasLink = (req, url) => url.searchParams.get('k') === LINK || req.headers['x-gist-link'] === LINK;
  const applyModels = () => { const c = cfg(); core.setModels({ fast: c.fast, deep: c.deep }); };
  applyModels();
  try { core.loadMemory(JSON.parse(fs.readFileSync(memoryFile, 'utf8'))); } catch { /* none yet */ }
  core.setHost({ ears: 'none', where: 'mac' });
  setInterval(() => { applyModels(); core.tick(); }, 1000);

  let replaying = false;
  let matrix = { running: false, results: [] };
  const publicUrl = () => {
    try {
      const m = (fs.readFileSync(path.join(ROOT, 'tunnel.log'), 'utf8').match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/g) || [])
        .filter((u) => u !== 'https://api.trycloudflare.com');
      return m.length ? m[m.length - 1] : '';
    } catch { return ''; }
  };
  const view = () => {
    const c = cfg();
    return {
      ...core.state(),
      mode: isMock() ? 'scripted' : 'live',
      models: isMock() ? null : { fast: `${c.fast.model} (${c.fast.effort})`, deep: `${c.deep.model} (${c.deep.effort})` },
    };
  };

  const json = (res, code, body) => {
    res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(body));
  };
  const readBody = (req) => new Promise((resolve) => {
    let b = '';
    req.on('data', (d) => { b += d; if (b.length > 12e6) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(b || '{}')); } catch { resolve({}); } });
  });

  async function replaySample(file, wpm = 165) {
    if (replaying) return;
    replaying = true;
    try {
      const sentences = fs.readFileSync(file, 'utf8').replace(/\s+/g, ' ').match(/[^.!?]+[.!?]+/g) || [];
      core.setListening(true);
      core.setHost({ ears: 'replay' });
      for (const sentence of sentences) {
        const text = sentence.trim();
        await new Promise((r) => setTimeout(r, (text.split(' ').length / wpm) * 60000));
        core.heard(text);
      }
    } finally { replaying = false; }
  }

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');
    // The link code may also ride in the path (/k/<code>/...), so every relative request the
    // lens makes carries it even where a browser drops query strings.
    let p = url.pathname;
    let pathCode = '';
    const coded = p.match(/^\/k\/([\w-]+)(\/.*)?$/);
    if (coded) {
      if (!coded[2]) { res.writeHead(302, { location: `/k/${coded[1]}/${url.search}` }); return res.end(); }
      pathCode = coded[1];
      p = coded[2];
    }
    const outside = viaTunnel(req);
    const isApi = req.method === 'POST' || ['/state', '/poll', '/info', '/memory', '/bench', '/bench-matrix'].includes(p);
    // Anything that reads the conversation or spends model calls needs the link code when it comes from outside.
    if (isApi && outside && !hasLink(req, url) && pathCode !== LINK) return json(res, 401, { error: 'This link has expired. Open the setup page on the Mac and scan the code again.' });
    // Other websites open in a browser on this Mac cannot post here: only JSON requests are taken, and no cross-origin access is granted.
    if (req.method === 'POST' && !String(req.headers['content-type'] || '').includes('application/json')) return json(res, 415, { error: 'JSON only' });
    if (req.method !== 'GET' && req.method !== 'POST') { res.writeHead(405); return res.end(); }

    // --- what the lens reads ---
    if (p === '/state') return json(res, 200, view());
    if (p === '/poll') {                               // answers at once if the lens is behind, else when something changes
      const have = Number(url.searchParams.get('v') || -1);
      if (core.state().v !== have) return json(res, 200, view());
      let done = false;
      const finish = () => { if (done) return; done = true; clearTimeout(timer); json(res, 200, view()); };
      const timer = setTimeout(finish, 25000);
      waiters.push(finish);
      req.on('close', () => { done = true; clearTimeout(timer); });
      return;
    }
    if (p === '/info') {
      const c = cfg();
      return json(res, 200, { core: GistCore.VERSION, mode: isMock() ? 'scripted' : 'live', publicUrl: publicUrl(), link: LINK, fast: c.fast, deep: c.deep });
    }
    if (p === '/memory') return json(res, 200, { items: core.memory() });

    // --- what feeds the brain ---
    if (req.method === 'POST') {
      const body = await readBody(req);
      if (p === '/chunk') { core.heard(body.text); return json(res, 200, { ok: true, listening: core.state().listening }); }
      if (p === '/listening') { core.setListening(!!body.listening); return json(res, 200, { listening: core.state().listening }); }
      if (p === '/end') { core.end(); return json(res, 200, { ok: true }); }
      if (p === '/day') { core.setDay(body.events); return json(res, 200, { ok: true, next: core.state().next }); }
      if (p === '/brief') { return json(res, 200, { ok: core.briefNow() }); }
      if (p === '/plan') { return json(res, 200, { events: await core.planDay() }); }
      if (p === '/host') { core.setHost(body); return json(res, 200, { ok: true }); }
      if (p === '/look') { const seen = await core.look(body.image, !!body.quiet); return json(res, 200, { seen }); }
      if (p === '/model') {                             // lets the in-page brain (?native in a desktop browser) reach the model through this Mac
        try { return json(res, 200, await (isMock() ? sendMock(body) : sendReal(body))); }
        catch (err) { return json(res, 200, { status: 0, text: String(err.message || err) }); }
      }
      if (p === '/forget' || p === '/reset') { core.forget(); core.setListening(true); return json(res, 200, { ok: true }); }
      if (p === '/replay-sample') {
        core.forget(); core.loadMemory([]);
        const name = (url.searchParams.get('name') || 'explanation').replace(/[^a-z0-9-]/gi, '');
        const file = path.join(ROOT, 'samples', `${name}.txt`);
        if (!fs.existsSync(file)) return json(res, 404, { error: 'no such sample' });
        replaySample(file, Math.max(60, Number(url.searchParams.get('wpm') || 165)));
        return json(res, 200, { ok: true });
      }
      if (p === '/demo-day') {                          // a sample calendar, so the brief can be shown without a phone
        const t = Date.now();
        core.setDay([
          { id: 'd1', title: 'Pitch feedback with the Meta mentors', start: t + 8 * 60000, end: t + 38 * 60000, location: 'Meta booth', notes: 'Show the glasses demo. Ask about display sleep and mic range.' },
          { id: 'd2', title: 'Junction final submission', start: t + 20 * 3600000, end: t + 21 * 3600000, location: '', notes: '' },
        ]);
        return json(res, 200, { ok: core.briefNow() });
      }
    }

    // --- measuring models on a fixed input (does not touch the live state) ---
    if (p === '/bench') {
      if (isMock()) return json(res, 400, { error: 'no key: bench needs the real API' });
      const tier = url.searchParams.get('tier') === 'fast' ? 'fast' : 'deep';
      const sample = fs.readFileSync(path.join(ROOT, 'samples', 'explanation.txt'), 'utf8').replace(/\s+/g, ' ').trim();
      const upTo = Number(url.searchParams.get('sentences') || 8);
      const text = (sample.match(/[^.!?]+[.!?]+/g) || []).slice(0, upTo).join(' ').trim();
      let image = null;
      if (url.searchParams.get('image')) {
        try { image = fs.readFileSync(path.join(ROOT, 'samples', 'slide.jpg')).toString('base64'); } catch { return json(res, 404, { error: 'samples/slide.jpg missing' }); }
      }
      try {
        const r = await core.bench(tier, url.searchParams.get('model'), url.searchParams.get('effort'), text, image);
        return json(res, 200, r);
      } catch (err) { return json(res, 200, { error: String(err.message || err) }); }
    }

    // --- a whole matrix of models and thinking levels, run in the background; poll /bench-matrix for results ---
    if (p === '/bench-matrix') {
      if (url.searchParams.get('start') && !matrix.running && !isMock()) {
        const sample = fs.readFileSync(path.join(ROOT, 'samples', 'explanation.txt'), 'utf8').replace(/\s+/g, ' ').trim();
        const text = (sample.match(/[^.!?]+[.!?]+/g) || []).slice(0, 8).join(' ').trim();
        const runs = Number(url.searchParams.get('runs') || 2);
        const combos = (url.searchParams.get('combos') || '').split(',').filter(Boolean).map((c) => c.split(':'));
        matrix = { running: true, results: [] };
        (async () => {
          for (const [tier, model, effort] of combos) {
            const row = { tier, model, effort, ms: [], out: null, usage: null, error: '' };
            matrix.results.push(row);
            for (let i = 0; i < runs; i++) {
              try {
                const r = await core.bench(tier === 'fast' ? 'fast' : 'deep', model, effort, text, null);
                row.ms.push(r.ms); row.out = r.clean; row.usage = r.usage;
              } catch (err) { row.error = String(err.message || err).slice(0, 160); break; }
            }
          }
          matrix.running = false;
        })();
      }
      return json(res, 200, matrix);
    }

    // --- static: the lens ---
    const rel = p === '/' ? 'index.html' : p === '/setup' ? 'setup.html' : p.slice(1);
    const file = path.join(LENS_DIR, path.normalize(rel));
    if (!file.startsWith(LENS_DIR + path.sep) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404); return res.end('not found');
    }
    const type = {
      '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
      '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.jpg': 'image/jpeg',
    }[path.extname(file)] || 'application/octet-stream';
    // The glasses browser caches hard and has no reload button, so nothing here may be cached (fonts aside).
    res.writeHead(200, { 'content-type': type, 'cache-control': type === 'font/woff2' ? 'public, max-age=86400' : 'no-store' });
    fs.createReadStream(file).pipe(res);
  });

  server.on('error', (err) => {
    console.error(err.code === 'EADDRINUSE' ? `Port ${PORT} is busy: another Aside brain is already running. Close it first.` : err);
    process.exit(1);
  });
  // Local only: the one way in from outside is the tunnel, and that needs the link code.
  server.listen(PORT, '127.0.0.1', () => {
    const c = cfg();
    console.log(`Aside brain ${GistCore.VERSION} on http://localhost:${PORT}`);
    console.log(isMock() ? '  scripted answers (no key found in key.txt)' : `  fast: ${c.fast.model} (${c.fast.effort})   deep: ${c.deep.model} (${c.deep.effort})`);
    console.log(`  setup page with QR codes: http://localhost:${PORT}/setup`);
  });
}

// ---------- replay a transcript file into a running server ----------
async function replay(file, { to, wpm }) {
  const sentences = fs.readFileSync(file, 'utf8').replace(/\s+/g, ' ').match(/[^.!?]+[.!?]+/g) || [];
  await fetch(`${to}/reset`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  for (const s of sentences) {
    const text = s.trim();
    await new Promise((r) => setTimeout(r, (text.split(' ').length / wpm) * 60000));
    console.log('> ' + text);
    await fetch(`${to}/chunk`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text }) });
  }
}

// ---------- cli ----------
const [cmd, ...rest] = process.argv.slice(2);
const flag = (name) => rest.includes(`--${name}`);
const opt = (name, d) => { const i = rest.indexOf(`--${name}`); return i >= 0 ? rest[i + 1] : d; };

if (cmd === 'serve') serve({ mock: flag('mock') });
else if (cmd === 'replay' && rest[0]) await replay(rest[0], { to: opt('to', `http://localhost:${PORT}`), wpm: Number(opt('wpm', 165)) });
else { console.log('usage: brain.mjs serve [--mock] | replay <file> [--to url] [--wpm 165]'); process.exit(cmd ? 1 : 0); }
