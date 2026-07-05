#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/vault-save.js
# Run: bash tests/researcher-save.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/re-searcher/skills/re-searcher/vault-save.js"
I="$ROOT/plugins/re-searcher/skills/re-searcher/vault-init.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-save tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"; V="$W/vault"
node "$I" --vault "$V" >/dev/null 2>&1
echo "vault-save tests"

# --- --new-run ---

# 1. allocates a run folder with findings/ and a date+letter+session id
OUT=$(node "$S" --new-run --topic "MCP Auth Landscape" --session 9f3c2ab1 --vault "$V"); rcode=$?
RUN1=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
{ [ $rcode -eq 0 ] && [ -d "$RUN1/findings" ]; } && ok "new-run allocates" || no "new-run" "rc=$rcode $OUT"
case "$RUN1" in "$V/topics/mcp-auth-landscape/runs/"*a-9f3c) ok "run id shape date+letter+sess4" ;; *) no "run id shape" "$RUN1" ;; esac

# 2. same-day second run gets the next letter
OUT=$(node "$S" --new-run --topic "MCP Auth Landscape" --session 9f3c2ab1 --vault "$V")
RUN2=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
case "$RUN2" in *b-9f3c) ok "collision -> next letter" ;; *) no "letter bump" "$RUN2" ;; esac

# 3. missing --topic fails loud
node "$S" --new-run --vault "$V" >/dev/null 2>&1; [ $? -eq 1 ] && ok "new-run without topic fails" || no "topic required" "$?"

# --- --check-staging ---

# 4. no plan.md -> exit 1 loud
mkdir -p "$W/norun"
ERR=$(node "$S" --check-staging "$W/norun" 2>&1 >/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$ERR" "plan.md"; } && ok "no plan.md fails loud" || no "no plan" "rc=$rcode $ERR"

# 5. manifest vs files: missing, stub, bad header, then complete
cat > "$RUN1/plan.md" <<'EOF'
---
topic: mcp-auth-landscape
title: MCP Auth Landscape
aliases: ["mcp oauth", "model context protocol auth"]
questions: ["does mcp require oauth 2.1?"]
scope: general
session: 9f3c2ab1
---

# Plan

## Question
What is the MCP auth landscape?

```manifest
[{"role": "spec-reader", "file": "findings/spec-reader.md"},
 {"role": "ecosystem", "file": "findings/ecosystem.md"}]
```
EOF
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" '"ok":false' && has "$OUT" 'spec-reader.md' && has "$OUT" 'ecosystem.md'; } \
  && ok "missing findings detected" || no "missing" "rc=$rcode $OUT"

cat > "$RUN1/findings/spec-reader.md" <<EOF
---
role: spec-reader
run: $(basename "$RUN1")
task: read the auth spec
date: 2026-07-05
---

# Findings — spec-reader

## Summary
$(printf 'The spec requires OAuth 2.1 with PKCE for remote servers. %.0s' 1 2 3 4 5 6 7 8 9 10)

## Details
$(printf 'Detail sentence about token endpoints and dynamic client registration. %.0s' 1 2 3 4 5 6 7 8)

## Sources
- src_test — the spec page
EOF
printf -- '---\nrole: ecosystem\n---\ntoo small' > "$RUN1/findings/ecosystem.md"
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'stubs' && has "$OUT" 'ecosystem.md'; } && ok "stub finding detected" || no "stub" "rc=$rcode $OUT"

node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], "no frontmatter here\n" + "Filler sentence for size requirements in the staging check. ".repeat(12));
' "$RUN1/findings/ecosystem.md"
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 2 ] && has "$OUT" 'badHeader' && has "$OUT" 'ecosystem.md'; } && ok "bad header detected" || no "bad header" "rc=$rcode $OUT"

cat > "$RUN1/findings/ecosystem.md" <<EOF
---
role: ecosystem
run: $(basename "$RUN1")
task: survey server implementations
date: 2026-07-05
---

# Findings — ecosystem

## Summary
$(printf 'Most public MCP servers ship bearer-token auth and defer OAuth to gateways. %.0s' 1 2 3 4 5 6 7 8)

