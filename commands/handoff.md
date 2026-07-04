---
description: Hand the current task off to a fresh claude session that mirrors this session's model, effort and permission mode, then /clear and move on
allowed-tools: Write, Bash(node ~/.claude/commands/lib/handoff-spawn.js:*), Bash(mkdir -p ~/.claude/handoffs)
---
Hand a task off to a NEW claude session. You are the context-holder: write everything the
fresh session needs, because it starts cold. The new session is launched with the SAME model,
effort level, and permission mode as this one, so the transition is seamless.

The task to hand off: `$ARGUMENTS` — if empty, infer the most clearly *pending* next task from
the conversation (something discussed but not started). If nothing is pending, ask the user
what to hand off and stop.

**1. Write the handoff file** (Write tool) to `~/.claude/handoffs/<slug>-<HHMM>.md` where
`<slug>` is 2-4 kebab-case words naming the task. The path must contain only
`[A-Za-z0-9/._-]` (no spaces). Run `mkdir -p ~/.claude/handoffs` first. Structure:

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

**2. Spawn the mirrored session** (project dir = where the task's code lives):

```bash
node ~/.claude/commands/lib/handoff-spawn.js --dir <projectDir> --handoff <handoffFile>
```

It reads this session's model + effort (`$CLAUDE_EFFORT`) + permission mode (from the session
transcript) and launches the new session with them. In tmux it opens a new window; otherwise it
prints the exact command to paste into a fresh terminal.

**3. Relay the spawn output verbatim** to the user (it reports the mirrored model/effort/permission),
and remind them: this session is now safe to `/clear` for the next task.
