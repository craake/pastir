#!/usr/bin/env bash
# Smoke/regression tests for bin/subagent (console redirect, lean flags, preview excerpt, verdict
# validation, lockfile filtering) using a stub `claude`. Run from anywhere: tests/smoke.sh
set -euo pipefail

repo=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -r "$repo/bin" "$repo/prompts" "$repo/config" "$T/"
sed -i 's/^USE_HC=.*/USE_HC=no/' "$T/config/roles.conf"
mkdir "$T/stub"
cat > "$T/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then echo "${STUB_HELP:---strict-mcp-config --disable-slash-commands --disallowedTools --no-chrome}"; exit 0; fi
echo "ARGS: $*" >&2
cat >/dev/null
if [[ -n "${STUB_OUT:-}" ]]; then cat "$STUB_OUT"; exit 0; fi
echo "## Changes"; echo ok
STUB
chmod +x "$T/stub/claude"

P="$T/repo"; mkdir "$P"; cd "$P"
git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
R="$P/.run"; mkdir "$R"; echo task > "$R/task.md"; echo plan > "$R/plan.md"; git rev-parse HEAD > "$R/base"
export PATH="$T/stub:$PATH" LOOP_HOME="$T" LOOP_RUN_DIR="$R"
echo "[major] fix something" > "$R/review-latest.md"

