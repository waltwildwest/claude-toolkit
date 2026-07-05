#!/usr/bin/env bash
# Tests for doctor-quality.js (module) + vault-views.regenDashboard.
# Run: bash tests/researcher-quality.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/plugins/re-searcher/skills/re-searcher"
Q="$SK/doctor-quality.js"
VW="$SK/vault-views.js"
I="$SK/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-quality tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "doctor-quality + dashboard tests"

# 1. scoreQuality + renderProfile on a synthetic fold
node -e '
const q = require(process.argv[1]);
const claims = new Map();
const mk = (id, extra) => Object.assign({ id, status: "active", supersededBy: [], contradictedBy: [], events: [],
  provenance: "model-asserted", tool: "websearch", source: "aaaa1111--spec-example--page", statement: "s", date: "2026-07-01" }, extra);
claims.set("c1", mk("c1", {}));
claims.set("c2", mk("c2", { provenance: "externally-verified", tool: "gh" }));
claims.set("c3", mk("c3", { status: "retracted" }));
claims.set("c4", mk("c4", { note: "downgraded: quote not found in x" }));
claims.set("c5", mk("c5", { source: null, tool: undefined, events: [{op:"downgrade", claim:"c5"}] }));
const s = q.scoreQuality(claims);
if (s.tools.websearch.claims !== 3) process.exit(1);
if (s.tools.websearch.live !== 1) process.exit(2);
if (s.tools.gh.verified !== 1) process.exit(3);
if (s.tools.unknown.downgraded !== 1) process.exit(4);
if (s.hosts["spec-example"].claims !== 4) process.exit(5);
if (s.hosts["(none)"].claims !== 1) process.exit(6);
if (s.totals.claims !== 5 || s.totals.retracted !== 1 || s.totals.downgraded !== 2) process.exit(7);
const md = q.renderProfile(s, "2026-07-05");
if (!/\| websearch \| 3 \|/.test(md) || !/Machine block/.test(md) || !/"v":1/.test(md)) process.exit(8);
' "$Q" && ok "scoreQuality buckets + renderProfile tables" || no "quality" "rc=$?"

# 2. regenDashboard with real numbers
OLD=$(node -e 'const d=new Date(Date.now()-45*86400000); console.log(d.toISOString().slice(0,10))')
cat >> "$V/index.jsonl" <<EOF
{"v":1,"slug":"old-moving","title":"Old Moving","aliases":[],"questions":[],"scope":"general","run":"r1","date":"$OLD","volatility":"moving"}
{"v":1,"slug":"new-stable","title":"New Stable","aliases":[],"questions":[],"scope":"general","run":"r2","date":"2026-07-05","volatility":"stable"}
EOF
cat >> "$V/claims.jsonl" <<'EOF'
{"v":1,"id":"clm_a","topic":"old-moving","statement":"old belief","provenance":"model-asserted","date":"2026-05-01"}
{"v":1,"id":"clm_b","topic":"old-moving","statement":"new belief","provenance":"model-asserted","date":"2026-06-01"}
{"v":1,"op":"supersede","claim":"clm_a","by":"clm_b","date":"2026-06-01"}
{"v":1,"id":"clm_c","topic":"new-stable","statement":"claim c","provenance":"model-asserted","date":"2026-07-01"}
{"v":1,"id":"clm_d","topic":"new-stable","statement":"claim d","provenance":"model-asserted","date":"2026-07-01"}
{"v":1,"op":"contradict","claim":"clm_c","by":"clm_d","date":"2026-07-02"}
{"v":1,"op":"verify","claim":"clm_b","by":"doctor","date":"2026-07-02"}
EOF
cat >> "$V/metrics.jsonl" <<'EOF'
{"v":1,"kind":"recall","ts":"2026-07-01T00:00:00Z","terms":["a"],"hits":["old-moving"]}
{"v":1,"kind":"recall","ts":"2026-07-02T00:00:00Z","terms":["b"],"hits":[]}
{"v":1,"kind":"near-miss","ts":"2026-07-02T00:00:01Z","terms":["b"],"near":["old-moving"],"inbox":[]}
{"v":1,"kind":"save","ts":"2026-07-03T00:00:00Z","run":"r1","topic":"old-moving","light":true,"fresh":false}
{"v":1,"kind":"save","ts":"2026-07-04T00:00:00Z","run":"r2","topic":"new-stable","light":false,"fresh":true}
EOF
mkdir -p "$V/topics/old-moving/runs/r1" "$V/topics/new-stable/runs/r2"
node -e 'require(process.argv[1]).regenDashboard(process.argv[2], null);' "$VW" "$V"
D="$V/DASHBOARD.md"
grep -q '2 topics · 2 runs' "$D" && ok "topic/run counts" || no "counts" "$(head -8 "$D")"
grep -q 'claims 3 active / 1 superseded / 0 retracted' "$D" && ok "claim tallies" || no "tallies" "$(grep claims "$D")"
grep -q 'hit rate 50%' "$D" && ok "hit rate from metrics" || no "hit rate" ""
grep -q '| 2026-07 | 2 | 1 | 50% |' "$D" && ok "--fresh canary table" || no "canary" "$(grep 2026-07 "$D")"
grep -q 'contradicted' "$D" && grep -q 'stale moving topic: old-moving' "$D" && ok "attention lines" || no "attention" ""
grep -q -- '~~old belief~~' "$D" && ok "belief-change line" || no "belief" ""
grep -q 'never run' "$D" && ok "doctor never-run line" || no "doctor line" ""

# 3. regenDashboard with a doctor summary adds the backlog line
node -e '
require(process.argv[1]).regenDashboard(process.argv[2], { work: { promote: [1], freshness: [], mine: [1,2], contradictions: [] } });
' "$VW" "$V"
grep -q 'doctor backlog: 1 to promote' "$D" && grep -q '2 runs to mine' "$D" && ok "doctor backlog line" || no "backlog" "$(grep backlog "$D")"

echo; echo "quality+dashboard: $pass passed, $fail failed"; [ $fail -eq 0 ]
