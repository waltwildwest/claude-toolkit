# /research correct — fixing the record

The registry is append-only: corrections are EVENTS, never edits.

1. Find the claim ids: `node vault-search.js "<topic terms>" --vault "$VAULT"` prints
   ids per served claim, or read `topics/<slug>/topic.md` (ids are on every line).
2. Write the events to a temp file with the Write tool (never inline shell), one JSON
   object per line:
   - replace: `{"op":"supersede","claim":"clm_OLD","by":"clm_NEW","reason":"..."}`
     — if the correct claim doesn't exist yet, run the research (or stage it in a run)
     first; supersede needs a real registered target.
   - withdraw: `{"op":"retract","claim":"clm_BAD","by":"human","reason":"..."}`
   - mark conflict: `{"op":"contradict","claim":"clm_A","by":"clm_B","reason":"..."}`
3. Apply: `node vault-save.js --events <file> --vault "$VAULT"` — cycle-creating
   supersedes are rejected by the DAG check; rejects print with reasons.
4. Views regenerate and the vault auto-commits. Verify with a fresh vault-search: the
   old claim should now appear only as `↳ supersedes` history, never as live.

Contradictions stay double-served and flagged until a supersede resolves them —
resolution is a human decision, never a silent one.
