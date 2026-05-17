#!/usr/bin/env bash
# Build the .deb for a single mapped package and print its path.
#
# Usage: bash .github/scripts/build-pkg.sh <pkg-name>
#
# Wraps `./menage_scripts.sh build <pkg>` and parses the
# `✔ Built: /abs/path/foo.deb` line from its output, because the .deb
# filename uses PKG_NAME (from the script header) which may differ from
# the mapped command name (e.g. `mcleaner` builds `manzolo-cleaner_*.deb`).
set -euo pipefail

PKG="${1:-}"
if [[ -z "$PKG" ]]; then
  echo "Usage: $0 <pkg-name>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

log=$(mktemp)
trap 'rm -f "$log"' EXIT

# Send the build output to stderr (so it shows up in the CI log) and keep
# stdout reserved for the .deb path the caller wants to capture.
if ! ./menage_scripts.sh build "$PKG" >"$log" 2>&1; then
  cat "$log" >&2
  echo "::error title=Build failed::menage_scripts.sh build $PKG exited non-zero" >&2
  exit 1
fi
cat "$log" >&2

# Strip ANSI codes so the regex matches even when colours are emitted.
deb=$(sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$log" \
      | grep -oE '✔ Built: .+\.deb' \
      | sed -E 's/^✔ Built: //' \
      | tail -n 1)

if [[ -z "$deb" || ! -f "$deb" ]]; then
  echo "::error title=Build parse failed::could not extract .deb path from build output" >&2
  exit 1
fi

echo "$deb"
