#!/usr/bin/env bash
# Tests for plugins/re-searcher/skills/re-searcher/quote-verify.js
# Run: bash tests/researcher-quote.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
Q="$ROOT/plugins/re-searcher/skills/re-searcher/quote-verify.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "researcher-quote tests: skipped on Windows"; exit 0;; esac
W="$(mktemp -d)"
qv(){ node "$Q" --quote-file "$W/q.txt" --source-file "$W/s.md"; }
echo "quote-verify tests"

cat > "$W/s.md" <<'EOF'
# The report

Subagents call tools to store their work in external systems, then pass
lightweight references back to the coordinator. This prevents information
loss during multi-stage processing — and reduces token overhead from copying
large outputs through conversation history.

Token usage by itself explains 80% of the variance.
EOF

# 1. exact substring -> exact
printf 'Token usage by itself explains 80%% of the variance.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"exact"'; } && ok "exact match" || no "exact" "rc=$rcode $OUT"

# 2. whitespace/linebreak differences -> normalized, sourceQuote has source's line break
printf 'Subagents call tools to store their work in external systems, then pass lightweight references back to the coordinator.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"normalized"'; } && ok "normalized whitespace match" || no "normalized" "rc=$rcode $OUT"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.sourceQuote.includes("then pass\nlightweight") ? 0 : 1)' "$OUT" \
  && ok "sourceQuote is exact source bytes" || no "source bytes" "$OUT"

# 3. curly quotes / em-dash in the LLM transcription -> normalized
printf 'loss during multi-stage processing - and reduces token overhead' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"normalized"'; } && ok "dash normalization" || no "dash" "rc=$rcode $OUT"

# 4. paraphrase with high word overlap -> fuzzy, returns real source span
printf 'Subagents store their work in external systems and pass lightweight references to the coordinator' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"fuzzy"'; } && ok "fuzzy relocation" || no "fuzzy" "rc=$rcode $OUT"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.sourceQuote && r.sourceQuote.includes("external systems") ? 0 : 1)' "$OUT" \
  && ok "fuzzy sourceQuote from source" || no "fuzzy bytes" "$OUT"
FUZZY_OUT="$OUT"

# 5. fabricated quote -> none, exit 1
printf 'The coordinator always re-reads every transcript before synthesis begins.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" '"method":"none"'; } && ok "fabrication rejected" || no "fabrication" "rc=$rcode $OUT"

# 6. usage error -> exit 2
node "$Q" --quote-file "$W/q.txt" >/dev/null 2>&1; [ $? -eq 2 ] && ok "usage error -> exit 2" || no "usage exit" "$?"

# 7. negation flip must NOT verify (word-set coverage was polarity-blind; LCS+negation-parity guard fixes it)
cat > "$W/s.md" <<'EOF'
The committee concluded that the compound is not safe for consumer use at all in its current form.
EOF
printf 'The committee concluded that the compound is safe for consumer use in its current form.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" '"method":"none"'; } && ok "negation flip rejected" || no "negation flip" "rc=$rcode $OUT"

# 8. bounded sourceQuote: fuzzy result must not spuriously grow into an oversized blob
node -e 'const r=JSON.parse(process.argv[1]); const q="Subagents store their work in external systems and pass lightweight references to the coordinator"; process.exit(r.sourceQuote && r.sourceQuote.length < (2*q.length + 60) ? 0 : 1)' "$FUZZY_OUT" \
  && ok "fuzzy sourceQuote is bounded" || no "fuzzy bounded" "$FUZZY_OUT"

# 9. IO error: --source-file pointing at a nonexistent path -> exit 2
printf 'anything' > "$W/q.txt"
node "$Q" --quote-file "$W/q.txt" --source-file "$W/does-not-exist.md" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing source file -> exit 2" || no "missing source file" "$?"

# --- Stage 1 amendments: markdown-stripped matching + link-safe windows ---

cat > "$W/s.md" <<'EOF'
# Redirects

Use the **303 See Other** code with a [Location](https://mdn.example/loc) header after PUT requests.
The `Cache-Control` header controls **revalidation** behavior for [shared caches](https://mdn.example/cache) everywhere.
EOF

# (a) plain transcription of marked-up source -> verified via stripped view
printf 'Use the 303 See Other code with a Location header after PUT requests.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"normalized"'; } && ok "markdown-stripped match" || no "stripped" "rc=$rcode $OUT"
node -e 'const r=JSON.parse(process.argv[1]); process.exit(r.sourceQuote.includes("**303 See Other**") && r.sourceQuote.includes("[Location](https://mdn.example/loc)") ? 0 : 1)' "$OUT" \
  && ok "sourceQuote keeps real markup bytes" || no "markup bytes" "$OUT"

# backticks + bold + link inside one quoted span
printf 'The Cache-Control header controls revalidation behavior for shared caches everywhere.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 0 ] && has "$OUT" '"method":"normalized"'; } && ok "backtick+bold+link stripped match" || no "dense markup" "rc=$rcode $OUT"

# (c) a match ending inside a link label must not clip mid-link
printf 'code with a Location' > "$W/q.txt"
OUT=$(qv); rcode=$?
node -e 'const r=JSON.parse(process.argv[1]); if(!r.verified) process.exit(1); const q=r.sourceQuote; const opens=(q.match(/\[/g)||[]).length; const full=(q.match(/\]\([^)]*\)/g)||[]).length; process.exit(opens===full ? 0 : 1)' "$OUT" \
  && ok "sourceQuote never clips mid-link" || no "link clip" "rc=$rcode $OUT"

# regression: negation-flip must still be rejected (guards not weakened)
cat > "$W/s.md" <<'EOF'
The device flow is not required for public clients and should be avoided when the standard flow works.
EOF
printf 'The device flow is required for public clients and should be avoided when the standard flow works.' > "$W/q.txt"
OUT=$(qv); rcode=$?
{ [ $rcode -eq 1 ] && has "$OUT" '"method":"none"'; } && ok "negation flip still rejected" || no "negation" "rc=$rcode $OUT"

echo; echo "quote-verify: $pass passed, $fail failed"; [ $fail -eq 0 ]
