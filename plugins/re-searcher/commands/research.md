---
description: Vault-first research — recall prior claims, run light/full research, persist plans, findings, sources and verified claims. Runs the re-searcher skill.
allowed-tools: Bash(node:*), Write, Read, Agent, Grep, Glob, WebSearch, WebFetch
---
Run the **re-searcher** skill with this input: `$ARGUMENTS`

Routing:
- Empty or a question → the full state machine (recall first, always).
- `--fresh <question>` → skip recall, research fresh, still persist to the vault.
- `correct …` → the correction flow (skill references/correct.md): supersede/retract/
  contradict events applied via vault-save.js --events.
- `save` / `harvest` → NOT BUILT YET (stage 2 — the harvester). Say so honestly; offer
  to keep findings in a run dir manually if the user needs capture right now.
- `doctor` → NOT BUILT YET (stage 3 — the librarian). Say so honestly.

As a plugin install this command is namespaced — `/re-searcher:research` — bare
`/research` exists for install.sh copies. Plain-language research asks ("research X",
"have we looked into Y") trigger the skill either way.

Note on allowed-tools: the skill's bash blocks start with a `SKILL_DIR=...` assignment,
which the `Bash(node:*)` prefix matcher does not recognize — expect a permission prompt
on those lines even with this list (same known quirk as /route).
