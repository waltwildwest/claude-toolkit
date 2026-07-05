#!/usr/bin/env bash
# Tests for skills/route/route-learn.js. Run: bash tests/route-learn.test.sh
# Isolated: temp HOME, no side effects.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEARN="$ROOT/plugins/route/skills/route/route-learn.js"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s  <<%s>>\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac }

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "route-learn tests: skipped on native Windows"; exit 0;; esac

H="$(mktemp -d)"
rl(){ HOME="$H" node "$LEARN" "$@"; }
RULES="$H/.claude/route-learn/route-rules.json"

echo "route-learn tests"

# log three "too_low" verdicts for the same task-class on haiku, and one for a fine class
rl log --matched refactor --tier haiku --verdict too_low --task r1 >/dev/null 2>&1
rl log --matched refactor --tier haiku --verdict too_low --task r2 >/dev/null 2>&1
rl log --matched refactor --tier haiku --verdict too_low --task r3 >/dev/null 2>&1
rl log --matched reformat --tier haiku --verdict right --task f1 >/dev/null 2>&1

# 1. status reflects logged decisions
OUT=$(rl status)
{ has "$OUT" "decisions logged: 4" && has "$OUT" "mode:            propose"; } && ok "status counts + default mode propose" || no "status" "$OUT"

# 2. review (propose mode) proposes moving refactor up a tier, does NOT touch rules yet
OUT=$(rl review)
{ has "$OUT" "refactor" && has "$OUT" "sonnet" && has "$OUT" "apply"; } && ok "review proposes refactor->sonnet" || no "review propose" "$OUT"
[ ! -f "$RULES" ] && ok "propose mode did not write rules file" || no "propose wrote rules" "$(cat "$RULES" 2>/dev/null)"

# 3. a well-sized class (reformat, judged right) produces NO proposal
OUT=$(rl review --json)
echo "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(r.proposals.some(p=>p.matched==="reformat")?1:0)' \
  && ok "no proposal for a well-sized class" || no "spurious proposal" "$OUT"

# 4. threshold: 2 sightings is below the default 3 -> no proposal
H2="$(mktemp -d)"; rl2(){ HOME="$H2" node "$LEARN" "$@"; }
rl2 log --matched audit --tier haiku --verdict too_low >/dev/null 2>&1
rl2 log --matched audit --tier haiku --verdict too_low >/dev/null 2>&1
OUT=$(rl2 review --json)
echo "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(r.proposals.length===0?0:1)' \
  && ok "below-threshold pattern not proposed" || no "threshold" "$OUT"
rm -rf "$H2"

# 5. apply --all writes the learned rule (backup created, changelog written)
OUT=$(rl apply --all)
{ has "$OUT" "applied 1" && [ -f "$RULES" ]; } && ok "apply --all writes rules file" || no "apply" "$OUT"
has "$(rl rules)" "\"refactor\" -> sonnet" && ok "learned rule in effect" || no "rules show" "$(rl rules)"
[ -f "$H/.claude/route-learn/changelog.jsonl" ] && ok "changelog written" || no "no changelog" ""

# 6. revert restores (removes the just-applied rule set back to empty prior state)
# first backup exists from the apply; revert should restore the pre-apply (absent->empty) file,
# and POP that backup so a second revert (with no backups left) reports nothing-to-revert.
OUT=$(rl revert)
has "$OUT" "reverted" && ok "revert runs" || no "revert" "$OUT"
OUT=$(node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))))' "$RULES" 2>&1)
has "$OUT" '"rules":[]' && ok "revert restored empty ruleset" || no "revert did not restore empty" "$OUT"
OUT=$(rl revert)
has "$OUT" "nothing to revert" && ok "revert pops backup (second revert has nothing left)" || no "revert did not pop" "$OUT"

# 7. auto mode applies without a separate apply step
H3="$(mktemp -d)"; rla(){ HOME="$H3" ROUTE_LEARN=auto node "$LEARN" "$@"; }
rla log --matched migrate --tier haiku --verdict too_low >/dev/null 2>&1
rla log --matched migrate --tier haiku --verdict too_low >/dev/null 2>&1
rla log --matched migrate --tier haiku --verdict too_low >/dev/null 2>&1
OUT=$(rla review)
{ has "$OUT" "auto" && has "$OUT" "applied"; } && ok "auto mode applies on review" || no "auto apply" "$OUT"
has "$(HOME="$H3" ROUTE_LEARN=auto node "$LEARN" rules)" "\"migrate\" -> sonnet" && ok "auto wrote the rule" || no "auto rule" ""
rm -rf "$H3"

# 8. off mode: log still works, review is disabled
H4="$(mktemp -d)"; rlo(){ HOME="$H4" ROUTE_LEARN=off node "$LEARN" "$@"; }
rlo log --matched xxx --tier haiku --verdict too_low >/dev/null 2>&1
OUT=$(rlo review 2>&1)
has "$OUT" "off" && ok "off mode disables review" || no "off mode" "$OUT"
rm -rf "$H4"

