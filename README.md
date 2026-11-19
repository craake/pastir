# pastir: one-prompt plan → implement → review loop for Herdr + WSL

```
you ─► pastir "Add rate limiting to /api/login"
          │
          ▼
   Orchestrator (Claude Code, Opus) ── interactive, in your Herdr pane
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
2. Opens Claude Code (Opus) as the orchestrator, already primed with the procedure. You can watch it
   and type into it at any time to steer it.
3. The orchestrator runs planner → implementer → reviewer, looping until the reviewer approves or
   the round limit is hit, then commits and writes `summary.md`.

Everything each subagent saw and said is kept in the run folder (`NN-role.prompt.md`,
`NN-role.out.md`, `NN-role.log`), so you can audit or replay any step.

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
- Cheaper orchestrator: `ORCHESTRATOR_MODEL=sonnet`. It only routes work, so Sonnet is usually enough.

Branch behaviour: set `NEW_BRANCH=yes|no` in `roles.conf` to choose the default (`yes` = new `pastir/<id>` branch per run; `no` = use the checked-out branch). `--new-branch` / `--current-branch` override it per run. Old installs without the key default to `yes`.

Prompts for each role live in `~/.pastir/prompts/*.md`. Edit them to add project rules. Re-running `install.sh` replaces them with the shipped versions, so keep a
copy of your edits.

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

## Upgrading from agent-loop

Re-run `bash install.sh`. It installs to `~/.pastir` (or your `LOOP_HOME`), copies your
`roles.conf` over if the new install has none, removes the old `loop` link and the old PowerShell
profile block. If you had edited prompts in `~/.agent-loop/prompts/`, the changed files are copied to
`~/.pastir/prompts.agent-loop-backup/`; the new install uses the stock prompts, so merge your edits
into `~/.pastir/prompts/` by hand. `~/.agent-loop` itself is left alone. Once you've merged anything
you need, you can delete it — but only if the installer printed an "Old install at ~/.agent-loop"
removal hint. It prints nothing when `~/.agent-loop` is still your active install (for example you set
`LOOP_HOME` to it, or `~/.pastir` is a symlink to it), and in that case you must not delete it.
The command is now `pastir`, branches are `pastir/<id>`, and run logs go to `.pastir/` (older
`.loop/` folders in projects can be deleted).
