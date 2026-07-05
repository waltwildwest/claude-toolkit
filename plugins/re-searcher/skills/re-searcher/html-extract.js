#!/usr/bin/env node
'use strict';
// html-extract — zero-dep readability-style HTML -> markdown extraction.
// Regex-based (no DOM): strips chrome, prefers <article>/<main>/<body>,
// converts block + inline markup, decodes entities, reports text metrics.
// Good on SSR pages (docs, blogs, GitHub, wikis); SPA shells and challenge
// pages come out thin — that is what the confidence scorer (assess) is for.
//
//   node html-extract.js <file.html> [--assess]   # flag position free
//
// Module API: extract(html), assess(html, extracted)  [assess added in Task 2]

const fs = require('fs');

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  mdash: '—', ndash: '–', hellip: '…', rsquo: '’', lsquo: '‘',
  rdquo: '”', ldquo: '“', copy: '©', reg: '®', trade: '™',
  laquo: '«', raquo: '»', times: '×', middot: '·' };

function decodeEntities(s) {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => safeCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => safeCodePoint(parseInt(d, 10)))
    .replace(/&([a-z]+);/gi, (m, n) => ENTITIES[n.toLowerCase()] !== undefined ? ENTITIES[n.toLowerCase()] : m);
}
function safeCodePoint(n) {
  try { return String.fromCodePoint(n); } catch (_e) { return ''; }
}

function stripTagBlocks(html, tags) {
  let out = html;
  for (const t of tags) out = out.replace(new RegExp('<' + t + '\\b[^>]*>[\\s\\S]*?<\\/' + t + '>', 'gi'), ' ');
  return out;
}

