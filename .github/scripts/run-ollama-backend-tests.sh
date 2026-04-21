#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_HOME="$(mktemp -d)"
TMP_BIN="$(mktemp -d)"
CONTAINER_NAME="ollama-mock-ci"

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$TEST_HOME" "$TMP_BIN"
}

trap cleanup EXIT

cat > "$TMP_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HOME/claude_invocation.txt"
EOF

cat > "$TMP_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HOME/codex_invocation.txt"
EOF

chmod +x "$TMP_BIN/claude" "$TMP_BIN/codex"

docker run -d \
    --name "$CONTAINER_NAME" \
    -p 11434:11434 \
    -v "$REPO_ROOT/.github/scripts/mock_ollama.py:/app/mock_ollama.py:ro" \
    python:3.12-alpine \
    python /app/mock_ollama.py >/dev/null

for _ in {1..30}; do
    if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

curl -fsS http://127.0.0.1:11434/api/tags | jq -e '.models | length >= 1' >/dev/null

export HOME="$TEST_HOME"
export PATH="$TMP_BIN:$PATH"
export OLLAMA_SERVER_URL="http://127.0.0.1:11434"
export MODEL="tinyllama:latest"

echo "::group::ollama-claude --list"
claude_list_output="$(bash "$REPO_ROOT/utils/ollama-tools/ollama-claude.sh" --list 2>&1)"
printf '%s\n' "$claude_list_output"
grep -F "Available models on http://127.0.0.1:11434:" <<<"$claude_list_output"
grep -F "tinyllama:latest" <<<"$claude_list_output"
grep -F "qwen2.5-coder:1.5b" <<<"$claude_list_output"
echo "::endgroup::"

echo "::group::ollama-codex --list"
codex_list_output="$(bash "$REPO_ROOT/utils/ollama-tools/ollama-codex.sh" --list 2>&1)"
printf '%s\n' "$codex_list_output"
grep -F "Available models on http://127.0.0.1:11434:" <<<"$codex_list_output"
grep -F "tinyllama:latest" <<<"$codex_list_output"
grep -F "qwen2.5-coder:1.5b" <<<"$codex_list_output"
echo "::endgroup::"

echo "::group::ollama-claude execution path"
bash "$REPO_ROOT/utils/ollama-tools/ollama-claude.sh" -- --print
grep -Fx -- "--model" "$HOME/claude_invocation.txt"
grep -Fx -- "tinyllama:latest" "$HOME/claude_invocation.txt"
grep -Fx -- "--print" "$HOME/claude_invocation.txt"
echo "::endgroup::"

echo "::group::ollama-codex execution path"
bash "$REPO_ROOT/utils/ollama-tools/ollama-codex.sh" -- --help
grep -Fx -- "--profile" "$HOME/codex_invocation.txt"
grep -Fx -- "ollama-remote" "$HOME/codex_invocation.txt"
grep -Fx -- "--help" "$HOME/codex_invocation.txt"
grep -F 'base_url = "http://127.0.0.1:11434/v1"' "$HOME/.codex/config.toml"
grep -F 'model = "tinyllama:latest"' "$HOME/.codex/config.toml"
echo "::endgroup::"
