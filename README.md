# claude-toolkit

Small, standalone tools for [Claude Code](https://claude.com/claude-code) that I actually use
every day. Each one is a single command you can drop into your setup and try in under a minute.
No framework, no lock-in. Steal the ones you like.

These are lightweight cuts of tools that live in my own cockpit. They work on their own.

---

## `/handoff` — pass a task to a fresh session, seamlessly

When a session gets long, its context fills with dead ends and stale assumptions and the output
quietly degrades. The fix is a fresh session. The friction is that a fresh session starts cold:
it has to re-read your notes, reconstruct what you were doing, and figure out your setup.

`/handoff` removes that friction. From inside your current session, one command:

1. writes a clean handoff brief (task, context, decisions already made, how to verify),
2. spawns a **new session that mirrors your current one** — same model, same effort level, same
   permission mode — and hands it the brief directly, so it doesn't have to go mine a file and
   rebuild context on its own,
3. leaves this session safe to `/clear` and move on.

Claude Code already has context and memory features. This is a quality-of-life layer on top:
the part that was missing for me was that a spawned session should pick up *exactly* where the
last one left off, including the model and effort I had dialed in.

### Install

```bash
git clone https://github.com/whomsfun-ai/claude-toolkit
cd claude-toolkit && ./install.sh
```

Or copy the two files by hand:

```bash
mkdir -p ~/.claude/commands/lib
cp commands/handoff.md      ~/.claude/commands/
cp lib/handoff-spawn.js     ~/.claude/commands/lib/
```

Then, in any Claude Code session: `/handoff` (or `/handoff <the next task>`).

### How the mirroring works

The interesting bit is detecting what to mirror. Claude Code exposes the current **effort** as an
env var (`$CLAUDE_EFFORT`), and records the current **model** and **permission mode** in the
session transcript under `~/.claude/projects/`. `handoff-spawn.js` reads both, then launches:

```
claude --model <yours> --effort <yours> --permission-mode <yours> "<pick up the handoff>"
```

In tmux it opens a new window. Outside tmux it prints the exact command to paste into a new
terminal. It never writes to `~/.claude`; it only reads the transcript to learn your settings.

### Requirements

Node (which you already have if you run Claude Code) and the `claude` CLI. tmux is optional but
makes it seamless.

---

## Roadmap

More tools as I write them up, each standalone: model-aware cost routing, adversarial
verification, an attention queue for parallel sessions.

## License

[MIT](./LICENSE). Do whatever you want with it.
