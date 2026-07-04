---
description: Size a task and dispatch it on the cheapest capable model, or print the honest cost/savings report. Runs the `route` skill.
allowed-tools: Bash(node:*), Write, Agent, Read, Grep, Glob
---
Run the **route** skill. As a plugin install this command is namespaced —
`/route:route` — not bare `/route`; bare `/route` only exists if you installed via
`./install.sh` instead. Plain-language requests ("delegate this", "what does this cost")
trigger the skill either way.

Note on `allowed-tools` above: it does not blanket-authorize the skill's bash. The
skill's snippets start with a `SKILL_DIR=...` assignment and `KEY=$(node ...)` command
substitution, which the `Bash(node:*)` prefix matcher does not recognize as a `node`
invocation — expect a permission prompt on those lines even with this command's
allowed-tools set. `Write` is listed because step 2 now writes the subagent prompt and
reviewed result to temp files instead of passing them as shell arguments.

Input: `$ARGUMENTS`
- If it is `report` (optionally with `--days N`, `--project substr`, `--baseline model`,
  `--json`), run route-report.js with those flags and relay the output, including all
  three baselines. `--baseline model` reprices everything against a specific model's
  rate instead of the default top-tier baseline.
- Otherwise treat it as a task: size it into a tier per the skill's table, say which tier
  and why in one line, then dispatch it on that tier (or keep it in this session if it's
  judgment tier). Fan out per the skill if it splits into independent pieces.
- If empty, run the report for the last 30 days.
