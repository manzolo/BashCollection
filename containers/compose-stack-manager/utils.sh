# compose-stack-manager module: help, logging, small helpers
# Sourced by compose-stack-manager.sh — do not execute directly.
print_help() {
    printf '%bCompose Stack Manager%b v%s\n' "$BOLD" "$NC" "$VERSION"
    printf '\nUsage: %s [OPTIONS]\n' "$SCRIPT_NAME"
    printf '\nModes:\n'
    printf '  default                 Check mode: scan stacks and show an ASCII dashboard\n'
    printf '  --update                Pull images and restart stacks only when updates exist\n'
    printf '\nOptions:\n'
    printf '  -i, --interactive       With --update, ask confirmation before down/rm/up\n'
    printf '  -h, --help              Show this help and exit\n'
}

log_warn() {
    LOG_ERRORS+=("$1")
}

print_errors() {
    local message
    for message in "${LOG_ERRORS[@]}"; do
        printf '%bWarning:%b %s\n' "$YELLOW" "$NC" "$message" >&2
    done
}

repeat_char() {
    local char="$1"
    local count="$2"
    local out=""
    local i
    for ((i = 0; i < count; i++)); do
        out+="$char"
    done
    printf '%s' "$out"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

