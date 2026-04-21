#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_BIN="$(mktemp -d)"
trap 'rm -rf "$TMP_BIN"' EXIT

while IFS= read -r mapping; do
    [[ -z "$mapping" || "$mapping" == \#* ]] && continue

    script_path="${mapping%%#*}"
    command_name="${mapping#*#}"

    if [[ ! -f "$REPO_ROOT/$script_path" ]]; then
        echo "Mapped script not found: $script_path"
        exit 1
    fi

    cat > "$TMP_BIN/$command_name" <<EOF
#!/usr/bin/env bash
exec bash "$REPO_ROOT/$script_path" "\$@"
EOF
    chmod +x "$TMP_BIN/$command_name"
done < "$REPO_ROOT/.manzolomap"

export PATH="$TMP_BIN:$PATH"

run_check() {
    local label="$1"
    shift

    echo "::group::$label"
    "$@"
    echo "::endgroup::"
}

run_check "mchroot --help" mchroot --help
run_check "mtest --help" mtest --help
run_check "firefox-session-recover --help" firefox-session-recover --help
run_check "network-viewer --help" network-viewer --help
run_check "share-manager info" share-manager info
run_check "ollama-claude --version" ollama-claude --version
run_check "ollama-claude --help" ollama-claude --help
run_check "ollama-codex --version" ollama-codex --version
run_check "ollama-codex --help" ollama-codex --help
run_check "openrouter-claude --version" openrouter-claude --version
run_check "openrouter-claude --help" openrouter-claude --help
