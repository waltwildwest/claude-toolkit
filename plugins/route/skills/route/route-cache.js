#!/usr/bin/env node
'use strict';
// route-cache — never pay twice for identical delegated work.
// A result cache for subagent output, keyed by SHA-256 of the normalized task
// instruction plus the exact bytes of every input file. Same work = cache hit
// across sessions and days; any change to instruction or inputs = new key.
// Storage: ~/.claude/route-cache/<key>.json. Local only, no network, no deps.
//
// Task text and results travel via FILES, never shell arguments, so a caller
// never has to interpolate untrusted prompt text into a command line.
//
//   route-cache key   --task-file <path> [--file <path>]...   # prints key
//   route-cache key   --task "<text>"    [--file <path>]...   # inline alt
//   route-cache get   <key>                                   # result -> stdout, exit 1 on miss
//   route-cache put   <key> [--task-file <p>|--task <t>] [--model <m>] [--result-file <p>]
//                                                             # result from --result-file or stdin
//   route-cache stats
//   route-cache prune [--days N] [--max-mb N]                 # days default 30
//
// Key format is v2 (length-framed); entries written by older versions miss
// harmlessly and are pruned by age.

const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const KEY_VERSION = 2;
const DIR = path.join(process.env.HOME || os.homedir(), '.claude', 'route-cache');
const HASH_CHUNK = 1 << 20; // 1 MiB streaming reads
const MAX_INLINE_BYTES = 64 * 1024;

function normalizeTask(text) {
  return text.trim().replace(/\s+/g, ' ');
}

// Length-framed so distinct component boundaries can never collide (a NUL byte
// inside a file cannot masquerade as the inter-component separator).
function frame(hash, tag, byteLength) {
  hash.update(`${tag}:${byteLength}\n`);
}

function hashFileInto(hash, file) {
  let size;
  try { size = fs.statSync(file).size; } catch (err) { throw new Error(`cannot stat --file ${file}: ${err.code || err.message}`); }
  frame(hash, 'file', size);
  let fd;
  try { fd = fs.openSync(file, 'r'); } catch (err) { throw new Error(`cannot read --file ${file}: ${err.code || err.message}`); }
  try {
    const buf = Buffer.allocUnsafe(HASH_CHUNK);
    let read;
    // eslint-disable-next-line no-cond-assign
    while ((read = fs.readSync(fd, buf, 0, HASH_CHUNK, null)) > 0) {
      hash.update(buf.subarray(0, read));
    }
  } finally {
    fs.closeSync(fd);
  }
}

function computeKey(taskText, files) {
  const h = crypto.createHash('sha256');
  h.update(`route-cache/v${KEY_VERSION}\n`);
  const task = Buffer.from(normalizeTask(taskText), 'utf8');
  frame(h, 'task', task.length);
  h.update(task);
  for (const f of files) hashFileInto(h, f);
  return h.digest('hex').slice(0, 32);
}

function taskTextFrom(flags) {
  if (flags['task-file']) {
    const p = flags['task-file'][0];
    try { return fs.readFileSync(p, 'utf8'); } catch (err) { throw new Error(`cannot read --task-file ${p}: ${err.code || err.message}`); }
  }
  if (flags.task) return flags.task[0];
  return null;
}

function entryPath(key) {
  if (!/^[a-f0-9]{32}$/.test(key)) throw new Error(`bad key: ${key}`);
  return path.join(DIR, `${key}.json`);
}

