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

echo "Installed to $dest"
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