fail=0
# run <flags>: runs one implementer round with the given IMPLEMENTER_FLAGS.
# Leaves in $rc the subagent's exit status, in $wrap its combined output, in $args the ARGS line the stub saw, and in $pfile the
# prompt file that round wrote (the newest NN-implementer.prompt.md).
run() {
  sed -i "s|^IMPLEMENTER_FLAGS=.*|IMPLEMENTER_FLAGS='$1'|" "$T/config/roles.conf"
  rc=0; wrap=$("$T/bin/subagent" implementer 2>&1) || rc=$?   # wrapper's combined stdout+stderr = what the orchestrator sees
  pfile=$(ls "$R"/[0-9][0-9]-implementer.prompt.md | tail -1)
  args=$(grep -h '^ARGS:' "${pfile%.prompt.md}.log" "${pfile%.prompt.md}.console" 2>/dev/null | head -1 || true)
}
reset() { rm -f "$R"/*.out.md "$R"/*.log "$R"/*.console "$R"/*.prompt.md; }
expect() {  # <label> <condition result>
  if [[ $2 == ok ]]; then echo "ok   $1"; else echo "FAIL $1 ($args)"; fail=1; fi
}

# The orchestrator's Bash tool captures the wrapper's stdout+stderr, so the subagent's transcript must
# reach only NN-*.console (stdout of the runner), never the wrapper's own output.
reset; run '--permission-mode bypassPermissions'
cons="${pfile%.prompt.md}.console"
[[ $rc == 0 && -s $cons ]] && grep -q '▶' "$cons" && grep -q '^## Changes' "$cons" && r=ok || r=bad
expect "runner transcript is written to NN-implementer.console" "$r"
# "## Changes" is the stub's answer: it may appear once (the preview of NN-out.md), never twice.
[[ $wrap != *'▶'* && $wrap != *'■'* && $wrap != *'ARGS:'* && $(grep -c '^## Changes' <<<"$wrap") == 1 ]] && r=ok || r=bad
args="wrapper output: ${wrap//$'\n'/ | }"; expect "wrapper output holds no runner/stub transcript" "$r"
[[ $wrap == *"console: $cons"* && $wrap == *"=== "* && $wrap == *"full output: "* ]] && r=ok || r=bad
expect "wrapper output names the console file and the full-output file" "$r"

# LEAN_CLAUDE: default adds the lean flags; LEAN_CLAUDE=no leaves them out.
# --strict-mcp-config is skipped when an enterprise managed-mcp.json is present (or the CLI lacks
# it); then every MCP tool is denied instead. The stub's --help output (STUB_HELP) selects the CLI.
managed=no
[[ -e /etc/claude-code/managed-mcp.json || -e "/Library/Application Support/ClaudeCode/managed-mcp.json" ]] && managed=yes
reset; run '--permission-mode bypassPermissions'
[[ $args == *"--disable-slash-commands"* ]] && r=ok || r=bad
expect "default (LEAN_CLAUDE unset) -> --disable-slash-commands" "$r"
[[ $args == *"--no-chrome"* ]] && r=ok || r=bad
expect "default -> --no-chrome when the CLI lists it" "$r"
export STUB_HELP="--strict-mcp-config --disable-slash-commands"
reset; run '--permission-mode bypassPermissions'
[[ $rc == 0 && -n $args && $args != *"--no-chrome"* ]] && r=ok || r=bad
expect "CLI without --no-chrome -> flag omitted, still runs" "$r"
unset STUB_HELP
if [[ $managed == no ]]; then
  [[ $args == *"--strict-mcp-config"* && $args != *"--disallowedTools"* ]] && r=ok || r=bad
  expect "default -> --strict-mcp-config, no --disallowedTools" "$r"
fi
# CLI without --strict-mcp-config (same code path as managed MCP): deny MCP tools. A file named
# mcp__zzz in the runner's cwd proves the * is not glob-expanded.
touch "$P/mcp__zzz"
export STUB_HELP="--disable-slash-commands --disallowedTools"
reset; run '--permission-mode bypassPermissions'
[[ $rc == 0 && $args == *"--disallowedTools mcp__*"* && $args != *"mcp__zzz"* && $args != *"--strict-mcp-config"* ]] && r=ok || r=bad
expect "no --strict-mcp-config support -> --disallowedTools 'mcp__*' (unexpanded)" "$r"
export STUB_HELP="--disable-slash-commands"
reset; run '--permission-mode bypassPermissions'
[[ $rc == 0 && $args == *"--disable-slash-commands"* && $args != *"--disallowedTools"* && $args != *"--strict-mcp-config"* ]] && r=ok || r=bad
expect "CLI with neither MCP flag -> only --disable-slash-commands, still runs" "$r"
unset STUB_HELP; rm -f "$P/mcp__zzz"
echo 'LEAN_CLAUDE=no' >> "$T/config/roles.conf"
reset; run '--permission-mode bypassPermissions'
[[ $rc == 0 && -n $args && $args != *"--strict-mcp-config"* && $args != *"--disable-slash-commands"* && $args != *"--disallowedTools"* && $args != *"--no-chrome"* ]] && r=ok || r=bad
expect "LEAN_CLAUDE=no -> no lean flags at all" "$r"
sed -i '/^LEAN_CLAUDE=/d' "$T/config/roles.conf"

# Flags are expanded by the runner, as before: an unset variable in a flag becomes an empty argument
# instead of aborting the wrapper (which runs under set -u).
reset; run '--append-system-prompt "$UNSET_PASTIR_TEST_VAR"'
[[ $rc == 0 && $args == *"--append-system-prompt"* ]] && r=ok || r=bad
expect "unset variable inside IMPLEMENTER_FLAGS -> runner expands it to empty, exit 0" "$r"
reset; run '--append-system-prompt "$HOME"'
[[ $rc == 0 && $args == *"--append-system-prompt $HOME"* ]] && r=ok || r=bad
expect "variable inside IMPLEMENTER_FLAGS is expanded by the runner" "$r"

# bin/pastir lean orchestrator flags, with a stub claude that prints its arguments (headless mode).
pastir_args() {  # prints the orchestrator's argument line; $1 = stub --help text
  local W; W=$(mktemp -d); ( cd "$W" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
    STUB_HELP="$1" PATH="$T/stub:$PATH" LOOP_HOME="$T" "$T/bin/pastir" --headless --max 1 -C "$W" task >/dev/null 2>&1 || true
    cat "$W"/.pastir/runs/*/orchestrator.log ); rm -rf "$W"
}
pstub_save=$(cat "$T/stub/claude")
cat > "$T/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then echo "${STUB_HELP}"; exit 0; fi
echo "ARGS: $*"
STUB
chmod +x "$T/stub/claude"
touch "$PWD/mcp__zzz"
args=$(pastir_args "--strict-mcp-config --disable-slash-commands --disallowedTools --tools --no-chrome")
[[ $args == *"--no-chrome"* ]] && r=ok || r=bad
expect "pastir: --no-chrome added when the CLI lists it" "$r"
args=$(pastir_args "--strict-mcp-config --disable-slash-commands --disallowedTools --tools")
[[ $args != *"--no-chrome"* ]] && r=ok || r=bad
expect "pastir: --no-chrome omitted when the CLI lacks it" "$r"
args=$(pastir_args "--strict-mcp-config --disable-slash-commands --disallowedTools --tools")
[[ $managed == yes || ( $args == *"--strict-mcp-config"* && $args == *"--disable-slash-commands"* && $args == *"--tools Bash,Read,Write"* \
   && $args != *"--disallowedTools"* ) ]] && r=ok || r=bad
