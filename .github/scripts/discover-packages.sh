#!/usr/bin/env bash
# Emit the list of mapped commands from .manzolomap as a JSON array.
#
# Used by the CI `discover` job to build the matrix of per-package smoke
# jobs. Also runnable locally for debugging:
#   bash .github/scripts/discover-packages.sh
#
# Output formats:
#   - stdout: compact JSON like ["mchroot","mcleaner",...,"openrouter-claude"]
#   - $GITHUB_OUTPUT (when set): appends `packages=<json>`
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAP="$REPO_ROOT/.manzolomap"

if [[ ! -f "$MAP" ]]; then
  echo "Error: .manzolomap not found at $MAP" >&2
  exit 1
fi

names=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  names+=("${line#*#}")
done < "$MAP"

# Compose JSON array without external deps
json="["
for i in "${!names[@]}"; do
  [[ $i -gt 0 ]] && json+=","
  json+="\"${names[$i]}\""
done
json+="]"

echo "$json"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "packages=$json" >> "$GITHUB_OUTPUT"
fi
