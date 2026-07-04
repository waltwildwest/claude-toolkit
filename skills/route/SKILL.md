---
name: route
description: Cost-aware model routing for delegated work. Size every delegable task into a tier (cheap/standard/judgment), dispatch subagents on the cheapest model that can do the job, fan big jobs out across parallel cheap agents with a strong-model review. Also prints an honest savings report (route-report) from your real session transcripts. Use when delegating work to subagents, when a task is big enough to split, or when the user asks what their setup costs or saves.
---

Route delegated work to the cheapest model that can do the job, and prove the savings
honestly. Two parts: a sizing policy you apply whenever you dispatch subagents, and a
report script that measures what it actually saved.

## 1. Size before you dispatch

Every task you're about to delegate gets a tier. Judge by what the task NEEDS, not by
how important the parent project is.

| Tier | Model to pass | The task is... |
|---|---|---|
| grunt | `haiku` | mechanical: read/search files, reformat, rename, collect excerpts, run commands and report output, first drafts from a tight spec |
| standard | `sonnet` | multi-file implementation from a clear plan, tests from existing patterns, research with synthesis, code review of a bounded diff |
| judgment | main session (don't delegate) | architecture, tricky debugging, anything ambiguous, final review of everything the cheap tiers produced |

Rules of thumb:
- Delegating DOWN a tier and reviewing the output beats doing it yourself at the top tier.
- If you can't write acceptance criteria for the task in two sentences, it's judgment tier.
- When a grunt-tier result comes back wrong, don't retry harder on the same tier; either
  tighten the prompt or promote one tier. Two failures = do it yourself.
- The main session reviews EVERY delegated result before using it. Cheap generation plus
  expensive review is the whole trade.

## 2. Fan out big jobs

When a job is many independent pieces (audit N files, migrate N call sites, research N
questions), don't run it sequentially on one strong model:

1. Split into independent pieces with identical, self-contained prompts.
2. Dispatch all pieces in parallel on the cheapest tier that fits (one message, many
   Agent calls).
3. Review the merged output in the main session against one checklist: correctness,
   consistency across pieces, and anything a piece flagged as uncertain.

Do NOT fan out when pieces depend on each other's results, when the job is small enough
for one agent, or when merging the pieces would cost more attention than doing the work.

## 3. Measure it (route-report)

To answer "what did this save?", run:

```bash
node "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/route}/route-report.js" [--days 30] [--project substr] [--json]
```

It reads your local transcripts (`~/.claude/projects`, nothing leaves the machine),
dedupes streamed messages, prices every token at current API rates, and prints your
actual cost next to three baselines:

- **naive** (top model on every call, no cache) — the headline number,
- **top model with cache** — what routing alone saved,
- **your mix with cache off** — what caching alone saved.

Quote savings WITH the baseline. "90% vs naive" and "40% vs a sensible setup" can both
be true; say which one you mean. The report prints both so you don't have to choose.
