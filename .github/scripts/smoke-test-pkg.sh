#!/usr/bin/env bash
# Run the smoke test for a single mapped package.
#
# Usage: bash .github/scripts/smoke-test-pkg.sh <pkg-name>
#
# Reads .github/smoke-tests.yaml. If the package has `skip`, prints a
# SKIPPED notice and exits 0. Otherwise installs any `apt_deps` and
# invokes the installed command (from /usr/local/bin) with `cmd`.
#
# Honours $GITHUB_STEP_SUMMARY when set to append a one-line outcome
# row, so the job summary at the bottom of the CI run shows per-package
# results at a glance.
set -euo pipefail

PKG="${1:-}"
if [[ -z "$PKG" ]]; then
  echo "Usage: $0 <pkg-name>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$REPO_ROOT/.github/smoke-tests.yaml"

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: $CONFIG not found" >&2
  exit 1
fi

# Extract the per-package config as JSON via Python (PyYAML is on
# ubuntu-latest by default). Empty object if the package is absent.
pkg_json=$(python3 - "$CONFIG" "$PKG" <<'PY'
import json, sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
print(json.dumps(data.get(sys.argv[2], {})))
PY
)

skip_reason=$(printf '%s' "$pkg_json" | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("skip","") or "")')
apt_deps=$(printf '%s' "$pkg_json" | python3 -c \
  'import json,sys; print(" ".join(json.load(sys.stdin).get("apt_deps", []) or []))')
test_script=$(printf '%s' "$pkg_json" | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("script","") or "")')
mapfile -t cmd_args < <(printf '%s' "$pkg_json" | python3 -c \
  'import json,sys
d = json.load(sys.stdin)
for a in (d.get("cmd") or ["--help"]):
    print(a)')

summary_line() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  printf '| %s | %s |\n' "$PKG" "$1" >> "$GITHUB_STEP_SUMMARY"
}

# Initialise the summary table once per workflow job
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && [[ ! -s "${GITHUB_STEP_SUMMARY}" ]]; then
  {
    echo "## Smoke test result"
    echo ""
    echo "| package | outcome |"
    echo "| --- | --- |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ -n "$skip_reason" ]]; then
  echo "::notice title=Smoke skipped::$PKG — $skip_reason"
  echo "⊘ SKIPPED ($PKG): $skip_reason"
  summary_line "⊘ skipped — $skip_reason"
  exit 0
fi

if [[ -n "$apt_deps" ]]; then
  echo "Installing extra apt deps: $apt_deps"
  sudo apt-get install -y --no-install-recommends $apt_deps
fi

# Resolve the installed command. We expect the .deb to be installed
# already (separate CI step), so the wrapper lives in /usr/local/bin.
bin="/usr/local/bin/$PKG"
if [[ ! -x "$bin" ]]; then
  if command -v "$PKG" >/dev/null 2>&1; then
    bin=$(command -v "$PKG")
  else
    echo "::error title=Smoke missing binary::$PKG not found in PATH"
    summary_line "✗ binary not installed"
    exit 1
  fi
fi

# If `script:` is set in the config, run the functional test script
# instead of (or in addition to) the basic cmd invocation. The script
# is expected to assert behaviour against fixtures and exit 0 on
# success. The `cmd` smoke run still happens first as a sanity check.
echo "::group::$PKG ${cmd_args[*]}"
set +e
"$bin" "${cmd_args[@]}"
rc=$?
set -e
echo "::endgroup::"

if [[ $rc -ne 0 ]]; then
  echo "::error title=Smoke failed::$PKG ${cmd_args[*]} exited $rc"
  summary_line "✗ ${cmd_args[*]} (exit $rc)"
  exit "$rc"
fi
echo "✓ $PKG ${cmd_args[*]} → exit 0"

if [[ -n "$test_script" ]]; then
  test_path="$REPO_ROOT/$test_script"
  if [[ ! -x "$test_path" ]]; then
    echo "::error title=Test script missing::$test_path not found or not executable"
    summary_line "✗ test script $test_script missing"
    exit 1
  fi
  echo "::group::$PKG functional test ($test_script)"
  set +e
  PKG_BIN="$bin" "$test_path"
  rc=$?
  set -e
  echo "::endgroup::"
  if [[ $rc -eq 0 ]]; then
    echo "✓ $PKG functional test → exit 0"
    summary_line "✓ ${cmd_args[*]} + functional"
  else
    echo "::error title=Functional test failed::$test_script exited $rc"
    summary_line "✗ functional test (exit $rc)"
    exit "$rc"
  fi
else
  summary_line "✓ ${cmd_args[*]}"
fi
