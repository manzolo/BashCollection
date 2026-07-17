# compose-stack-manager module: compose file discovery and docker access
# Sourced by compose-stack-manager.sh — do not execute directly.
find_compose_in_dir() {
    local dir="$1"
    local file
    for file in "${COMPOSE_FILES[@]}"; do
        if [ -f "$dir/$file" ]; then
            printf '%s' "$dir/$file"
            return 0
        fi
    done
    return 1
}

scan_directory_recursive() {
    local dir="$1"
    local compose_path
    local entry
    local label

    if [ ! -d "$dir" ]; then
        return 0
    fi

    shopt -s nullglob
    for entry in "$dir"/*; do
        [ -d "$entry" ] || continue
        [ -L "$entry" ] && continue

        if [ ! -r "$entry" ] || [ ! -x "$entry" ]; then
            log_warn "Permission denied while scanning: $entry"
            continue
        fi

        if ! compose_path="$(find_compose_in_dir "$entry")"; then
            continue
        fi

        STACK_DIRS+=("$entry")
        STACK_FILES+=("$compose_path")
        label="$(basename "$entry")"
        STACK_LABELS+=("$label")
    done
    shopt -u nullglob
}

docker_accessible() {
    docker info >/dev/null 2>&1
}