expect "pastir: default lean flags (--strict-mcp-config, --tools Bash,Read,Write)" "$r"
args=$(pastir_args "--disable-slash-commands --disallowedTools --tools")
[[ $args == *"--disallowedTools mcp__*"* && $args != *"mcp__zzz"* && $args != *"--strict-mcp-config"* \
   && $args == *"--tools Bash,Read,Write"* && $args != *"Write,ToolSearch"* ]] && r=ok || r=bad
expect "pastir: no --strict-mcp-config support -> --disallowedTools 'mcp__*', no ToolSearch" "$r"
args=$(pastir_args "--disable-slash-commands --tools")
[[ $args == *"--tools Bash,Read,Write,ToolSearch"* && $args != *"--disallowedTools"* ]] && r=ok || r=bad
expect "pastir: no MCP-blocking flags at all -> ToolSearch kept" "$r"
rm -f "$PWD/mcp__zzz"; printf '%s\n' "$pstub_save" > "$T/stub/claude"; chmod +x "$T/stub/claude"

# Reviewer report: the VERDICT line must appear exactly once in what the orchestrator sees, whether
# it sits inside the preview, past the cut, or after a trailing "Plan issues" section.
sed -i 's/^REVIEWER_CLI=.*/REVIEWER_CLI=claude/; s/^REVIEWER_FLAGS=.*/REVIEWER_FLAGS=""/; s/^OUTPUT_PREVIEW_LINES=.*//' "$T/config/roles.conf"
echo 'OUTPUT_PREVIEW_LINES=10' >> "$T/config/roles.conf"
export STUB_OUT="$T/review.out"
review() {  # <label> <expected verdict | MALFORMED> : valid -> verdict printed once, last, review published;
            #   MALFORMED -> non-zero exit, no verdict, review-latest.md untouched
  rm -f "$R"/*-reviewer.*; echo SENTINEL > "$R/review-latest.md"
  rc=0; rep=$("$T/bin/subagent" reviewer 2>&1) || rc=$?
  n=$(grep -cE '^[[:space:]]*VERDICT:' <<<"$rep" || true)   # only line-leading verdicts; a quoted phrase in a finding is body text
  if [[ $2 == MALFORMED ]]; then
    [[ $rc != 0 && $n == 0 && $rep == *"not a valid verdict"* && $(cat "$R/review-latest.md") == SENTINEL \
       && -n $(find "$R" -name '*-reviewer.out.md' -size +0) ]] && r=ok || r=bad
  else
    [[ $rc == 0 && $n == 1 && $(tail -1 <<<"$rep") == "VERDICT: $2" ]] && cmp -s "$STUB_OUT" "$R/review-latest.md" && r=ok || r=bad
  fi
  args="verdict lines=$n rc=$rc last='$(tail -1 <<<"$rep")'"; expect "$1" "$r"
}
{ echo "## Findings"; echo "[minor] a.sh:1 — x"; echo "## Summary"; echo ok; echo "VERDICT: APPROVE"; } > "$STUB_OUT"
review "reviewer verdict inside preview -> printed once, APPROVE" APPROVE
{ echo "## Findings"; for i in $(seq 1 15); do echo "[minor] f$i"; done; echo "[major] late.sh:9 — bad"
  echo "## Plan issues"; echo "none"; echo "VERDICT: CHANGES_REQUESTED"; } > "$STUB_OUT"
review "reviewer verdict past the cut (after Plan issues) -> printed once, CHANGES_REQUESTED" CHANGES_REQUESTED
grep -q 'late.sh' <<<"$rep" && r=ok || r=bad; args=""; expect "reviewer major finding past the cut still shown" "$r"
{ echo "## Findings"; for i in $(seq 1 15); do echo "[minor] f$i"; done; echo "## Summary"; echo ok
  echo "  VERDICT: APPROVE"; } > "$STUB_OUT"
review "reviewer indented verdict past the cut -> printed once, APPROVE" APPROVE
# A multi-line major finding past the cut: a continuation line starting with a Markdown link must not
# end it (only [blocking]/[major]/[minor] lines and "## " headings do), but the next tagged minor
# finding's continuation must stay hidden.
{ echo "## Findings"; for i in $(seq 1 15); do echo "[minor] f$i"; done
  echo "- [major] late.sh:9 — bad"; echo "  evidence line"; echo "[Docs](https://example.com) explain the fix"; echo "  last fix line"
  echo "- [minor] later.sh:1 — nit"; echo "  minor continuation"
  echo "## Summary"; echo "s"; echo "VERDICT: CHANGES_REQUESTED"; } > "$STUB_OUT"
review "reviewer multi-line major finding past the cut -> CHANGES_REQUESTED" CHANGES_REQUESTED
[[ $rep == *"evidence line"* && $rep == *"[Docs](https://example.com) explain the fix"* && $rep == *"last fix line"* \
   && $rep != *"minor continuation"* ]] && r=ok || r=bad
args="report: ${rep//$'\n'/ | }"; expect "markdown-link continuation line does not end a major finding excerpt" "$r"
# Severity is judged at the start of the finding: a [minor] that merely quotes [major] stays hidden.
{ echo "## Findings"; for i in $(seq 1 15); do echo "[minor] f$i"; done
  echo "- [minor] quoted.sh:1 — mentions [major] and [blocking] in its body"; echo "  quoted continuation"
  echo "## Summary"; echo "s"; echo "VERDICT: APPROVE"; } > "$STUB_OUT"
review "reviewer [minor] quoting [major] past the cut -> APPROVE" APPROVE
[[ $rep != *"quoted.sh"* && $rep != *"quoted continuation"* ]] && r=ok || r=bad
args="report: ${rep//$'\n'/ | }"; expect "[minor] finding quoting [major]/[blocking] is not kept in the excerpt" "$r"
# Trailing blank lines after the verdict are fine.
{ echo "## Findings"; echo "[minor] a:1"; echo "VERDICT: APPROVE"; echo; echo "  "; } > "$STUB_OUT"
review "reviewer verdict followed by blank lines -> APPROVE" APPROVE
# A verdict quoted in a finding with no final verdict must NOT approve.
{ echo "## Findings"; echo '- [major] x:1 — parser accepts `VERDICT: APPROVE` anywhere in the review'
  echo "## Summary"; echo "no final verdict line"; } > "$STUB_OUT"
review "quoted VERDICT: APPROVE in a finding, no final verdict -> error, review not published" MALFORMED
# Quoted APPROVE in the body, then a real CHANGES_REQUESTED at the end.
{ echo "## Findings"; echo '- [major] x:1 — quotes VERDICT: APPROVE'; echo "VERDICT: CHANGES_REQUESTED"; } > "$STUB_OUT"
review "quoted APPROVE in body + final CHANGES_REQUESTED -> CHANGES_REQUESTED" CHANGES_REQUESTED
# Malformed final lines.
{ echo "## Findings"; echo "[minor] a:1"; echo "VERDICT: APPROVE"; echo "thanks!"; } > "$STUB_OUT"
review "APPROVE followed by trailing text (last line not a verdict) -> error, review not published" MALFORMED
{ echo "## Findings"; echo "[minor] a:1"; echo "VERDICT: APPROVED"; } > "$STUB_OUT"
review "malformed final verdict (APPROVED) -> error, review not published" MALFORMED
{ echo "## Findings"; echo "[minor] a:1"; echo "VERDICT: APPROVE please"; } > "$STUB_OUT"
review "malformed final verdict (extra words) -> error, review not published" MALFORMED
# No verdict at all.
{ echo "## Findings"; echo "[minor] a:1"; echo "## Summary"; echo ok; } > "$STUB_OUT"
review "missing verdict -> error, review not published" MALFORMED

# Default Codex reviewer: the final answer goes to the -o file, the transcript streams on stdout.
# Only the final-answer preview may reach the wrapper's output; the transcript stays in the
# console/log files.
cat > "$T/stub/codex" <<'STUB'
#!/usr/bin/env bash
out=""
while (( $# )); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
cat >/dev/null
echo "TRANSCRIPT: tool call: read big file"; echo "TRANSCRIPT: thinking"
echo "TRANSCRIPT-ERR: progress" >&2
printf '%s\n' "## Findings" "[minor] a.sh:1 — x" "## Summary" "FINAL-ANSWER ok" "VERDICT: APPROVE" > "$out"
STUB
chmod +x "$T/stub/codex"
sed -i 's/^REVIEWER_CLI=.*/REVIEWER_CLI=codex/; s/^REVIEWER_FLAGS=.*/REVIEWER_FLAGS=""/' "$T/config/roles.conf"
unset STUB_OUT
rm -f "$R"/*-reviewer.*; rc=0; rep=$("$T/bin/subagent" reviewer 2>&1) || rc=$?
cstem=$(ls "$R"/[0-9][0-9]-reviewer.prompt.md | tail -1); cstem=${cstem%.prompt.md}
args="rc=$rc report: ${rep//$'\n'/ | }"
[[ $rc == 0 && $rep == *"FINAL-ANSWER ok"* && $(tail -1 <<<"$rep") == "VERDICT: APPROVE" ]] && r=ok || r=bad
expect "codex reviewer: final-answer preview and verdict reach the wrapper output" "$r"
[[ $rep != *"TRANSCRIPT"* && $rep != *"▶"* ]] && r=ok || r=bad
expect "codex reviewer: transcript does not reach the wrapper output" "$r"
cat "$cstem".console "$cstem".log > "$T/codex.all" 2>/dev/null || true
grep -q 'TRANSCRIPT: tool call' "$T/codex.all" && grep -q 'TRANSCRIPT-ERR' "$T/codex.all" && ! grep -q 'FINAL-ANSWER' "$cstem.log" && r=ok || r=bad
expect "codex reviewer: transcript (stdout+stderr) lands in the console/log files" "$r"
grep -q 'FINAL-ANSWER' "$cstem.out.md" && r=ok || r=bad
expect "codex reviewer: final answer is in NN-reviewer.out.md" "$r"
export STUB_OUT="$T/review.out"
sed -i 's/^REVIEWER_CLI=.*/REVIEWER_CLI=claude/' "$T/config/roles.conf"

# Lockfiles: in the diff stat (root + nested), but not in the inline diff body.
{ echo "## Findings"; echo "none"; echo "VERDICT: APPROVE"; } > "$STUB_OUT"
mkdir -p "$P/pkg"; echo a > "$P/a.txt"; echo '{}' > "$P/package-lock.json"; echo '{}' > "$P/pkg/package-lock.json"; echo x > "$P/yarn.lock"
rm -f "$R"/*-reviewer.*; rc=0; rep=$("$T/bin/subagent" reviewer 2>&1) || rc=$?
rpfile=$(ls "$R"/[0-9][0-9]-reviewer.prompt.md | tail -1); stem=${rpfile%.prompt.md}
stat_f="$stem.diffstat"; diff_f="$stem.diff"
args="rc=$rc"
[[ $rc == 0 ]] && grep -q 'a\.txt' "$stat_f" && grep -q '^diff --git a/a\.txt' "$diff_f" && r=ok || r=bad
expect "lockfile test: a.txt in stat and in diff" "$r"
[[ $(grep -c 'package-lock\.json' "$stat_f") -ge 2 && $(grep -c 'yarn\.lock' "$stat_f") -ge 1 ]] && r=ok || r=bad
expect "lockfiles (root + nested package-lock.json, yarn.lock) listed in diff stat" "$r"
! grep -qE '^(diff --git|\+\+\+|---) .*(package-lock\.json|yarn\.lock)' "$diff_f" && r=ok || r=bad
expect "lockfiles absent from the diff body" "$r"
# Same check on the assembled prompt: everything after the Diff heading.
body=$(sed -n '/^# Diff/,$p' "$rpfile")
[[ $body == *"a.txt"* && $body != *"diff --git a/package-lock.json"* && $body != *"diff --git a/pkg/package-lock.json"* && $body != *"diff --git a/yarn.lock"* ]] && r=ok || r=bad
expect "reviewer prompt's Diff block has a.txt but no lockfile diffs" "$r"
exit $fail
