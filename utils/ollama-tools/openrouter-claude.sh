#!/bin/bash
# PKG_NAME: openrouter-claude
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), curl, jq
# PKG_RECOMMENDS: fzf
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Run Claude CLI with an OpenRouter backend
# PKG_LONG_DESCRIPTION: Wrapper for the Claude CLI that redirects API calls
#  to OpenRouter instead of Anthropic's cloud, enabling access to hundreds
#  of models (including free-tier ones) via a single API key.
#  .
#  Features:
#  - Interactive model selection via fzf or numbered list
#  - Filters free-tier (:free) models by default; --all shows paid models too
#  - First-run guided configuration wizard (stores API key securely, mode 600)
#  - JSON config file with API key, default model, free_only flag, and timeout
#  - Maps all Claude tiers (Opus/Sonnet/Haiku) to the selected model via env vars
#  - Auto-installs the Claude CLI if not present
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
set -euo pipefail

# ---------------------------------------------------------------------------
# openrouter-claude — wrapper for Claude CLI that uses an OpenRouter backend
# ---------------------------------------------------------------------------

readonly VERSION="1.0.0"

# OpenRouter API endpoints (not user-configurable)
readonly OPENROUTER_BASE_URL="https://openrouter.ai/api"
readonly OPENROUTER_MODELS_URL="https://openrouter.ai/api/v1/models"

# --- Config file -----------------------------------------------------------
CONFIG_DIR="$HOME/.config/manzolo/openrouter-claude"
CONFIG_FILE="$CONFIG_DIR/config.json"

# Bootstrap defaults (used when creating config for the first time)
readonly _BS_TIMEOUT=15
readonly _BS_FREE_ONLY=true

# Working variables (resolved after load_config; env var takes precedence)
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
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

# --- Config management (load / save / first-run) ---------------------------
load_config() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    info "Loading config: ${CONFIG_FILE}"
    local key model free timeout
    key=$(jq -r '.api_key // empty' "$CONFIG_FILE")
    model=$(jq -r '.default_model // empty' "$CONFIG_FILE")
    free=$(jq -r '.free_only // true' "$CONFIG_FILE")
    timeout=$(jq -r '.curl_timeout // empty' "$CONFIG_FILE")
    # Priority: env var > config file > bootstrap default
    [[ -z "$OPENROUTER_API_KEY" && -n "$key"   ]] && OPENROUTER_API_KEY="$key"
    [[ -n "$model"                              ]] && DEFAULT_MODEL="${DEFAULT_MODEL:-$model}"
    [[ "$free" == "false"                       ]] && SHOW_ALL_DEFAULT=true
    [[ -n "$timeout"                            ]] && CURL_TIMEOUT="$timeout"
}

