---
name: route
description: Spend the expensive model only where it earns its price. Size every piece of delegable work, check a local result cache before dispatching anything, run big jobs as parallel cheap agents under a strong-model review, and measure the whole thing against honest baselines with route-report. Use when delegating work to subagents, when a job is big enough to split, when identical work may have been done before, or when the user asks what their setup costs or saves.
---

You are about to spend money on model calls. Before any delegation, walk these four
steps in order. The theme of all four: the top model's job is judgment, everything
else is overhead to be driven down.

Every step below that touches `route-cache.js` resolves the skill directory the same
way — do this once, early, and reuse `$SKILL_DIR`:

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
[ -d "$SKILL_DIR" ] || SKILL_DIR="$HOME/.claude/skills/route"
CACHE="$SKILL_DIR/route-cache.js"
```

`${CLAUDE_SKILL_DIR}` is replaced by literal text at skill-load time — the `:-default`
shorthand never fires, it only ever gets an empty or missing directory, so it never
resolves plugin installs (e.g. under `~/.claude/plugins/cache/.../skills/route`). The
`[ -d ... ] ||` fallback is required, not cosmetic. **Shell state does not persist
between Bash tool calls** — re-run these three lines at the top of every self-contained
bash block below, don't assume a variable set earlier is still there.

Also guard every `node` call: Claude Code does not put `node` on PATH itself, and only a
separately-installed system Node makes the cache and report work. Before any node
command, check for it and skip cleanly if it's missing — don't error, tell the user:

```bash
command -v node >/dev/null || { echo "route: cache/report need a system Node.js on PATH; skipping"; }
```

**1. Size the work, relative to the model you're running.** Routing is always relative
to your current model, never to fixed tiers. First read the plan for the model you're on
— it detects your session model and only ever routes work *down*, never to a model as
costly as your own:

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"; [ -d "$SKILL_DIR" ] || SKILL_DIR="$HOME/.claude/skills/route"
command -v node >/dev/null && node "$SKILL_DIR/route-plan.js"
```

It prints which model takes grunt work, which takes standard work, and confirms that
reasoning and the final review stay on *your* model. If you're already on the cheapest
tier it tells you to do the work yourself instead of routing up. Use the tiers it prints
(the `haiku`/`sonnet` names below are the defaults for a top-tier brain).

Then size each task with two questions:

- *Can I write its acceptance criteria in two sentences?* If not, it isn't delegable at
  any price — keep it in this session. Architecture, ambiguous debugging, and the final
  review of delegated output always stay here, on your model.
- *Would a careful intern with the files and the instructions get it right?* If yes, it's
  grunt work — searching, reformatting, extracting, collecting excerpts, running commands
  and reporting output, first drafts from a tight spec — send it to the plan's grunt tier
  (`haiku` by default). If it needs real implementation skill but the path is clear —
  multi-file changes from a plan, tests that follow existing patterns, bounded research —
  send it to the standard tier (`sonnet` by default).

If a cheap-tier result comes back wrong, do not re-roll the same prompt on the same
model. Tighten the instructions once, or move up one tier. Wrong twice = do it yourself;
the escalation already cost more attention than the task deserved.

**2. Check the cache before dispatching.** Mechanical work repeats: the same file gets
summarized in two sessions, the same extraction runs after a `/clear`. The result cache
makes the second time free. Check it only when a repeat is plausible — file-anchored
work, or anything expensive enough that one future hit pays for the check; skip it for
one-off trivia.

The task and result travel through **files, never shell arguments or command
substitution** — a subagent prompt can contain backticks, `$(...)`, quotes, anything,
and it must never be interpolated into a command line.

1. Write the *verbatim subagent prompt* to a temp file with the **Write tool** (not bash
   `echo`/heredoc) — e.g. `/tmp/route-prompt-<slug>.txt`, or under the system temp dir.
   Never build this file by piping a variable through bash.
