# Staging claims — claims-staged.jsonl

One JSON object per line, written into the run dir before persist. Two record shapes.

## Claim records

```json
{"statement": "Remote MCP servers must use OAuth 2.1", "quote": "requires OAuth 2.1 with PKCE",
 "source": "src_3f9a12", "provenance": "verbatim-grounded", "confidence": "high",
 "type": "finding", "found_by": "spec-reader", "tool": "websearch",
 "locator": "https://spec.example/auth#section-2", "ref": "c1"}
```

Rules (enforced by vault-save; rejects land in claims-rejected.jsonl with reasons):
- `statement` (required): one falsifiable sentence. The claim IS the statement; the
  quote is its evidence.
- `provenance`: `verbatim-grounded | model-asserted | human-asserted`. Never stage
  `externally-verified` — the doctor grants that (stage 3), staging it is rejected.
- `verbatim-grounded` requires `source` (a sources/<id>.md id printed by vault-fetch)
  AND `quote`. The quote is verified mechanically against the cached extraction:
  found → rewritten to exact source bytes; not found → the claim is KEPT but downgraded
  to model-asserted with a note. So: copy quotes from the extraction text you actually
  read — never compose them from memory.
- `confidence`: `high | medium | speculation` (default medium).
  `type`: `finding | absence` (default finding).
- **absence claims** record "searched X, found nothing as of <date>": put the null
  result in the statement and add `"queries": [...]` with what you tried — exhaustive
  null results should never be silently re-run.
- `ref` (optional): a batch-local handle so staged events can point at this claim before
  its real id exists. Stripped before registration.
- `v`, `id`, `run`, `date`, `topic` are script-assigned — do not stage them. Unknown
  extra fields are preserved verbatim.

## Event records (same file; or standalone via `vault-save.js --events`)

```json
{"op": "supersede", "claim": "clm_abc123", "by": "ref:c1", "reason": "newer spec revision"}
{"op": "contradict", "claim": "ref:c1", "by": "ref:c2", "reason": "sources disagree"}
{"op": "retract", "claim": "clm_abc123", "by": "human", "reason": "wrong research"}
```

- `claim`/`by` accept real ids (`clm_…`) or batch refs (`ref:<name>`).
- `supersede`: `by` is the replacing claim. Cycle-creating edges are rejected (DAG
  check). Superseded claims are preserved as history; recall serves the terminal claim.
- `contradict`: symmetric — BOTH claims keep serving, flagged, until a human resolves
  with an explicit supersede.
- `verify` is doctor-granted (stage 3); staging it is rejected.

## When sources conflict within a run

Record BOTH claims (each with its own source), add a mutual contradict event via refs,
and state in synthesis.md which source tier won and why. Never silently pick a winner.