## Details
$(printf 'Detail sentence about gateway adapters and session tokens in the wild. %.0s' 1 2 3 4 5 6 7 8)
EOF
OUT=$(node "$S" --check-staging "$RUN1"); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"ok":true' && has "$OUT" '"agents":2'; } && ok "complete staging passes" || no "complete" "rc=$rcode $OUT"

# --- persist (Task 8) ---

# seed a cached source the claims can ground against
cat > "$V/sources/src_fix1.md" <<'EOF'
---
v: 1
kind: web
title: "Fixture spec page"
---
The **MCP spec** requires [OAuth 2.1](https://spec.example/auth) with PKCE for all remote servers as of the June revision.
Bearer tokens remain acceptable for local stdio servers only.
EOF

printf '# Synthesis\n\nOAuth 2.1 with PKCE is required for remote servers.\n\n## Gaps\n\n- none\n' > "$RUN1/synthesis.md"
cat > "$RUN1/claims-staged.jsonl" <<'EOF'
{"statement":"Remote MCP servers must use OAuth 2.1","quote":"requires OAuth 2.1 with PKCE for all remote servers","source":"src_fix1","provenance":"verbatim-grounded","confidence":"high","found_by":"spec-reader"}
{"statement":"Bearer tokens are fine for local stdio servers","quote":"Bearer tokens remain acceptable for local stdio servers only.","source":"src_fix1","provenance":"verbatim-grounded"}
{"statement":"The spec bans API keys outright","quote":"API keys are prohibited in every deployment mode","source":"src_fix1","provenance":"verbatim-grounded"}
{"statement":"bad record","confidence":"certain"}
{"statement":"No MCP server supports SAML as of 2026-07","type":"absence","found_by":"ecosystem","tool":"websearch"}
{"statement":"Source A says device flow is mandatory","ref":"a","provenance":"model-asserted"}
{"statement":"Source B says device flow is optional","ref":"b","provenance":"model-asserted"}
{"op":"contradict","claim":"ref:a","by":"ref:b"}
EOF
printf '{"fake":"transcript line 1"}\n{"fake":"transcript line 2"}\n' > "$W/session.jsonl"

OUT=$(node "$S" "$RUN1" --vault "$V" --session 9f3c2ab1 --transcript "$W/session.jsonl"); rcode=$?
[ $rcode -eq 0 ] && ok "persist exits 0" || no "persist rc" "rc=$rcode $OUT"
has "$OUT" '"status":"partial"' && ok "partial status (1 reject)" || no "status" "$OUT"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.claims.accepted===6 && r.claims.rejected===1 && r.claims.downgraded===1 && r.claims.events===1 && r.claims.ids.length===6 ? 0 : 1)' "$OUT" \
  && ok "claim tallies: 6 accepted / 1 rejected / 1 downgraded / 1 event" || no "tallies" "$OUT"
has "$OUT" 'fresh run · 2 agents' && ok "provenance line" || no "prov line" "$OUT"

# tier-1 artifacts
[ -f "$RUN1/lineage.json" ] && grep -q '9f3c2ab1' "$RUN1/lineage.json" && ok "lineage written" || no "lineage" ""
[ -f "$RUN1/transcripts/session.jsonl.gz" ] && ok "transcript gzipped into run" || no "transcript" "$(ls "$RUN1")"
node -e '
const zlib=require("zlib"),fs=require("fs");
const t=zlib.gunzipSync(fs.readFileSync(process.argv[1])).toString();
process.exit(t.includes("transcript line 2") ? 0 : 1);
' "$RUN1/transcripts/session.jsonl.gz" && ok "transcript roundtrips" || no "gunzip" ""
grep -q '"slug":"mcp-auth-landscape"' "$V/index.jsonl" && ok "index appended" || no "index" "$(cat "$V/index.jsonl")"

