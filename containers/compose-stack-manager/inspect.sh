# compose-stack-manager module: compose ps collection and parsing
# Sourced by compose-stack-manager.sh — do not execute directly.
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

