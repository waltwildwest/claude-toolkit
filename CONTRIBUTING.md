# Contributing

Thanks for looking. This is a small, opinionated repo; a few ground rules keep it that way.

- **The skill is the source of truth.** `skills/handoff/SKILL.md` (plus `handoff-spawn.js`) and `skills/route/SKILL.md` (plus `route-report.js` and `route-cache.js`) hold the real logic. The `/handoff` and `/route` commands are thin wrappers — don't copy logic into them, and don't let them drift from their skills.
- **Run all the tests before a PR.** `for t in tests/*.test.sh; do bash "$t"; done` — all 78 should pass (handoff, route-cache, route-report suites). If you change spawn, cache, or report behaviour, add a case that would have caught the old behaviour.
- **Keep it standalone.** No new runtime dependencies: the `claude` CLI always; a system Node.js only for `route`'s cache/report (Claude Code does not provide `node` on PATH itself). Nothing should phone home. Nothing should write outside `~/.claude/handoffs` (handoff) or `~/.claude/route-cache` (route).
- **Match the tone.** Plain and honest over clever. If a claim can't be verified, cut it.

Open an issue first for anything larger than a fix, so we can agree on the shape before you build it.