# tier-2 artifacts: registry, quarantine, quote rewrite, ref resolution
grep -c '"id":"clm_' "$V/claims.jsonl" | grep -q '^6$' && ok "6 claims registered" || no "registry" "$(cat "$V/claims.jsonl")"
grep -q '\[OAuth 2.1\](https://spec.example/auth)' "$V/claims.jsonl" && ok "quote rewritten to source bytes" || no "rewrite" ""
grep -q 'downgraded: quote not found' "$V/claims.jsonl" && ok "fabricated quote downgraded in registry" || no "downgrade note" ""
[ -f "$RUN1/claims-rejected.jsonl" ] && grep -q 'bad confidence' "$RUN1/claims-rejected.jsonl" && ok "reject quarantined with reason" || no "quarantine" ""
node -e '
const recs = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
const ev = recs.find((r) => r.op === "contradict");
process.exit(ev && ev.claim.startsWith("clm_") && ev.by.startsWith("clm_") ? 0 : 1);
' "$V/claims.jsonl" && ok "batch refs resolved to real ids" || no "ref resolve" "$(grep contradict "$V/claims.jsonl")"

# views + git
grep -q 'OAuth 2.1 with PKCE is required' "$V/topics/mcp-auth-landscape/topic.md" && ok "topic view regenerated" || no "topic view" ""
grep -q 'mcp-auth-landscape' "$V/INDEX.md" && ok "INDEX regenerated" || no "INDEX" ""
git -C "$V" log --oneline | grep -q "persist run" && ok "auto-commit" || no "git" "$(git -C "$V" log --oneline 2>&1)"
grep -q '"kind":"save"' "$V/metrics.jsonl" && ok "metrics logged" || no "metrics" ""

# human notes survive a re-persist; re-persist must not duplicate claims,
# must not re-append events, and must not report phantom rejects
printf 'precious-note-9000\n' >> "$V/topics/mcp-auth-landscape/topic.md"
OUT=$(node "$S" "$RUN1" --vault "$V" --session 9f3c2ab1)
grep -q 'precious-note-9000' "$V/topics/mcp-auth-landscape/topic.md" && ok "human notes preserved on re-persist" || no "notes" ""
grep -c '"id":"clm_' "$V/claims.jsonl" | grep -q '^6$' && ok "re-persist dedupes claims" || no "dedupe" "$(grep -c '"id":"clm_' "$V/claims.jsonl")"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.claims.rejected===1 && r.claims.events===0 && r.claims.duplicates===7 ? 0 : 1)' "$OUT" \
  && ok "re-persist: only the still-invalid record re-rejects, event deduped" || no "re-persist tallies" "$OUT"
grep -q 'unknown claim: ref:' "$RUN1/claims-rejected.jsonl" && no "phantom ref reject" "$(grep 'unknown claim' "$RUN1/claims-rejected.jsonl")" || ok "no phantom ref rejects"
grep -c '"op":"contradict"' "$V/claims.jsonl" | grep -q '^1$' && ok "contradict registered exactly once" || no "event dup" "$(grep -c '"op":"contradict"' "$V/claims.jsonl")"

# topic mismatch fails loud
mkdir -p "$V/topics/other-topic/runs/2026-07-05a-zzzz/findings"
cp "$RUN1/plan.md" "$V/topics/other-topic/runs/2026-07-05a-zzzz/plan.md"
node "$S" "$V/topics/other-topic/runs/2026-07-05a-zzzz" --vault "$V" >/dev/null 2>&1
[ $? -eq 1 ] && ok "topic/folder mismatch fails loud" || no "mismatch" "$?"

# --light: no claims file is fine, provenance line says light
OUT=$(node "$S" --new-run --topic quick-check --session 9f3c2ab1 --vault "$V")
RUNL=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
cat > "$RUNL/plan.md" <<'EOF'
---
topic: quick-check
title: Quick check
aliases: []
questions: []
scope: general
---
# Plan

```manifest
[{"role": "solo", "file": "findings/solo.md"}]
```
EOF
node -e '
const fs=require("fs");
fs.writeFileSync(process.argv[1] + "/findings/solo.md", "---\nrole: solo\nrun: x\n---\n\n# Findings\n\n" + "A light-path finding sentence with enough real content to pass the size floor. ".repeat(8));
' "$RUNL"
OUT=$(node "$S" "$RUNL" --vault "$V" --light --session 9f3c2ab1); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"status":"complete"' && has "$OUT" 'light run'; } && ok "light path persists clean" || no "light" "rc=$rcode $OUT"

