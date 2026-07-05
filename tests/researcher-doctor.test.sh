#!/usr/bin/env bash
# Contract E2E for vault-doctor.js: a vault seeded with every known defect ->
# the report names each -> deterministic fixes leave a clean re-run.
# CI-safe: wayback via local fixture server (WAYBACK_API); no live network, no LLM.
# Run: bash tests/researcher-doctor.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
D="$SK/vault-doctor.js"
S="$SK/vault-save.js"
SR="$SK/vault-search.js"
I="$SK/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-doctor tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1

cat > "$W/wb-server.js" <<'EOF'
'use strict';
const http = require('http');
const srv = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/wayback/available') {
    const target = u.searchParams.get('url') || '';
    res.writeHead(200, { 'content-type': 'application/json' });
    if (target.includes('wb%3Dknown') || target.includes('wb=known')) {
      return res.end(JSON.stringify({ archived_snapshots: { closest: { available: true, url: 'http://archive.example/snap/9' } } }));
    }
    return res.end(JSON.stringify({ archived_snapshots: {} }));
  }
  if (u.pathname.startsWith('/save/')) { res.writeHead(429); return res.end('no'); }
  res.writeHead(404); res.end();
});
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));
EOF
node "$W/wb-server.js" > "$W/wbport.txt" & WBSRV=$!
trap 'kill $WBSRV 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$W/wbport.txt" ] && break; sleep 0.2; done
export WAYBACK_API="http://127.0.0.1:$(cat "$W/wbport.txt")"

OLD=$(node -e 'const d=new Date(Date.now()-45*86400000); console.log(d.toISOString().slice(0,10))')

# --- seed every defect the handoff names ---
# orphan run, duplicate-session runs, an unmined light run
mkdir -p "$V/topics/seeded/runs/2026-06-01a-orph" \
         "$V/topics/seeded/runs/2026-06-02a-dupa" "$V/topics/seeded/runs/2026-06-02b-dupb" \
         "$V/topics/seeded/runs/2026-06-03a-lite"
echo '# plan' > "$V/topics/seeded/runs/2026-06-01a-orph/plan.md"
echo '{"v":1,"session":"sess-dup","light":false}' > "$V/topics/seeded/runs/2026-06-02a-dupa/lineage.json"
echo '{"v":1,"session":"sess-dup","light":false}' > "$V/topics/seeded/runs/2026-06-02b-dupb/lineage.json"
echo '{"v":1,"session":"sess-lite","light":true}' > "$V/topics/seeded/runs/2026-06-03a-lite/lineage.json"

# index: a stale MOVING topic (two records -> compaction has work) + alias-learning target
cat >> "$V/index.jsonl" <<EOF
{"v":1,"slug":"seeded","title":"Seeded Topic","aliases":["seed probe"],"questions":[],"scope":"general","run":"r0","date":"$OLD","volatility":"moving"}
{"v":1,"slug":"seeded","title":"Seeded Topic","aliases":["seed probe"],"questions":[],"scope":"general","run":"r0b","date":"$OLD","volatility":"moving"}
{"v":1,"slug":"kube-networking","title":"Kube Networking","aliases":[],"questions":[],"scope":"general","run":"r1","date":"2026-07-01"}
EOF

# source (wayback still queued) + claims: promote target (valid quote), stale
# moving claim, contradiction pair, broken source ref
cat > "$V/sources/srcpromo.md" <<'EOF'
---
v: 1
kind: web
wayback: queued
---
OAuth 2.1 is required for all remote MCP servers.
EOF
cat >> "$V/claims.jsonl" <<EOF
{"v":1,"id":"clm_promo","run":"r0","topic":"seeded","statement":"OAuth is required for remote MCP servers","quote":"OAuth 2.1 is required for all remote MCP servers.","source":"srcpromo","provenance":"verbatim-grounded","confidence":"high","date":"$OLD"}
{"v":1,"id":"clm_contra","run":"r0b","topic":"seeded","statement":"OAuth is optional for remote MCP servers","provenance":"model-asserted","date":"2026-07-05"}
{"v":1,"id":"clm_broken","run":"r0","topic":"seeded","statement":"claim with vanished origin","quote":"x","source":"srcnope","provenance":"verbatim-grounded","date":"2026-07-05"}
EOF

