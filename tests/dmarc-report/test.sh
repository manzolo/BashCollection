#!/usr/bin/env bash
# Functional test for dmarc-report.
# Runs the installed binary against a synthetic DMARC XML and asserts
# that key fields from the fixture show up in the report.
set -euo pipefail

BIN="${PKG_BIN:-/usr/local/bin/dmarc-report}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$HERE/fixtures/sample.xml"

[[ -x "$BIN" ]] || { echo "binary not found: $BIN" >&2; exit 1; }
[[ -f "$FIXTURE" ]] || { echo "fixture missing: $FIXTURE" >&2; exit 1; }

out=$("$BIN" "$FIXTURE" 2>&1)

assert_contains() {
  local needle="$1"
  if ! grep -qF -- "$needle" <<<"$out"; then
    echo "ASSERTION FAILED: expected output to contain '$needle'" >&2
    echo "--- output was: ---" >&2
    echo "$out" >&2
    exit 1
  fi
}

assert_contains "SampleOrg"
assert_contains "198.51.100.10"
assert_contains "203.0.113.50"
# The fixture has both a pass and a fail record — sanity check both
# outcomes appear (printed capitalised in the result table).
assert_contains "Pass"
assert_contains "Fail"

echo "dmarc-report functional test: PASS"
