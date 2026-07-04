# claude-toolkit

> Small, honest tools for [Claude Code](https://claude.com/claude-code) that work in both the CLI and the desktop app.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin%20%C2%B7%20skill%20%C2%B7%20command-black.svg)](https://claude.com/claude-code)
[![tests](https://img.shields.io/badge/tests-13%20passing-brightgreen.svg)](./tests/handoff.test.sh)

Tools I actually use every day, packaged so you can install one in under a minute and read exactly how it works. No framework, no lock-in, nothing phones home. These are standalone cuts of things that live in my own setup.

**Available now:** [`handoff`](#handoff--pass-a-task-to-a-fresh-session) · `pickup`.

---

## `handoff` — pass a task to a fresh session

When a session runs long, its context fills with dead ends and stale assumptions and the output quietly degrades. The fix is a fresh session. The friction is that a fresh session starts cold: it has to re-read your notes, reconstruct what you were doing, and figure out your setup.

`handoff` removes that friction. It:

1. writes a clean, structured brief — task, context, decisions already made, how to verify;
2. starts a **new session that mirrors your current one** (same model, same effort level, same permission mode) and hands it the brief;
3. leaves the old session safe to `/clear`.

Claude Code already has context and memory features. This is the quality-of-life layer that was missing for me: a spawned session should pick up *exactly* where the last one left off, down to the model and effort I had dialed in.

```console
$ /handoff
Handoff spawned in a new tmux window (model=claude-opus-4-8  effort=xhigh  permission=auto).
Switch to it with your tmux window keys. Safe to /clear here and move on.
```

### Install

**Option A — as a plugin (recommended).** From inside any Claude Code session:

```
/plugin marketplace add whomsfun-ai/claude-toolkit
/plugin install handoff@claude-toolkit
```

That installs both skills (`handoff` + `pickup`) through Claude Code's own plugin flow — versioned, updatable with `/plugin marketplace update`, removable from the `/plugin` menu. As a plugin the skills are namespaced, so the slash form is `/handoff:handoff` and `/handoff:pickup`; asking in plain words ("hand this off to a fresh session") works the same either way.

**Option B — copy the files.** In your own terminal:

```bash
git clone https://github.com/whomsfun-ai/claude-toolkit
cd claude-toolkit && ./install.sh
```

Installs the `handoff` and `pickup` **skills** into `~/.claude/skills/` and a thin `/handoff` **command** into `~/.claude/commands/`. To uninstall, delete those.

> **Run `install.sh` yourself — don't ask Claude to.** If you ask Claude Code to run the installer for you in auto mode, its permission classifier will refuse: an agent writing executable code into `~/.claude/` is exactly the kind of action it's designed to hand back to a human. That's Claude's safety model working, not a bug in the toolkit — and it's why the plugin path exists. The installer is ~30 lines; read it, then run it.

### Use it

**In the terminal** — run `/handoff` (or `/handoff:handoff` if you installed the plugin; or `/handoff <the next task>`, or just ask to "hand this off to a fresh session"). It writes the brief and opens a new mirrored session automatically: a new tmux window, or a new Terminal window on macOS, or it prints the exact command to paste if neither is available.

**In the desktop app** — the desktop app supports skills but not custom commands or auto-spawning a session, so:

1. run the **handoff** skill — it writes the brief;
2. open a new session in the same project (sidebar `+`);
3. run the **pickup** skill — it loads the brief and continues.

Same context handoff; the only manual step is opening the session, which the app makes you do anyway.

### How the mirroring works

The interesting part is detecting *what* to mirror, with zero config:

- **Effort** comes from the `$CLAUDE_EFFORT` environment variable.
- **Model** and **permission mode** are read from the current session transcript under `~/.claude/projects/` (last value wins).

`handoff-spawn.js` then launches:

```bash
claude --model <yours> --effort <yours> --permission-mode <yours> "<pick up the handoff>"
```

It never writes to `~/.claude` — it only *reads* the transcript to learn your settings. Modes the CLI understands (`acceptEdits`, `auto`, `plan`, …) are passed through; the default interactive mode is left alone so the new session matches it.

---

## `pickup` — continue from the latest handoff

Reads the most recent brief in `~/.claude/handoffs/`, states the task, and continues it — honoring the brief's decisions, staying in scope, and running its verify step. Mainly for the desktop flow, handy anywhere.

## Repository layout

```
skills/handoff/   SKILL.md + handoff-spawn.js   the tool (source of truth; CLI + desktop)
skills/pickup/    SKILL.md                       loads the latest brief in a new session
commands/handoff.md                              thin /handoff wrapper for install.sh installs
.claude-plugin/marketplace.json                  plugin marketplace manifest (Option A)
tests/handoff.test.sh                            13 tests (detection, safety, tmux, live pickup)
install.sh · LICENSE
```

The same `skills/` folders back both install paths — the marketplace manifest just points at them, so there is exactly one source of truth.

## Requirements

Node (bundled with Claude Code) and the `claude` CLI. tmux is optional — with it, handoffs open a new window seamlessly; without it, macOS opens a new Terminal, and everywhere else you get the exact command to paste.

## Tests

```bash
bash tests/handoff.test.sh
```

Covers mirror detection, shell-injection safety, every fallback path, error handling, real tmux window creation, and a live end-to-end handoff pickup.

## Roadmap

More standalone tools as I write them up: model-aware cost routing, adversarial verification, an attention queue for parallel sessions.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). The short version: the skill is the source of truth, and changes should keep it that way and pass the tests.

## License

[MIT](./LICENSE).
