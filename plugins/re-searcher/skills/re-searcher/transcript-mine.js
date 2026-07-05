#!/usr/bin/env node
'use strict';
// transcript-mine — deterministic pre-extraction from Claude Code transcripts
// (spec Harvester): keys EXCLUSIVELY on the embedded Anthropic Messages shape
// (message.role + message.content blocks text/tool_use/tool_result) — never
// the envelope, which churns between Claude Code versions. Line-by-line,
// skip-don't-abort; every extracted item carries a raw transcript:line
// pointer so lineage survives degraded parsing. No LLM anywhere in here.
//
//   node transcript-mine.js <transcript.jsonl>
//
// stdout: one JSON line {version, versionWarning, sessionId, cwd, writes,
//         sources, finals, summary, unknownBlocks, skippedLines, messages}
// exit 0 parsed (even degraded) / 1 unreadable, usage, or no messages found

const fs = require('fs');

const KNOWN_MAJOR = 2;
const SOURCE_TOOLS = /^(WebSearch|WebFetch|mcp__)/;
const MAX_WRITE_CHARS = 100000;
const MIN_FINAL_CHARS = 80;
const KEEP_FINALS = 3;

function summarizeInput(input) {
  if (!input || typeof input !== 'object') return '';
  if (typeof input.query === 'string') return input.query.slice(0, 200);
  if (typeof input.url === 'string') return input.url.slice(0, 300);
  const k = Object.keys(input)[0];
  return k ? (k + '=' + String(input[k]).slice(0, 120)) : '';
}

function mine(file) {
  const raw = fs.readFileSync(file, 'utf8').split('\n');
  const out = { version: null, versionWarning: null, sessionId: null, cwd: null,
    writes: [], sources: [], finals: [], summary: null,
    unknownBlocks: 0, skippedLines: 0, messages: 0 };
  for (let i = 0; i < raw.length; i++) {
    if (!raw[i].trim()) continue;
    let r;
    try { r = JSON.parse(raw[i]); } catch (_e) { out.skippedLines++; continue; }
    if (r && r.version && !out.version) {
      out.version = String(r.version);
      if (parseInt(out.version, 10) !== KNOWN_MAJOR) {
        out.versionWarning = 'unknown transcript major version ' + out.version + ' — extraction may be degraded';
        process.stderr.write('transcript-mine: ' + out.versionWarning + '\n');
      }
    }
    if (r && r.sessionId && !out.sessionId) out.sessionId = String(r.sessionId);
    if (r && r.cwd && !out.cwd) out.cwd = String(r.cwd);
    const m = r && r.message;
    if (!m || !m.role || !Array.isArray(m.content)) continue; // envelope noise, not a message
    out.messages++;
    for (const c of m.content) {
      if (!c || typeof c !== 'object') { out.unknownBlocks++; continue; }
      if (c.type === 'text') {
        if (m.role === 'assistant' && typeof c.text === 'string' && c.text.trim().length >= MIN_FINAL_CHARS) {
          out.finals.push({ line: i + 1, chars: c.text.length, text: c.text });
        }
      } else if (c.type === 'tool_use') {
        if (c.name === 'Write' && c.input && typeof c.input.file_path === 'string') {
          const content = typeof c.input.content === 'string' ? c.input.content : '';
          out.writes.push({ line: i + 1, file: c.input.file_path,
            bytes: Buffer.byteLength(content, 'utf8'),
            truncated: content.length > MAX_WRITE_CHARS,
            content: content.slice(0, MAX_WRITE_CHARS) });
        } else if (typeof c.name === 'string' && SOURCE_TOOLS.test(c.name)) {
          out.sources.push({ line: i + 1, tool: c.name, detail: summarizeInput(c.input) });
        }
      } else if (c.type === 'tool_result' || c.type === 'thinking') {
        // dropped by design: results are bulk noise, thinking is not citable
      } else {
        out.unknownBlocks++; // canary — new block types must never abort parsing
      }
    }
  }
  out.finals = out.finals.slice(-KEEP_FINALS);
  out.summary = out.finals.length ? out.finals[out.finals.length - 1].text : null;
  return out;
}

function main() {
  const file = process.argv[2];
  if (!file || file.startsWith('--')) { process.stderr.write('usage: transcript-mine.js <transcript.jsonl>\n'); process.exit(1); }
  let res;
  try { res = mine(file); }
  catch (err) { process.stderr.write('cannot read ' + file + ': ' + (err.code || err.message) + '\n'); process.exit(1); }
  if (!res.messages) {
    process.stderr.write('no Messages-shaped records found in ' + file + ' — wrong file, or an unknown transcript layout\n');
    process.exit(1);
  }
  process.stdout.write(JSON.stringify(res) + '\n');
}

if (require.main === module) main();
module.exports = { mine };
