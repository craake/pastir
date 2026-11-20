<p align="center">
  <img src="logo.png" alt="Logo" width="500">
</p>

# pastir: one-prompt plan → implement → review loop for Herdr + WSL

**pastir** is a CLI that turns a single task prompt into a reviewed, committed change. It runs in
WSL, works inside Herdr, and can also be launched from PowerShell. A Claude Code orchestrator
drives a planner (Claude Opus), an implementer (Claude Sonnet) and an independent reviewer
(GPT-6.2 Sol via Codex), looping until the reviewer approves or the round limit is hit. Only after
approval does it commit to a local branch; it never pushes, and it keeps every prompt and output in
the run folder so you can audit it. `roles.conf` sets the model and CLI for each of the three
subagents.

```
you ─► pastir "Add rate limiting to /api/login"
          │
          ▼
   Orchestrator (Claude Code, Sonnet) ── interactive, in your Herdr pane
          │  calls `subagent <role>` (model is fixed by roles.conf, not by the orchestrator)
          ├─► planner      Claude Opus      (read-only)            → plan.md
          ├─► implementer  Claude Sonnet    (edits + runs tests)   → working tree
          └─► reviewer     GPT-6.2 Sol      (codex, read-only)     → VERDICT: APPROVE | CHANGES_REQUESTED
                 ▲                                   │
                 └──── up to MAX_ITERATIONS ─────────┘
          on APPROVE: commit on branch pastir/<id> (or current branch), write summary.md
```

## Install (inside WSL)

```bash
unzip pastir.zip && cd pastir && bash install.sh
```