# --- --events (Task 8) ---

C1=$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.id && r.statement.includes("OAuth 2.1"));console.log(l[0].id)' "$V/claims.jsonl")
C2=$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.id && r.statement.includes("Bearer tokens"));console.log(l[0].id)' "$V/claims.jsonl")
printf '{"op":"supersede","claim":"%s","by":"%s","reason":"newer revision"}\n{"op":"supersede","claim":"%s","by":"%s","reason":"would cycle"}\n' "$C1" "$C2" "$C2" "$C1" > "$W/events.jsonl"
OUT=$(node "$S" --events "$W/events.jsonl" --vault "$V"); rcode=$?
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.applied===1 && r.rejected.length===1 && /cycle/.test(r.rejected[0].reason) ? 0 : 1)' "$OUT" \
  && ok "events: apply + cycle reject" || no "events" "rc=$rcode $OUT"
git -C "$V" log --oneline -1 | grep -q "event" && ok "events auto-commit" || no "events git" "$(git -C "$V" log --oneline -1)"
grep -q 'Superseded' "$V/topics/mcp-auth-landscape/topic.md" && ok "views reflect supersession" || no "views supersede" ""

# an unexpected throw inside the locked region still emits structured JSON + exit 1
OUT=$(node "$S" --new-run --topic err-topic --session errr1234 --vault "$V")
RUNE=$(node -e 'console.log(JSON.parse(process.argv[1]).runDir)' "$OUT")
cat > "$RUNE/plan.md" <<'EOF'
---
topic: err-topic
title: Err
aliases: []
questions: []
scope: general
---
# Plan

```manifest
[{"role": "solo", "file": "findings/solo.md"}]
```
EOF
mkdir -p "$V/topics/err-topic/topic.md"
OUT=$(node "$S" "$RUNE" --vault "$V" --light 2>/dev/null); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" '"status":"error"'; } && ok "throw inside lock emits error JSON" || no "error json" "rc=$rcode $OUT"
[ -d "$V/.lock" ] && no "lock released after throw" "still held" || ok "lock released after throw"
rm -rf "$V/topics/err-topic"

# --- stage 3: --events --doctor (provenance promotion) ---

# doctor-applied verify promotes provenance end-to-end; plain --events still rejects
CID=$(node -e '
const lib = require(process.argv[1]);
const recs = lib.readJsonl(process.argv[2] + "/claims.jsonl").records;
const c = recs.find((r) => r.id && !r.op);
process.stdout.write(c ? c.id : "");
' "$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js" "$V")
[ -n "$CID" ] || no "doctor verify precondition" "no claim found in registry"
printf '{"op":"verify","claim":"%s","by":"doctor","reason":"quote re-verified"}\n' "$CID" > "$W/verify-events.jsonl"
OUT=$(node "$S" --events "$W/verify-events.jsonl" --vault "$V"); rcode=$?
has "$OUT" '"applied":0' && ok "plain --events still rejects verify" || no "verify gate" "rc=$rcode $OUT"
OUT=$(node "$S" --events "$W/verify-events.jsonl" --vault "$V" --doctor); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"applied":1'; } && ok "--doctor applies verify" || no "doctor apply" "rc=$rcode $OUT"
node -e '
const lib = require(process.argv[1]);
const { claims } = lib.foldClaims(lib.readJsonl(process.argv[2] + "/claims.jsonl").records);
const c = claims.get(process.argv[3]);
process.exit(c && c.provenance === "externally-verified" ? 0 : 1);
' "$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js" "$V" "$CID" \
  && ok "verify event promotes provenance in the fold" || no "promotion fold" ""
OUT=$(node "$S" --events "$W/verify-events.jsonl" --vault "$V" --doctor)
has "$OUT" '"applied":0' && ok "doctor re-apply dedupes (idempotent)" || no "verify dedupe" "$OUT"

# --- stage 3: volatility + --fresh ---
R3=$(node "$S" --new-run --topic vol-topic --session volt1 --vault "$V")
RD3=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).runDir)' "$R3")
cat > "$RD3/plan.md" <<'EOF'
---
topic: vol-topic
title: Volatility test
scope: general
volatility: live
session: volt1
aliases: []
questions: []
---

