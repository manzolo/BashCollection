#!/bin/bash
# PKG_NAME: llamacpp-claude
# PKG_VERSION: 1.1.4
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), curl, jq, python3, python3-requests
# PKG_RECOMMENDS: fzf
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Run Claude CLI with a llama.cpp server backend
# PKG_LONG_DESCRIPTION: Wrapper for the Claude CLI that redirects API calls
#  to a llama-server instance instead of Anthropic's cloud. Uses an embedded
#  proxy to translate the Anthropic Messages API to the OpenAI-compatible API
#  exposed by llama-server (local or remote, no SSH required).
#  .
#  Features:
#  - Interactive model selection via fzf or numbered list
#  - First-run guided configuration wizard
#  - JSON config file (server_url, proxy_port, default_model)
#  - Auto-installs the Claude CLI if not present
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
set -euo pipefail

readonly VERSION="1.1.4"
PROXY_SCRIPT="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/llamacpp-proxy.py"
readonly PROXY_SCRIPT

# --- Config ----------------------------------------------------------------
CONFIG_DIR="$HOME/.config/manzolo/llamacpp-claude"
CONFIG_FILE="$CONFIG_DIR/config.json"

readonly _BS_SERVER_URL="http://localhost:11435"
readonly _BS_DEFAULT_MODEL=""
readonly _BS_PROXY_PORT=11436
readonly _BS_TIMEOUT=10

LLAMA_SERVER_URL="${LLAMA_SERVER_URL:-}"
DEFAULT_MODEL="${DEFAULT_MODEL:-}"
PROXY_PORT=$_BS_PROXY_PORT
CURL_TIMEOUT=$_BS_TIMEOUT

