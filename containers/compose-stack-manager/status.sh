# compose-stack-manager module: status classification and port formatting
# Sourced by compose-stack-manager.sh — do not execute directly.
status_kind() {
    local status_lc
    status_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    if [[ "$status_lc" == *"running"* ]] || [[ "$status_lc" == up* ]]; then
        printf '%s' "$STATUS_RUNNING"
    elif [[ "$status_lc" == *"paused"* ]] || [[ "$status_lc" == *"restarting"* ]]; then
        printf '%s' "$STATUS_WARN"
    elif [[ "$status_lc" == *"not running"* ]] || [[ "$status_lc" == *"exited"* ]] || [[ "$status_lc" == *"dead"* ]]; then
        printf '%s' "$STATUS_STOPPED"
    else
        printf '%s' "$STATUS_ERROR"
    fi
}

colorize_status() {
    local status="$1"
    local kind="$2"
    case "$kind" in
        "$STATUS_RUNNING") printf '%b%s%b' "$GREEN" "$status" "$NC" ;;
        "$STATUS_WARN") printf '%b%s%b' "$YELLOW" "$status" "$NC" ;;
        *) printf '%b%s%b' "$RED" "$status" "$NC" ;;
    esac
}

extract_ports() {
    local ports="$1"
    local host_ports=()
    local internal_ports=()
    local chunks=()
    local chunk
    local cleaned
    local target_port
    local published_port

    # Compose's non-JSON formatter renders publishers as Go structs:
    # [{0.0.0.0 80 8080 tcp} {:: 80 8080 tcp} { 6379 0 tcp}]
    if [[ "$ports" == *"{"*"}"* ]]; then
        while [[ "$ports" =~ \{([^}]*)\} ]]; do
            chunk="$(trim "${BASH_REMATCH[1]}")"
            ports="${ports#*"${BASH_REMATCH[0]}"}"
            read -ra chunks <<< "$chunk"
            if [ "${#chunks[@]}" -ge 4 ]; then
                target_port="${chunks[1]}"
                published_port="${chunks[2]}"
            elif [ "${#chunks[@]}" -ge 3 ]; then
                target_port="${chunks[0]}"
                published_port="${chunks[1]}"
            else
                continue
            fi

            if [[ ! "$target_port" =~ ^[0-9]+$ ]]; then
                continue
            fi
            internal_ports+=("$target_port")
            if [[ "$published_port" =~ ^[0-9]+$ ]] && [ "$published_port" -gt 0 ]; then
                host_ports+=("$published_port")
            fi
        done
    fi

    ports="${ports//$'\n'/,}"
    IFS=',' read -ra chunks <<< "$ports"
    for chunk in "${chunks[@]}"; do
        cleaned="$(trim "$chunk")"
        [ -n "$cleaned" ] || continue

        if [[ "$cleaned" =~ ^[^:]+:([0-9]+)-\>([0-9]+) ]]; then
            published_port="${BASH_REMATCH[1]}"
            target_port="${BASH_REMATCH[2]}"
        elif [[ "$cleaned" =~ ^([0-9]+)-\>([0-9]+) ]]; then
            published_port="${BASH_REMATCH[1]}"
            target_port="${BASH_REMATCH[2]}"
        elif [[ "$cleaned" =~ ^([0-9]+)(/[^[:space:]]+)?$ ]]; then
            published_port="0"
            target_port="${BASH_REMATCH[1]}"
        else
            continue
        fi

        internal_ports+=("$target_port")
        if [ "$published_port" -gt 0 ]; then
            host_ports+=("$published_port")
        fi
    done

    printf '%s|%s' "$(join_unique_ports "${host_ports[@]}")" "$(join_unique_ports "${internal_ports[@]}")"
}

join_unique_ports() {
    local ports=("$@")
    local item
    local seen="|"
    local joined=""

    for item in "${ports[@]}"; do
        [ -n "$item" ] || continue
        if [[ "$seen" != *"|$item|"* ]]; then
            [ -n "$joined" ] && joined+=", "
            joined+="$item"
            seen+="$item|"
        fi
    done

    printf '%s' "${joined:--}"
}

wrap_port_list() {
    local value="$1"
    local width="$2"
    local items=()
    local item
    local line=""

    if [ "$value" = "-" ]; then
        printf '%s\n' "-"
        return
    fi

    IFS=',' read -ra items <<< "$value"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [ -n "$item" ] || continue

        if [ -z "$line" ]; then
            line="$item"
        elif [ $((${#line} + ${#item} + 2)) -le "$width" ]; then
            line+=", $item"
        else
            printf '%s\n' "$line"
            line="$item"
        fi
    done

    [ -n "$line" ] && printf '%s\n' "$line"
}

