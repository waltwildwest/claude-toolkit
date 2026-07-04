---
name: handoff
description: Hand the current task off to a fresh Claude session with a clean written brief, mirroring this session's model, effort and permission mode. Use when the context is getting long, or you want to start fresh on the next task without losing where you were. Works in the terminal (auto-spawns) and the desktop app (writes the brief for a new session to pick up).
---

Hand a task off to a NEW session. You are the context-holder: write everything the fresh
session needs, because it starts cold.

The task to hand off comes from the user's request; if none is given, infer the most clearly
*pending* next task from the conversation (something discussed but not started). If nothing is
pending, ask what to hand off and stop.

**1. Write the handoff brief** (Write tool) to `~/.claude/handoffs/<slug>-<HHMM>.md`, where
`<slug>` is 2-4 kebab-case words. The path must contain only `[A-Za-z0-9/._-]` (no spaces).
Run `mkdir -p ~/.claude/handoffs` first. Structure:

```markdown
# Handoff: <task in one line>

## Task
<what to do, concretely — acceptance criteria the new session can verify>

## Context
- Project: <absolute project dir> (branch: <branch>)
- Relevant files: <path:line — why each matters>
- Decisions already made: <constraints the new session must NOT relitigate>
- Gotchas: <anything you learned the hard way this session>

## Verify before done
<the exact command/check that proves the task works>

## Out of scope
<what NOT to touch, if relevant>
```

Be specific: paste short code excerpts rather than "look at the auth module." The new session
has zero memory of this conversation.

**2. Spawn the continuation.** The pickup prompt is always: *"A previous session handed this
task off to you. Read the handoff file at `<handoffFile>`, state the task in one line, then
execute it."*

**In the Claude desktop app** (`$CLAUDE_CODE_ENTRYPOINT` contains `desktop`), pick by state:
- **If a `spawn_task`-style tool is available AND the task doesn't depend on uncommitted
  changes** (non-git project, or clean/committed tree): call it — title
  `Pick up handoff: <slug>`, prompt as above. The chip **auto-runs on one click**, but in a
  fresh worktree, which is why uncommitted work rules it out.
- **Otherwise** run the spawner below — on desktop it deep-links a new session tab
  (`claude://code/new`) with the prompt prefilled in the real project directory; the user
  presses Enter and re-approves folder access.

**Everywhere else** run the spawner:

```bash
node "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/handoff}/handoff-spawn.js" --dir <projectDir> --handoff <handoffFile>
```

It reads this session's model + effort (`$CLAUDE_EFFORT`) + permission mode (from the session
transcript) and launches a new session with them: in tmux a new window; on macOS without tmux
a new Terminal window; otherwise it prints the exact command to run. (Desktop deep links can't
carry flags, so desktop continuations use the app's defaults — the brief carries the context.)

**3. Hand the user the continuation.** Relay what happened (chip waiting / tab opened — press
Enter / window spawned / command to paste) and tell them this session is now safe to `/clear`.
The brief stays at the path from step 1, so the **`pickup`** skill works as a fallback in any
new session.
