# nvidia-manager module: GPU selection and performance controls
# Sourced by nvidia-manager.sh — do not execute directly.

select_gpu_index() {
    SELECTED_GPU_INDEX=""
    require_nvidia_smi || return 1

    local gpu_lines
    gpu_lines=$(nvidia-smi --query-gpu=index,name --format=csv,noheader,nounits 2>/dev/null || true)
    if [ -z "$gpu_lines" ]; then
        whiptail --title "GPU Selection" --msgbox "No NVIDIA GPU detected." 10 60
        return 1
    fi

    local menu_items=()
    local index name
    while IFS=',' read -r index name; do
        index="${index//[[:space:]]/}"
        name="${name#"${name%%[![:space:]]*}"}"
        menu_items+=("$index" "$name")
    done <<< "$gpu_lines"

    local choice
    choice=$(whiptail --title "Select GPU" --menu "Choose a GPU" 15 78 6 "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1
    SELECTED_GPU_INDEX="$choice"
}

set_persistence_mode() {
    require_nvidia_smi || return

    local choice
    choice=$(whiptail --title "Persistence Mode" --menu "Set NVIDIA persistence mode" 12 60 2 \
        "1" "Enable persistence mode" \
        "0" "Disable persistence mode" 3>&1 1>&2 2>&3) || return

    if nvidia-smi -pm "$choice"; then
        whiptail --title "Persistence Mode" --msgbox "Persistence mode updated." 10 60
    else
        whiptail --title "Persistence Mode" --msgbox "Could not update persistence mode." 10 60
    fi
}

set_power_limit() {
    local gpu_index
    select_gpu_index || return
    gpu_index="$SELECTED_GPU_INDEX"

    local current_limits
    current_limits=$(nvidia-smi -i "$gpu_index" -q -d POWER 2>/dev/null | awk -F ':' '/Current Power Limit|Min Power Limit|Max Power Limit/ {gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $1 ": " $2}' || true)

    local watts
    watts=$(whiptail --title "Power Limit" --inputbox "GPU $gpu_index power limits:\n${current_limits:-Unavailable}\n\nEnter new power limit in watts:" 16 70 3>&1 1>&2 2>&3) || return

    if ! [[ "$watts" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        whiptail --title "Power Limit" --msgbox "Invalid power limit: $watts" 10 60
        return
    fi

    if whiptail --title "Confirm Power Limit" --yesno "Set GPU $gpu_index power limit to ${watts}W?" 10 60; then
        if nvidia-smi -i "$gpu_index" -pl "$watts"; then
            whiptail --title "Power Limit" --msgbox "Power limit updated." 10 60
        else
            whiptail --title "Power Limit" --msgbox "Could not update power limit. The selected GPU/driver may not support it." 10 70
        fi
    fi
}

set_fan_speed() {
    if ! command -v nvidia-settings >/dev/null 2>&1; then
        whiptail --title "Fan Control" --msgbox "nvidia-settings is required for fan control." 10 60
        return
    fi

    local gpu_index
    select_gpu_index || return
    gpu_index="$SELECTED_GPU_INDEX"

    local percent
    percent=$(whiptail --title "Fan Control" --inputbox "Enter fan speed percentage for GPU $gpu_index (0-100).\n\nRequires X session and Coolbits fan control enabled." 12 70 3>&1 1>&2 2>&3) || return

    if ! [[ "$percent" =~ ^[0-9]+$ ]] || [ "$percent" -gt 100 ]; then
        whiptail --title "Fan Control" --msgbox "Invalid fan speed: $percent" 10 60
        return
    fi

    # Fan indices in nvidia-settings are global and unrelated to GPU index, and
    # a GPU usually has several fans. On a single-GPU system every reported fan
    # belongs to that GPU, so drive all of them; on multi-GPU systems the fan
    # mapping is ambiguous, so fall back to a best-effort single fan.
    local fan_args=()
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | grep -c .)
    if [ "${gpu_count:-0}" -le 1 ]; then
        local fan
        while IFS= read -r fan; do
            [ -n "$fan" ] && fan_args+=("-a" "[fan:${fan}]/GPUTargetFanSpeed=${percent}")
        done < <(nvidia-settings -q fans 2>/dev/null | grep -oE '\[fan:[0-9]+\]' | grep -oE '[0-9]+' | sort -un)
    fi
    if [ ${#fan_args[@]} -eq 0 ]; then
        fan_args=("-a" "[fan:${gpu_index}]/GPUTargetFanSpeed=${percent}")
    fi

    if whiptail --title "Confirm Fan Control" --yesno "Set GPU $gpu_index fan speed to ${percent}%?\n\nThis switches the GPU fans to manual control." 12 70; then
        if nvidia-settings -a "[gpu:${gpu_index}]/GPUFanControlState=1" "${fan_args[@]}"; then
            whiptail --title "Fan Control" --msgbox "Fan speed updated." 10 60
        else
            whiptail --title "Fan Control" --msgbox "Could not update fan speed. Check DISPLAY, X permissions and Coolbits." 12 70
        fi
    fi
}

reset_fan_control() {
    if ! command -v nvidia-settings >/dev/null 2>&1; then
        whiptail --title "Fan Control" --msgbox "nvidia-settings is required for fan control." 10 60
        return
    fi

    local gpu_index
    select_gpu_index || return
    gpu_index="$SELECTED_GPU_INDEX"

    if nvidia-settings -a "[gpu:${gpu_index}]/GPUFanControlState=0"; then
        whiptail --title "Fan Control" --msgbox "Fan control reset to automatic." 10 60
    else
        whiptail --title "Fan Control" --msgbox "Could not reset fan control. Check DISPLAY and X permissions." 12 70
    fi
}

set_clock_offsets() {
    if ! command -v nvidia-settings >/dev/null 2>&1; then
        whiptail --title "Clock Offsets" --msgbox "nvidia-settings is required for clock offsets." 10 60
        return
    fi

    local gpu_index
    select_gpu_index || return
    gpu_index="$SELECTED_GPU_INDEX"

    local graphics_offset memory_offset
    graphics_offset=$(whiptail --title "Graphics Clock Offset" --inputbox "Enter graphics clock offset in MHz for GPU $gpu_index.\nUse 0 to leave unchanged." 12 70 "0" 3>&1 1>&2 2>&3) || return
    memory_offset=$(whiptail --title "Memory Clock Offset" --inputbox "Enter memory transfer rate offset in MHz for GPU $gpu_index.\nUse 0 to leave unchanged." 12 70 "0" 3>&1 1>&2 2>&3) || return

    if ! [[ "$graphics_offset" =~ ^-?[0-9]+$ ]] || ! [[ "$memory_offset" =~ ^-?[0-9]+$ ]]; then
        whiptail --title "Clock Offsets" --msgbox "Offsets must be integer MHz values." 10 60
        return
    fi

    if whiptail --title "Confirm Clock Offsets" --yesno "Apply offsets to GPU $gpu_index?\n\nGraphics: ${graphics_offset} MHz\nMemory: ${memory_offset} MHz\n\nRequires X session and Coolbits overclocking enabled." 14 70; then
        local ok=true
        if [ "$graphics_offset" != "0" ]; then
            nvidia-settings -a "[gpu:${gpu_index}]/GPUGraphicsClockOffset[3]=${graphics_offset}" || ok=false
        fi
        if [ "$memory_offset" != "0" ]; then
            nvidia-settings -a "[gpu:${gpu_index}]/GPUMemoryTransferRateOffset[3]=${memory_offset}" || ok=false
        fi

        if $ok; then
            whiptail --title "Clock Offsets" --msgbox "Clock offsets applied." 10 60
        else
            whiptail --title "Clock Offsets" --msgbox "Could not apply one or more offsets. Check DISPLAY, X permissions and Coolbits." 12 70
        fi
    fi
}

reset_gpu_clocks() {
    local gpu_index
    select_gpu_index || return
    gpu_index="$SELECTED_GPU_INDEX"

    if whiptail --title "Reset Clocks" --yesno "Reset locked graphics and memory clocks for GPU $gpu_index?" 10 70; then
        local ok=true
        nvidia-smi -i "$gpu_index" -rgc || ok=false
        nvidia-smi -i "$gpu_index" -rmc || ok=false

        if $ok; then
            whiptail --title "Reset Clocks" --msgbox "GPU clocks reset." 10 60
        else
            whiptail --title "Reset Clocks" --msgbox "Could not reset one or more clock settings." 10 60
        fi
    fi
}

performance_controls() {
    require_nvidia_smi || return

    while true; do
        local choice
        choice=$(whiptail --title "NVIDIA Performance Controls" --menu "Choose a performance setting" 18 74 8 \
            "1" "Enable/disable persistence mode" \
            "2" "Set GPU power limit" \
            "3" "Set manual fan speed (nvidia-settings)" \
            "4" "Reset fan control to automatic" \
            "5" "Set clock offsets (nvidia-settings)" \
            "6" "Reset locked GPU clocks (nvidia-smi)" \
            "7" "Back" 3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) set_persistence_mode ;;
            2) set_power_limit ;;
            3) set_fan_speed ;;
            4) reset_fan_control ;;
            5) set_clock_offsets ;;
            6) reset_gpu_clocks ;;
            7) return ;;
            *) return ;;
        esac
    done
}

# Returns success only if the PID is still reported by nvidia-smi as a GPU
# compute process, so a recycled PID is not killed after the menu was built.
