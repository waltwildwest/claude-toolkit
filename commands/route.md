---
description: Size a task and dispatch it on the cheapest capable model, or print the honest cost/savings report. Runs the `route` skill.
allowed-tools: Bash(node:*), Agent, Read, Grep, Glob
---
Run the **route** skill.

Input: `$ARGUMENTS`
- If it is `report` (optionally with `--days N`, `--project substr`, `--json`), run
  route-report.js with those flags and relay the output, including all three baselines.
- Otherwise treat it as a task: size it into a tier per the skill's table, say which tier
  and why in one line, then dispatch it on that tier (or keep it in this session if it's
  judgment tier). Fan out per the skill if it splits into independent pieces.
- If empty, run the report for the last 30 days.
