#!/usr/bin/env bash
# Run inside WSL:  bash install.sh
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
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
install_ps_profile() {
  local exe=$1 winpath prof tmp block bom=
  command -v "$exe" >/dev/null || return 0
  winpath=$(timeout 60 "$exe" -NoLogo -NoProfile -NonInteractive -Command '$PROFILE' 2>/dev/null | tr -d '\r') || return 0
  [[ -n "$winpath" ]] || return 0
  prof=$(wslpath -u "$winpath") || return 0
  # Render the managed block before touching the profile: a failed grep/sed inside a larger pipeline
  # would otherwise be masked and leave an empty block behind a success message.
  block=$(grep -v '^#' "$src/windows/pastir.ps1" \
    | sed -e "s|__DISTRO__|$WSL_DISTRO_NAME|" -e "s|__PASTIR__|$HOME/.local/bin/pastir|") \
    && [[ -n "$block" ]] || die "cannot render $src/windows/pastir.ps1; $winpath left unchanged"
  mkdir -p "$(dirname "$prof")" && touch "$prof"
  # Update a symlinked profile at its target, so the link survives the mv below.
  prof=$(readlink -f -- "$prof") || die "cannot resolve $winpath; left unchanged"
  # Build the new profile in a temp file and only copy it over the profile once it is complete.
  # Windows PowerShell often saves profiles as UTF-8 with BOM: strip it so a marker on line 1
  # matches, and put it back so the file's encoding is unchanged.
  [[ "$(head -c3 "$prof" | od -An -tx1 | tr -d ' \n')" == efbbbf ]] && bom=1
  # The temp file lives next to the profile so the final mv is an atomic same-filesystem rename.
  tmp=$(mktemp "$prof.XXXXXX") || die "cannot create temp file next to $winpath; left unchanged"
  {
    { [[ -z "$bom" ]] || printf '\xEF\xBB\xBF'; } &&
    { if [[ -n "$bom" ]]; then tail -c +4 "$prof"; else cat "$prof"; fi |
        # also strips the block written before the rename (agent-loop)
        sed -e '/^# >>> agent-loop >>>/,/^# <<< agent-loop <<</d' \
            -e '/^# >>> pastir >>>/,/^# <<< pastir <<</d'; }
  } > "$tmp" &&
  {
    { [[ ! -s "$tmp" || -z "$(tail -c1 "$tmp")" ]] || printf '\r\n'; } &&
    { echo "# >>> pastir >>>  (managed by pastir install.sh)"
      printf '%s\n' "$block"
      echo "# <<< pastir <<<"
    } | sed 's/$/\r/'
  } >> "$tmp" || { rm -f "$tmp"; die "cannot build new profile; $winpath left unchanged"; }
  # mktemp creates 0600: copy the original's permissions before replacing it.
  chmod --reference="$prof" -- "$tmp" && mv -f -- "$tmp" "$prof" \
    || { rm -f "$tmp"; die "cannot replace $winpath; left unchanged"; }
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
