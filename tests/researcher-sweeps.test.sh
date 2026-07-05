#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/doctor-sweeps.js (module).
# Run: bash tests/researcher-sweeps.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
SW="$SK/doctor-sweeps.js"
I="$SK/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-sweeps tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "doctor-sweeps tests"

# Seed runs: one healthy, one orphan (no lineage), two sharing a session
mkdir -p "$V/topics/topic-a/runs/2026-07-01a-good/findings" \
         "$V/topics/topic-a/runs/2026-07-02a-orph/findings" \
         "$V/topics/topic-b/runs/2026-07-03a-dup1" \
         "$V/topics/topic-b/runs/2026-07-03b-dup2"
echo '{"v":1,"session":"sess-good","run":"2026-07-01a-good","topic":"topic-a"}' > "$V/topics/topic-a/runs/2026-07-01a-good/lineage.json"
echo '# plan' > "$V/topics/topic-a/runs/2026-07-02a-orph/plan.md"
echo '{"v":1,"session":"sess-dup","run":"2026-07-03a-dup1","topic":"topic-b"}' > "$V/topics/topic-b/runs/2026-07-03a-dup1/lineage.json"
echo '{"v":1,"session":"sess-dup","run":"2026-07-03b-dup2","topic":"topic-b"}' > "$V/topics/topic-b/runs/2026-07-03b-dup2/lineage.json"

# Seed sources + claims: good quote, bad quote, missing source, tombstoned source, v2 record, torn line
cat > "$V/sources/srcok.md" <<'EOF'
---
v: 1
kind: web
---
The MCP spec requires OAuth 2.1 with PKCE for all remote servers.
EOF
printf '{"v":1,"source":"srcgone2","reason":"test","date":"2026-07-01"}\n' > "$V/sources/srcgone2.tombstone.json"
cat >> "$V/claims.jsonl" <<'EOF'
{"v":1,"id":"clm_ok","topic":"topic-a","statement":"OAuth 2.1 required","quote":"requires OAuth 2.1 with PKCE","source":"srcok","provenance":"verbatim-grounded","date":"2026-07-01"}
{"v":1,"id":"clm_badq","topic":"topic-a","statement":"Bearer allowed","quote":"bearer tokens are fine forever","source":"srcok","provenance":"verbatim-grounded","date":"2026-07-01"}
{"v":1,"id":"clm_gone","topic":"topic-a","statement":"claim on missing source","quote":"x","source":"srcgone1","provenance":"verbatim-grounded","date":"2026-07-01"}
{"v":1,"id":"clm_tomb","topic":"topic-a","statement":"claim on redacted source","quote":"x","source":"srcgone2","provenance":"verbatim-grounded","date":"2026-07-01"}
{"v":2,"id":"clm_v2","topic":"topic-a","statement":"future schema","provenance":"model-asserted","date":"2026-07-01"}
not json at all
EOF

# Seed inbox (one live pointer, one dead) + raw html (one secret, one clean)
printf '%s\n' "{\"v\":1,\"kind\":\"pointer\",\"session\":\"alive\",\"transcript\":\"$V/sources/srcok.md\"}" >> "$V/inbox.jsonl"
printf '{"v":1,"kind":"pointer","session":"dead","transcript":"/nonexistent/t.jsonl"}\n' >> "$V/inbox.jsonl"
printf '<html>key AKIAABCDEFGHIJKLMNOP here</html>' > "$V/sources/raw/aaaa1111.html"
printf '<html>clean page</html>' > "$V/sources/raw/bbbb2222.html"

node -e '
const path = require("path");
const lib = require(path.join(process.argv[2], "vault-lib.js"));
const sw = require(process.argv[1]);
const V = process.argv[3];
const { claims } = lib.foldClaims(lib.readJsonl(path.join(V, "claims.jsonl")).records);
const orph = sw.sweepOrphanRuns(V);
if (orph.length !== 1 || orph[0].run !== "2026-07-02a-orph") process.exit(1);
const dup = sw.sweepDuplicateSessions(V);
if (dup.length !== 1 || dup[0].session !== "sess-dup" || dup[0].runs.length !== 2) process.exit(2);
const refs = sw.sweepSourceRefs(V, claims);
if (refs.broken.length !== 1 || refs.broken[0].source !== "srcgone1") process.exit(3);
if (refs.tombstoned.length !== 1 || refs.tombstoned[0].source !== "srcgone2") process.exit(4);
const q = sw.sweepQuotes(V, claims);
if (q.checked !== 2 || q.passed !== 1 || q.failed.length !== 1 || q.failed[0].claim !== "clm_badq") process.exit(5);
const sec = sw.sweepSecrets(V);
if (sec.length !== 1 || sec[0].pattern !== "aws-access-key" || !/aaaa1111/.test(sec[0].file)) process.exit(6);
const dead = sw.deadInboxPointers(V);
if (dead.length !== 1 || dead[0].session !== "dead") process.exit(7);
const census = sw.schemaCensus(V);
const cc = census["claims.jsonl"];
if (!cc || cc.skipped !== 1 || cc.aboveCurrent !== 1) process.exit(8);
if (!sw.listRunDirs(V).length === 4) process.exit(9);
' "$SW" "$SK" "$V" 2>/dev/null \
  && ok "all sweeps find exactly the seeded defects" || no "sweeps" "rc=$?"

# Sweeps are pure: nothing in the vault changed
node -e '
const fs = require("fs");
process.exit(fs.existsSync(process.argv[1] + "/.lock") ? 1 : 0);
' "$V" && ok "no lock left, no mutation" || no "purity" ""

echo; echo "doctor-sweeps: $pass passed, $fail failed"; [ $fail -eq 0 ]