# --- Colours ---------------------------------------------------------------
if [[ -t 2 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

info()    { echo "${CYAN}[INFO]${RESET} $*" >&2; }
warn()    { echo "${YELLOW}[WARN]${RESET} $*" >&2; }
error()   { echo "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo "${GREEN}[OK]${RESET} $*" >&2; }

# --- Cleanup ---------------------------------------------------------------
PROXY_PID=""
cleanup() {
    if [[ -n "$PROXY_PID" ]]; then kill "$PROXY_PID" 2>/dev/null; fi
}
trap cleanup EXIT

# --- Dependencies ----------------------------------------------------------
check_dependencies() {
    local missing=()
    for cmd in curl jq python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || { error "Missing dependencies: ${missing[*]}"; exit 1; }
    python3 -c "import requests" 2>/dev/null || {
        error "Missing python3 module: requests"
        error "Install with: pip3 install requests"
        exit 1
    }
    [[ -f "$PROXY_SCRIPT" ]] || {
        error "Proxy script not found: ${PROXY_SCRIPT}"
        exit 1
    }
}

# --- Config ----------------------------------------------------------------
init_config() {
    [[ -f "$CONFIG_FILE" ]] && return
    if [[ -t 0 ]]; then
        setup_first_run
    else
        mkdir -p "$CONFIG_DIR"
        jq -n \
            --arg url "$_BS_SERVER_URL" \
            --arg model "$_BS_DEFAULT_MODEL" \
            --argjson port "$_BS_PROXY_PORT" \
            --argjson timeout "$_BS_TIMEOUT" \
            '{server_url: $url, default_model: $model, proxy_port: $port, curl_timeout: $timeout}' \
            > "$CONFIG_FILE"
        warn "Config created with defaults: ${CONFIG_FILE}"
        info "  Edit this file to set server_url and default_model."
    fi
}

setup_first_run() {
    info "First-time setup for llamacpp-claude."
    local url model
    read -rp "llama-server URL [${_BS_SERVER_URL}]: " url
    [[ -z "$url" ]] && url="$_BS_SERVER_URL"
    LLAMA_SERVER_URL="$url"
    read -rp "Default model (lascia vuoto per selezione interattiva): " model
    DEFAULT_MODEL="$model"
    mkdir -p "$CONFIG_DIR"
    jq -n \
        --arg url "$LLAMA_SERVER_URL" \
        --arg model "$DEFAULT_MODEL" \
        --argjson port "$_BS_PROXY_PORT" \
        --argjson timeout "$_BS_TIMEOUT" \
        '{server_url: $url, default_model: $model, proxy_port: $port, curl_timeout: $timeout}' \
        > "$CONFIG_FILE"
    success "Config saved: ${CONFIG_FILE}"
}

load_config() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    info "Loading config: ${CONFIG_FILE}"
    local url model port timeout
    url=$(jq -r '.server_url // empty' "$CONFIG_FILE")
    model=$(jq -r '.default_model // empty' "$CONFIG_FILE")
    port=$(jq -r '.proxy_port // empty' "$CONFIG_FILE")
    timeout=$(jq -r '.curl_timeout // empty' "$CONFIG_FILE")
    [[ -n "$url"     ]] && LLAMA_SERVER_URL="${LLAMA_SERVER_URL:-$url}"
    [[ -n "$model"   ]] && DEFAULT_MODEL="${DEFAULT_MODEL:-$model}"
    [[ -n "$port"    ]] && PROXY_PORT="$port"
    [[ -n "$timeout" ]] && CURL_TIMEOUT="$timeout"
    LLAMA_SERVER_URL="${LLAMA_SERVER_URL:-$_BS_SERVER_URL}"
}

# --- Proxy -----------------------------------------------------------------
start_proxy() {
    local backend="$1" port="$2" model="$3"
    info "Starting Anthropic→OpenAI proxy on :${port} → ${backend}"
    python3 "$PROXY_SCRIPT" --port "$port" --backend "$backend" --model "$model" &
    PROXY_PID=$!
    sleep 1
    kill -0 "$PROXY_PID" 2>/dev/null || { error "Proxy failed to start."; exit 1; }
    success "Proxy active (PID ${PROXY_PID})"
}

# --- Model list ------------------------------------------------------------
_CACHED_MODELS=""

fetch_models() {
    [[ -n "$_CACHED_MODELS" ]] && { echo "$_CACHED_MODELS"; return; }
    _CACHED_MODELS=$(curl -sf --max-time "$CURL_TIMEOUT" "${LLAMA_SERVER_URL}/v1/models" \
        | jq -r '.data[].id' 2>/dev/null) || {
        error "Cannot fetch models from ${LLAMA_SERVER_URL}"
        error "Is llama-server running?"
        exit 1
    }
    [[ -n "$_CACHED_MODELS" ]] || { error "No models found at ${LLAMA_SERVER_URL}"; exit 1; }
    echo "$_CACHED_MODELS"
}

show_models() {
    info "Available models on ${BOLD}${LLAMA_SERVER_URL}${RESET}:"
    fetch_models | while read -r m; do echo "  $m"; done
}

select_model_interactive() {
    mapfile -t models < <(fetch_models)
    if [[ ${#models[@]} -eq 0 ]]; then error "No models available."; exit 1; fi

    if command -v fzf &>/dev/null; then
        local sorted=()
        for m in "${models[@]}"; do
            [[ "$m" == "$DEFAULT_MODEL" ]] && sorted=("$m" "${sorted[@]}") || sorted+=("$m")
        done
        local selected
        selected=$(printf "%s\n" "${sorted[@]}" | \
            fzf --height 40% --border --prompt 'Model> ' \
                --header "llama-server: ${LLAMA_SERVER_URL}") || true
        if [[ -z "$selected" ]]; then
            [[ -n "$DEFAULT_MODEL" ]] || { error "No model selected."; exit 1; }
            warn "Nessuna selezione. Uso default: ${DEFAULT_MODEL}"
            MODEL="$DEFAULT_MODEL"; return
        fi
        success "Selezionato: ${BOLD}${selected}${RESET}"; MODEL="$selected"; return
    fi

    echo "Modelli disponibili:" >&2
    [[ -n "$DEFAULT_MODEL" ]] && echo "  0) ${DEFAULT_MODEL} (default)" >&2
    for i in "${!models[@]}"; do
        printf "  %d) %s\n" $((i+1)) "${models[$i]}" >&2
    done
    read -rp "Numero (Invio per default): " choice
    if [[ -z "$choice" && -n "$DEFAULT_MODEL" ]]; then
        MODEL="$DEFAULT_MODEL"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#models[@]} )); then
        MODEL="${models[$((choice-1))]}"
        success "Selezionato: ${BOLD}${MODEL}${RESET}"
    else
        if [[ -n "$DEFAULT_MODEL" ]]; then MODEL="$DEFAULT_MODEL"; else error "Selezione non valida."; exit 1; fi
    fi
}

# --- Claude install --------------------------------------------------------
ensure_claude_installed() {
    command -v claude &>/dev/null && return
    warn "claude CLI non trovato."
    [[ -t 0 ]] || { error "Installa claude da https://claude.ai/install.sh"; exit 1; }
    read -rp "Installare Claude CLI ora? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { error "Claude CLI richiesto."; exit 1; }
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
    command -v claude &>/dev/null || { error "Installazione fallita."; exit 1; }
    success "Claude CLI installato."
}

# --- Help ------------------------------------------------------------------
show_help() {
    cat <<EOF
${BOLD}llamacpp-claude${RESET} v${VERSION} — Run Claude CLI with a llama.cpp server backend

${BOLD}USAGE${RESET}
    $(basename "$0") [OPTIONS] [MODEL] [-- CLAUDE_ARGS...]

${BOLD}OPTIONS${RESET}
    -h, --help       Show this help and exit
    -l, --list       List available models and exit
    -c, --config     Show config file path and exit
    -v, --version    Show version and exit

${BOLD}ARGUMENTS${RESET}
    MODEL            Model name to use (default: ${DEFAULT_MODEL:-<interactive>})
    CLAUDE_ARGS      Extra arguments passed through to claude (after --)

${BOLD}ENVIRONMENT VARIABLES${RESET}
    MODEL                Override default model
    LLAMA_SERVER_URL     Override llama-server URL

${BOLD}CONFIG FILE${RESET}
    ${CONFIG_FILE}
    Fields: server_url, default_model, proxy_port, curl_timeout

${BOLD}EXAMPLES${RESET}
    $(basename "$0")                                        # selezione interattiva
    $(basename "$0") deepseek-v4-flash                      # modello specifico
    $(basename "$0") deepseek-v4-flash -- -p "Ciao"         # con argomenti claude
    LLAMA_SERVER_URL=http://myserver:11435 $(basename "$0") # server via env var
EOF
}

# --- Arg parsing -----------------------------------------------------------
parse_args() {
    EXTRA_ARGS=()
    MODEL="${MODEL:-$DEFAULT_MODEL}"
    local model_from_arg="" passthrough=false

    while [[ $# -gt 0 ]]; do
        $passthrough && { EXTRA_ARGS+=("$1"); shift; continue; }
        case "$1" in
            -h|--help)    show_help; exit 0 ;;
            -l|--list)    LIST_ONLY=true ;;
            -c|--config)  echo "$CONFIG_FILE"; exit 0 ;;
            -v|--version) echo "llamacpp-claude v${VERSION}"; exit 0 ;;
            --)           passthrough=true ;;
            -*)           EXTRA_ARGS+=("$1") ;;
            *)  [[ -z "$model_from_arg" ]] && model_from_arg="$1" || EXTRA_ARGS+=("$1") ;;
        esac
        shift
    done
    if [[ -n "$model_from_arg" ]]; then
        MODEL="$model_from_arg"
        MODEL_FROM_ARG=1
    fi
}