This installs to `~/.pastir` and links `pastir` and `subagent` into `~/.local/bin`.
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
pastir "Add rate limiting to /api/login: 5 attempts/min per IP, 429 with Retry-After"
pastir -f specs/feature.md            # longer task from a file
pastir --headless "..."               # no TUI; good for unattended runs
pastir --max 5 "..."                  # more review rounds
pastir --current-branch "..."         # work on the branch you're on instead of creating pastir/<id>
```

What happens:
1. Creates branch `pastir/<timestamp>` (or, with `--current-branch` / `NEW_BRANCH=no`, stays on the checked-out branch) and a run folder `.pastir/runs/<timestamp>/` (git-ignored locally).
2. Opens Claude Code (Sonnet by default) as the orchestrator, already primed with the procedure. You can watch it
   and type into it at any time to steer it.
3. The orchestrator runs planner → implementer → reviewer, looping until the reviewer approves or
   the round limit is hit, then commits and writes `summary.md`.

Everything each subagent saw and said is kept in the run folder (`NN-role.prompt.md`,
`NN-role.out.md`, `NN-role.log`, and `NN-role.console` for inline runs), so you can audit or replay any step.

## Herdr integration

If `hc` (herdr-core) works from inside WSL (`hc ls` succeeds), each subagent opens as its own
Herdr terminal named `pastir-<run>-NN-role`: it shows up in the sidebar and you can `hc attach` to it.
If `hc` isn't reachable from WSL, subagents run inline in the orchestrator's pane. The loop works the
same either way. Force it with `USE_HC=yes|no` in `~/.pastir/config/roles.conf`.

## Changing models / CLIs

Edit `~/.pastir/config/roles.conf`. Each role has `*_CLI`, `*_MODEL`, `*_FLAGS`.
Examples:
- Stronger reviewer: `REVIEWER_MODEL=gpt-6.2-astra`
- Use Oh My Pi for implementation: `IMPLEMENTER_CLI=omp` and `IMPLEMENTER_MODEL=<model id>`.
  `omp` is called as `omp -p --model <id> < prompt`. Confirm with `omp --help` that your version
  accepts those flags and adjust `bin/subagent` (the `omp)` line) if it doesn't.
- Stronger orchestrator: `ORCHESTRATOR_MODEL=opus`. Sonnet is the default because the orchestrator only routes work.

Branch behaviour: set `NEW_BRANCH=yes|no` in `roles.conf` to choose the default (`yes` = new `pastir/<id>` branch per run; `no` = use the checked-out branch). `--new-branch` / `--current-branch` override it per run. Old installs without the key default to `yes`.

Prompts for each role live in `~/.pastir/prompts/*.md`. Edit them to add project rules. Re-running `install.sh` replaces them with the shipped versions, so keep a
copy of your edits.

## Token usage

pastir is set up to keep token use down. Knobs in `roles.conf`:
- `LEAN_CLAUDE=yes` (default): the orchestrator and Claude subagents start without MCP servers and without skills/slash commands, whose schemas are otherwise re-sent on every request. `CLAUDE.md` still loads. Set `no` if the planner or implementer needs an MCP server. If an enterprise-managed MCP config exists on the platform Claude runs on (`/etc/claude-code/managed-mcp.json` on Linux/WSL, `/Library/Application Support/ClaudeCode/managed-mcp.json` on macOS), `--strict-mcp-config` is skipped because it conflicts with it; every MCP tool is denied instead (`--disallowedTools 'mcp__*'`, when the CLI supports it) and skills/slash commands are still disabled.
- `OUTPUT_PREVIEW_LINES=80` (default): how much of each subagent's output the orchestrator sees. The full output is always in `NN-role.out.md`, and reviewer blocking/major findings are never cut.

Other savings that are always on: inline subagent output goes to `NN-role.console` instead of the orchestrator's context, lockfiles and minified assets are left out of the diff sent to the reviewer (the diff stat still lists them), and the prompts ask for short plans, reports and reviews.

Existing installs keep their own `~/.pastir/config/roles.conf`, so add these keys there to change them (the defaults above apply when they are absent). `ORCHESTRATOR_MODEL=sonnet` only reaches fresh installs.

## Safety notes

- The implementer runs with `--permission-mode bypassPermissions` so it can run tests unattended.
  By default it runs on a fresh `pastir/<id>` branch (with `--current-branch` / `NEW_BRANCH=no` it runs on
  your checked-out branch instead), and `pastir` refuses to start with uncommitted changes (`--allow-dirty`
  overrides this only in new-branch mode), but it can still run any shell command in WSL. Tighten `IMPLEMENTER_FLAGS` if needed.
- The planner can't edit files and the reviewer runs in Codex's read-only sandbox.
- `--current-branch` / `NEW_BRANCH=no` makes pastir commit directly to the branch you're on (including `main`). It refuses to start on a detached HEAD or with any uncommitted or untracked changes, even with `--allow-dirty`, because the final `git add -A` would include them. Commit or stash first. Before committing, the orchestrator checks that the branch is still the one recorded at start and skips the commit if it is not.
- Nothing is pushed. Review the branch and merge it yourself.

## Starting from PowerShell (Herdr Windows app)

`install.sh` adds a `pastir` function to your PowerShell profiles (PowerShell 7 and 5.1, between
`# >>> pastir >>>` markers). Open a new PowerShell tab and run:

```powershell
pastir -C ~/projects/myapp "Create relevant .gitignore for this project"
pastir -C \\wsl.localhost\Ubuntu\home\you\myapp "..."   # UNC path to a WSL folder
pastir -C C:\code\myapp "..."                               # Windows folder (slower, via /mnt/c)
```

`~` means your WSL home. Arguments are base64-encoded on the way into WSL because PowerShell
rewrites `~` to `C:\Users\<you>` and `wsl.exe` mangles quotes. You don't need to escape anything
except what PowerShell itself needs (`''` inside single quotes, `""` inside double quotes).

Or just type `wsl`, `cd` into the project, and run `pastir "..."` as usual.

The project folder must be a git repository. Re-run `install.sh` if you reinstall or move
claude/codex: it records their PATH in `~/.pastir/config/path.env`. PowerShell launches and
the Herdr terminals that subagents open don't read `~/.bashrc`/`~/.zshrc`, so they need it.
