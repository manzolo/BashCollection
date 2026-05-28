#!/bin/bash
# PKG_NAME: nvidia-manager
# PKG_VERSION: 1.1.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), whiptail
# PKG_RECOMMENDS:
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Interactive NVIDIA driver and GPU management tool
# PKG_LONG_DESCRIPTION: TUI-based tool for managing NVIDIA drivers and GPU settings.
#  .
#  Features:
#  - Check NVIDIA driver status with nvidia-smi
#  - Install and update NVIDIA drivers
#  - Configure GPU settings
#  - Monitor GPU usage and temperature
#  - Interactive whiptail-based interface
#  - Graceful Ctrl+C handling in status and troubleshoot screens
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_NAME="$(basename "$0")"

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Interactive NVIDIA driver and GPU management tool.

Options:
  -h, --help      Show this help message and exit

Features:
  - Check NVIDIA driver status with nvidia-smi
  - Live GPU dashboard with utilization, temperature, VRAM, power, fan and processes
  - Install, update and clean NVIDIA drivers
  - Configure performance settings: persistence mode, power limit, fan speed, clock offsets
  - View GPU processes and terminate selected PIDs
  - Install and validate NVIDIA Container Toolkit
  - Run troubleshooting diagnostics

Run:
  sudo $SCRIPT_NAME
EOF
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Try '$SCRIPT_NAME --help'." >&2
        exit 2
        ;;
esac

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Check if whiptail is installed
if ! command -v whiptail &> /dev/null; then
    echo "whiptail is not installed. Installing..."
    if ! apt-get update || ! apt-get install -y whiptail; then
        echo "Error: Could not install whiptail. Check your connection and repositories."
        exit 1
    fi
fi

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

require_nvidia_smi() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        whiptail --title "NVIDIA Required" --msgbox "nvidia-smi is not available. Install a working NVIDIA driver first." 10 70
        return 1
    fi

    if ! nvidia-smi >/dev/null 2>&1; then
        whiptail --title "NVIDIA Required" --msgbox "nvidia-smi is installed but cannot communicate with the NVIDIA driver." 10 70
        return 1
    fi
}

pause_for_enter() {
    echo ""
    echo -e "${CYAN}Press Enter to return to main menu...${NC}"
    read -r
}

# Function to check NVIDIA driver status
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
SELECTED_GPU_INDEX=""

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
check_and_install_toolkit() {
    # Check for container runtime (Docker or containerd)
    local runtime=""
    if command -v docker &> /dev/null; then
        runtime="docker"
    elif command -v containerd &> /dev/null; then
        runtime="containerd"
    else
        whiptail --title "Container Toolkit" --msgbox "No supported container runtime (Docker or containerd) found." 10 70
        return
    fi

    # Check if NVIDIA Container Toolkit is functional
    local toolkit_installed=false
    local test_image="nvidia/cuda:12.2.0-base-ubuntu22.04" # Specific version for broader compatibility
    if [ "$runtime" = "docker" ]; then
        # Attempt to pull the image first to avoid transient failures
        if docker pull "$test_image" &> /dev/null; then
            if docker run --rm --gpus all "$test_image" nvidia-smi &> /dev/null; then
                toolkit_installed=true
            fi
        fi
    elif [ "$runtime" = "containerd" ]; then
        if ctr images pull docker.io/"$test_image" && \
           ctr run --rm --gpus 0 docker.io/"$test_image" test nvidia-smi &> /dev/null; then
            toolkit_installed=true
        fi
    fi

    if $toolkit_installed; then
        local version
        version=$(nvidia-container-toolkit --version 2>/dev/null || echo "Unknown")
        whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit is installed (Version: $version) and working." 10 70
        return
    fi

    # Prompt to install or update toolkit
    if whiptail --title "Install Container Toolkit" --yesno "NVIDIA Container Toolkit is not installed or not working. Install/update it?" 10 70; then
        echo "Setting up NVIDIA Container Toolkit repository..."

        # Add NVIDIA Container Toolkit repository
        local repo_url="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"
        local gpg_key="https://nvidia.github.io/libnvidia-container/gpgkey"
        local keyring="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"

        # Check if GPG key exists to avoid overwrite prompt
        if [ -f "$keyring" ]; then
            echo "GPG key already exists at $keyring. Skipping key download."
        else
            if ! curl -fsSL "$gpg_key" | sudo gpg --dearmor -o "$keyring"; then
                whiptail --title "Error" --msgbox "Could not add NVIDIA GPG key. Check your connection." 10 60
                return
            fi
        fi

        # Add repository with proper signed-by syntax
        if ! curl -fsSL "$repo_url" | \
            sed 's|deb |deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] |' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list; then
            whiptail --title "Error" --msgbox "Could not add NVIDIA repository. Check your connection." 10 60
            return
        fi

        # Install or update the toolkit
        echo "Installing NVIDIA Container Toolkit..."
        if apt-get update && apt-get install -y nvidia-container-toolkit; then
            # Configure runtime based on detected runtime
            if [ "$runtime" = "docker" ]; then
                if nvidia-ctk runtime configure --runtime=docker && systemctl restart docker; then
                    whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit installed and configured for Docker." 10 70
                else
                    whiptail --title "Warning" --msgbox "Toolkit installed, but Docker configuration failed. Please check manually." 15 70
                fi
            elif [ "$runtime" = "containerd" ]; then
                if nvidia-ctk runtime configure --runtime=containerd && systemctl restart containerd; then
                    whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit installed and configured for containerd." 10 70
                else
                    whiptail --title "Warning" --msgbox "Toolkit installed, but containerd configuration failed. Please check manually." 15 70
                fi
            fi

            # Suggest reboot if needed
            if [ -f "/var/run/reboot-required" ]; then
                if whiptail --title "Reboot Required" --yesno "A system reboot is required to complete the installation. Reboot now?" 10 60; then
                    reboot
                else
                    whiptail --title "Reboot Required" --msgbox "Please reboot your system manually to complete the installation." 10 60
                fi
            fi
        else
            whiptail --title "Error" --msgbox "Error installing NVIDIA Container Toolkit." 10 60
        fi
    else
        whiptail --title "Container Toolkit" --msgbox "Installation canceled." 10 60
    fi
}

