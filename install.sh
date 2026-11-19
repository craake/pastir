#!/usr/bin/env bash
# Run inside WSL:  bash install.sh
set -euo pipefail
src="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
dest="${LOOP_HOME:-$HOME/.pastir}"
die() { echo "install.sh: $*" >&2; exit 1; }

mkdir -p "$dest" "$HOME/.local/bin"
# Absolute path: the links in ~/.local/bin would otherwise resolve a relative LOOP_HOME from there.
dest=$(CDPATH= cd -- "$dest" && pwd) || die "cannot resolve install dir: $dest"
old="$HOME/.agent-loop"   # pre-rename install location
# The old README encouraged editing ~/.agent-loop/prompts/*.md. Back them up before the copy below
# (which overwrites them when LOOP_HOME is the old dir) instead of silently dropping the edits.
# A file counts as unedited if it matches the shipped prompt, with or without the loop/<id> ->
# pastir/<id> rename.
if [[ -d "$old/prompts" ]]; then
  bak="$dest/prompts.agent-loop-backup"
  backed_up=0
  for f in "$old"/prompts/*.md; do
    [[ -f "$f" ]] || continue
    n=$(basename "$f")
    if [[ -f "$src/prompts/$n" ]] && {
         cmp -s "$f" "$src/prompts/$n" ||
         cmp -s "$f" <(sed 's|`pastir/<id>`|`loop/<id>`|g' "$src/prompts/$n"); }; then
      continue
    fi
    [[ -e "$bak/$n" ]] && continue   # keep an earlier backup; never overwrite it
    # Stage under a temp name, then rename: a partial copy is never mistaken for a finished backup.
    # Abort on any failure, before the copy below can overwrite the only copy of the edits.
    mkdir -p "$bak" || die "cannot create $bak; nothing was overwritten"
    tmp=$(mktemp "$bak/.$n.XXXXXX") || die "cannot stage a backup of $f; nothing was overwritten"
    if ! { cp "$f" "$tmp" && mv "$tmp" "$bak/$n"; }; then
      rm -f "$tmp"
      die "backup of $f failed; nothing was overwritten"
    fi
    backed_up=1
    echo "Backed up customised prompt: $bak/$n"
  done
  if (( backed_up )); then
    echo "  Your old prompts differ from the new ones in $dest/prompts/ - merge your edits by hand"
    echo "  (e.g. diff -u \"$dest/prompts/<name>.md\" \"$bak/<name>.md\")."
  fi
fi
cp -r "$src/bin" "$src/prompts" "$dest/"
# keep an existing config so re-installs don't overwrite your model choices
mkdir -p "$dest/config"
if [[ ! -f "$dest/config/roles.conf" && -f "$old/config/roles.conf" && ! "$old" -ef "$dest" ]]; then
  # Stage in the destination dir and rename, so an interrupted copy never leaves a partial
  # roles.conf that the next run would mistake for a finished migration.
  tmp=$(mktemp "$dest/config/.roles.conf.XXXXXX") || die "cannot stage $old/config/roles.conf"
  if ! { cp "$old/config/roles.conf" "$tmp" && mv "$tmp" "$dest/config/roles.conf"; }; then
    rm -f "$tmp"
    die "cannot migrate $old/config/roles.conf"
  fi
  echo "Migrated roles.conf from $old"
fi
if [[ ! -f "$dest/config/roles.conf" ]]; then
  tmp=$(mktemp "$dest/config/.roles.conf.XXXXXX") || die "cannot stage default roles.conf"
  if ! { cp "$src/config/roles.conf" "$tmp" && mv "$tmp" "$dest/config/roles.conf"; }; then
    rm -f "$tmp"
    die "cannot install default roles.conf"
  fi
fi
chmod +x "$dest/bin/"*
ln -sf "$dest/bin/pastir" "$HOME/.local/bin/pastir"
ln -sf "$dest/bin/subagent" "$HOME/.local/bin/subagent"
# Remember this shell's PATH (where claude/codex/node live) for launches from PowerShell,
# which start WSL without reading ~/.bashrc. Re-run install.sh if you move those tools.
printf 'export PATH=%q:"$PATH"\n' "$PATH" > "$dest/config/path.env"

echo "Installed to $dest"

# The command used to be `loop`: drop its link if it points at an old loop executable
# (default ~/.agent-loop, or this install dir when LOOP_HOME is custom).
lnk="$HOME/.local/bin/loop"
if [[ -L "$lnk" ]]; then
  t=$(readlink -m "$lnk")
  if [[ "$t" == "$(readlink -m "$old/bin/loop")" || "$t" == "$(readlink -m "$dest/bin/loop")" \
        || "$(readlink "$lnk")" == */.agent-loop/bin/loop ]]; then
    rm -f "$lnk" && echo "Removed old 'loop' link (now: pastir)"
  fi
