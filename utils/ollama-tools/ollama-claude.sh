#!/bin/bash
# PKG_NAME: ollama-claude
# PKG_VERSION: 1.1.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), curl, jq
# PKG_RECOMMENDS: fzf
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Run Claude CLI with an Ollama server backend
# PKG_LONG_DESCRIPTION: Wrapper for the Claude CLI that redirects API calls
#  to a local (or remote) Ollama server instead of Anthropic's cloud.
#  .
#  Features:
#  - Interactive model selection via fzf or numbered list
#  - First-run guided configuration wizard
#  - JSON config file with server URL, default model, and timeout
#  - Priority: CLI arg > env var > config file > bootstrap default
#  - Validates the chosen model against the live Ollama catalogue
#  - Auto-installs the Claude CLI if not present
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
set -euo pipefail

# ---------------------------------------------------------------------------
# ollama-claude — wrapper for Claude CLI that uses an Ollama server backend
# ---------------------------------------------------------------------------

readonly VERSION="1.1.0"

# --- Config file -----------------------------------------------------------
CONFIG_DIR="$HOME/.config/manzolo/ollama-claude"
CONFIG_FILE="$CONFIG_DIR/config.json"

# Bootstrap defaults (generic — actual values are set interactively on first run)
readonly _BS_SERVER_URL="http://localhost:11434"
readonly _BS_DEFAULT_MODEL=""
readonly _BS_TIMEOUT=10

# Working variables (resolved after load_config; env var takes precedence)
OLLAMA_SERVER_URL="${OLLAMA_SERVER_URL:-}"
DEFAULT_MODEL="${DEFAULT_MODEL:-}"
CURL_TIMEOUT=$_BS_TIMEOUT

