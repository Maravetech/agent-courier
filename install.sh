#!/usr/bin/env bash
# Link the courier skill into other agents' skill folders (Claude Code users: install the plugin instead).
# Usage: ./install.sh [--check] [dir ...]
# Default dirs: ~/.agents/skills (Codex and other agents), ~/.openclaw/skills, ~/.hermes/skills. Only existing parents are touched.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills/courier"
CHECK=0
if [[ "${1:-}" == "--check" ]]; then CHECK=1; shift; fi
DIRS=("$@")
if [[ ${#DIRS[@]} -eq 0 ]]; then DIRS=("$HOME/.agents/skills" "$HOME/.openclaw/skills" "$HOME/.hermes/skills"); fi
rc=0
for d in "${DIRS[@]}"; do
  link="$d/courier"
  if [[ ! -d "$d" ]]; then echo "skip   $d (not found)"; continue; fi
  if [[ -L "$link" && "$(readlink "$link")" == "$SRC" ]]; then echo "ok     $link"; continue; fi
  if [[ -e "$link" || -L "$link" ]]; then echo "CONFLICT $link exists and is not our link; leaving it alone"; rc=2; continue; fi
  if [[ $CHECK -eq 1 ]]; then echo "missing $link"; rc=2; continue; fi
  ln -s "$SRC" "$link" && echo "linked $link -> $SRC"
done
exit $rc
