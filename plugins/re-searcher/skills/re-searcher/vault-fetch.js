#!/usr/bin/env node
'use strict';
// vault-fetch — raw fetch -> extraction -> confidence gate -> store.
// The vault's sources must be actually raw: this fetches real bytes (no AI
// extraction), converts with html-extract, and REFUSES to store garbage —
// low confidence exits 2 so the caller escalates to a browser or WebFetch
// (which is then stored labeled as an extraction, by the Stage 1 flow).
//
//   node vault-fetch.js <url> [--vault <dir>] [--timeout <ms>] [--max-bytes <n>]
//
// stdout: one JSON line {status, url, finalUrl, sourceId, sourcePath, rawPath,
//         title, textLength, score, signals, extractionHash, wayback}
// status: stored | duplicate | low-confidence | fetch-error
// exit:   0 stored/duplicate, 2 low-confidence, 1 fetch-error/usage
//
// Storage: sources/<hash8>--<host>--<slug>.md (+ raw at sources/raw/<hash8>.html)
// and an append to sources/fetch-log.jsonl (Stage 0 dedupe lookup).
// Env seams: WAYBACK=off disables wayback entirely; WAYBACK_API=<base> overrides
// both availability and save endpoints; WAYBACK_TIMEOUT_MS (default 3000).

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');
const { extract, assess } = require('./html-extract');
const lib = require('./vault-lib');

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) re-searcher-vault-fetch/0.1';
const MAX_REDIRECTS = 5;
const WAYBACK_OFF = (process.env.WAYBACK || '').toLowerCase() === 'off';
const WB_BASE = process.env.WAYBACK_API || null;
const WB_AVAIL = (WB_BASE || 'https://archive.org') + '/wayback/available?url=';
const WB_SAVE = (WB_BASE || 'https://web.archive.org') + '/save/';
const WB_TIMEOUT = Number(process.env.WAYBACK_TIMEOUT_MS || 3000);

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i !== -1 ? process.argv[i + 1] : dflt;
}

function normalizeUrl(u) {
  try {
    const url = new URL(u);
    url.hash = '';
    url.hostname = url.hostname.toLowerCase();
    for (const k of Array.from(url.searchParams.keys())) if (/^utm_/i.test(k)) url.searchParams.delete(k);
    return url.toString();
  } catch (_e) { return u; }
}

function fetchRaw(u, timeoutMs, maxBytes, redirects, cb) {
  // SSRF guard on every hop — a redirect to a private/loopback address is the
  // classic bypass, so the check runs here (fetchRaw recurses on 3xx).
  lib.checkPublicHost(u, (blockErr) => {
    if (blockErr) return cb(blockErr);
    doFetch(u, timeoutMs, maxBytes, redirects, cb);
  });
}

function doFetch(u, timeoutMs, maxBytes, redirects, cb) {
  let mod;
  try { mod = new URL(u).protocol === 'http:' ? require('http') : require('https'); }
  catch (e) { return cb(new Error('bad url: ' + u)); }
  const req = mod.get(u, { headers: { 'user-agent': UA, 'accept': 'text/html,*/*', 'accept-encoding': 'gzip' } }, (res) => {
    const loc = res.headers.location;
    if (res.statusCode >= 300 && res.statusCode < 400 && loc) {
      res.resume();
      if (redirects >= MAX_REDIRECTS) return cb(new Error('too many redirects'));
      return fetchRaw(new URL(loc, u).toString(), timeoutMs, maxBytes, redirects + 1, cb);
    }
    if (res.statusCode !== 200) { res.resume(); return cb(new Error('http ' + res.statusCode)); }
    const gz = /gzip/.test(res.headers['content-encoding'] || '');
    const chunks = []; let size = 0; let done = false;
    res.on('data', (c) => {
      size += c.length;
      if (size > maxBytes && !done) { done = true; req.destroy(); return cb(new Error('response exceeds --max-bytes ' + maxBytes)); }
      chunks.push(c);
    });
    res.on('end', () => {
      if (done) return;
      let buf = Buffer.concat(chunks);
      if (gz) { try { buf = zlib.gunzipSync(buf); } catch (e) { return cb(new Error('gunzip failed: ' + e.message)); } }
      cb(null, { body: buf, finalUrl: u });
    });
    res.on('error', (e) => { if (!done) cb(e); });
  });
  req.setTimeout(timeoutMs, () => { req.destroy(new Error('timeout after ' + timeoutMs + 'ms')); });
  req.on('error', (e) => cb(e));
}

function slugify(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'page';
}