# dead inbox pointer, wayback queue (one resolvable, one exhausted), alias-learning metrics, raw secret
printf '{"v":1,"kind":"pointer","session":"deadsess","transcript":"/nonexistent/x.jsonl"}\n' >> "$V/inbox.jsonl"
cat >> "$V/wayback-queue.jsonl" <<'EOF'
{"v":1,"url":"http://target.example/page?wb=known","source_id":"srcpromo","ts":"2026-07-01T00:00:00Z","attempts":0}
{"v":1,"url":"http://target.example/dead?wb=fail","source_id":null,"ts":"2026-07-01T00:00:00Z","attempts":4}
EOF
cat >> "$V/metrics.jsonl" <<'EOF'
{"v":1,"kind":"near-miss","ts":"2026-07-01T00:00:00Z","terms":["k8s","ingress"],"near":["kube-networking"],"inbox":[]}
{"v":1,"kind":"recall","ts":"2026-07-02T00:00:00Z","terms":["k8s","ingress"],"hits":["kube-networking"]}
EOF
printf '<html>AKIAABCDEFGHIJKLMNOP</html>' > "$V/sources/raw/cccc3333.html"

echo "vault-doctor contract E2E (wayback fixture on $WAYBACK_API)"

# --- first run: every seeded defect is named; fixes applied ---
OUT=$(node "$D" --vault "$V" 2>/dev/null); rcode=$?
[ $rcode -eq 0 ] && ok "doctor exits 0" || no "exit" "rc=$rcode"
printf '%s' "$OUT" > "$W/report1.json"
node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const must = (c, m) => { if (!c) { process.stderr.write("MISS: " + m + "\n"); process.exit(1); } };
must(r.status === "ok", "status");
must(r.report.orphanRuns.length === 1 && r.report.orphanRuns[0].run === "2026-06-01a-orph", "orphan run");
must(r.report.duplicateSessions.length === 1 && r.report.duplicateSessions[0].session === "sess-dup", "duplicate sessions");
must(r.report.sourceRefs.broken.length === 1 && r.report.sourceRefs.broken[0].claim === "clm_broken", "broken source ref");
must(r.report.quotes.checked === 1 && r.report.quotes.failed.length === 0, "quote recheck");
must(r.report.secrets.length === 1, "secret hit");
must(r.fixed.deadPointersDropped === 1, "dead pointer dropped");
must(r.fixed.indexCompacted.before === 3 && r.fixed.indexCompacted.after === 2, "index compacted");
must(r.fixed.claimsCurrent === 3, "claims-current count");
must(r.fixed.aliasesLearned.length === 1 && r.fixed.aliasesLearned[0].alias === "k8s ingress", "alias learned");
must(r.fixed.wayback.exists === 1 && r.fixed.wayback.droppedFailed === 1, "wayback drain");
must(r.work.promote.length === 2, "promote items");
must(r.work.freshness.length === 1 && r.work.freshness[0].topic === "seeded" && r.work.freshness[0].claims.length === 1, "freshness topic");
must(r.work.mine.length === 1 && r.work.mine[0].run === "2026-06-03a-lite", "mine item");
must(r.work.contradictions.length === 1, "contradiction pair");
must(r.hwm.claims === 3 && typeof r.hwm.metrics === "number", "hwm");
' "$W/report1.json" && ok "report names every seeded defect" || no "report" "$(cat "$W/report1.json")"

# fixes are on disk
grep -q '^wayback: exists$' "$V/sources/srcpromo.md" && grep -q '^wayback_url: http://archive.example/snap/9$' "$V/sources/srcpromo.md" \
  && ok "source frontmatter wayback updated" || no "wb frontmatter" "$(head -8 "$V/sources/srcpromo.md")"
