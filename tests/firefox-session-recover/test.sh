#!/usr/bin/env bash
# Functional test for firefox-session-recover.
# Asserts that the --help payload contains the documented usage
# header and the key descriptive sections. The actual restore flow
# needs a real Firefox profile + sessionstore-backups dir, so we
# don't exercise it here.
set -euo pipefail

BIN="${PKG_BIN:-/usr/local/bin/firefox-session-recover}"
[[ -x "$BIN" ]] || { echo "binary not found: $BIN" >&2; exit 1; }

out=$("$BIN" --help 2>&1)

for marker in "Usage:" "firefox-session-recover"; do
  if ! grep -qF -- "$marker" <<<"$out"; then
    echo "ASSERTION FAILED: --help missing '$marker'" >&2
    echo "$out" >&2
    exit 1
  fi
done

echo "firefox-session-recover functional test: PASS"