# 9. nudge is silent until enough new decisions, then emits a Stop-hook reminder on stderr
H5="$(mktemp -d)"; rln(){ HOME="$H5" node "$LEARN" "$@"; }
rln log --matched aaa --tier haiku --verdict right >/dev/null 2>&1
OUT=$(rln nudge 2>&1); [ -z "$OUT" ] && ok "nudge silent below threshold" || no "nudge not silent" "$OUT"
rln log --matched aaa --tier haiku --verdict right >/dev/null 2>&1
rln log --matched aaa --tier haiku --verdict right >/dev/null 2>&1
OUT=$(rln nudge 2>&1 >/dev/null)
has "$OUT" "new routing verdicts" && ok "nudge fires above threshold (stderr)" || no "nudge fire" "$OUT"
rm -rf "$H5"

# 10. validation: bad tier / verdict rejected
OUT=$(rl log --matched zzz --tier bogus --verdict right 2>&1); rc=$?
{ [ $rc -eq 1 ] && has "$OUT" "--tier must be"; } && ok "bad tier rejected" || no "bad tier" "$OUT"
OUT=$(rl log --matched zzz --tier haiku --verdict maybe 2>&1); rc=$?
{ [ $rc -eq 1 ] && has "$OUT" "--verdict must be"; } && ok "bad verdict rejected" || no "bad verdict" "$OUT"

# 11. too_high pattern proposes moving DOWN a tier
H6="$(mktemp -d)"; rlh(){ HOME="$H6" node "$LEARN" "$@"; }
rlh log --matched trivial --tier opus --verdict too_high >/dev/null 2>&1
rlh log --matched trivial --tier opus --verdict too_high >/dev/null 2>&1
rlh log --matched trivial --tier opus --verdict too_high >/dev/null 2>&1
OUT=$(rlh review --json)
echo "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8"));const p=r.proposals.find(x=>x.matched==="trivial");process.exit(p&&p.toTier==="sonnet"?0:1)' \
  && ok "too_high proposes a cheaper tier" || no "too_high down" "$OUT"
rm -rf "$H6"

# 12. N applies then N reverts returns to the empty ruleset (undo-stack repro from the review)
H7="$(mktemp -d)"; rl7(){ HOME="$H7" node "$LEARN" "$@"; }
RULES7="$H7/.claude/route-learn/route-rules.json"
rl7 log --matched alpha --tier haiku --verdict too_low >/dev/null 2>&1
rl7 log --matched alpha --tier haiku --verdict too_low >/dev/null 2>&1
rl7 log --matched alpha --tier haiku --verdict too_low >/dev/null 2>&1
rl7 review >/dev/null 2>&1
rl7 apply --all >/dev/null 2>&1   # apply A: backup B0=empty, rules=[alpha]
rl7 log --matched beta --tier haiku --verdict too_low >/dev/null 2>&1
rl7 log --matched beta --tier haiku --verdict too_low >/dev/null 2>&1
rl7 log --matched beta --tier haiku --verdict too_low >/dev/null 2>&1
rl7 review >/dev/null 2>&1
rl7 apply --all >/dev/null 2>&1   # apply C: backup B1=[alpha], rules=[alpha,beta]
N_RULES=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).rules.length)' "$RULES7")
[ "$N_RULES" = "2" ] && ok "setup: 2 applies produced 2 rules" || no "setup rules" "$N_RULES"
rl7 revert >/dev/null 2>&1  # -> restore B1=[alpha], delete B1
rl7 revert >/dev/null 2>&1  # -> restore B0=empty, delete B0
FINAL=$(node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).rules))' "$RULES7" 2>&1)
[ "$FINAL" = "[]" ] && ok "N applies then N reverts returns to empty ruleset" || no "undo stack" "$FINAL"
rm -rf "$H7"

# 13. re-running review when a rule is already in effect produces NO new proposal and NO new backup
H8="$(mktemp -d)"; rl8(){ HOME="$H8" node "$LEARN" "$@"; }
BACKUPS8="$H8/.claude/route-learn/backups"
rl8 log --matched gamma --tier haiku --verdict too_low >/dev/null 2>&1
rl8 log --matched gamma --tier haiku --verdict too_low >/dev/null 2>&1
rl8 log --matched gamma --tier haiku --verdict too_low >/dev/null 2>&1
rl8 review >/dev/null 2>&1
rl8 apply --all >/dev/null 2>&1
COUNT_BEFORE=$(ls "$BACKUPS8" 2>/dev/null | wc -l | tr -d ' ')
OUT=$(rl8 review --json)
echo "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(r.proposals.some(p=>p.matched==="gamma")?1:0)' \
  && ok "already-in-effect rule produces no new proposal" || no "re-proposed" "$OUT"