[ "$(grep -c . "$V/wayback-queue.jsonl")" = "0" ] && ok "wayback queue drained" || no "queue" "$(cat "$V/wayback-queue.jsonl")"
[ "$(grep -c . "$V/inbox.jsonl")" = "0" ] && ok "dead pointer removed" || no "inbox" "$(cat "$V/inbox.jsonl")"
[ "$(grep -c . "$V/index.jsonl")" = "2" ] && ok "index compacted with learned alias merged" || no "index lines" "$(cat "$V/index.jsonl")"
node -e '
const fs = require("fs");
const recs = fs.readFileSync(process.argv[1] + "/index.jsonl", "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
const k = recs.filter((r) => r.slug === "kube-networking").pop();
process.exit(k && k.aliases.includes("k8s ingress") ? 0 : 1);
' "$V" && ok "learned alias in index" || no "alias" ""
[ "$(grep -c . "$V/claims-current.jsonl")" = "3" ] && ok "claims-current materialized" || no "claims-current" ""
grep -q '| unknown | 3 |' "$V/profiles/source-quality.md" && ok "profiles/source-quality.md written" || no "profiles" "$(cat "$V/profiles/source-quality.md" 2>/dev/null | head -20)"
grep -q 'doctor backlog: 2 to promote' "$V/DASHBOARD.md" && ok "dashboard has doctor backlog" || no "dashboard" "$(grep backlog "$V/DASHBOARD.md")"

# --- promotion path: doctor-sanctioned verify -> recall serves externally-verified ---
printf '{"op":"verify","claim":"clm_promo","by":"doctor","reason":"semantically supported by srcpromo"}\n' > "$W/ev.jsonl"
OUT=$(node "$S" --events "$W/ev.jsonl" --doctor --vault "$V")
has "$OUT" '"applied":1' && ok "verify applied via --doctor" || no "verify apply" "$OUT"
OUT=$(node "$SR" oauth remote --vault "$V" --json 2>/dev/null)
has "$OUT" '"provenance":"externally-verified"' && ok "recall serves promoted claim" || no "recall promoted" "$OUT"

# --- second run: idempotent; promotion consumed; contradictions incremental ---
OUT2=$(node "$D" --vault "$V" 2>/dev/null); rcode=$?
printf '%s' "$OUT2" > "$W/report2.json"
node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const must = (c, m) => { if (!c) { process.stderr.write("MISS: " + m + "\n"); process.exit(1); } };
must(r.fixed.deadPointersDropped === 0, "no pointers to drop");
must(r.fixed.indexCompacted.before === r.fixed.indexCompacted.after, "index already compact");
must(r.fixed.aliasesLearned.length === 0, "no new aliases");
must(r.fixed.wayback.exists + r.fixed.wayback.requested + r.fixed.wayback.retried + r.fixed.wayback.droppedFailed === 0, "queue stays empty");
must(r.work.promote.length === 1 && r.work.promote[0].claim === "clm_broken", "promotion consumed");
must(r.work.freshness.length === 1, "freshness stable");
must(r.work.mine.length === 1, "mine stable");
must(r.work.contradictions.length === 0, "contradictions incremental");
must(r.report.orphanRuns.length === 1 && r.report.duplicateSessions.length === 1, "report items persist");
' "$W/report2.json" && ok "re-run is clean and incremental" || no "idempotent" "$(cat "$W/report2.json")"

# hwm advanced past the verify event
node -e '
const lib = require(process.argv[1] + "/vault-lib.js");
const last = lib.readJsonl(process.argv[2] + "/metrics.jsonl").records.filter((m) => m.kind === "doctor").pop();
process.exit(last && last.hwm.claims === 4 ? 0 : 1);
' "$SK" "$V" && ok "hwm advances with the registry" || no "hwm" ""

# --no-network keeps queue entries untouched
printf '{"v":1,"url":"http://x.example/q?wb=known","source_id":null,"ts":"2026-07-05T00:00:00Z","attempts":0}\n' >> "$V/wayback-queue.jsonl"
OUT=$(node "$D" --vault "$V" --no-network 2>/dev/null)
node -e '
const r = JSON.parse(process.argv[1]);
process.exit(r.fixed.wayback.kept === 1 && r.fixed.wayback.exists === 0 ? 0 : 1);
' "$OUT" && [ "$(grep -c . "$V/wayback-queue.jsonl")" = "1" ] && ok "--no-network keeps the queue" || no "no-network" "$OUT"

# --schedule-snippet
OUT=$(node "$D" --schedule-snippet)
{ has "$OUT" 'cron' && has "$OUT" '/research doctor'; } && ok "--schedule-snippet prints both paths" || no "snippet" "$OUT"

echo; echo "vault-doctor: $pass passed, $fail failed"; [ $fail -eq 0 ]
