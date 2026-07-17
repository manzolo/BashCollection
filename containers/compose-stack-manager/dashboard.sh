# compose-stack-manager module: stack table rendering and check mode
# Sourced by compose-stack-manager.sh — do not execute directly.
print_stack_table() {
    local stack_index="$1"
    local rows="${CHECK_STACK_ROWS[$stack_index]}"
    local service_width="${CHECK_STACK_WIDTH_SERVICE[$stack_index]}"
    local status_width="${CHECK_STACK_WIDTH_STATUS[$stack_index]}"
    local host_ports_width="${CHECK_STACK_WIDTH_HOST_PORTS[$stack_index]}"
    local internal_ports_width="${CHECK_STACK_WIDTH_INTERNAL_PORTS[$stack_index]}"
    local image_width="${CHECK_STACK_WIDTH_IMAGE[$stack_index]}"
    [ "$host_ports_width" -gt "$MAX_HOST_PORTS_WIDTH" ] && host_ports_width="$MAX_HOST_PORTS_WIDTH"
    [ "$internal_ports_width" -gt "$MAX_INTERNAL_PORTS_WIDTH" ] && internal_ports_width="$MAX_INTERNAL_PORTS_WIDTH"
    local total_width=$((service_width + status_width + host_ports_width + internal_ports_width + image_width + 16))
    local separator
    local row_ref
    local row_index
    local service
    local status_plain
    local status_colored
    local host_ports
    local internal_ports
    local image
    local kind
    local host_port_lines=()
    local internal_port_lines=()
    local port_line_count
    local port_line_index
    local row_service
    local row_status
    local row_host_ports
    local row_internal_ports
    local row_image

    printf '\n%b%s%b\n' "$BOLD$BLUE" "${CHECK_STACK_NAMES[$stack_index]}" "$NC"
    separator="$(repeat_char '-' "$total_width")"
    printf '%s\n' "$separator"
    printf "| %-${service_width}s | %-${status_width}s | %-${host_ports_width}s | %-${internal_ports_width}s | %-${image_width}s |\n" \
        "SERVICE" "STATUS" "HOST PORTS" "INTERNAL PORTS" "IMAGE"
    printf '%s\n' "$separator"

    for row_ref in $rows; do
        row_index="${row_ref#*:}"
        service="${CHECK_SERVICES[$row_index]}"
        status_plain="${CHECK_STATUSES[$row_index]}"
        kind="${CHECK_STATUS_KINDS[$row_index]}"
        status_colored="$(colorize_status "$status_plain" "$kind")"
        host_ports="${CHECK_HOST_PORTS[$row_index]}"
        internal_ports="${CHECK_INTERNAL_PORTS[$row_index]}"
        image="${CHECK_IMAGES[$row_index]}"

        mapfile -t host_port_lines < <(wrap_port_list "$host_ports" "$host_ports_width")
        mapfile -t internal_port_lines < <(wrap_port_list "$internal_ports" "$internal_ports_width")
        port_line_count="${#host_port_lines[@]}"
        [ "${#internal_port_lines[@]}" -gt "$port_line_count" ] && port_line_count="${#internal_port_lines[@]}"

        for ((port_line_index = 0; port_line_index < port_line_count; port_line_index++)); do
            row_host_ports="${host_port_lines[$port_line_index]:-}"
            row_internal_ports="${internal_port_lines[$port_line_index]:-}"
            if [ "$port_line_index" -eq 0 ]; then
                row_service="$service"
                row_status="${status_colored}$(repeat_char ' ' $((status_width - ${#status_plain} > 0 ? status_width - ${#status_plain} : 0)))"
                row_image="$image"
            else
                row_service=""
                row_status="$(repeat_char ' ' "$status_width")"
                row_image=""
            fi

            printf "| %-${service_width}s | %b | %-${host_ports_width}s | %-${internal_ports_width}s | %-${image_width}s |\n" \
                "$row_service" \
                "$row_status" \
                "$row_host_ports" \
                "$row_internal_ports" \
                "$row_image"
        done
    done
    printf '%s\n' "$separator"
}

run_check_mode() {
    local idx
    local running_stacks=0
    local stopped_stacks=0

    if [ ${#STACK_DIRS[@]} -eq 0 ]; then
        printf '%bNo compose stacks found under %s%b\n' "$YELLOW" "$START_DIR" "$NC"
        print_errors
        return 0
    fi

    for idx in "${!STACK_DIRS[@]}"; do
        if collect_stack_rows "${STACK_DIRS[$idx]}" "${STACK_FILES[$idx]}" "${STACK_LABELS[$idx]}" "$idx"; then
            running_stacks=$((running_stacks + 1))
        else
            stopped_stacks=$((stopped_stacks + 1))
        fi
    done

    for idx in "${!STACK_DIRS[@]}"; do
        print_stack_table "$idx"
    done

    stopped_stacks=$((${#STACK_DIRS[@]} - running_stacks))
    printf '\n%bSummary:%b %d stacks, %d running, %d stopped\n' "$BOLD" "$NC" "${#STACK_DIRS[@]}" "$running_stacks" "$stopped_stacks"
    print_errors
}

