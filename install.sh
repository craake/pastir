#!/usr/bin/env bash
# Run inside WSL:  bash install.sh
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
dest="${LOOP_HOME:-$HOME/.agent-loop}"

mkdir -p "$dest" "$HOME/.local/bin"
cp -r "$src/bin" "$src/prompts" "$dest/"
# keep an existing config so re-installs don't overwrite your model choices
mkdir -p "$dest/config"
[[ -f "$dest/config/roles.conf" ]] || cp "$src/config/roles.conf" "$dest/config/"
chmod +x "$dest/bin/"*
ln -sf "$dest/bin/loop" "$HOME/.local/bin/loop"
ln -sf "$dest/bin/subagent" "$HOME/.local/bin/subagent"
# Remember this shell's PATH (where claude/codex/node live) for launches from PowerShell,
# which start WSL without reading ~/.bashrc. Re-run install.sh if you move those tools.
printf 'export PATH=%q:"$PATH"\n' "$PATH" > "$dest/config/path.env"

echo "Installed to $dest"

# PowerShell `loop` function (for running loop straight from a Herdr/PowerShell terminal).
# Written between marker lines so re-running install.sh replaces it instead of duplicating it.
install_ps_profile() {
  local exe=$1 winpath prof
  command -v "$exe" >/dev/null || return 0
  winpath=$(timeout 60 "$exe" -NoLogo -NoProfile -NonInteractive -Command '$PROFILE' 2>/dev/null | tr -d '\r') || return 0
  [[ -n "$winpath" ]] || return 0
  prof=$(wslpath -u "$winpath") || return 0
  mkdir -p "$(dirname "$prof")" && touch "$prof"
  sed -i '/^# >>> agent-loop >>>/,/^# <<< agent-loop <<</d' "$prof"
  [[ ! -s "$prof" || -z "$(tail -c1 "$prof")" ]] || printf '\r\n' >> "$prof"
  { echo "# >>> agent-loop >>>  (managed by agent-loop install.sh)"
    grep -v '^#' "$src/windows/loop.ps1" \
      | sed -e "s|__DISTRO__|$WSL_DISTRO_NAME|" -e "s|__LOOP__|$HOME/.local/bin/loop|"
    echo "# <<< agent-loop <<<"
  } | sed 's/$/\r/' >> "$prof"
  echo "  ✓ PowerShell 'loop' function → $winpath"
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