function readEntry(key) {
  const file = entryPath(key); // validates key format; throws on garbage
  let entry;
  try { entry = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
  // A structurally broken entry (no usable result) is treated as a miss, never a crash.
  if (!entry || typeof entry.result !== 'string' || typeof entry.encoding !== 'string') return null;
  return entry;
}

function writeEntry(key, entry) {
  fs.mkdirSync(DIR, { recursive: true });
  const file = entryPath(key);
  const tmp = `${file}.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
  fs.writeFileSync(tmp, JSON.stringify(entry, null, 1));
  try { fs.renameSync(tmp, file); } catch (err) { try { fs.unlinkSync(tmp); } catch { /* ignore */ } throw err; }
}

function parseTime(s) {
  const t = Date.parse(s || 0);
  return Number.isNaN(t) ? 0 : t; // unparseable == epoch: pruned first, sorted oldest
}

function humanizeAge(fromIso) {
  const parsed = Date.parse(fromIso || 0);
  if (Number.isNaN(parsed)) return 'unknown age';
  const sec = Math.floor((Date.now() - parsed) / 1000);
  if (sec < 60) return 'just now';
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h`;
  return `${Math.floor(hr / 24)}d`;
}

// Supports "--flag value" and "--flag=value". Rejects a missing value or a value
// that is itself another flag, so `key --task --file x` fails loudly instead of
// silently hashing task="--file".
function parseFlags(argv, spec) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--') && a.includes('=')) {
      const eq = a.indexOf('=');
      const name = a.slice(2, eq);
      if (!spec.includes(`--${name}`)) throw new Error(`unknown flag: --${name}`);
      out[name] = (out[name] || []).concat(a.slice(eq + 1));
    } else if (spec.includes(a)) {
      const name = a.slice(2);
      const val = argv[i += 1];
      if (val === undefined || (typeof val === 'string' && val.startsWith('--'))) {
        throw new Error(`missing value for ${a}`);
      }
      out[name] = (out[name] || []).concat(val);
    } else if (a.startsWith('--')) {
      throw new Error(`unknown flag: ${a}`);
    } else {
      out._.push(a);
    }
  }
  return out;
}

function readStdinBuffer() {
  try { return fs.readFileSync(0); } catch { return Buffer.alloc(0); }
}

// Round-trip safe for any bytes: UTF-8 is stored as-is, anything else as base64.
function encodeResult(buf) {
  const utf8 = buf.toString('utf8');
  if (Buffer.compare(Buffer.from(utf8, 'utf8'), buf) === 0) return { encoding: 'utf8', result: utf8 };
  return { encoding: 'base64', result: buf.toString('base64') };
}

function decodeResult(entry) {
  return entry.encoding === 'base64' ? Buffer.from(entry.result, 'base64') : Buffer.from(entry.result, 'utf8');
}

function cmdKey(argv) {
  const f = parseFlags(argv, ['--task', '--task-file', '--file']);
  const task = taskTextFrom(f);
  if (task === null) throw new Error('key requires --task-file <path> or --task "<text>"');
  console.log(computeKey(task, f.file || []));
  return 0;
}

function cmdGet(argv) {
  const f = parseFlags(argv, []);
  const key = f._[0];
  if (!key) throw new Error('get requires a key');
  const entry = readEntry(key);
  if (!entry) { console.error('route-cache: miss'); return 1; }
  const hits = entry.hits || 0;
  console.error(`route-cache: hit (${humanizeAge(entry.createdAt)}, from ${entry.model || 'unknown'}, ${hits} hits)`);
  try {
    if (fs.existsSync(entryPath(key))) {
      writeEntry(key, { ...entry, hits: hits + 1, lastHitAt: new Date().toISOString() });
    }
  } catch { /* best effort: a read-only or racing cache must not block a hit */ }
  process.stdout.write(decodeResult(entry));
  return 0;
}

function cmdPut(argv) {
  const f = parseFlags(argv, ['--task', '--task-file', '--model', '--result-file']);
  const key = f._[0];
  if (!key) throw new Error('put requires a key');
  entryPath(key); // validate before doing work
  let buf;
  if (f['result-file']) {
    const p = f['result-file'][0];
    try { buf = fs.readFileSync(p); } catch (err) { throw new Error(`cannot read --result-file ${p}: ${err.code || err.message}`); }
  } else {
    buf = readStdinBuffer();
  }
  if (buf.toString('utf8').trim() === '') {
    throw new Error('put: empty result, refusing to cache nothing');
  }
  const encoded = encodeResult(buf);
  writeEntry(key, {
    v: KEY_VERSION,
    task: taskTextFrom(f) ? normalizeTask(taskTextFrom(f)) : null,
    model: f.model ? f.model[0] : null,
    createdAt: new Date().toISOString(),
    lastHitAt: null,
    hits: 0,
    ...encoded,
  });
  console.error(`route-cache: stored ${key}`);
  if (buf.length > MAX_INLINE_BYTES) {
    console.error(`route-cache: large result (${Math.round(buf.length / 1024)} KB), reuse will consume context`);
  }
  return 0;
}

