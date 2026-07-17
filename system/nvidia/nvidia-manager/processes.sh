# nvidia-manager module: GPU process viewer
# Sourced by nvidia-manager.sh — do not execute directly.
pid_is_gpu_process() {
    nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null \
        | tr -d ' ' | grep -Fxq "$1"
}

show_gpu_processes() {
    require_nvidia_smi || return

    # process_name is queried last so that a comma inside a process name
    # cannot shift the remaining comma-separated fields.
    local process_lines
    process_lines=$(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid,process_name --format=csv,noheader,nounits 2>/dev/null || true)

    if [ -z "$process_lines" ]; then
        whiptail --title "GPU Processes" --msgbox "No compute processes are currently reported by nvidia-smi." 10 70
        return
    fi

    local menu_items=()
    local pid process_name used_memory gpu_uuid
    while IFS=',' read -r pid used_memory gpu_uuid process_name; do
        pid="${pid//[[:space:]]/}"
        process_name="${process_name#"${process_name%%[![:space:]]*}"}"
        used_memory="${used_memory//[[:space:]]/}"
        gpu_uuid="${gpu_uuid//[[:space:]]/}"
        menu_items+=("$pid" "${used_memory}MiB | ${gpu_uuid:0:12} | $process_name")
    done <<< "$process_lines"

    local selected_pid
    selected_pid=$(whiptail --title "GPU Processes" --menu "Select a process to manage" 20 90 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || return

    local action
    action=$(whiptail --title "Process $selected_pid" --menu "Choose action for PID $selected_pid" 12 60 3 \
        "info" "Show process details" \
        "term" "Terminate gracefully (SIGTERM)" \
        "kill" "Force kill (SIGKILL)" 3>&1 1>&2 2>&3) || return

    case "$action" in
        info)
            local details
            details=$(ps -p "$selected_pid" -o pid,ppid,user,stat,etime,cmd 2>&1 || true)
            whiptail --title "Process Details" --msgbox "$details" 18 90
            ;;
        term)
            if ! pid_is_gpu_process "$selected_pid"; then
                whiptail --title "Terminate Process" --msgbox "PID $selected_pid is no longer an active GPU process. Aborting to avoid killing a recycled PID." 11 70
                return
            fi
            if whiptail --title "Confirm Terminate" --yesno "Send SIGTERM to PID $selected_pid?" 10 60; then
                if kill -TERM "$selected_pid"; then
                    whiptail --title "Terminate Process" --msgbox "SIGTERM sent to PID $selected_pid." 10 60
                else
                    whiptail --title "Terminate Process" --msgbox "Could not terminate PID $selected_pid." 10 60
                fi
            fi
            ;;
        kill)
            if ! pid_is_gpu_process "$selected_pid"; then
                whiptail --title "Force Kill Process" --msgbox "PID $selected_pid is no longer an active GPU process. Aborting to avoid killing a recycled PID." 11 70
                return
            fi
            if whiptail --title "Confirm Force Kill" --yesno "Send SIGKILL to PID $selected_pid?\n\nUnsaved work may be lost." 12 60; then
                if kill -KILL "$selected_pid"; then
                    whiptail --title "Force Kill Process" --msgbox "SIGKILL sent to PID $selected_pid." 10 60
                else
                    whiptail --title "Force Kill Process" --msgbox "Could not kill PID $selected_pid." 10 60
                fi
            fi
            ;;
    esac
}

# Function to check and install the NVIDIA Container Toolkit
