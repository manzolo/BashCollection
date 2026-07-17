# compose-stack-manager module: image updates, cleanup, restart, summary
# Sourced by compose-stack-manager.sh — do not execute directly.
pull_has_updates() {
    local output="$1"
    if printf '%s' "$output" | grep -Eqi '(downloaded newer image|status: downloaded newer image|pull complete|extracting|download complete)'; then
        return 0
    fi
    return 1
}

confirm_update() {
    local stack_label="$1"
    local answer
    printf 'Update stack %s? [Y/n] ' "$stack_label"
    read -r answer
    answer="${answer:-Y}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

collect_stack_images() {
    local stack_dir="$1"
    (
        cd "$stack_dir" || exit 1
        docker compose config 2>/dev/null
    ) | awk '
        $1 == "image:" {
            image = $2
            if (!seen[image]++) {
                print image
            }
        }
    '
}

image_repository() {
    local image_ref="$1"
    local tail_part="${image_ref##*/}"
    if [[ "$image_ref" == *"@"* ]]; then
        printf '%s' "${image_ref%@*}"
    elif [[ "$tail_part" == *:* ]]; then
        printf '%s' "${image_ref%:*}"
    else
        printf '%s' "$image_ref"
    fi
}

cleanup_old_images_for_ref() {
    local image_ref="$1"
    local repository
    local image_lines
    local index=0
    local image_id

    repository="$(image_repository "$image_ref")"

    [ -n "$repository" ] || return 0

    image_lines="$(docker images --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.Digest}}|{{.ID}}|{{.CreatedAt}}' "$repository" 2>/dev/null \
        | awk -F'|' -v repo="$repository" '$1 == repo { print }' \
        | sort -t'|' -k5,5r)"

    [ -n "$image_lines" ] || return 0

    while IFS='|' read -r _ _ _ image_id _; do
        [ -n "$image_id" ] || continue
        index=$((index + 1))
        if [ "$index" -le 2 ]; then
            continue
        fi
        docker rmi "$image_id" >/dev/null 2>&1 || true
    done <<< "$image_lines"
}

cleanup_dangling_images() {
    local before_ids=()
    local after_ids=()

    mapfile -t before_ids < <(docker image ls --filter dangling=true --quiet --no-trunc 2>/dev/null | sort -u)
    [ ${#before_ids[@]} -gt 0 ] || {
        printf '0'
        return 0
    }

    docker image prune --force >/dev/null 2>&1 || true
    mapfile -t after_ids < <(docker image ls --filter dangling=true --quiet --no-trunc 2>/dev/null | sort -u)
    printf '%d' "$((${#before_ids[@]} - ${#after_ids[@]}))"
}

restart_stack() {
    local stack_dir="$1"
    local output

    output="$(
        cd "$stack_dir" &&
        {
            docker compose down &&
            docker compose rm -f &&
            docker compose up -d
        } 2>&1
    )"
    local exit_code=$?
    printf '%s' "$output"
    return "$exit_code"
}

record_update_result() {
    UPDATE_STACKS+=("$1")
    UPDATE_RESULTS+=("$2")
    UPDATE_DETAILS+=("$3")
}

run_update_mode() {
    local idx
    local stack_dir
    local stack_label
    local pull_output
    local restart_output
    local images
    local image_ref
    local dangling_removed=0
    local updated_count=0
    local unchanged_count=0
    local failed_count=0

    if [ ${#STACK_DIRS[@]} -eq 0 ]; then
        printf '%bNo compose stacks found under %s%b\n' "$YELLOW" "$START_DIR" "$NC"
        print_errors
        return 0
    fi

    if ! command_exists docker; then
        printf '%bDocker is not installed or not in PATH.%b\n' "$RED" "$NC" >&2
        return 1
    fi

    for idx in "${!STACK_DIRS[@]}"; do
        stack_dir="${STACK_DIRS[$idx]}"
        stack_label="${STACK_LABELS[$idx]}"

        if ! pull_output="$(
            cd "$stack_dir" &&
            docker compose pull 2>&1
        )"; then
            if printf '%s' "$pull_output" | grep -qi 'permission denied'; then
                log_warn "Update failed for $stack_label: permission denied. Add the user to the docker group or run with sufficient privileges."
                record_update_result "$stack_label" "$UPDATE_FAILED" "docker compose pull permission denied"
            else
                log_warn "Update failed for $stack_label during pull."
                record_update_result "$stack_label" "$UPDATE_FAILED" "docker compose pull failed"
            fi
            printf '✖ %s\n' "$stack_label"
            failed_count=$((failed_count + 1))
            continue
        fi

        if ! pull_has_updates "$pull_output"; then
            record_update_result "$stack_label" "$UPDATE_UNCHANGED" "No new images downloaded."
            printf 'ℹ %s\n' "$stack_label"
            unchanged_count=$((unchanged_count + 1))
            continue
        fi

        if $INTERACTIVE && ! confirm_update "$stack_label"; then
            record_update_result "$stack_label" "$UPDATE_SKIPPED" "Update found but restart skipped by user."
            printf 'ℹ %s\n' "$stack_label"
            unchanged_count=$((unchanged_count + 1))
            continue
        fi

        if ! restart_output="$(restart_stack "$stack_dir")"; then
            if printf '%s' "$restart_output" | grep -qi 'permission denied'; then
                log_warn "Restart failed for $stack_label: permission denied."
                record_update_result "$stack_label" "$UPDATE_FAILED" "restart permission denied"
            else
                log_warn "Restart failed for $stack_label after image update."
                record_update_result "$stack_label" "$UPDATE_FAILED" "stack restart failed"
            fi
            printf '✖ %s\n' "$stack_label"
            failed_count=$((failed_count + 1))
            continue
        fi

        images="$(collect_stack_images "$stack_dir")"
        while IFS= read -r image_ref; do
            [ -n "$image_ref" ] || continue
            cleanup_old_images_for_ref "$image_ref"
        done <<< "$images"

        record_update_result "$stack_label" "$UPDATE_UPDATED" "Images updated and stack restarted."
        printf '✔ %s\n' "$stack_label"
        updated_count=$((updated_count + 1))
    done

    if [ "$updated_count" -gt 0 ]; then
        dangling_removed="$(cleanup_dangling_images)"
    fi

    printf '\n'
    print_update_summary
    printf 'Dangling images removed: %d\n' "$dangling_removed"
    print_errors
    return $((failed_count > 0 ? 1 : 0))
}

print_update_summary() {
    local stack_width=5
    local result_width=6
    local detail_width=6
    local idx
    local result_label
    local colored_result
    local separator
    local status
    local updated_count=0
    local unchanged_count=0
    local failed_count=0

    for idx in "${!UPDATE_STACKS[@]}"; do
        [ ${#UPDATE_STACKS[$idx]} -gt "$stack_width" ] && stack_width=${#UPDATE_STACKS[$idx]}
        case "${UPDATE_RESULTS[$idx]}" in
            "$UPDATE_UPDATED") result_label="updated" ;;
            "$UPDATE_UNCHANGED") result_label="unchanged" ;;
            "$UPDATE_SKIPPED") result_label="skipped" ;;
            *) result_label="failed" ;;
        esac
        [ ${#result_label} -gt "$result_width" ] && result_width=${#result_label}
        [ ${#UPDATE_DETAILS[$idx]} -gt "$detail_width" ] && detail_width=${#UPDATE_DETAILS[$idx]}
    done

    separator="$(repeat_char '-' $((stack_width + result_width + detail_width + 10)))"
    printf '%s\n' "$separator"
    printf "| %-${stack_width}s | %-${result_width}s | %-${detail_width}s |\n" "STACK" "RESULT" "DETAIL"
    printf '%s\n' "$separator"

    for idx in "${!UPDATE_STACKS[@]}"; do
        status="${UPDATE_RESULTS[$idx]}"
        case "$status" in
            "$UPDATE_UPDATED")
                result_label="updated"
                colored_result="${GREEN}${result_label}${NC}"
                updated_count=$((updated_count + 1))
                ;;
            "$UPDATE_UNCHANGED"|"$UPDATE_SKIPPED")
                result_label="${status#update_}"
                [ "$status" = "$UPDATE_UNCHANGED" ] && result_label="unchanged"
                [ "$status" = "$UPDATE_SKIPPED" ] && result_label="skipped"
                colored_result="${YELLOW}${result_label}${NC}"
                unchanged_count=$((unchanged_count + 1))
                ;;
            *)
                result_label="failed"
                colored_result="${RED}${result_label}${NC}"
                failed_count=$((failed_count + 1))
                ;;
        esac
        printf "| %-${stack_width}s | %b | %-${detail_width}s |\n" \
            "${UPDATE_STACKS[$idx]}" \
            "${colored_result}$(repeat_char ' ' $((result_width - ${#result_label} > 0 ? result_width - ${#result_label} : 0)))" \
            "${UPDATE_DETAILS[$idx]}"
    done
    printf '%s\n' "$separator"
    printf 'Updated: %d | Unchanged: %d | Failed: %d\n' "$updated_count" "$unchanged_count" "$failed_count"
}