function atomicWrite(file, data) {
  const tmp = file + '.tmp' + process.pid;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

function emit(obj, code) { process.stdout.write(JSON.stringify(obj) + '\n'); process.exit(code); }

// Wayback (spec Pillar 2): availability-check first (snapshot exists -> record
// it); else fire the save with a short cap; on failure/429 append to
// wayback-queue.jsonl, drained slowly by the doctor. NEVER on the critical
// path: every error degrades to a queue entry, the fetch result stands.
function waybackStep(vault, normUrl, sourceId, cb) {
  if (WAYBACK_OFF) return cb({ status: 'off' });
  fetchRaw(WB_AVAIL + encodeURIComponent(normUrl), WB_TIMEOUT, 512 * 1024, 0, (err, res) => {
    if (!err) {
      try {
        const j = JSON.parse(res.body.toString('utf8'));
        const c = j && j.archived_snapshots && j.archived_snapshots.closest;
        if (c && c.available && c.url) return cb({ status: 'exists', snapshot: String(c.url) });
      } catch (_e) { /* unparseable availability answer — fall through to save */ }
    }
    fetchRaw(WB_SAVE + normUrl, WB_TIMEOUT, 512 * 1024, 0, (err2) => {
      if (!err2) return cb({ status: 'requested' });
      try {
        fs.appendFileSync(path.join(vault, 'wayback-queue.jsonl'),
          JSON.stringify({ v: 1, url: normUrl, source_id: sourceId, ts: new Date().toISOString(), attempts: 0 }) + '\n');
        return cb({ status: 'queued' });
      } catch (_e) { return cb({ status: 'failed' }); }
    });
  });
}

function main() {
  const url = process.argv[2];
  if (!url || url.startsWith('--')) { process.stderr.write('usage: vault-fetch.js <url> [--vault <dir>] [--timeout <ms>] [--max-bytes <n>]\n'); process.exit(1); }
  const vault = arg('--vault', process.env.RESEARCH_VAULT_DIR || null);
  if (!vault || !fs.existsSync(vault)) {
    process.stderr.write('vault missing at ' + (vault || '(unset)') + ' — pass --vault or set RESEARCH_VAULT_DIR (a missing vault must never look like an empty one)\n');
    process.exit(1);
  }
  const timeoutMs = Number(arg('--timeout', 10000));
  const maxBytes = Number(arg('--max-bytes', 5 * 1024 * 1024));
  const base = { status: null, url, finalUrl: null, sourceId: null, sourcePath: null, rawPath: null, title: null, textLength: null, score: null, signals: [], extractionHash: null, wayback: null };

  fetchRaw(url, timeoutMs, maxBytes, 0, (err, res) => {
    if (err) return emit(Object.assign(base, { status: 'fetch-error', signals: [String(err.message)] }), 1);
    const html = res.body.toString('utf8');
    const ext = extract(html);
    const conf = assess(html, ext);
    const rawSha = crypto.createHash('sha256').update(res.body).digest('hex');
    const extSha = crypto.createHash('sha256').update(ext.markdown, 'utf8').digest('hex');
    const filled = Object.assign(base, { finalUrl: res.finalUrl, title: ext.title, textLength: ext.textLength, score: conf.score, signals: conf.signals, extractionHash: extSha });
    if (!conf.usable) return emit(Object.assign(filled, { status: 'low-confidence' }), 2);

    const srcDir = path.join(vault, 'sources');
    const rawDir = path.join(srcDir, 'raw');
    fs.mkdirSync(rawDir, { recursive: true });
    const logFile = path.join(srcDir, 'fetch-log.jsonl');
    const normUrl = normalizeUrl(res.finalUrl);

    if (fs.existsSync(logFile)) {
      for (const line of fs.readFileSync(logFile, 'utf8').split('\n')) {
        if (!line.trim()) continue;
        let rec; try { rec = JSON.parse(line); } catch (_e) { continue; } // skip-don't-abort (spec)
        if (rec.norm_url === normUrl && rec.extraction_sha256 === extSha) {
          return emit(Object.assign(filled, { status: 'duplicate', sourceId: rec.source_id, sourcePath: rec.source_path }), 0);
        }
      }
    }

    const hash8 = rawSha.slice(0, 8);
    let host = 'unknown'; try { host = new URL(res.finalUrl).hostname.replace(/^www\./, ''); } catch (_e) {}
    const id = hash8 + '--' + slugify(host) + '--' + slugify(ext.title || url);
    const sourcePath = path.join(srcDir, id + '.md');
    const rawPath = path.join(rawDir, hash8 + '.html');
    waybackStep(vault, normUrl, id, (wb) => {
      const fetched = new Date().toISOString();
      const fmLines = ['---', 'v: 1', 'kind: web', 'url: ' + url, 'final_url: ' + res.finalUrl,
        'fetched: ' + fetched, 'title: ' + JSON.stringify(ext.title), 'raw_sha256: ' + rawSha,
        'extraction_sha256: ' + extSha, 'score: ' + conf.score,
        'signals: ' + JSON.stringify(conf.signals), 'auth_context: public',
        'wayback: ' + wb.status];
      if (wb.snapshot) fmLines.push('wayback_url: ' + wb.snapshot);
      const fm = fmLines.concat(['---', '']).join('\n');
      atomicWrite(sourcePath, fm + ext.markdown + '\n');
      atomicWrite(rawPath, res.body);
      fs.appendFileSync(logFile, JSON.stringify({ v: 1, source_id: id, source_path: sourcePath, norm_url: normUrl, url, final_url: res.finalUrl, raw_sha256: rawSha, extraction_sha256: extSha, fetched, score: conf.score, wayback: wb.status }) + '\n');
      emit(Object.assign(filled, { status: 'stored', sourceId: id, sourcePath, rawPath, wayback: wb.status }), 0);
    });
  });
}

main();
