#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-lib.js
# Run: bash tests/researcher-lib.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-lib tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"; mkdir -p "$V"
echo "vault-lib tests"

# 1. frontmatter roundtrip incl JSON arrays
node -e '
const lib = require(process.argv[1]);
const { fields, body } = lib.parseFrontmatter("---\ntopic: mcp-auth\naliases: [\"a b\", \"c\"]\nn: 3\n---\nBody here");
if (fields.topic !== "mcp-auth") process.exit(1);
if (!Array.isArray(fields.aliases) || fields.aliases[0] !== "a b") process.exit(2);
if (fields.n !== 3) process.exit(3);
if (body.trim() !== "Body here") process.exit(4);
' "$LIB" && ok "parseFrontmatter" || no "parseFrontmatter" "rc=$?"

# 2. readJsonl skips bad lines with a count
printf '{"a":1}\nnot json\n{"a":2}\n' > "$W/x.jsonl"
node -e '
const lib = require(process.argv[1]);
const r = lib.readJsonl(process.argv[2]);
process.exit(r.records.length === 2 && r.skipped === 1 && !r.missing ? 0 : 1);
' "$LIB" "$W/x.jsonl" 2>/dev/null && ok "readJsonl skip-dont-abort" || no "readJsonl" ""

# 3. fold: supersede chain resolves to terminal; retract kills; contradict flags both; verify promotes
node -e '
const lib = require(process.argv[1]);
const recs = [
  {id:"clm_a", statement:"old", topic:"t"},
  {id:"clm_b", statement:"mid", topic:"t"},
  {id:"clm_c", statement:"new", topic:"t"},
  {id:"clm_d", statement:"dead", topic:"t"},
  {id:"clm_e", statement:"x", topic:"t"},
  {id:"clm_f", statement:"y", topic:"t"},
  {op:"supersede", claim:"clm_a", by:"clm_b"},
  {op:"supersede", claim:"clm_b", by:"clm_c"},
  {op:"retract", claim:"clm_d", by:"human"},
  {op:"contradict", claim:"clm_e", by:"clm_f"},
  {op:"verify", claim:"clm_f", by:"doctor"},
];
const { claims } = lib.foldClaims(recs);
const term = lib.resolveTerminal(claims, "clm_a");
if (term.length !== 1 || term[0].id !== "clm_c") process.exit(1);
if (claims.get("clm_d").status !== "retracted") process.exit(2);
if (!claims.get("clm_e").contradictedBy.includes("clm_f")) process.exit(3);
if (!claims.get("clm_f").contradictedBy.includes("clm_e")) process.exit(4);
if (claims.get("clm_f").provenance !== "externally-verified") process.exit(5);
if (lib.resolveTerminal(claims, "clm_d").length !== 0) process.exit(6);
' "$LIB" && ok "foldClaims + resolveTerminal" || no "fold" "rc=$?"

# 4. resolveTerminal is cycle-safe on corrupt data
node -e '
const lib = require(process.argv[1]);
const recs = [
  {id:"clm_a", statement:"a"}, {id:"clm_b", statement:"b"},
  {op:"supersede", claim:"clm_a", by:"clm_b"},
  {op:"supersede", claim:"clm_b", by:"clm_a"},
];
const { claims } = lib.foldClaims(recs);
process.exit(lib.resolveTerminal(claims, "clm_a").length === 0 ? 0 : 1);
' "$LIB" && ok "terminal cycle-safe" || no "cycle" ""

# 5. newId collision bumps
node -e '
const lib = require(process.argv[1]);
const a = lib.newId("clm", "seed", new Set());
const b = lib.newId("clm", "seed", new Set([a]));
process.exit(a !== b && a.startsWith("clm_") && b.startsWith("clm_") ? 0 : 1);
' "$LIB" && ok "newId collision bump" || no "newId" ""

# 6. withLock serializes two concurrent writers
node -e '
const lib = require(process.argv[1]); const fs = require("fs");
lib.withLock(process.argv[2], () => {
  fs.appendFileSync(process.argv[2] + "/log.txt", process.argv[3] + "-start\n");
  lib.msleep(250);
  fs.appendFileSync(process.argv[2] + "/log.txt", process.argv[3] + "-end\n");
});' "$LIB" "$V" a & P1=$!
node -e '
const lib = require(process.argv[1]); const fs = require("fs");
lib.withLock(process.argv[2], () => {
  fs.appendFileSync(process.argv[2] + "/log.txt", process.argv[3] + "-start\n");
  lib.msleep(250);
  fs.appendFileSync(process.argv[2] + "/log.txt", process.argv[3] + "-end\n");
});' "$LIB" "$V" b & P2=$!
wait $P1; R1=$?; wait $P2; R2=$?
node -e '
const lines = require("fs").readFileSync(process.argv[1] + "/log.txt", "utf8").trim().split("\n");
if (lines.length !== 4) process.exit(1);
// no interleaving: line 0/1 share a prefix, line 2/3 share the other
const p0 = lines[0][0], p1 = lines[1][0], p2 = lines[2][0], p3 = lines[3][0];
process.exit(p0 === p1 && p2 === p3 && p0 !== p2 ? 0 : 2);
' "$V" && [ $R1 -eq 0 ] && [ $R2 -eq 0 ] && ok "lock serializes writers" || no "lock" "$(cat "$V/log.txt" 2>/dev/null)"
[ -d "$V/.lock" ] && no "lock released" "still held" || ok "lock released"

