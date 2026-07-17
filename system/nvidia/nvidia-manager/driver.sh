# nvidia-manager module: driver status, dashboard, install, cleanup
# Sourced by nvidia-manager.sh — do not execute directly.
check_driver_status() {
    # Set up trap to catch Ctrl+C and return to menu gracefully
    trap 'echo -e "\n${YELLOW}Returning to main menu...${NC}"; return 0' INT

    clear
    echo "Checking NVIDIA driver status..."
    echo -e "${GRAY}Press Ctrl+C to return to main menu${NC}"
    echo ""

    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi
        pause_for_enter
    else
        whiptail --title "NVIDIA Driver Status" --msgbox "NVIDIA driver not detected or not working correctly." 10 60
    fi

    # Remove trap when done
    trap - INT
}

show_live_dashboard() {
    require_nvidia_smi || return

    local interval=2
    trap 'echo -e "\n${YELLOW}Returning to main menu...${NC}"; trap - INT; return 0' INT

    while true; do
        clear
        echo "=== NVIDIA Live Dashboard ==="
        echo "Updated: $(date '+%Y-%m-%d %H:%M:%S') | refresh: ${interval}s | press q or Ctrl+C to return"
        echo ""

        nvidia-smi --query-gpu=index,name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw,power.limit,fan.speed,pstate \
            --format=csv,noheader,nounits 2>/dev/null | \
            awk -F ', ' '
                BEGIN {
                    printf "%-4s %-28s %8s %7s %17s %17s %9s %7s\n", "GPU", "Name", "Util", "Temp", "VRAM", "Power", "Fan", "Pstate"
                    printf "%-4s %-28s %8s %7s %17s %17s %9s %7s\n", "---", "----", "----", "----", "----", "-----", "---", "------"
                }
                {
                    fan=$9
                    if (fan == "[N/A]" || fan == "N/A") fan="N/A"; else fan=fan "%"
                    printf "%-4s %-28.28s %7s%% %6sC %8s/%-7s MiB %7s/%-7s W %9s %7s\n", $1, $2, $3, $4, $5, $6, $7, $8, fan, $10
                }'

        echo ""
        echo "=== GPU Processes ==="
        local process_output
        process_output=$(nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory,process_name --format=csv,noheader,nounits 2>/dev/null || true)
        if [ -n "$process_output" ]; then
            printf "%-18s %-8s %-42s %10s\n" "GPU UUID" "PID" "Process" "VRAM MiB"
            printf "%-18s %-8s %-42s %10s\n" "--------" "---" "-------" "--------"
            echo "$process_output" | awk -F ', ' '{printf "%-18.18s %-8s %-42.42s %10s\n", $1, $2, $4, $3}'
        else
            echo "No compute processes reported by nvidia-smi."
        fi

        local key=""
        read -r -t "$interval" -n 1 key || true
        if [[ "$key" == "q" || "$key" == "Q" ]]; then
            break
        fi
    done

    trap - INT
}

# Function to clean NVIDIA drivers
clean_drivers() {
    if whiptail --title "Clean NVIDIA Drivers" --yesno "This operation will remove all NVIDIA drivers. Continue?" 10 60; then
        echo "Removing NVIDIA drivers..."
        if apt-get remove --purge -y 'nvidia-*' 'libnvidia-*' && apt-get autoremove -y && apt-get autoclean; then
            whiptail --title "Clean NVIDIA Drivers" --msgbox "NVIDIA drivers removed successfully." 10 60
        else
            whiptail --title "Clean NVIDIA Drivers" --msgbox "An error occurred while removing the drivers." 10 60
        fi
    else
        whiptail --title "Clean NVIDIA Drivers" --msgbox "Operation canceled." 10 60
    fi
}

# Function to search for available NVIDIA drivers
search_drivers() {
    clear
    echo "Searching for available NVIDIA drivers..."
    if ! apt-get update; then
        whiptail --title "Driver Search" --msgbox "Could not update repositories. Check your connection." 10 60
        return
    fi

    local DRIVER_LIST
    # Search and sort by version number (descending - newest first)
    DRIVER_LIST=$(apt-cache search --names-only '^nvidia-driver-[0-9]+' | \
                  awk '{print $1}' | \
                  sort -t'-' -k3 -rn)

    if [ -z "$DRIVER_LIST" ]; then
        whiptail --title "Driver Search" --msgbox "No NVIDIA drivers found." 10 60
        return
    fi

    # Create proper whiptail menu format (tag description pairs)
    local DRIVERS_MENU=()
    while IFS= read -r driver; do
        # Extract version number for better description
        local version
        version=$(echo "$driver" | grep -oP 'nvidia-driver-\K[0-9]+')
        DRIVERS_MENU+=("$driver" "Version $version (NVIDIA Driver)")
    done <<< "$DRIVER_LIST"
    
    CHOICE=$(whiptail --title "Available NVIDIA Drivers" --menu "Select a driver to install" 25 78 15 "${DRIVERS_MENU[@]}" 3>&1 1>&2 2>&3)
    
    if [ -n "$CHOICE" ]; then
        if whiptail --title "Driver Installation" --yesno "Install $CHOICE?" 10 60; then
            install_driver "$CHOICE"
        fi
    else
        whiptail --title "Driver Installation" --msgbox "No driver selected." 10 60
    fi
}

# Function to install a specific NVIDIA driver
install_driver() {
    local driver_name=$1
    echo "Installing $driver_name..."
    if apt-get update && apt-get install -y "$driver_name"; then
        whiptail --title "Driver Installation" --msgbox "$driver_name installed successfully." 10 60
    else
        whiptail --title "Driver Installation" --msgbox "Error installing $driver_name." 10 60
    fi
}

# Result is returned via the SELECTED_GPU_INDEX global instead of stdout, so
# that error dialogs raised here (and inside require_nvidia_smi) render on the
# terminal rather than being swallowed by a command substitution.
