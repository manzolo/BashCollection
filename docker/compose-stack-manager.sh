#!/bin/bash
# PKG_NAME: compose-stack-manager
# PKG_VERSION: 1.0.8
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), docker-ce
# PKG_RECOMMENDS: docker-compose-plugin
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Docker Compose stack monitor and updater with ASCII dashboard

set -uo pipefail

readonly VERSION="1.0.8"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

readonly STATUS_RUNNING="running"
readonly STATUS_WARN="warning"
readonly STATUS_STOPPED="stopped"
readonly STATUS_ERROR="error"

readonly UPDATE_UPDATED="updated"
readonly UPDATE_UNCHANGED="unchanged"
readonly UPDATE_FAILED="failed"
readonly UPDATE_SKIPPED="skipped"

readonly MAX_HOST_PORTS_WIDTH=18
readonly MAX_INTERNAL_PORTS_WIDTH=24

readonly COMPOSE_FILES=(
    "docker-compose.yml"
    "docker-compose.yaml"
    "compose.yml"
    "compose.yaml"
)

MODE="check"
INTERACTIVE=false
START_DIR="$(pwd)"
HAS_PYTHON3=false
LOG_ERRORS=()

STACK_DIRS=()
STACK_FILES=()
STACK_LABELS=()

CHECK_STACK_NAMES=()
CHECK_STACK_ROWS=()
CHECK_STACK_WIDTH_SERVICE=()
CHECK_STACK_WIDTH_STATUS=()
CHECK_STACK_WIDTH_HOST_PORTS=()
CHECK_STACK_WIDTH_INTERNAL_PORTS=()
CHECK_STACK_WIDTH_IMAGE=()
CHECK_SERVICES=()
CHECK_STATUSES=()
CHECK_STATUS_KINDS=()
CHECK_HOST_PORTS=()
CHECK_INTERNAL_PORTS=()
CHECK_IMAGES=()

UPDATE_STACKS=()
UPDATE_RESULTS=()
UPDATE_DETAILS=()

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

collect_compose_ps_json() {
    local stack_dir="$1"
    (
        cd "$stack_dir" || exit 1
        docker compose ps --all --format json 2>/dev/null
    )
}

parse_ps_json() {
    local json_input="$1"
    if ! $HAS_PYTHON3; then
        return 1
    fi

    JSON_INPUT="$json_input" python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get("JSON_INPUT", "").strip()
if not raw:
    sys.exit(1)

try:
    data = json.loads(raw)
except json.JSONDecodeError:
    try:
        data = [json.loads(line) for line in raw.splitlines() if line.strip()]
    except json.JSONDecodeError:
        sys.exit(1)

if isinstance(data, dict):
    data = [data]

for item in data:
    service = item.get("Service") or item.get("Name") or "-"
    status = item.get("Status") or item.get("State") or "unknown"
    ports = item.get("Publishers") or item.get("Ports") or ""
    image = item.get("Image") or "-"

    if isinstance(ports, list):
        port_chunks = []
        for port in ports:
            if isinstance(port, dict):
                published = port.get("PublishedPort")
                target = port.get("TargetPort")
                if target is not None:
                    port_chunks.append(f"{published or 0}->{target}")
            elif isinstance(port, str):
                port_chunks.append(port)
        ports = ",".join(port_chunks)
    else:
        ports = str(ports)

    print(f"{service}|{status}|{ports}|{image}")
PY
}

collect_compose_ps_table() {
    local stack_dir="$1"
    (
        cd "$stack_dir" || exit 1
        docker compose ps --all --format '{{.Service}}|{{.Status}}|{{.Publishers}}|{{.Image}}' 2>/dev/null
    )
}

parse_ps_table() {
    awk -F '|' '
        NF == 0 { next }
        {
            service = $1
            status = $2
            ports = $3
            image = $4
            if (ports == "<none>" || ports == "") {
                ports = ""
            }
            if (service == "") {
                service = "-"
            }
            if (status == "") {
                status = "unknown"
            }
            if (image == "") {
                image = "-"
            }
            print service "|" status "|" ports "|" image
        }
    '
}

