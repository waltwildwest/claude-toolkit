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
- `save` → harvest THIS session now: `node "$SKILL_DIR/vault-harvest.js" --latest --vault "$VAULT"`,
  then relay its provenanceLine (details: skill §7 + references/harvest.md).
- `harvest <session-id>` → harvest that past session; `harvest --inbox` → drain every
  pending pointer. Report the JSON tallies in one line.
- `doctor` → the librarian: `node "$SKILL_DIR/vault-doctor.js" --vault "$VAULT"` (deterministic
  sweep — fixes + work report JSON), then dispatch the LLM passes from that report per the
  skill's references/doctor.md. One-line report: fixes + work backlog.
- `export <slug>` → `node "$SKILL_DIR/vault-export.js" <slug> --vault "$VAULT"` — relay the
  file path from the JSON (`--no-extracts` for links-only).

As a plugin install this command is namespaced — `/re-searcher:research` — bare
`/research` exists for install.sh copies. Plain-language research asks ("research X",
"have we looked into Y") trigger the skill either way.

Note on allowed-tools: the skill's bash blocks start with a `SKILL_DIR=...` assignment,
which the `Bash(node:*)` prefix matcher does not recognize — expect a permission prompt
on those lines even with this list (same known quirk as /route).
