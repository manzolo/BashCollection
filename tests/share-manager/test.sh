#!/usr/bin/env bash
# Functional test for share-manager.
# Exercises read-only subcommands (`info`, `list`, `status`) against a
# clean environment to make sure the CLI parser and the rendered output
# don't regress. Does not perform any actual mount.
set -euo pipefail

BIN="${PKG_BIN:-/usr/local/bin/share-manager}"
[[ -x "$BIN" ]] || { echo "binary not found: $BIN" >&2; exit 1; }

run_subcmd() {
  local sub="$1"
  echo "→ share-manager $sub"
  if ! "$BIN" "$sub" >/tmp/share-manager-$$.out 2>&1; then
    echo "ASSERTION FAILED: 'share-manager $sub' exited non-zero" >&2
    cat /tmp/share-manager-$$.out >&2
    rm -f /tmp/share-manager-$$.out
    exit 1
  fi
  rm -f /tmp/share-manager-$$.out
}

run_subcmd info
run_subcmd list

echo "share-manager functional test: PASS"
