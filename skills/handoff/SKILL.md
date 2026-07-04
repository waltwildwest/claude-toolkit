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

**2. Spawn the mirrored session.** Run the spawner bundled with this skill (it locates itself, so
it works wherever the skill is installed):

```bash
node "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/handoff}/handoff-spawn.js" --dir <projectDir> --handoff <handoffFile>
```

It reads this session's model + effort (`$CLAUDE_EFFORT`) + permission mode (from the session
transcript) and launches a new session with them. It routes by where you are: in the Claude
desktop app it spawns nothing and prints the pickup steps (nothing outside the app can open a
desktop session); in tmux it opens a new window; on macOS without tmux it opens a new Terminal
window; otherwise it prints the exact command to run.

**3. Hand the user the continuation.**
- **If the spawner printed pickup steps (desktop app):** check whether a session-spawning tool
  is available (e.g. `spawn_task` from the desktop harness). If so, call it — title
  `Pick up handoff: <slug>`, prompt: *"A previous session handed this task off to you. Read the
  handoff file at `<handoffFile>`, state the task in one line, then execute it."* — and tell the
  user a one-click chip is waiting. If no such tool exists, relay the spawner's steps: open a
  new session in this project and run the **`pickup`** skill.
- **Otherwise** relay the spawner output verbatim (it opened a window or printed the command).
- Either way, tell the user this session is now safe to `/clear`. The brief stays at the path
  from step 1, so `pickup` works as a fallback in any new session.