# Troubleshooting NVIDIA
troubleshoot_nvidia() {
    # Set up trap to catch Ctrl+C and return to menu gracefully
    trap 'echo -e "\n${YELLOW}Returning to main menu...${NC}"; return 0' INT

    log "Running NVIDIA troubleshooting..."

    clear
    echo "=== NVIDIA Troubleshooting Report ==="
    echo "Generated: $(date)"
    echo -e "${GRAY}Press Ctrl+C to return to main menu${NC}"
    echo
    
    # 1. Verifica presenza driver host
    local host_version
    host_version=$(detect_host_nvidia)
    
    # 2. Verifica container
    detect_container_nvidia
    
    # 3. Test OpenGL
    echo "=== OpenGL Test ==="
    if command -v glxinfo >/dev/null 2>&1; then
        local gl_renderer
        gl_renderer=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -n1)
        if [[ "$gl_renderer" =~ NVIDIA ]]; then
            success "$gl_renderer"
        else
            warning "OpenGL renderer: $gl_renderer"
        fi
    else
        warning "glxinfo not available (install mesa-utils)"
    fi
    echo
    
    # 4. Test CUDA (se disponibile)
    echo "=== CUDA Test ==="
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            success "nvidia-smi working"
            nvidia-smi -L 2>/dev/null || warning "Could not list GPU devices"
        else
            error "nvidia-smi failed"
        fi
    else
        warning "nvidia-smi not available"
    fi
    echo
    
    # 5. Verifica device nodes
    echo "=== Device Nodes ==="
    local nvidia_devices=(
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
    )
    
    for device in "${nvidia_devices[@]}"; do
        if [ -e "$device" ]; then
            success "Found: $device"
        else
            warning "Missing: $device"
        fi
    done
    echo
    
    echo
    log "Troubleshooting completed"
    pause_for_enter

    # Remove trap when done
    trap - INT
}

# Rileva driver NVIDIA host
detect_host_nvidia() {
    log "Detecting host NVIDIA driver..."
    
    local host_version=""
    local detection_method=""
    
    # Metodo 1: /proc/driver/nvidia/version
    if [ -f "/proc/driver/nvidia/version" ]; then
        host_version=$(sed -nE 's/.*Module[ \t]+([0-9]+\.[0-9]+).*/\1/p' /proc/driver/nvidia/version | head -n1)
        if [ -n "$host_version" ]; then
            detection_method="/proc/driver/nvidia/version"
        fi
    fi
    
    # Metodo 2: nvidia-smi
    if [ -z "$host_version" ] && command -v nvidia-smi >/dev/null 2>&1; then
        host_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ')
        if [ -n "$host_version" ]; then
            detection_method="nvidia-smi"
        fi
    fi
    
    # Metodo 3: modinfo
    if [ -z "$host_version" ] && command -v modinfo >/dev/null 2>&1; then
        host_version=$(modinfo nvidia 2>/dev/null | grep '^version:' | awk '{print $2}')
        if [ -n "$host_version" ]; then
            detection_method="modinfo"
        fi
    fi
    
    echo "=== Host NVIDIA Driver ==="
    if [ -n "$host_version" ]; then
        success "Version: $host_version"
        echo "Detection method: $detection_method"
        echo "Major version: $(echo "$host_version" | cut -d. -f1)"
    else
        warning "No NVIDIA driver detected on host"
    fi
    echo
    
    echo "$host_version"
}

# Rileva driver container
detect_container_nvidia() {
    log "Detecting container NVIDIA packages..."
    
    echo "=== Container NVIDIA Packages ==="
    
    local nvidia_packages
    nvidia_packages=$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /nvidia/ {printf "%-30s %s\n", $2, $3}')
    
    if [ -n "$nvidia_packages" ]; then
        echo "$nvidia_packages"
        
        # Estrai versione principale
        local main_version
        main_version=$(dpkg -l 2>/dev/null | \
            awk '$1 == "ii" && $2 ~ /^libnvidia-gl-/ {print $3}' | \
            sed -nE 's/^([0-9]+(\.[0-9]+)?).*/\1/p' | \
            head -n1)
        
        if [ -n "$main_version" ]; then
            success "Primary driver version: $main_version"
        fi
    else
        warning "No NVIDIA packages found in container"
    fi
    echo
}

# Main menu
while true; do
    CHOICE=$(whiptail --title "NVIDIA Driver Manager" --menu "Choose an option" 22 70 10 \
        "1" "Search and Install Drivers" \
        "2" "Manage Container Toolkit" \
        "3" "Check Driver Status" \
        "4" "Live GPU Dashboard" \
        "5" "Performance Controls" \
        "6" "GPU Process Viewer" \
        "7" "Clean Drivers" \
        "8" "Troubleshoot" \
        "9" "Exit" 3>&1 1>&2 2>&3)

    case $CHOICE in
        1)
            search_drivers
            ;;
        2)
            check_and_install_toolkit
            ;;
        3)
            check_driver_status
            ;;
        4)
            show_live_dashboard
            ;;
        5)
            performance_controls
            ;;
        6)
            show_gpu_processes
            ;;
        7)
            clean_drivers
            ;;
        8)
            troubleshoot_nvidia
            ;;
        9)
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
done
