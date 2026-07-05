# claude-toolkit

> Small, honest tools for [Claude Code](https://claude.com/claude-code) that work in both the CLI and the desktop app.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-marketplace-black.svg)](https://claude.com/claude-code)

Tools I actually use every day. **Each one lives in its own repo, stands on its own
merits, and installs on its own** — this repo is the marketplace index that ties them
together. No framework, no lock-in, nothing phones home.

That one-plugin-per-repo shape is deliberate. The unit of install, enable and disable in
Claude Code is the *plugin* — mega-bundles force you to adopt (and context-load) a
hundred skills to use one. Here you add the marketplace once and install exactly the
tools you want; each repo's README goes deep on the process, the capabilities, and the
why of that single tool.

## The tools

| Tool | One line | Why it exists |
|---|---|---|
| [**handoff**](https://github.com/waltwildwest/handoff) (+ pickup) | Pass a task to a fresh session that mirrors your model, effort and permission mode | Long sessions rot; restarting shouldn't cost you the decisions, dead ends and verify steps the old session already paid for |
| [**route**](https://github.com/waltwildwest/route) | Cost-aware delegation: size → cache → cheap-under-expensive-review → honest savings report | Most agent work is grunt work; route it down the ladder and *prove* the savings against real baselines instead of vibes |
| [**re-searcher**](https://github.com/waltwildwest/re-searcher) | A persistent research vault with recall-first answers and quote-verified claims | Research that evaporates into a chat summary gets re-derived forever; claims should come back dated, sourced and falsifiable |

## Install

Add the marketplace once, then install only what you want:

```
/plugin marketplace add waltwildwest/claude-toolkit
/plugin install handoff@claude-toolkit
/plugin install route@claude-toolkit
/plugin install re-searcher@claude-toolkit
```

Prefer copies you can read and edit? Every repo also ships an `install.sh` that copies
the skill + command into `~/.claude/` — clone the tool's repo and run it. Plugin installs
additionally auto-load each tool's hooks; `install.sh` prints the snippet to enable them
by hand.

> **Run `install.sh` yourself — don't ask Claude to.** An agent writing executable code
> into `~/.claude/` is exactly the kind of action Claude Code's permission classifier
> hands back to a human. That's the safety model working — and it's why the plugin path
> exists. Each installer is ~50 lines; read it, then run it.

> **Note:** the tool repos are private while each proves itself in real use; they go
> public individually on their own merits. If a repo link 404s for you, that tool isn't
> out yet.

## Principles

- **The skill is the source of truth** — commands are thin wrappers; the SKILL.md and
  its scripts hold the real logic, and you can read all of it.
- **Standalone** — the `claude` CLI always; a system Node.js where noted. No other
  runtime dependencies, no services, no telemetry.
- **Honest over impressive** — savings quoted with their baselines, provenance downgraded
  rather than faked, gaps recorded instead of papered over.
- **Tested** — every script ships with a bash test suite (`./run-tests.sh` in each repo);
  no live network, no LLM calls, no real `~/.claude` state touched.

## License

MIT — see [LICENSE](./LICENSE). Each tool repo carries its own copy.