function listEntries() {
  if (!fs.existsSync(DIR)) return [];
  return fs.readdirSync(DIR)
    .filter((n) => n.endsWith('.json'))
    .map((n) => {
      const full = path.join(DIR, n);
      try { return { file: full, size: fs.statSync(full).size, entry: JSON.parse(fs.readFileSync(full, 'utf8')) }; }
      catch { return null; }
    })
    .filter(Boolean);
}

function unlinkQuiet(file) {
  try { fs.unlinkSync(file); return true; } catch (err) { if (err.code === 'ENOENT') return false; throw err; }
}

function cmdStats() {
  const all = listEntries();
  const hits = all.reduce((s, e) => s + (e.entry.hits || 0), 0);
  const bytes = all.reduce((s, e) => s + e.size, 0);
  console.log(`route-cache: ${all.length} entries, ${(bytes / 1024).toFixed(1)} KB, ${hits} hits total`);
  return 0;
}

// Remove leftover temp files from crashed writes (older than 5 minutes).
function sweepTemp() {
  if (!fs.existsSync(DIR)) return;
  const cutoff = Date.now() - 5 * 60 * 1000;
  for (const n of fs.readdirSync(DIR)) {
    if (!n.includes('.tmp-')) continue;
    const full = path.join(DIR, n);
    try { if (fs.statSync(full).mtimeMs < cutoff) unlinkQuiet(full); } catch { /* ignore */ }
  }
}

function pruneBySize(entries, maxMb) {
  const maxBytes = maxMb * 1024 * 1024;
  const sorted = [...entries].sort((a, b) => parseTime(a.entry.createdAt) - parseTime(b.entry.createdAt));
  let total = sorted.reduce((s, e) => s + e.size, 0);
  let removed = 0;
  for (const e of sorted) {
    if (total <= maxBytes) break;
    if (unlinkQuiet(e.file)) { total -= e.size; removed += 1; }
  }
  return removed;
}

function cmdPrune(argv) {
  const f = parseFlags(argv, ['--days', '--max-mb']);
  const days = f.days ? Number(f.days[0]) : 30;
  if (!Number.isFinite(days) || days < 0) throw new Error('--days must be a non-negative number');
  sweepTemp();
  const cutoff = Date.now() - days * 86400e3;
  const all = listEntries();
  const removedByAge = all.filter((e) => parseTime(e.entry.createdAt) < cutoff);
  let agePruned = 0;
  for (const e of removedByAge) if (unlinkQuiet(e.file)) agePruned += 1;
  let sizePruned = 0;
  if (f['max-mb']) {
    const maxMb = Number(f['max-mb'][0]);
    if (!Number.isFinite(maxMb) || maxMb < 0) throw new Error('--max-mb must be a non-negative number');
    const goneByAge = new Set(removedByAge.map((e) => e.file));
    sizePruned = pruneBySize(all.filter((e) => !goneByAge.has(e.file)), maxMb);
  }
  const detail = sizePruned ? ` (${agePruned} by age > ${days}d, ${sizePruned} by size cap)` : ` older than ${days}d`;
  console.log(`route-cache: pruned ${agePruned + sizePruned} entries${detail}`);
  return 0;
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const commands = { key: cmdKey, get: cmdGet, put: cmdPut, stats: cmdStats, prune: cmdPrune };
  if (!cmd || cmd === '--help' || cmd === '-h' || !commands[cmd]) {
    console.log('usage: route-cache key|get|put|stats|prune  (see file header)');
    return cmd && cmd !== '--help' && cmd !== '-h' ? 1 : 0;
  }
  return commands[cmd](rest);
}

// process.exitCode (not process.exit) so buffered stdout drains before exit —
// otherwise a large cached result piped to a reader is truncated at ~64 KiB.
try { process.exitCode = main(); } catch (err) {
  console.error(`route-cache: ${err.message}`);
  process.exitCode = 1;
}