record_check_row() {
    local stack_index="$1"
    local service="$2"
    local status="$3"
    local row_host_ports="$4"
    local row_internal_ports="$5"
    local image="$6"
    local kind="$7"
    local row_id="${stack_index}:${#CHECK_SERVICES[@]}"

    CHECK_STACK_ROWS[stack_index]+="${row_id} "
    CHECK_SERVICES+=("$service")
    CHECK_STATUSES+=("$status")
    CHECK_STATUS_KINDS+=("$kind")
    CHECK_HOST_PORTS+=("$row_host_ports")
    CHECK_INTERNAL_PORTS+=("$row_internal_ports")
    CHECK_IMAGES+=("$image")

    local width_service="${CHECK_STACK_WIDTH_SERVICE[$stack_index]}"
    local width_status="${CHECK_STACK_WIDTH_STATUS[$stack_index]}"
    local width_host_ports="${CHECK_STACK_WIDTH_HOST_PORTS[$stack_index]}"
    local width_internal_ports="${CHECK_STACK_WIDTH_INTERNAL_PORTS[$stack_index]}"
    local width_image="${CHECK_STACK_WIDTH_IMAGE[$stack_index]}"

    [ ${#service} -gt "$width_service" ] && CHECK_STACK_WIDTH_SERVICE[stack_index]=${#service}
    [ ${#status} -gt "$width_status" ] && CHECK_STACK_WIDTH_STATUS[stack_index]=${#status}
    [ ${#row_host_ports} -gt "$width_host_ports" ] && CHECK_STACK_WIDTH_HOST_PORTS[stack_index]=${#row_host_ports}
    [ ${#row_internal_ports} -gt "$width_internal_ports" ] && CHECK_STACK_WIDTH_INTERNAL_PORTS[stack_index]=${#row_internal_ports}
    [ ${#image} -gt "$width_image" ] && CHECK_STACK_WIDTH_IMAGE[stack_index]=${#image}
}

collect_stack_rows() {
    local stack_dir="$1"
    local stack_file="$2"
    local stack_label="$3"
    local stack_index="$4"
    local json_output=""
    local parsed=""
    local service
    local status
    local ports
    local host_ports
    local internal_ports
    local image
    local kind
    local any_running=false

    CHECK_STACK_NAMES[stack_index]="$stack_label"
    CHECK_STACK_WIDTH_SERVICE[stack_index]=7
    CHECK_STACK_WIDTH_STATUS[stack_index]=6
    CHECK_STACK_WIDTH_HOST_PORTS[stack_index]=10
    CHECK_STACK_WIDTH_INTERNAL_PORTS[stack_index]=14
    CHECK_STACK_WIDTH_IMAGE[stack_index]=5
    CHECK_STACK_ROWS[stack_index]=""

    if ! command_exists docker; then
        record_check_row "$stack_index" "-" "docker missing" "-" "-" "-" "$STATUS_ERROR"
        return 1
    fi

    if ! docker_accessible; then
        record_check_row "$stack_index" "-" "docker unavailable" "-" "-" "-" "$STATUS_ERROR"
        return 1
    fi

    json_output="$(collect_compose_ps_json "$stack_dir")"
    if [ -n "$json_output" ] && parsed="$(parse_ps_json "$json_output" 2>/dev/null)"; then
        :
    else
        parsed="$(collect_compose_ps_table "$stack_dir" | parse_ps_table 2>/dev/null || true)"
    fi

    if [ -z "$parsed" ]; then
        record_check_row "$stack_index" "-" "no containers" "-" "-" "$(basename "$stack_file")" "$STATUS_STOPPED"
        return 1
    fi

    while IFS='|' read -r service status ports image; do
        [ -n "$service$status$ports$image" ] || continue
        IFS='|' read -r host_ports internal_ports <<< "$(extract_ports "$ports")"
        kind="$(status_kind "$status")"
        if [ "$kind" = "$STATUS_RUNNING" ]; then
            any_running=true
        fi
        record_check_row "$stack_index" "$service" "$status" "$host_ports" "$internal_ports" "$image" "$kind"
    done <<< "$parsed"

    $any_running
}

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

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --update)
                MODE="update"
                ;;
            -i|--interactive)
                INTERACTIVE=true
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            *)
                printf '%bUnknown option:%b %s\n' "$RED" "$NC" "$1" >&2
                print_help >&2
                exit 1
                ;;
        esac
        shift
    done

    if $INTERACTIVE && [ "$MODE" != "update" ]; then
        printf '%bWarning:%b --interactive has effect only with --update\n' "$YELLOW" "$NC" >&2
    fi
}

main() {
    parse_args "$@"

    if command_exists python3; then
        HAS_PYTHON3=true
    fi

    scan_directory_recursive "$START_DIR"

    case "$MODE" in
        check) run_check_mode ;;
        update) run_update_mode ;;
    esac
}

main "$@"