# Plan

```manifest
[{"role": "solo", "file": "findings/solo.md"}]
```
EOF
{ printf -- '---\nrole: solo\n---\n'; head -c 600 /dev/zero | tr '\0' 'x'; } > "$RD3/findings/solo.md"
OUT=$(node "$S" "$RD3" --light --fresh --session volt1 --vault "$V"); rcode=$?
[ $rcode -eq 0 ] || no "vol persist" "rc=$rcode $OUT"
node -e '
const lib = require(process.argv[1]);
const idx = lib.readJsonl(process.argv[2] + "/index.jsonl").records.filter((r) => r.slug === "vol-topic").pop();
process.exit(idx && idx.volatility === "live" ? 0 : 1);
' "$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js" "$V" && ok "plan volatility lands in index" || no "volatility" ""
grep '"kind":"save"' "$V/metrics.jsonl" | grep -q '"fresh":true' && ok "--fresh recorded in save metric" || no "fresh metric" ""

# a second run WITHOUT volatility preserves the previous value (never resets to moving)
R4=$(node "$S" --new-run --topic vol-topic --session volt2 --vault "$V")
RD4=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).runDir)' "$R4")
sed -e 's/^volatility: live$//' -e 's/volt1/volt2/' "$RD3/plan.md" > "$RD4/plan.md"
cp "$RD3/findings/solo.md" "$RD4/findings/solo.md"
node "$S" "$RD4" --light --session volt2 --vault "$V" >/dev/null
node -e '
const lib = require(process.argv[1]);
const idx = lib.readJsonl(process.argv[2] + "/index.jsonl").records.filter((r) => r.slug === "vol-topic").pop();
const m = lib.readJsonl(process.argv[2] + "/metrics.jsonl").records.filter((r) => r.kind === "save").pop();
if (!idx || idx.volatility !== "live") process.exit(1);
if (!m || m.fresh !== false) process.exit(2);
' "$ROOT/plugins/re-searcher/skills/re-searcher/vault-lib.js" "$V" && ok "absent volatility preserved; fresh defaults false" || no "vol preserve" "rc=$?"

# --- stage 3 hardening: near-duplicate claims collapse to one ---
RD5=$(node "$S" --new-run --topic dedup-topic --session dedup1 --vault "$V" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).runDir)')
cat > "$RD5/plan.md" <<'PLAN'
---
topic: dedup-topic
title: Dedup
scope: general
session: dedup1
aliases: []
questions: []
---

# Plan

```manifest
[{"role": "solo", "file": "findings/solo.md"}]
```
PLAN
{ printf -- '---\nrole: solo\n---\n'; head -c 600 /dev/zero | tr '\0' 'x'; } > "$RD5/findings/solo.md"
cat > "$RD5/claims-staged.jsonl" <<'CS'
{"statement":"The sky is blue","provenance":"model-asserted"}
{"statement":"The sky is blue ","provenance":"model-asserted"}
{"statement":"the SKY is blue.","provenance":"model-asserted"}
{"statement":"The sky is green","provenance":"model-asserted"}
CS
OUT=$(node "$S" "$RD5" --session dedup1 --vault "$V")
node -e '
const r = JSON.parse(process.argv[1]);
if (r.claims.accepted !== 2) { console.error("accepted=" + r.claims.accepted + " (expected 2)"); process.exit(1); }
if (r.claims.duplicates !== 2) { console.error("duplicates=" + r.claims.duplicates + " (expected 2)"); process.exit(2); }
' "$OUT" && ok "near-duplicate claims collapse (blue x3 -> 1, green -> 1)" || no "near-dup" "$OUT"

echo; echo "vault-save: $pass passed, $fail failed"; [ $fail -eq 0 ]