COUNT_AFTER=$(ls "$BACKUPS8" 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT_BEFORE" = "$COUNT_AFTER" ] && ok "re-review of in-effect rule creates no new backup" || no "backup count changed" "before=$COUNT_BEFORE after=$COUNT_AFTER"
rm -rf "$H8"

# 14. cmdLog rejects a --matched containing a newline or "<"
OUT=$(rl log --matched "$(printf 'bad\nvalue')" --tier haiku --verdict right 2>&1); rc=$?
[ $rc -eq 1 ] && ok "log rejects --matched with newline" || no "newline matched accepted" "$OUT (rc=$rc)"
OUT=$(rl log --matched 'bad<script>' --tier haiku --verdict right 2>&1); rc=$?
[ $rc -eq 1 ] && ok "log rejects --matched with <" || no "angle-bracket matched accepted" "$OUT (rc=$rc)"

# 15. a poisoned decisions.jsonl row (matched with control chars) is ignored by review (auto mode)
H9="$(mktemp -d)"; rl9(){ HOME="$H9" ROUTE_LEARN=auto node "$LEARN" "$@"; }
DIR9="$H9/.claude/route-learn"; mkdir -p "$DIR9"
for i in 1 2 3; do
  printf '{"at":"2026-01-01T00:00:00.000Z","matched":"evil\\u0007payload","tier":"haiku","verdict":"too_low","task":null}\n' >> "$DIR9/decisions.jsonl"
done
OUT=$(rl9 review --json)
echo "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(r.proposals.length===0?0:1)' \
  && ok "poisoned decisions.jsonl produces no proposal" || no "poisoned row materialized a rule" "$OUT"
RULES9="$DIR9/route-rules.json"
if [ -f "$RULES9" ]; then
  R9=$(node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).rules))' "$RULES9")
else
  R9="[]"
fi
has "$R9" "evil" && no "poisoned matched written to rules" "$R9" || ok "poisoned matched never reaches route-rules.json"
rm -rf "$H9"

# 16. nudge writes to stderr, not stdout, and stays silent on a second call with no new decisions
H10="$(mktemp -d)"; rl10(){ HOME="$H10" node "$LEARN" "$@"; }
rl10 log --matched delta --tier haiku --verdict right >/dev/null 2>&1
rl10 log --matched delta --tier haiku --verdict right >/dev/null 2>&1
rl10 log --matched delta --tier haiku --verdict right >/dev/null 2>&1
OUTFILE="$H10/nudge.out"; ERRFILE="$H10/nudge.err"
rl10 nudge >"$OUTFILE" 2>"$ERRFILE"
[ ! -s "$OUTFILE" ] && ok "nudge writes nothing to stdout" || no "nudge wrote to stdout" "$(cat "$OUTFILE")"
has "$(cat "$ERRFILE")" "route-learn" && ok "nudge writes reminder to stderr" || no "nudge stderr empty" "$(cat "$ERRFILE")"
STDERR_SECOND=$(rl10 nudge 2>&1 >/dev/null)
[ -z "$STDERR_SECOND" ] && ok "nudge silent on second call with no new decisions" || no "nudge re-fired" "$STDERR_SECOND"
rm -rf "$H10"

# 21. a stray non-numeric file in backups/ does not misdirect "newest" selection
H11="$(mktemp -d)"; rl11(){ HOME="$H11" node "$LEARN" "$@"; }
for i in 1 2 3; do rl11 log --matched gamma --tier haiku --verdict too_low >/dev/null 2>&1; done
rl11 review >/dev/null 2>&1; rl11 apply --all >/dev/null 2>&1
printf 'garbage' > "$H11/.claude/route-learn/backups/zzz-not-a-seq.json"   # stray, sorts LAST alphabetically
OUT=$(rl11 revert 2>&1); rc=$?
{ [ $rc -eq 0 ] && has "$OUT" "0000000000.json"; } && ok "stray backup file ignored (numeric seq wins)" || no "stray backup misdirects" "rc=$rc $OUT"
N=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).rules.length)' "$H11/.claude/route-learn/route-rules.json")
[ "$N" = "0" ] && ok "revert restored empty despite stray file" || no "stray broke revert" "$N"
rm -rf "$H11"

# 22. concurrent reverts don't crash and don't under-pop the stack
H12="$(mktemp -d)"; rl12(){ HOME="$H12" node "$LEARN" "$@"; }
for m in aaa bbb ccc ddd; do for i in 1 2 3; do rl12 log --matched "$m" --tier haiku --verdict too_low >/dev/null 2>&1; done; rl12 review >/dev/null 2>&1; rl12 apply --all >/dev/null 2>&1; done
BEFORE=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).rules.length)' "$H12/.claude/route-learn/route-rules.json")
for i in 1 2 3 4; do HOME="$H12" node "$LEARN" revert >/dev/null 2>&1 & done
wait
AFTER=$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).rules.length)}catch(e){console.log("ERR")}' "$H12/.claude/route-learn/route-rules.json")
{ [ "$BEFORE" = "4" ] && [ "$AFTER" = "0" ]; } && ok "4 concurrent reverts: no crash, walked back to empty" || no "concurrent reverts" "before=$BEFORE after=$AFTER"
rm -rf "$H12"

rm -rf "$H"
echo
echo "route-learn: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