# 7. stale lock is stolen
mkdir "$V/.lock"
touch -t 202001010000 "$V/.lock"
node -e '
const lib = require(process.argv[1]);
lib.withLock(process.argv[2], () => {});' "$LIB" "$V" 2>"$W/steal.err" && ok "stale lock stolen" || no "stale steal" "$(cat "$W/steal.err")"
grep -q "stale" "$W/steal.err" && ok "steal is loud" || no "steal loud" "$(cat "$W/steal.err")"

# 8. gitCommit outside a repo warns, never throws
node -e '
const lib = require(process.argv[1]);
const r = lib.gitCommit(process.argv[2], "test");
process.exit(!r.committed && /git/.test(r.warning || "") ? 0 : 1);
' "$LIB" "$V" && ok "gitCommit non-repo warns" || no "gitCommit" ""

# 9. frontmatter tolerates CRLF line endings (fields parse, body preserved)
node -e '
const lib = require(process.argv[1]);
const { fields, body } = lib.parseFrontmatter("---\r\ntopic: mcp-auth\r\nrole: reader\r\n---\r\nBody line");
if (fields.topic !== "mcp-auth" || fields.role !== "reader") process.exit(1);
if (!body.includes("Body line")) process.exit(2);
' "$LIB" && ok "parseFrontmatter CRLF" || no "crlf" "rc=$?"

# 10. today() shape
node -e '
const lib = require(process.argv[1]);
process.exit(/^\d{4}-\d{2}-\d{2}$/.test(lib.today()) ? 0 : 1);
' "$LIB" && ok "today() shape" || no "today" ""

# 11. allocateRun: atomic leaf mkdir, letter bump, findings/ created, throws when exhausted
node -e '
const lib = require(process.argv[1]);
const fs = require("fs"), path = require("path");
const v = process.argv[2];
const a = lib.allocateRun(v, "MCP Auth Landscape", "9f3c2ab1");
if (!/^\d{4}-\d{2}-\d{2}a-9f3c$/.test(a.runId)) process.exit(1);
if (a.topic !== "mcp-auth-landscape") process.exit(2);
if (!fs.existsSync(path.join(a.runDir, "findings"))) process.exit(3);
const b = lib.allocateRun(v, "MCP Auth Landscape", "9f3c2ab1");
if (!/b-9f3c$/.test(b.runId)) process.exit(4);
for (const l of "cdefghijklmnopqrstuvwxyz") lib.allocateRun(v, "MCP Auth Landscape", "9f3c2ab1");
try { lib.allocateRun(v, "MCP Auth Landscape", "9f3c2ab1"); process.exit(5); }
catch (e) { process.exit(/26 same-day/.test(e.message) ? 0 : 6); }
' "$LIB" "$V" && ok "allocateRun atomic + letter bump + throws on exhaustion" || no "allocateRun" "rc=$?"

# 12. foldClaims: downgrade event lowers provenance, script-only op
node -e '
const lib = require(process.argv[1]);
const { claims } = lib.foldClaims([
  {v:1, id:"clm_dg1", topic:"t", statement:"s", provenance:"verbatim-grounded"},
  {v:1, op:"downgrade", claim:"clm_dg1", by:"redaction", to:"model-asserted", reason:"source redacted: test"},
  {v:1, op:"downgrade", claim:"clm_missing"},
]);
const c = claims.get("clm_dg1");
if (!c || c.provenance !== "model-asserted") process.exit(1);
if (c.status !== "active") process.exit(2);
if (c.events.length !== 1) process.exit(3);
' "$LIB" && ok "foldClaims downgrade lowers provenance, keeps status" || no "downgrade fold" "rc=$?"

# 13. isSafeName rejects traversal, accepts real ids/slugs
node -e '
const lib = require(process.argv[1]);
const good = ["clm_abc123", "aaaa1111--host--slug", "mcp-auth", "topic_1", "a.b"];
const bad = ["../etc/passwd", "a/b", "..", "a..b", "/abs", "x\\y", "", "a".repeat(201)];
for (const g of good) if (!lib.isSafeName(g)) { console.error("rejected good: " + g); process.exit(1); }
for (const b of bad) if (lib.isSafeName(b)) { console.error("accepted bad: " + JSON.stringify(b)); process.exit(2); }
' "$LIB" && ok "isSafeName rejects traversal, accepts real ids" || no "isSafeName" "rc=$?"

echo; echo "vault-lib: $pass passed, $fail failed"; [ $fail -eq 0 ]