# --- Colours (only when stderr is a terminal) ------------------------------
if [[ -t 2 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly CYAN=$'\033[0;36m'
    readonly BOLD=$'\033[1m'
    readonly RESET=$'\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# --- Utility functions (all output on stderr) ------------------------------
info()    { echo "${CYAN}[INFO]${RESET} $*" >&2; }
warn()    { echo "${YELLOW}[WARN]${RESET} $*" >&2; }
error()   { echo "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo "${GREEN}[OK]${RESET} $*" >&2; }

# --- Dependency check ------------------------------------------------------
check_dependencies() {
    local missing=()
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}"
        error "Install them with your package manager and try again."
        exit 1
    fi
}

# --- Config management (init / load / first-run) ---------------------------
setup_first_run() {
    info "First-time setup for ollama-claude."
    local url model
    read -rp "Ollama server URL [${_BS_SERVER_URL}]: " url
    [[ -z "$url" ]] && url="$_BS_SERVER_URL"
    OLLAMA_SERVER_URL="$url"
    read -rp "Default model (leave empty to select interactively on each run): " model
    DEFAULT_MODEL="$model"
    mkdir -p "$CONFIG_DIR"
    jq -n \
        --arg url "$OLLAMA_SERVER_URL" \
        --arg model "$DEFAULT_MODEL" \
        --argjson timeout "$_BS_TIMEOUT" \
        '{server_url: $url, default_model: $model, curl_timeout: $timeout}' \
        > "$CONFIG_FILE"
    success "Config saved: ${CONFIG_FILE}"
    info "  Edit this file to change settings."
}

init_config() {
    [[ -f "$CONFIG_FILE" ]] && return
    if [[ -t 0 ]]; then
        setup_first_run
    else
        mkdir -p "$CONFIG_DIR"
        jq -n \
            --arg url "$_BS_SERVER_URL" \
            --arg model "$_BS_DEFAULT_MODEL" \
            --argjson timeout "$_BS_TIMEOUT" \
            '{server_url: $url, default_model: $model, curl_timeout: $timeout}' \
            > "$CONFIG_FILE"
        warn "Config created with generic defaults: ${CONFIG_FILE}"
        info "  Edit this file with the actual server URL and model."
    fi
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        OLLAMA_SERVER_URL="${OLLAMA_SERVER_URL:-$_BS_SERVER_URL}"
        DEFAULT_MODEL="${DEFAULT_MODEL:-$_BS_DEFAULT_MODEL}"
        return
    fi
    info "Loading config: ${CONFIG_FILE}"
    local url model timeout
    url=$(jq -r '.server_url // empty' "$CONFIG_FILE")
    model=$(jq -r '.default_model // empty' "$CONFIG_FILE")
    timeout=$(jq -r '.curl_timeout // empty' "$CONFIG_FILE")
    # Priority: env var > config file > bootstrap default
    [[ -n "$url"     ]] && OLLAMA_SERVER_URL="${OLLAMA_SERVER_URL:-$url}"
    [[ -n "$model"   ]] && DEFAULT_MODEL="${DEFAULT_MODEL:-$model}"
    [[ -n "$timeout" ]] && CURL_TIMEOUT="$timeout"
    OLLAMA_SERVER_URL="${OLLAMA_SERVER_URL:-$_BS_SERVER_URL}"
    DEFAULT_MODEL="${DEFAULT_MODEL:-$_BS_DEFAULT_MODEL}"
}

# --- Model cache (single API call) ----------------------------------------
_CACHED_MODELS=""

fetch_models() {
    if [[ -z "$_CACHED_MODELS" ]]; then
        _CACHED_MODELS=$(curl -s --max-time "$CURL_TIMEOUT" \
            "${OLLAMA_SERVER_URL}/api/tags" | jq -r '.models[].name') || {
            error "Failed to fetch models from ${OLLAMA_SERVER_URL}"
            exit 1
        }
        if [[ -z "$_CACHED_MODELS" ]]; then
            error "No models found on ${OLLAMA_SERVER_URL}"
            exit 1
        fi
    fi
    echo "$_CACHED_MODELS"
}

# --- Display models --------------------------------------------------------
show_models() {
    info "Available models on ${BOLD}${OLLAMA_SERVER_URL}${RESET}:"
    fetch_models | while read -r model; do
        echo "  $model"
    done
}

# --- Interactive selection -------------------------------------------------
select_model_interactive() {
    info "Fetching available models..."
    mapfile -t models < <(fetch_models)

    if [[ ${#models[@]} -eq 0 ]]; then
        error "No models available."
        exit 1
    fi

    # Prefer fzf if available
    if command -v fzf &>/dev/null; then
        info "Select a model (arrow keys, Enter to confirm, Esc to cancel):"
        local selected
        # Put the default model first so fzf highlights it
        local sorted_models=()
        for m in "${models[@]}"; do
            [[ "$m" == "$DEFAULT_MODEL" ]] && sorted_models=("$m" "${sorted_models[@]}") || sorted_models+=("$m")
        done
        selected=$(printf "%s\n" "${sorted_models[@]}" | fzf --height 40% --border --prompt 'Model> ' --header "Default: ${DEFAULT_MODEL}") || true
        if [[ -z "$selected" ]]; then
            warn "No selection made. Using default model: ${DEFAULT_MODEL}"
            MODEL="$DEFAULT_MODEL"
            return
        fi
        success "Selected model: ${BOLD}${selected}${RESET}"
        MODEL="$selected"
        return
    fi

    # Fallback: numbered list
    echo "Available models:" >&2
    echo >&2
    echo "  0) ${DEFAULT_MODEL} (default)" >&2
    for idx in "${!models[@]}"; do
        printf "  %d) %s\n" $((idx + 1)) "${models[$idx]}" >&2
    done
    echo >&2
    read -rp "Enter number of model (or press Enter for default): " choice
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        warn "Using default model: ${DEFAULT_MODEL}"
        MODEL="$DEFAULT_MODEL"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#models[@]} )); then
        MODEL="${models[$((choice - 1))]}"
        success "Selected model: ${BOLD}${MODEL}${RESET}"
    else
        warn "Invalid choice. Using default model: ${DEFAULT_MODEL}"
        MODEL="$DEFAULT_MODEL"
    fi
}

# --- Validate model --------------------------------------------------------
validate_model() {
    local model="$1"
    if ! fetch_models | grep -qx "$model"; then
        warn "Model '${model}' not found on the server."
        if [[ -t 0 ]]; then
            show_models
            echo >&2
            read -rp "Select a model from the list? (y/N): " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                select_model_interactive
            else
                info "Proceeding with model: ${model} (may not be available)"
            fi
        else
            error "Model '${model}' is not available and stdin is not a terminal."
            error "Use --list to see available models."
            exit 1
        fi
    fi
}

# --- Ensure claude is installed --------------------------------------------
ensure_claude_installed() {
    if command -v claude &>/dev/null; then
        return
    fi
    warn "claude CLI not found."
    if [[ -t 0 ]]; then
        read -rp "Install Claude CLI now? (y/N): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            info "Installing Claude CLI..."
            curl -fsSL https://claude.ai/install.sh | bash
            # Add ~/.local/bin to PATH in case it wasn't there before
            export PATH="$HOME/.local/bin:$PATH"
            if ! command -v claude &>/dev/null; then
                error "Installation failed."
                exit 1
            fi
            success "Claude CLI installed."
        else
            error "Claude CLI is required. Install it manually and try again."
            exit 1
        fi
    else
        error "Claude CLI is required. Install it from https://claude.ai/install.sh"
        exit 1
    fi
}

# --- Help ------------------------------------------------------------------
show_help() {
    cat <<EOF
${BOLD}ollama-claude${RESET} v${VERSION} — Run Claude CLI with an Ollama backend

${BOLD}USAGE${RESET}
    $(basename "$0") [OPTIONS] [MODEL] [-- CLAUDE_ARGS...]

${BOLD}OPTIONS${RESET}
    -h, --help       Show this help and exit
    -l, --list       List available models and exit
    -c, --config     Show config file path and exit
    -v, --version    Show version and exit

${BOLD}ARGUMENTS${RESET}
    MODEL            Name of the model to use (default: ${DEFAULT_MODEL})
    CLAUDE_ARGS      Extra arguments passed through to claude (after --)

${BOLD}ENVIRONMENT VARIABLES${RESET}
    MODEL                Override the default model
    OLLAMA_SERVER_URL    Override the server URL

${BOLD}CONFIG FILE${RESET}
    ${CONFIG_FILE}
    Fields: server_url, default_model, curl_timeout

${BOLD}EXAMPLES${RESET}
    $(basename "$0")                          # interactive selection
    $(basename "$0") qwen3-coder:30b          # use specific model
    $(basename "$0") qwen3-coder:30b -- -p "Ciao"  # pass extra args to claude
    MODEL=llama3 $(basename "$0")             # use env var
EOF
}

# --- Parse arguments -------------------------------------------------------
parse_args() {
    EXTRA_ARGS=()
    MODEL="${MODEL:-$DEFAULT_MODEL}"
    local model_from_arg=""
    local passthrough=false

    while [[ $# -gt 0 ]]; do
        if $passthrough; then
            EXTRA_ARGS+=("$1")
            shift
            continue
        fi
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--list)
                show_models
                exit 0
                ;;
            -c|--config)
                echo "$CONFIG_FILE"
                exit 0
                ;;
            -v|--version)
                echo "ollama-claude v${VERSION}"
                exit 0
                ;;
            --)
                passthrough=true
                shift
                ;;
            -*)
                EXTRA_ARGS+=("$1")
                shift
                ;;
            *)
                if [[ -z "$model_from_arg" ]]; then
                    model_from_arg="$1"
                else
                    EXTRA_ARGS+=("$1")
                fi
                shift
                ;;
        esac
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

    # Go interactive only when no model was given (CLI arg or env var) and stdin is a terminal
    if [[ -z "${MODEL_FROM_ARG:-}" && -z "${MODEL_SET_BY_USER:-}" && -t 0 ]]; then
        select_model_interactive
    fi

    # Validate the chosen model
    validate_model "$MODEL"

    # Ensure claude is available
    ensure_claude_installed

    # Configure environment for Ollama
    export ANTHROPIC_AUTH_TOKEN=ollama
    export ANTHROPIC_API_KEY=ollama
    export ANTHROPIC_BASE_URL="${OLLAMA_SERVER_URL}"

    success "Using model: ${BOLD}${MODEL}${RESET}"

    # Replace this process with claude
    exec claude --model "$MODEL" "${EXTRA_ARGS[@]}"
}

# Detect if MODEL was explicitly set by the user via env var
if [[ -n "${MODEL+x}" && -n "${MODEL:-}" ]]; then
    MODEL_SET_BY_USER=1
fi

main "$@"