2. In one self-contained bash block, re-establish `SKILL_DIR`/`CACHE` (per above) and
   check the cache:

   ```bash
   SKILL_DIR="${CLAUDE_SKILL_DIR}"; [ -d "$SKILL_DIR" ] || SKILL_DIR="$HOME/.claude/skills/route"
   CACHE="$SKILL_DIR/route-cache.js"
   command -v node >/dev/null || { echo "route: cache/report need a system Node.js on PATH; skipping"; exit 0; }
   KEY=$(node "$CACHE" key --task-file "$PROMPT_FILE" --file "<input1>" [--file "<input2>"...])
   node "$CACHE" get "$KEY"   # hit: result on stdout, age + source model on stderr
   ```

   Quote every `--file` path — inputs may contain spaces.

On a hit: reuse the result and relay its age and source model to the user, done. On a
miss: dispatch the subagent as planned, **review its output**, write the reviewed output
to a temp file with the **Write tool**, then in *another* self-contained bash block
re-derive the same key (the prompt file from step 1 is still on disk) and store it:

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"; [ -d "$SKILL_DIR" ] || SKILL_DIR="$HOME/.claude/skills/route"
CACHE="$SKILL_DIR/route-cache.js"
command -v node >/dev/null || { echo "route: cache/report need a system Node.js on PATH; skipping"; exit 0; }
KEY=$(node "$CACHE" key --task-file "$PROMPT_FILE" --file "<input1>" [--file "<input2>"...])
node "$CACHE" put "$KEY" --task-file "$PROMPT_FILE" --model haiku --result-file "$RESULT_FILE"
```

The key hashes the normalized instruction plus the exact bytes of every input file, so
edits invalidate automatically and renames still hit. Hard exclusions — never cache:
work that reads the network, depends on time or conversation context, involves
judgment, or whose output contains secrets. Store only reviewed output, never a raw
subagent dump. If a cheap-tier result was wrong and you escalated, overwrite the entry
with the better output; if the user asks to redo work, skip `get` and overwrite. Upkeep:
`stats`, `prune --days N [--max-mb N]`.

**3. Fan out what's parallel.** A job made of independent pieces (audit N files, migrate
N call sites, answer N research questions) should not run sequentially on one strong
model. Write one self-contained prompt per piece, dispatch them all on the cheapest
capable tier in a single message (very wide jobs in batches of about ten, merged as you
go), then review the merged output here against one checklist: is each piece correct,
are the pieces consistent with each other, and did any piece flag uncertainty. Cheap
generation under expensive review is the entire trade — skip the review and you've just
bought N cheap mistakes.

Each shard is its own cache unit: it has its own verbatim prompt file, so `get`/`put` it
independently, same as step 2 — check the cache for a shard before dispatching it, and
after review, store each shard's reviewed output keyed by that shard's own prompt file.
A hit on shard 3 doesn't need shard 1 through 10 re-run to find out.

Fan-out pays twice. The obvious win is price. The quieter one is context: the agents
absorb the bulk reading, and those file dumps die with them instead of rotting this
session's window — only conclusions come back. Routing protects the budget and the
orchestrator's attention with the same move.

Do not fan out when pieces feed each other, when one agent could finish the whole job
comfortably, or when merging would cost more attention than the work itself.

**4. Prove it, don't vibe it.** When anyone asks what this saves, reuse `$SKILL_DIR` and
the same node guard from above:

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"; [ -d "$SKILL_DIR" ] || SKILL_DIR="$HOME/.claude/skills/route"
REPORT="$SKILL_DIR/route-report.js"
command -v node >/dev/null || { echo "route: cache/report need a system Node.js on PATH; skipping"; exit 0; }
node "$REPORT" [--days 30] [--project substr] [--json]
```

route-report reads the local transcripts under `~/.claude/projects` (read-only, nothing
leaves the machine), dedupes streamed messages, prices every token at current API rates,
and prints the actual cost next to three baselines: the naive one (top model on every
call, no cache), the top model with cache (what routing alone saved), and the actual mix
with cache off (what caching alone saved). Always quote a savings number together with
its baseline — the flattering number and the honest one are both in the output on
purpose.