// Convert inline markup inside a block's inner HTML to markdown text.
function inline(s) {
  let t = s;
  t = t.replace(/<a\b[^>]*href=["']([^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi,
    (_, href, text) => {
      const label = plain(text).trim();
      if (!label) return '';
      return href && !/^\s*(#|javascript:)/i.test(href) ? '[' + label + '](' + href + ')' : label;
    });
  t = t.replace(/<(strong|b)\b[^>]*>([\s\S]*?)<\/\1>/gi, (_, _t, x) => '**' + plain(x).trim() + '**');
  t = t.replace(/<(em|i)\b[^>]*>([\s\S]*?)<\/\1>/gi, (_, _t, x) => '*' + plain(x).trim() + '*');
  t = t.replace(/<code\b[^>]*>([\s\S]*?)<\/code>/gi, (_, x) => '`' + plain(x).trim() + '`');
  return plain(t);
}
// Strip any remaining tags, decode entities, collapse intra-block whitespace.
function plain(s) {
  return decodeEntities(s.replace(/<[^>]+>/g, ' ')).replace(/[ \t\r\f]+/g, ' ');
}

function extract(html) {
  let h = String(html).replace(/<!--[\s\S]*?-->/g, ' ');
  const titleM = h.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
  const title = titleM ? plain(titleM[1]).trim() : '';
  h = stripTagBlocks(h, ['script', 'style', 'noscript', 'svg', 'iframe', 'template', 'canvas']);

  // Region: prefer semantic content containers, largest-first among articles.
  let region = null;
  const articles = h.match(/<article\b[^>]*>[\s\S]*?<\/article>/gi);
  if (articles && articles.length) region = articles.sort((a, b) => b.length - a.length)[0];
  if (!region) { const m = h.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i); if (m) region = m[1]; }
  if (!region) { const m = h.match(/<body\b[^>]*>([\s\S]*?)<\/body>/i); if (m) region = m[1]; }
  if (!region) region = h;
  region = stripTagBlocks(region, ['nav', 'footer', 'header', 'aside', 'form', 'button', 'select', 'dialog']);

  // Protect code blocks from inline processing.
  const fences = [];
  region = region.replace(/<pre\b[^>]*>([\s\S]*?)<\/pre>/gi, (_, body) => {
    const code = decodeEntities(body.replace(/<[^>]+>/g, '')).replace(/^\n+|\s+$/g, '');
    fences.push(code);
    return '\n\n~~~' + (fences.length - 1) + '~~~\n\n';
  });

  // Link-density accounting BEFORE tags are consumed.
  let linkChars = 0;
  region.replace(/<a\b[^>]*>([\s\S]*?)<\/a>/gi, (_, text) => { linkChars += plain(text).trim().length; return ''; });

  let md = region;
  md = md.replace(/<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi,
    (_, lvl, text) => '\n\n' + '#'.repeat(Number(lvl)) + ' ' + inline(text).trim() + '\n\n');
  md = md.replace(/<li\b[^>]*>([\s\S]*?)<\/li>/gi, (_, text) => '\n- ' + inline(text).trim());
  md = md.replace(/<(ul|ol)\b[^>]*>/gi, '\n').replace(/<\/(ul|ol)>/gi, '\n');
  md = md.replace(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi, (_, row) => {
    const cells = [];
    row.replace(/<(td|th)\b[^>]*>([\s\S]*?)<\/\1>/gi, (_m, _t, c) => { cells.push(inline(c).trim()); return ''; });
    return cells.length ? '\n| ' + cells.join(' | ') + ' |' : '';
  });
  md = md.replace(/<blockquote\b[^>]*>([\s\S]*?)<\/blockquote>/gi, (_, q) => '\n\n> ' + inline(q).trim() + '\n\n');
  md = md.replace(/<(p|div|section)\b[^>]*>/gi, '\n\n').replace(/<br\s*\/?>/gi, '\n');
  md = inline(md);

  md = md.replace(/~~~(\d+)~~~/g, (_, i) => '```\n' + (fences[Number(i)] || '') + '\n```');
  md = md.split('\n').map((l) => l.replace(/[ \t]+$/g, '')).join('\n')
    .replace(/\n{3,}/g, '\n\n').trim();

  const textLength = md.replace(/\s+/g, ' ').length;
  const linkDensity = textLength > 0 ? Math.min(1, linkChars / textLength) : 0;
  return { title, markdown: md, textLength, linkDensity: Number(linkDensity.toFixed(3)) };
}

const CHALLENGE_RE = /just a moment|checking your browser|attention required|cf-ray|ray id:|enable javascript and cookies|access denied|captcha/i;

function assess(html, ext) {
  const signals = [];
  let score = 1.0;
  // Structural challenge detection (Stage 0 amendment): a challenge signature
  // only counts when it appears in the <title> or co-occurs with a thin
  // extraction — a "Captcha" string in a 43K-char article's login chrome is
  // not a challenge page.
  const inTitle = CHALLENGE_RE.test(ext.title || '');
  const inBody = CHALLENGE_RE.test(String(html));
  if (inTitle || (inBody && ext.textLength < 400)) { signals.push('challenge-page'); score -= 0.6; }
  if (ext.textLength < 400) { signals.push('thin-text'); score -= 0.55; }
  if (ext.linkDensity > 0.5) { signals.push('link-farm'); score -= 0.3; }
  const rawLen = String(html).length;
  if (rawLen > 20000 && ext.textLength < rawLen / 200) { signals.push('script-shell'); score -= 0.3; }
  score = Math.max(0, Math.min(1, Number(score.toFixed(2))));
  return { score, usable: score >= 0.5, signals };
}

function main() {
  const argv = process.argv.slice(2);
  const wantAssess = argv.includes('--assess');
  const file = argv.find((a) => !a.startsWith('--'));
  if (!file) { process.stderr.write('usage: html-extract.js <file.html> [--assess]\n'); process.exit(1); }
  let html;
  try { html = fs.readFileSync(file, 'utf8'); }
  catch (err) { process.stderr.write('cannot read ' + file + ': ' + (err.code || err.message) + '\n'); process.exit(1); }
  const ext = extract(html);
  const out = wantAssess ? Object.assign({}, ext, assess(html, ext)) : ext;
  process.stdout.write(JSON.stringify(out) + '\n');
}

if (require.main === module) main();
module.exports = { extract, assess, decodeEntities, plain };
