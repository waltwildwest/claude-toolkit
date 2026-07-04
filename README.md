# claude-toolkit

> Small, honest tools for [Claude Code](https://claude.com/claude-code) that work in both the CLI and the desktop app.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin%20%C2%B7%20skill%20%C2%B7%20command-black.svg)](https://claude.com/claude-code)
[![tests](https://img.shields.io/badge/tests-34%20passing-brightgreen.svg)](./tests/handoff.test.sh)

Tools I actually use every day, packaged so you can install one in under a minute and read exactly how it works. No framework, no lock-in, nothing phones home. These are standalone cuts of things that live in my own setup.

**Available now:** [`handoff`](#handoff--pass-a-task-to-a-fresh-session) · `pickup` · [`route`](#route--cost-aware-model-routing-with-honest-math).

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

**In the desktop app** — the skill hands the continuation to the app's own task system: a **chip** appears in your session (`Pick up handoff: …`). One click and the new session starts running immediately — it inherits the origin session's model, effort and permission mode, shows up **linked under the origin session** ("session launched"), and reports back there when it finishes. It runs in a fresh worktree cut from your last commit, so commit anything the task needs first (the skill reminds you when that matters).

If the app doesn't expose the session-spawning tool, the spawner falls back to a `claude://code/new` deep link — a new session tab with the pickup prompt prefilled and the folder selected; press Enter to start. (Auto-submit from outside the app doesn't exist by design: the app's session-start IPC only accepts its own UI, so a malicious URL can never auto-run a prompt. One click is the floor.) Last resort: new session (sidebar `+`), then run the **pickup** skill.

<details>
<summary><b>How is a handoff chip different from a regular task chip?</b></summary>

Mechanically they're the same plumbing — the desktop app's `spawn_task` tool, which queues a suggestion chip; clicking it creates a fresh-worktree session that's linked to the origin (`spawnedFrom` in the app's session registry) and inherits its settings. The difference is the contract:

- A **regular task chip** delegates a *side errand* the session noticed in passing (dead code, a stale doc). Its whole context fits in the chip's prompt, and the origin session remains the main thread of work.
- A **handoff chip** transfers *ownership of the main task*. Its prompt is just a pointer to the real payload — the brief in `~/.claude/handoffs/` with the task, decisions already made, gotchas, and the verify step — and the origin session is done: you `/clear` it and move on. The new session isn't helping the old one; it *replaces* it.

Same vehicle, opposite direction: side-task chips fan work *out* of a session that continues; the handoff chip is how a session that's ending passes the torch.
</details>

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

## `route` — cost-aware model routing, with honest math

"Just use the best model for everything" is simple and expensive. `route` packages the policy I actually run:

1. **Size before dispatching.** Every delegable task gets a tier: grunt work goes to Haiku, standard implementation to Sonnet, and judgment calls stay with the top model. The skill gives Claude the sizing table and the rules of thumb (including when to give up and promote a task a tier).
2. **Fan out big jobs.** Many independent pieces run in parallel on cheap models; the strong model reviews the merged result. Cheap generation plus expensive review is the whole trade.
3. **Measure it.** `route-report` reads your local transcripts (nothing leaves your machine), dedupes streamed messages, prices every token at current API rates, and prints your actual cost against **three baselines**: the naive one (top model, every call, no cache), top-model-with-cache (what routing alone saved), and your-mix-without-cache (what caching alone saved).

```console
$ /route report
  actual cost                     $6540.79
  naive baseline (no cache)       $63448.95   you saved 89.7%
  same top model, with cache      $10584.14   routing alone saved 38.2%
  your mix, cache off             $40727.65   caching alone saved 83.9%
```

That output is the point: a savings number without its baseline is marketing. The report prints the flattering number and the honest ones in the same breath. (If you're on a subscription rather than the API, the dollars are notional at API rates — the percentages are what matter.)

Install is the same as handoff: `/plugin install route@claude-toolkit`, or `./install.sh` puts the `route` skill and the `/route` command in place. Use `/route <task>` to size and dispatch a task, `/route report` for the math.

## Repository layout

```
skills/handoff/   SKILL.md + handoff-spawn.js   the tool (source of truth; CLI + desktop)
skills/pickup/    SKILL.md                       loads the latest brief in a new session
skills/route/     SKILL.md + route-report.js     sizing policy + transcript cost report
commands/handoff.md · commands/route.md          thin CLI wrappers for install.sh installs
.claude-plugin/marketplace.json                  plugin marketplace manifest (Option A)
tests/handoff.test.sh · tests/route.test.sh      34 tests (routing matrix, safety, cost math, baselines)
install.sh · LICENSE
```

The same `skills/` folders back both install paths — the marketplace manifest just points at them, so there is exactly one source of truth.

## Requirements

Node (bundled with Claude Code) and the `claude` CLI. tmux is optional — with it, handoffs open a new window seamlessly; without it, macOS opens a new Terminal, and everywhere else you get the exact command to paste.

## Tests

```bash
bash tests/handoff.test.sh && bash tests/route.test.sh
```

Covers mirror detection, shell-injection safety, error handling, and the full routing matrix — desktop deep link (success, failure fallback, precedence over tmux), macOS Terminal.app (success and paste fallback), simulated Linux, and real tmux window creation on a private socket. Window-opening binaries are shimmed onto `PATH`, so the suite never opens anything on your screen.

## Roadmap

More standalone tools as I write them up: adversarial verification, an attention queue for parallel sessions.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). The short version: the skill is the source of truth, and changes should keep it that way and pass the tests.

## License

[MIT](./LICENSE).