# --- Main ------------------------------------------------------------------
main() {
    check_dependencies
    init_config
    load_config
    parse_args "$@"

    if [[ "${LIST_ONLY:-false}" == "true" ]]; then
        show_models
        exit 0
    fi

    if [[ -z "${MODEL_FROM_ARG:-}" && -z "${MODEL_SET_BY_USER:-}" && -t 0 ]]; then
        select_model_interactive
    fi

    [[ -n "${MODEL:-}" ]] || { error "Nessun modello selezionato."; exit 1; }

    fetch_models | grep -qx "$MODEL" || {
        warn "Modello '${MODEL}' non trovato sul server."
        if [[ -t 0 ]]; then select_model_interactive; else error "Modello non disponibile."; exit 1; fi
    }

    start_proxy "$LLAMA_SERVER_URL" "$PROXY_PORT" "$MODEL"
    ensure_claude_installed

    export ANTHROPIC_AUTH_TOKEN=llamacpp
    export ANTHROPIC_API_KEY=llamacpp
    export ANTHROPIC_BASE_URL="http://localhost:${PROXY_PORT}"

    success "Modello: ${BOLD}${MODEL}${RESET} | Server: ${LLAMA_SERVER_URL} | Proxy: :${PROXY_PORT}"

    claude --model "$MODEL" "${EXTRA_ARGS[@]}"
}

[[ -n "${MODEL+x}" && -n "${MODEL:-}" ]] && MODEL_SET_BY_USER=1
LIST_ONLY=false

main "$@"
