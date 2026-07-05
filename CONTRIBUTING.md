# Contributing

Thanks for looking. This repo is the **marketplace index** — the tools themselves each
live in their own repo, and that's where code contributions go:

- [handoff](https://github.com/waltwildwest/handoff)
- [route](https://github.com/waltwildwest/route)
- [re-searcher](https://github.com/waltwildwest/re-searcher)

Ground rules that apply across all of them:

- **The skill is the source of truth.** Each tool's SKILL.md plus its scripts hold the
  real logic. The slash commands are thin wrappers — don't copy logic into them, and
  don't let them drift from their skills.
- **Run the tests before a PR.** Every tool repo has `./run-tests.sh`; all suites must
  pass. If you change behaviour, add a case that would have caught the old behaviour.
- **Keep it standalone.** No new runtime dependencies: the `claude` CLI always; a system
  Node.js only where a tool already requires it. Nothing phones home. Nothing writes
  outside the tool's own documented directories under `~/.claude/`.
- **Match the tone.** Plain and honest over clever. If a claim can't be verified, cut it.

For this index repo specifically: PRs are welcome for the README, the marketplace
manifest, and metadata fixes. Open an issue first for anything larger, so we can agree
on the shape before you build it.
