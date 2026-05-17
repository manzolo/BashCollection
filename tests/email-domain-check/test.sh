#!/usr/bin/env bash
# Functional test for email-domain-check.
# Runs against example.com (an IANA-reserved domain that has reliably
# resolvable SPF/DMARC/MX records) and asserts the four expected
# section markers show up in the summary block.
set -euo pipefail

BIN="${PKG_BIN:-/usr/local/bin/email-domain-check}"
[[ -x "$BIN" ]] || { echo "binary not found: $BIN" >&2; exit 1; }

out=$("$BIN" example.com 2>&1) || {
  echo "ASSERTION FAILED: command exited non-zero" >&2
  echo "$out" >&2
  exit 1
}

for marker in "SPF:" "DKIM:" "DMARC:" "MX:" "EMAIL CHECK: example.com"; do
  if ! grep -qF -- "$marker" <<<"$out"; then
    echo "ASSERTION FAILED: expected output to contain '$marker'" >&2
    echo "--- output: ---" >&2
    echo "$out" >&2
    exit 1
  fi
done

echo "email-domain-check functional test: PASS"
