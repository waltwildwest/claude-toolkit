# Harvest — capturing sessions after the fact

## What a harvest produces

A light-style run under topics/<topic>/runs/<id>/ containing:
- plan.md — classification: harvest, a 1-role manifest, aliases seeded from the topic guess
- findings/harvest.md — the deterministic digest: session summary, every Write payload
  (.md payloads embedded, others listed) with `transcript:<line>` pointers, source-tool
  events (WebSearch / WebFetch / mcp__*), and the transcript path
- synthesis.md — the session's final assistant text, labeled harvested
- lineage.json + transcripts/*.gz — persisted via vault-save --light, so the lock, views
  and auto-commit machinery is the same as any run
NO claims are authored: harvested content is model output — the librarian (stage 3)
verifies and promotes it. Treat harvested material as model-asserted context, not verdicts.

## Mechanics

- Extraction is deterministic (transcript-mine.js): keyed on the embedded Messages shape
  only, never the envelope; unknown transcript majors warn loudly and degrade, never abort.
- Idempotent: a session that appears in ANY run's lineage.json is skipped
  (status already-harvested). Re-running /research save is always safe.
  Known limitation: the idempotence check is unlocked, so two SIMULTANEOUS
  harvests of the same session could each create a run — harmless duplication
  at worst (the stage-3 doctor's orphan/duplicate sweep is the cleanup path);
  don't script parallel harvests of one session.
- If the persist step fails, the staged run dir is reported as `orphanedRun`
  (it has no lineage.json, so it never blocks a retry — inspect or delete it).
- Resolution order: existing file path → session-id lookup (<projects>/*/<id>.jsonl) →
  --latest (newest .jsonl in the cwd's project dir). CLAUDE_PROJECTS_DIR overrides
  ~/.claude/projects (tests use this; you should not need it).
- The inbox (inbox.jsonl) holds Stop-hook pointers: {session, transcript, subagents, cwd,
  topicGuess, ts, transcript_dies}. Appends are lock-free single lines (the hook must never
  stall); REMOVALS rewrite the file under the vault lock and auto-commit
  (`research: drain inbox (N pointers)`). Subagent transcripts ARE mined (stage 3): every agent-*.jsonl under the
  session's subagents/ dir is folded into the digest (## Subagents) and
  gzipped into the run beside the main transcript. Drains report an `errors`
  tally; error pointers stay queued for the next drain.
- Bulk drain (--inbox): pointers whose transcript file no longer exists are dropped as
  transcript-missing — transcripts rot on Claude Code's retention schedule;
  transcript_dies is the estimate (RESEARCH_TRANSCRIPT_TTL_DAYS tunes it, default 30).
- The Stop hook (inbox-note.js) is silent, exits 0 always, no-ops without a vault, and is
  disabled with RESEARCH_INBOX=off.

## When to harvest

- On a recall breadcrumb (`unharvested session … may cover this`) — run exactly the printed
  command, then re-run the search.
- When the user says "save this" / runs /research save after ad-hoc research.
- Bulk (`harvest --inbox`) only when the user asks — capture is cheap, but runs are
  user-visible artifacts; never drain on your own initiative.
