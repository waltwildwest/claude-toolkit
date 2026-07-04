# Contributing

Thanks for looking. This is a small, opinionated repo; a few ground rules keep it that way.

- **The skill is the source of truth.** `skills/handoff/SKILL.md` (plus `handoff-spawn.js`) holds the real logic. The `/handoff` command is a thin wrapper — don't copy logic into it, and don't let the two drift.
- **Run the tests before a PR.** `bash tests/handoff.test.sh` — all 13 should pass. If you change spawn behaviour, add a case that would have caught the old behaviour.
- **Keep it standalone.** No new runtime dependencies: Node and the `claude` CLI only. Nothing should phone home, and nothing should write outside `~/.claude/handoffs`.
- **Match the tone.** Plain and honest over clever. If a claim can't be verified, cut it.

Open an issue first for anything larger than a fix, so we can agree on the shape before you build it.
