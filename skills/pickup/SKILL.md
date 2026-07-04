---
name: pickup
description: Load and continue from the most recent handoff brief. Use at the start of a fresh session that is picking up a task handed off by the handoff skill (especially in the Claude desktop app, where a new session can't be auto-spawned).
---

Pick up a handed-off task by reading the most recent handoff brief and continuing it.

**1. Find the latest brief.** List `~/.claude/handoffs/` and take the most recently modified
`.md` file:

```bash
ls -t ~/.claude/handoffs/*.md 2>/dev/null | head -1
```

If the directory is empty or missing, tell the user there's no handoff to pick up and stop.

**2. Read it** (Read tool) and state the task in one line so the user can confirm you have the
right one.

**3. Execute it.** Honor the brief's Context (do not relitigate decisions already made), stay
inside its Out-of-scope boundaries, and finish by running its "Verify before done" check.

The brief was written by a previous session that had full context; treat it as the source of
truth for what to do and why.
