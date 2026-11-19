# agent-loop: one-prompt plan → implement → review loop for Herdr + WSL

```
you ─► loop "Add rate limiting to /api/login"
          │
          ▼
   Orchestrator (Claude Code, Opus) ── interactive, in your Herdr pane
          │  calls `subagent <role>` (model is fixed by roles.conf, not by the orchestrator)
          ├─► planner      Claude Opus      (read-only)            → plan.md
          ├─► implementer  Claude Sonnet    (edits + runs tests)   → working tree
          └─► reviewer     GPT-6.2 Sol      (codex, read-only)     → VERDICT: APPROVE | CHANGES_REQUESTED
                 ▲                                   │
                 └──── up to MAX_ITERATIONS ─────────┘
          on APPROVE: commit on branch loop/<id>, write summary.md
```

## Install (inside WSL)

```bash
unzip agent-loop.zip && cd agent-loop && bash install.sh
```

This installs to `~/.agent-loop` and links `loop` and `subagent` into `~/.local/bin`.
Prerequisites (inside WSL, logged in): `claude` (Claude Code), `codex` (ChatGPT login with
GPT-6.2 Sol access), `git`. `omp` is optional.

**Quick check before the first real run:**
```bash
claude -p --model opus "say ok"
codex exec -m gpt-6.2-sol -s read-only "say ok"
```

## Use

In a Herdr terminal opened on WSL, `cd` into a project and run:

```bash
loop "Add rate limiting to /api/login: 5 attempts/min per IP, 429 with Retry-After"
loop -f specs/feature.md            # longer task from a file
loop --headless "..."               # no TUI; good for unattended runs
loop --max 5 "..."                  # more review rounds
```

What happens:
1. Creates branch `loop/<timestamp>` and a run folder `.loop/runs/<timestamp>/` (git-ignored locally).
2. Opens Claude Code (Opus) as the orchestrator, already primed with the procedure. You can watch it
   and type into it at any time to steer it.
3. The orchestrator runs planner → implementer → reviewer, looping until the reviewer approves or
   the round limit is hit, then commits and writes `summary.md`.

Everything each subagent saw and said is kept in the run folder (`NN-role.prompt.md`,
`NN-role.out.md`, `NN-role.log`), so you can audit or replay any step.

## Herdr integration

If `hc` (herdr-core) works from inside WSL (`hc ls` succeeds), each subagent opens as its own
Herdr terminal named `loop-<run>-NN-role`: it shows up in the sidebar and you can `hc attach` to it.
If `hc` isn't reachable from WSL, subagents run inline in the orchestrator's pane. The loop works the
same either way. Force it with `USE_HC=yes|no` in `~/.agent-loop/config/roles.conf`.

## Changing models / CLIs

Edit `~/.agent-loop/config/roles.conf`. Each role has `*_CLI`, `*_MODEL`, `*_FLAGS`.
Examples:
- Stronger reviewer: `REVIEWER_MODEL=gpt-6.2-astra`
- Use Oh My Pi for implementation: `IMPLEMENTER_CLI=omp` and `IMPLEMENTER_MODEL=<model id>`.
  `omp` is called as `omp -p --model <id> < prompt`. Confirm with `omp --help` that your version
  accepts those flags and adjust `bin/subagent` (the `omp)` line) if it doesn't.
- Cheaper orchestrator: `ORCHESTRATOR_MODEL=sonnet`. It only routes work, so Sonnet is usually enough.

Prompts for each role live in `~/.agent-loop/prompts/*.md`. Edit them to add project rules.

## Safety notes

- The implementer runs with `--permission-mode bypassPermissions` so it can run tests unattended.
  It runs on a fresh branch and `loop` refuses to start with uncommitted changes (`--allow-dirty`
  overrides), but it can still run any shell command in WSL. Tighten `IMPLEMENTER_FLAGS` if needed.
- The planner can't edit files and the reviewer runs in Codex's read-only sandbox.
- Nothing is pushed. Review the branch and merge it yourself.