save_config() {
    local key="${1:-$OPENROUTER_API_KEY}"
    local model="${2:-$DEFAULT_MODEL}"
    local free_only="${3:-true}"
    mkdir -p "$CONFIG_DIR"
    jq -n \
        --arg key "$key" \
        --arg model "$model" \
        --argjson free "$free_only" \
        --argjson timeout "$CURL_TIMEOUT" \
        '{api_key: $key, default_model: $model, free_only: $free, curl_timeout: $timeout}' \
        > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

setup_first_run() {
    info "First-time setup for openrouter-claude."
    info "Get an API key at: https://openrouter.ai/keys"
    local key
    read -rsp "API Key (sk-or-...): " key
    echo >&2
    if [[ -z "$key" ]]; then
        error "API key is required."
        exit 1
    fi
    OPENROUTER_API_KEY="$key"
    save_config "$key" "" true
    success "Config saved: ${CONFIG_FILE}"
    info "  Edit this file to change default model and other settings."
}

# --- Require API key -------------------------------------------------------
require_api_key() {
    [[ -n "$OPENROUTER_API_KEY" ]] && return
    if [[ -t 0 ]]; then
        setup_first_run
    else
        error "OPENROUTER_API_KEY is not set and no config found."
        error "Options:"
        error "  1. export OPENROUTER_API_KEY=sk-or-..."
        error "  2. Run ./openrouter-claude interactively to configure"
        error "  3. Edit directly: ${CONFIG_FILE}"
        exit 1
    fi
}

# --- Model cache (two slots: free-only and full catalogue) -----------------
_CACHED_MODELS=""      # free-tier only
_CACHED_MODELS_ALL=""  # full catalogue

fetch_models() {
    local show_all="${1:-false}"

    if [[ "$show_all" == "true" ]]; then
        [[ -n "$_CACHED_MODELS_ALL" ]] && { echo "$_CACHED_MODELS_ALL"; return; }
    else
        [[ -n "$_CACHED_MODELS" ]] && { echo "$_CACHED_MODELS"; return; }
    fi

    local raw
    raw=$(curl -sf --max-time "$CURL_TIMEOUT" \
        -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
        -H "Content-Type: application/json" \
        "${OPENROUTER_MODELS_URL}") || {
        error "Failed to fetch models from OpenRouter (check your API key)."
        exit 1
    }

    _CACHED_MODELS_ALL=$(printf '%s' "$raw" | jq -r '.data[].id' | sort)

    if [[ -z "$_CACHED_MODELS_ALL" ]]; then
        error "No models returned from OpenRouter."
        exit 1
    fi

    if [[ "$show_all" == "true" ]]; then
        echo "$_CACHED_MODELS_ALL"
        return
    fi

    _CACHED_MODELS=$(printf '%s\n' "$_CACHED_MODELS_ALL" | grep ':free$' || true)
    if [[ -z "$_CACHED_MODELS" ]]; then
        warn "No :free models found. Showing all models."
        _CACHED_MODELS="$_CACHED_MODELS_ALL"
    fi
    echo "$_CACHED_MODELS"
}

# --- Display models --------------------------------------------------------
show_models() {
    local show_all="${1:-false}"
    local label
    [[ "$show_all" == "true" ]] && label=" (all)" || label=" (free tier — usa --all per vedere tutti)"
    info "Available OpenRouter models${label}:"
    fetch_models "$show_all" | while read -r model; do
        echo "  $model"
    done
}

# --- Interactive selection -------------------------------------------------
select_model_interactive() {
    local show_all="${1:-false}"
    info "Fetching available models..."
    mapfile -t models < <(fetch_models "$show_all")

    if [[ ${#models[@]} -eq 0 ]]; then
        error "No models available."
        exit 1
    fi

    local header_label
    [[ "$show_all" == "true" ]] && header_label="all models" || header_label="free-tier only (--all for more)"

    if command -v fzf &>/dev/null; then
        info "Select a model (arrow keys, Enter to confirm, Esc to cancel):"
        local selected
        local sorted_models=()
        if [[ -n "$DEFAULT_MODEL" ]]; then
            for m in "${models[@]}"; do
                [[ "$m" == "$DEFAULT_MODEL" ]] && sorted_models=("$m" "${sorted_models[@]}") || sorted_models+=("$m")
            done
        else
            sorted_models=("${models[@]}")
        fi
        selected=$(printf "%s\n" "${sorted_models[@]}" | \
            fzf --height 60% --border --prompt 'Model> ' \
                --header "OpenRouter — ${header_label}") || true
        if [[ -z "$selected" ]]; then
            if [[ -n "$DEFAULT_MODEL" ]]; then
                warn "No selection made. Using default model: ${DEFAULT_MODEL}"
                MODEL="$DEFAULT_MODEL"
            else
                error "No model selected."
                exit 1
            fi
            return
        fi
        success "Selected model: ${BOLD}${selected}${RESET}"
        MODEL="$selected"
        return
    fi

    # Fallback: numbered list
    echo "Available models (${header_label}):" >&2
    echo >&2
    if [[ -n "$DEFAULT_MODEL" ]]; then
        echo "  0) ${DEFAULT_MODEL} (default)" >&2
    fi
    for idx in "${!models[@]}"; do
        printf "  %d) %s\n" $((idx + 1)) "${models[$idx]}" >&2
    done
    echo >&2
    local prompt
    [[ -n "$DEFAULT_MODEL" ]] && prompt="Enter number (or press Enter for default): " || prompt="Enter number: "
    read -rp "$prompt" choice

    if [[ -z "$choice" && -n "$DEFAULT_MODEL" ]]; then
        warn "Using default model: ${DEFAULT_MODEL}"
        MODEL="$DEFAULT_MODEL"
    elif [[ "$choice" == "0" && -n "$DEFAULT_MODEL" ]]; then
        warn "Using default model: ${DEFAULT_MODEL}"
        MODEL="$DEFAULT_MODEL"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#models[@]} )); then
        MODEL="${models[$((choice - 1))]}"
        success "Selected model: ${BOLD}${MODEL}${RESET}"
    elif [[ -z "$choice" && -z "$DEFAULT_MODEL" ]]; then
        error "No model selected. Use --list to see available models."
        exit 1
    else
        if [[ -n "$DEFAULT_MODEL" ]]; then
            warn "Invalid choice. Using default model: ${DEFAULT_MODEL}"
            MODEL="$DEFAULT_MODEL"
        else
            error "Invalid choice. Use --list to see available models."
            exit 1
        fi
    fi
}

# --- Validate model --------------------------------------------------------
validate_model() {
    local model="$1"
    # Always validate against full catalogue (user may pass a paid model without --all)
    if ! fetch_models true | grep -qx "$model"; then
        warn "Model '${model}' not found in the OpenRouter catalogue."
        if [[ -t 0 ]]; then
            show_models "$SHOW_ALL"
            echo >&2
            read -rp "Select a model from the list? (y/N): " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                select_model_interactive "$SHOW_ALL"
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

# --- Configure environment for OpenRouter ----------------------------------
configure_env() {
    local model="$1"
    export ANTHROPIC_BASE_URL="${OPENROUTER_BASE_URL}"
    export ANTHROPIC_AUTH_TOKEN="${OPENROUTER_API_KEY}"
    export ANTHROPIC_API_KEY=""   # must be explicitly empty so the SDK uses AUTH_TOKEN
    export ANTHROPIC_DEFAULT_OPUS_MODEL="${model}"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="${model}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${model}"
}

# --- Help ------------------------------------------------------------------
show_help() {
    local default_label="${DEFAULT_MODEL:-<nessuno, verrà chiesto interattivamente>}"
    cat <<EOF
${BOLD}openrouter-claude${RESET} v${VERSION} — Run Claude CLI with an OpenRouter backend

${BOLD}USAGE${RESET}
    $(basename "$0") [OPTIONS] [MODEL] [-- CLAUDE_ARGS...]

${BOLD}OPTIONS${RESET}
    -h, --help       Show this help and exit
    -l, --list       List available models and exit (free-tier only by default)
    -a, --all        Show all models including paid (use with -l or standalone)
    -c, --config     Show config file path and exit
    -v, --version    Show version and exit

${BOLD}ARGUMENTS${RESET}
    MODEL            OpenRouter model slug (es. google/gemma-4-31b-it:free)
    CLAUDE_ARGS      Extra arguments passed through to claude (after --)

${BOLD}ENVIRONMENT VARIABLES${RESET}
    OPENROUTER_API_KEY    Your OpenRouter API key (overrides config file)
    MODEL                 Override model selection (skips interactive prompt)

${BOLD}CONFIG FILE${RESET}
    ${CONFIG_FILE}
    Fields: api_key, default_model, free_only, curl_timeout

${BOLD}NOTES${RESET}
    By default only :free models are shown. Use --all to see paid models too.
    All Claude internal tiers (Opus/Sonnet/Haiku) are mapped to the selected
    model via ANTHROPIC_DEFAULT_*_MODEL env vars.
    Current default model: ${default_label}

${BOLD}EXAMPLES${RESET}
    $(basename "$0")                                        # selezione interattiva (solo :free)
    $(basename "$0") --all                                  # selezione interattiva (tutti)
    $(basename "$0") google/gemma-4-31b-it:free             # modello specifico
    $(basename "$0") --list                                 # elenca modelli free
    $(basename "$0") --list --all                           # elenca tutti i modelli
    $(basename "$0") google/gemma-4-31b-it:free -- -p "Ciao"
    MODEL=nvidia/nemotron-3-super-120b-a12b:free $(basename "$0")
EOF
}

# --- Parse arguments -------------------------------------------------------
parse_args() {
    EXTRA_ARGS=()
    MODEL="${MODEL:-$DEFAULT_MODEL}"
    SHOW_ALL="${SHOW_ALL_DEFAULT:-false}"
    LIST_ONLY=false
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
                LIST_ONLY=true
                shift
                ;;
            -a|--all)
                SHOW_ALL=true
                shift
                ;;
            -c|--config)
                echo "$CONFIG_FILE"
                exit 0
                ;;
            -v|--version)
                echo "openrouter-claude v${VERSION}"
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
    load_config
    parse_args "$@"
    require_api_key

    if [[ "${LIST_ONLY:-false}" == "true" ]]; then
        show_models "$SHOW_ALL"
        exit 0
    fi

    # Interactive selection when no model provided and stdin is a terminal
    if [[ -z "${MODEL_FROM_ARG:-}" && -z "${MODEL_SET_BY_USER:-}" && -t 0 ]]; then
        select_model_interactive "$SHOW_ALL"
    fi

    # Guard: no model in non-interactive mode
    if [[ -z "${MODEL:-}" ]]; then
        error "No model selected."
        error "Use --list to see available models, or set MODEL=<slug>"
        exit 1
    fi

    validate_model "$MODEL"
    ensure_claude_installed
    configure_env "$MODEL"

    success "Using model: ${BOLD}${MODEL}${RESET} via OpenRouter"

    # Replace this process with claude (no --model: mapping is via env vars)
    exec claude "${EXTRA_ARGS[@]}"
}

# Detect if MODEL was explicitly set by the user via env var
if [[ -n "${MODEL+x}" && -n "${MODEL:-}" ]]; then
    MODEL_SET_BY_USER=1
fi

main "$@"
