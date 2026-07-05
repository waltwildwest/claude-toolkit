# Full path — fan-out mechanics

## plan.md (persist BEFORE fan-out)

Start from `node vault-init.js --template plan`. The frontmatter feeds the index — it is
the grep-bait future recall depends on:
- `topic:` the slug (MUST match the run folder's topic segment; vault-save enforces it)
- `aliases:` 3–5 synonyms someone might probe with later; `questions:` 3–5 anticipated
  future questions, phrased the way they'd actually be asked
- `scope:` `general` or `project:<name>` — cross-project recall announces itself
The ```manifest fenced block is the completeness contract: a JSON array with one
`{"role": ..., "file": "findings/<role>.md"}` per agent. `--check-staging` compares it
against reality; a manifest you didn't write means capture can't be checked by anyone —
including a resumed session after compaction.

## Briefing agents

Emit `node vault-init.js --template task-spec` and fill it per agent: ONE core objective,
an explicit scope boundary, the output file from the manifest, the run-dir path, and the
vault dir. Budgets (Anthropic's): straightforward 1 agent / 3–10 calls; comparisons 2–4
agents; open landscape 5–10 with an explicit stop-at-diminishing-returns line. Agents:
- fetch via vault-fetch so sources are cached and sourceIds exist for claims; on exit 2
  (low confidence) escalate: better URL → browser MCP if available → WebFetch, stored
  labeled `provenance: extraction` — never fake grounding
- Write findings with the finding template (≥500 bytes of real content, frontmatter
  `role:` matching the manifest)
- return ONLY a ≤2k summary + the file path (full findings live on disk, not in context)

## After fan-out

1. `vault-save.js --check-staging <run-dir>` — exit 2: re-request the missing/stub
   finding from that agent once; still missing → record it under Gaps in synthesis.md
   and move on (a visible gap beats a fake completion).
2. Read the findings FILES before synthesizing — never synthesize from return blurbs.
3. synthesis.md sections: Verdict · Key claims · Gaps · How to re-verify · Related.
4. Stage claims (see references/claims.md), then persist:
   `vault-save.js <run-dir> --session <session-id> --transcript <path>...`
   Transcript paths: `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` (plus subagent
   transcript files if you can identify them). Copies are gzipped into the run folder so
   provenance survives Claude Code's retention window; a missing path is a warning, not
   a failure.
5. Read the persist JSON: `status: "partial"` → quarantined records are in the run's
   claims-rejected.jsonl with reasons; say "claims: partial (N quarantined)" in the
   answer. `claims.ids` lists the assigned claim ids (useful for follow-up events).