fi
rm -f "$dest/bin/loop"   # stale pre-rename executable left by cp -r over an old install dir
# Only suggest deleting the old dir when the active install is not it or inside it
# (readlink -m normalises trailing slashes and symlinks).
old_r=$(readlink -m "$old")
dest_r=$(readlink -m "$dest")
if [[ -d "$old" && "$dest_r" != "$old_r" && "$dest_r" != "$old_r"/* ]]; then
  echo "Old install at ~/.agent-loop is no longer used; after merging any backed-up prompts, remove it with: rm -rf ~/.agent-loop"
fi

# PowerShell `pastir` function (for running pastir straight from a Herdr/PowerShell terminal).
# Written between marker lines so re-running install.sh replaces it instead of duplicating it.
# ps_tmp: private staging dir of the profile being updated; ps_dtmp: staged new profile beside its
# destination; ps_keep: set while the profile may be half-written, so the recovery copy must survive.
ps_tmp=; ps_dtmp=; ps_keep=
ps_cleanup() {
  [[ -z "$ps_dtmp" ]] || rm -f -- "$ps_dtmp"
  if [[ -n "$ps_tmp" ]]; then
    if [[ -n "$ps_keep" ]]; then
      echo "install.sh: profile may be incomplete; recovery copy kept at $ps_tmp/profile.orig" >&2
    else
      rm -rf -- "$ps_tmp"
    fi
  fi
}
trap ps_cleanup EXIT
install_ps_profile() {
  local exe=$1 winpath prof block bom= existed= body msg in stage orig dest_dir interrupted= try restored= mode state
  command -v "$exe" >/dev/null || return 0
  winpath=$(timeout 60 "$exe" -NoLogo -NoProfile -NonInteractive -Command '$PROFILE' 2>/dev/null | tr -d '\r') || return 0
  [[ -n "$winpath" ]] || return 0
  prof=$(wslpath -u "$winpath") || return 0
  # Render the managed block before touching the profile: a failed grep/sed inside a larger pipeline
  # would otherwise be masked and leave an empty block behind a success message.
  block=$(grep -v '^#' "$src/windows/pastir.ps1" \
    | sed -e "s|__DISTRO__|$WSL_DISTRO_NAME|" -e "s|__PASTIR__|$HOME/.local/bin/pastir|") \
    && [[ -n "$block" ]] || die "cannot render $src/windows/pastir.ps1; $winpath left unchanged"
  # Update a symlinked profile at its target. -m tolerates a profile (or its folder) that does not exist yet.
  prof=$(readlink -m -- "$prof") || die "cannot resolve $winpath; left unchanged"
  # Private (mode 700) staging dir: the recovery copy holds the profile's contents, so it must not be
  # readable by others whatever the profile's own mode or directory was. One dir per profile, removed
  # by ps_cleanup (also on die/exit/fatal signals), so a failure leaves the profile alone.
  ps_tmp=$(umask 077 && mktemp -d) || die "cannot create temp dir; $winpath left unchanged"
  stage=$ps_tmp/profile.new
  orig=$ps_tmp/profile.orig
  body=$ps_tmp/profile.body
  # Snapshot first, and build everything from the snapshot, never from a second read of the live
  # profile: the write below can then tell whether someone edited the profile in between.
  # A missing profile is just empty input; nothing is created until the final write.
  in=/dev/null
  if [[ -e "$prof" ]]; then
    existed=1
    in=$orig
    (umask 077; cat -- "$prof" > "$orig") || die "cannot read $winpath; left unchanged"
    # Windows PowerShell often saves profiles as UTF-8 with BOM: strip it so a marker on line 1
    # matches, and put it back so the file's encoding is unchanged.
    [[ "$(head -c3 -- "$in" | od -An -tx1 | tr -d ' \n')" == efbbbf ]] && bom=1
  fi
  (umask 077; if [[ -n "$bom" ]]; then tail -c +4 -- "$in"; else cat -- "$in"; fi > "$body") \
    || die "cannot read $winpath; left unchanged"
  # Only strip complete start/end pairs (CRLF tolerated): a sed range with no end marker would delete
  # the rest of the profile. Anything unpaired means someone edited the block; leave the file alone.
  msg=$(awk '
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^# >>> (agent-loop|pastir) >>>/ {
      if (open != "") { print "start marker at line " NR " inside the block started at line " sl; bad = 1; exit }
      open = $3; sl = NR; next }
    line ~ /^# <<< (agent-loop|pastir) <<</ {
      if (open == "" || $3 != open) { print "end marker at line " NR " has no matching start"; bad = 1; exit }
      open = ""; next }
    END { if (!bad && open != "") { print "start marker at line " sl " has no matching end"; bad = 1 }; exit bad }
  ' "$body") || die "$winpath has a damaged managed block ($msg); left unchanged"
  (umask 077; {
    { [[ -z "$bom" ]] || printf '\xEF\xBB\xBF'; } &&
    # also strips the block written before the rename (agent-loop)
    sed -e '/^# >>> agent-loop >>>/,/^# <<< agent-loop <<</d' \
        -e '/^# >>> pastir >>>/,/^# <<< pastir <<</d' "$body"
  } > "$stage" ) &&
  {
    { [[ ! -s "$stage" || -z "$(tail -c1 "$stage")" ]] || printf '\r\n'; } &&
    { echo "# >>> pastir >>>  (managed by pastir install.sh)"
      printf '%s\n' "$block"
      echo "# <<< pastir <<<"
    } | sed 's/$/\r/'
  } >> "$stage" || die "cannot build new profile; $winpath left unchanged"
  if [[ -n "$existed" ]]; then
    # Write through the existing file rather than renaming over it: its inode, hard links, ownership,
    # mode and ACLs survive. That is not atomic, so keep a copy and restore it if the write fails or
    # is interrupted; $orig is that copy. Refuse if the profile is no longer what we built from.
    cmp -s -- "$orig" "$prof" || die "profile changed during install; $winpath left unchanged"
    # From here until the profile is verified, the recovery copy must outlive any exit. INT/TERM/HUP
    # only set a flag, so the restore below always gets to run (bash defers the trap until the
    # foreground cat ends; if cat itself was killed, the profile is simply truncated and restored).
    ps_keep=1
    trap 'interrupted=1' INT TERM HUP
    if ! { cat -- "$stage" > "$prof"; } 2>/dev/null || [[ -n "$interrupted" ]] || ! cmp -s -- "$stage" "$prof"; then
      # Often the write is refused before anything is truncated; then there is nothing to restore.
      if ! cmp -s -- "$orig" "$prof"; then
        for try in 1 2 3; do
          { cat -- "$orig" > "$prof"; } 2>/dev/null || :   # judged by cmp below, not by exit status
          if cmp -s -- "$orig" "$prof"; then restored=1; break; fi
        done
        if [[ -z "$restored" ]]; then
          trap - INT TERM HUP
          echo "install.sh: could not restore $winpath" >&2
          exit 1   # ps_cleanup keeps and reports the recovery copy (ps_keep is still set)
        fi
      fi
      trap - INT TERM HUP
      ps_keep=
      state="left unchanged"; [[ -z "$restored" ]] || state="original restored"
      [[ -z "$interrupted" ]] || die "interrupted; $winpath $state"
      die "cannot write $winpath; $state"
    fi
    trap - INT TERM HUP
    ps_keep=
  else
    # New profile: nothing to preserve, so stage it next to its destination and link it into place.
    # ln (unlike mv) refuses to replace an existing name, so a profile created meanwhile is never
    # clobbered, and a failed or partial write never leaves half a script at the real path.
    dest_dir=$(dirname -- "$prof")
    mkdir -p -- "$dest_dir" && ps_dtmp=$(mktemp -- "$dest_dir/.pastir-profile.XXXXXX") \
      || die "cannot create $winpath"
    mode=$(printf '%03o' $(( 0666 & ~$(umask) )))
    { cat -- "$stage" > "$ps_dtmp" && chmod "$mode" "$ps_dtmp" 2>/dev/null; } || true
    cmp -s -- "$stage" "$ps_dtmp" || die "cannot create $winpath"
    if ! ln -- "$ps_dtmp" "$prof" 2>/dev/null; then
      [[ ! -e "$prof" && ! -L "$prof" ]] || die "profile appeared during install; $winpath left unchanged"
      # No hard links on this filesystem: claim the name exclusively (noclobber = O_EXCL), then fill it.
      (set -C; : > "$prof") 2>/dev/null || die "profile appeared during install; $winpath left unchanged"
      if ! { cat -- "$stage" > "$prof"; } 2>/dev/null || ! cmp -s -- "$stage" "$prof"; then
        rm -f -- "$prof"   # we created it a moment ago, so removing it is safe
        die "cannot create $winpath"
      fi
    fi
    rm -f -- "$ps_dtmp"; ps_dtmp=
  fi
  rm -rf -- "$ps_tmp"; ps_tmp=
  echo "  ✓ PowerShell 'pastir' function → $winpath"
}
if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
  install_ps_profile pwsh.exe         # PowerShell 7
  install_ps_profile powershell.exe   # Windows PowerShell 5.1
fi

for c in claude codex git; do
  command -v "$c" >/dev/null && echo "  ✓ $c" || echo "  ✗ $c not found (required)"
done
command -v omp >/dev/null && echo "  ✓ omp (optional)" || echo "  - omp not found (optional)"
if command -v hc >/dev/null && hc ls >/dev/null 2>&1; then
  echo "  ✓ hc (WSL) reachable — subagents will open as Herdr terminals"
elif command -v hc.exe >/dev/null && hc.exe ls >/dev/null 2>&1; then
  echo "  ✓ hc.exe (Windows Herdr app) reachable via interop — subagents will open as Herdr terminals"
else
  echo "  - Herdr not reachable from WSL — subagents will run inline in the orchestrator's pane"
  echo "    (to fix: make sure the Windows folder containing hc.exe is on the Windows PATH, then reopen WSL)"
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Add to ~/.bashrc:  export PATH=\"\$HOME/.local/bin:\$PATH\"";; esac
