---
description: Hand the current task off to a fresh session that mirrors this session's model, effort and permission mode. Runs the `handoff` skill.
allowed-tools: Write, Bash(node:*), Bash(mkdir -p ~/.claude/handoffs)
---
Run the **handoff** skill to hand off this task to a fresh, mirrored session, following its
steps exactly (write the brief, spawn the mirrored session, relay the output).

Task to hand off: `$ARGUMENTS`  — if empty, infer the most clearly *pending* next task from the
conversation (something discussed but not started).
