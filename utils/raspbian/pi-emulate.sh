#!/bin/bash

# ==============================================================================
# QEMU Raspberry Pi Manager - Professional Edition
# Version: 2.0.0
# Description: Advanced management system for Raspberry Pi OS emulation in QEMU
# Author: Enhanced version with dialog UI and improved networking
# ==============================================================================

# Use safer error handling
set -eo pipefail

# Initialize environment variables
export VERBOSE="${VERBOSE:-0}"
export DEBUG="${DEBUG:-0}"
export NO_DIALOG="${NO_DIALOG:-0}"

# ==============================================================================
# GLOBAL CONFIGURATION
# ==============================================================================

# Paths and directories
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Use home directory for workspace to avoid permission issues
readonly WORK_DIR="${HOME}/.qemu-rpi-manager"
readonly IMAGES_DIR="${WORK_DIR}/images"
readonly KERNELS_DIR="${WORK_DIR}/kernels"
readonly SNAPSHOTS_DIR="${WORK_DIR}/snapshots"
readonly CONFIGS_DIR="${WORK_DIR}/configs"
readonly LOGS_DIR="${WORK_DIR}/logs"
readonly TEMP_DIR="${WORK_DIR}/temp"
readonly CACHE_DIR="${WORK_DIR}/cache"

# Configuration files
readonly CONFIG_FILE="${CONFIGS_DIR}/qemu-rpi.conf"
readonly INSTANCES_DB="${CONFIGS_DIR}/instances.db"
readonly NETWORK_CONFIG="${CONFIGS_DIR}/network.conf"

# Logging
readonly LOG_FILE="${LOGS_DIR}/qemu-rpi-$(date +%Y%m%d-%H%M%S).log"

# Dialog configuration
export DIALOGRC="${CONFIGS_DIR}/dialog.rc"
readonly DIALOG_HEIGHT=20
readonly DIALOG_WIDTH=70

# QEMU defaults
readonly DEFAULT_MEMORY="256"  # versatilepb supports max 256MB
readonly DEFAULT_CORES="1"     # versatilepb supports single core
readonly DEFAULT_SSH_PORT="5022"
readonly DEFAULT_VNC_PORT="5901"
readonly DEFAULT_MONITOR_PORT="5555"

# Network profiles
declare -A NETWORK_PROFILES=(
    ["NAT"]="user,id=net0,hostfwd=tcp::\${SSH_PORT}-:22"
    ["Bridge"]="bridge,id=net0,br=br0"
    ["TAP"]="tap,id=net0,ifname=tap0,script=no,downscript=no"
    ["None"]="none"
)

# OS Catalog with enhanced metadata
declare -A OS_CATALOG=(
    ["jessie_2017"]="jessie|2017-04-10|4.4.34|versatile-pb.dtb|256|http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/2017-04-10-raspbian-jessie.zip"
    ["stretch_2018"]="stretch|2018-11-13|4.14.79|versatile-pb.dtb|512|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2018-11-15/2018-11-13-raspbian-stretch-lite.zip"
    ["buster_2020"]="buster|2020-02-13|4.19.50|versatile-pb-buster.dtb|512|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2020-02-14/2020-02-13-raspbian-buster-lite.zip"
    ["bullseye_2022"]="bullseye|2022-04-04|5.10.63|versatile-pb.dtb|1024|https://downloads.raspberrypi.org/raspios_oldstable_lite_armhf/images/raspios_oldstable_lite_armhf-2022-04-07/2022-04-04-raspios-buster-armhf-lite.img.xz"
)

# Kernel repository
readonly KERNEL_REPO="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master"

# ==============================================================================
# LOGGING SYSTEM
# ==============================================================================

log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    # Don't redirect stderr globally, just for logging
    echo "=== QEMU RPi Manager Started: $(date) ===" >> "$LOG_FILE"
}

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    
    case $level in
        ERROR)   
            echo -e "\033[0;31m[ERROR]\033[0m $message" >&2 
            ;;
        WARNING) 
            echo -e "\033[1;33m[WARNING]\033[0m $message" >&2 
            ;;
        INFO)    
            if [ "${VERBOSE}" = "1" ]; then
                echo -e "\033[0;32m[INFO]\033[0m $message"
            fi
            ;;
        DEBUG)   
            if [ "${DEBUG}" = "1" ]; then
                echo -e "\033[0;34m[DEBUG]\033[0m $message"
            fi
            ;;
    esac
    return 0
}

# ==============================================================================
# DIALOG UI FUNCTIONS
# ==============================================================================

check_dialog() {
    if ! command -v dialog &> /dev/null; then
        echo "Dialog is required for the UI. Installing..."
        echo "You may be prompted for your password."
        if ! ${SUDO_CMD} apt-get update && ${SUDO_CMD} apt-get install -y dialog whiptail; then
            echo "Failed to install dialog. Please install it manually:"
            echo "sudo apt-get install dialog"
            exit 1
        fi
    fi
    return 0
}

create_dialog_rc() {
    cat > "$DIALOGRC" <<'EOF'
# Dialog configuration
aspect = 0
separate_widget = ""
tab_len = 0
visit_items = ON
use_shadow = ON
use_colors = ON

# Color scheme
screen_color = (CYAN,BLUE,ON)
shadow_color = (BLACK,BLACK,ON)
dialog_color = (BLACK,WHITE,OFF)
title_color = (BLUE,WHITE,ON)
border_color = title_color
button_active_color = (WHITE,BLUE,ON)
button_inactive_color = dialog_color
button_key_active_color = button_active_color
button_key_inactive_color = (RED,WHITE,OFF)
button_label_active_color = (YELLOW,BLUE,ON)
button_label_inactive_color = (BLACK,WHITE,ON)
inputbox_color = dialog_color
inputbox_border_color = dialog_color
searchbox_color = dialog_color
searchbox_title_color = title_color
searchbox_border_color = border_color
position_indicator_color = title_color
menubox_color = dialog_color
menubox_border_color = border_color
item_color = dialog_color
item_selected_color = (WHITE,BLUE,ON)
tag_color = title_color
tag_selected_color = button_label_active_color
tag_key_color = button_key_inactive_color
tag_key_selected_color = (RED,BLUE,ON)
check_color = dialog_color
check_selected_color = button_active_color
uarrow_color = (GREEN,WHITE,ON)
darrow_color = uarrow_color
itemhelp_color = (WHITE,BLACK,OFF)
form_active_text_color = button_active_color
form_text_color = (WHITE,CYAN,ON)
form_item_readonly_color = (CYAN,WHITE,ON)
gauge_color = (BLUE,WHITE,ON)
EOF
}

show_main_menu() {
    local choice
    choice=$(dialog --clear --backtitle "QEMU Raspberry Pi Manager v2.0" \
        --title "[ Main Menu ]" \
        --menu "Select an option:" 18 65 11 \
        "1" "Quick Start (Launch with defaults)" \
        "2" "Create New Instance" \
        "3" "Manage Instances" \
        "4" "Download OS Images" \
        "5" "Kernel Management" \
        "6" "Network Configuration" \
        "7" "Advanced Settings" \
        "8" "System Diagnostics" \
        "9" "View Logs" \
        "0" "Exit" \
        2>&1 >/dev/tty)
    
    echo "$choice"
}

show_progress() {
    local title=$1
    local text=$2
    dialog --gauge "$text" 10 70 0 --title "$title"
}

# ==============================================================================
# SYSTEM CHECKS AND INITIALIZATION
# ==============================================================================

init_workspace() {
    local dirs=("$WORK_DIR" "$IMAGES_DIR" "$KERNELS_DIR" "$SNAPSHOTS_DIR" 
                "$CONFIGS_DIR" "$LOGS_DIR" "$TEMP_DIR" "$CACHE_DIR")
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" || {
            log ERROR "Failed to create directory: $dir"
            return 1
        }
    done
    
    # Initialize database if not exists
    if [ ! -f "$INSTANCES_DB" ]; then
        cat > "$INSTANCES_DB" <<EOF
# Instance Database
# Format: ID|Name|Image|Kernel|DTB|Memory|Status|Created|LastRun
EOF
    fi
    
    # Create default config if not exists
    if [ ! -f "$CONFIG_FILE" ]; then
        create_default_config
    fi
    
    create_dialog_rc
    return 0
}

create_default_config() {
    cat > "$CONFIG_FILE" <<EOF
# QEMU Raspberry Pi Manager Configuration

# Default QEMU settings
DEFAULT_MEMORY=${DEFAULT_MEMORY}
DEFAULT_CORES=1
DEFAULT_MACHINE=versatilepb
DEFAULT_CPU=arm1176

# Network defaults
DEFAULT_NETWORK_MODE=NAT
DEFAULT_SSH_PORT=${DEFAULT_SSH_PORT}
DEFAULT_VNC_PORT=${DEFAULT_VNC_PORT}

# Performance tuning
ENABLE_KVM=false
ENABLE_BALLOON=true
ENABLE_VIRTIO=false

# Storage
DEFAULT_DISK_FORMAT=qcow2
ENABLE_SNAPSHOTS=true
COMPRESS_IMAGES=true

# UI Preferences
VERBOSE=0
DEBUG=0
AUTO_BACKUP=true
EOF
}

check_requirements() {
    local missing=()
    local required_cmds=(qemu-system-arm qemu-img wget unzip xz fdisk dialog nc ssh)
    
    # Check curl as optional for better download progress
    if command -v curl &> /dev/null; then
        log INFO "curl available for downloads"
    else
        log INFO "curl not found, will use wget"
    fi
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        dialog --msgbox "Missing dependencies:\n${missing[*]}\n\nInstalling..." 10 50
        install_dependencies "${missing[@]}"
    fi
    
    return 0
}

install_dependencies() {
    local deps=("$@")
    local apt_packages=""
    
    for dep in "${deps[@]}"; do
        case $dep in
            qemu-system-arm) apt_packages+=" qemu-system-arm qemu-utils" ;;
            nc) apt_packages+=" netcat" ;;
            dialog) apt_packages+=" dialog" ;;
            xz) apt_packages+=" xz-utils" ;;
            fdisk) apt_packages+=" fdisk" ;;
            *) apt_packages+=" $dep" ;;
        esac
    done
    
    # Also recommend curl for better downloads
    apt_packages+=" curl"
    
    dialog --msgbox "Missing packages:$apt_packages\n\nYou will be prompted for your password to install them." 10 60
    
    # Simple installation without complex progress tracking
    clear
    echo "Installing dependencies..."
    echo "Packages: $apt_packages"
    echo ""
    ${SUDO_CMD} apt-get update
    ${SUDO_CMD} apt-get install -y $apt_packages
    
    dialog --msgbox "Dependencies installed successfully!" 8 40
}

# ==============================================================================
# NETWORK CONFIGURATION MODULE
# ==============================================================================

setup_network_bridge() {
    dialog --title "Network Bridge Setup" --msgbox \
        "Setting up network bridge for better connectivity.\n\nThis requires sudo access." 10 50
    
    local bridge_name="br0"
    local interface=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [ -z "$interface" ]; then
        dialog --msgbox "Could not detect primary network interface!" 10 50
        return 1
    fi
    
    # Create bridge setup script
    cat > "${TEMP_DIR}/setup-bridge.sh" <<EOF
#!/bin/bash
# Create bridge
${SUDO_CMD} ip link add name ${bridge_name} type bridge
${SUDO_CMD} ip link set ${bridge_name} up

# Add interface to bridge
${SUDO_CMD} ip link set ${interface} master ${bridge_name}

# Get IP from DHCP
${SUDO_CMD} dhclient ${bridge_name}

# Enable IP forwarding
${SUDO_CMD} sysctl -w net.ipv4.ip_forward=1
${SUDO_CMD} sysctl -w net.ipv6.conf.all.forwarding=1

# Configure iptables
${SUDO_CMD} iptables -t nat -A POSTROUTING -o ${bridge_name} -j MASQUERADE
${SUDO_CMD} iptables -A FORWARD -i ${bridge_name} -j ACCEPT
EOF
    
    chmod +x "${TEMP_DIR}/setup-bridge.sh"
    
    if dialog --yesno "Execute bridge setup?\n\nInterface: ${interface}\nBridge: ${bridge_name}" 10 50; then
        "${TEMP_DIR}/setup-bridge.sh" 2>&1 | show_progress "Setting up Network Bridge" "Configuring..."
        echo "BRIDGE_NAME=${bridge_name}" >> "$NETWORK_CONFIG"
        echo "BRIDGE_INTERFACE=${interface}" >> "$NETWORK_CONFIG"
        dialog --msgbox "Network bridge configured successfully!" 8 40
    fi
}

configure_tap_network() {
    local tap_name="tap0"
    
    cat > "${TEMP_DIR}/setup-tap.sh" <<EOF
#!/bin/bash
# Create TAP interface
${SUDO_CMD} ip tuntap add dev ${tap_name} mode tap user $USER
${SUDO_CMD} ip link set ${tap_name} up
${SUDO_CMD} ip link set ${tap_name} master br0

# Configure permissions
${SUDO_CMD} chmod 666 /dev/net/tun
EOF
    
    chmod +x "${TEMP_DIR}/setup-tap.sh"
    "${TEMP_DIR}/setup-tap.sh"
    
    echo "TAP_INTERFACE=${tap_name}" >> "$NETWORK_CONFIG"
}

fix_guest_networking() {
    local instance_id=$1
    
    dialog --title "Network Troubleshooting" --infobox "Analyzing network issues..." 5 40
    
    # Create network fix script for guest
    cat > "${TEMP_DIR}/fix-network.sh" <<'EOF'
#!/bin/bash
# Network fix script for Raspberry Pi guest

echo "=== Fixing Network Configuration ==="

# Load network modules
modprobe 8139cp 2>/dev/null
modprobe 8139too 2>/dev/null
modprobe pcnet32 2>/dev/null

# Restart networking
sudo systemctl restart networking 2>/dev/null || sudo /etc/init.d/networking restart

# Configure DHCP
sudo dhclient -r
sudo dhclient eth0

# Check connectivity
ping -c 1 8.8.8.8 && echo "Network is working!" || echo "Network still not working"

# Show network info
ip addr show
ip route show
EOF
    
    dialog --msgbox "Network fix script created.\n\nCopy to guest and run:\nsudo bash fix-network.sh" 10 50
}

# ==============================================================================
# IMAGE MANAGEMENT MODULE
# ==============================================================================

download_os_image() {
    local os_list=""
    local counter=1
    
    for key in "${!OS_CATALOG[@]}"; do
        IFS='|' read -r version date kernel dtb memory url <<< "${OS_CATALOG[$key]}"
        os_list+="$counter \"$key - Raspbian $version ($date)\" "
        ((counter++))
    done
    
    local choice
    choice=$(eval dialog --title \"Download OS Image\" --menu \"Select OS version:\" 15 70 8 $os_list 2>&1 >/dev/tty)
    
    [ -z "$choice" ] && return
    
    local selected_key=$(echo "${!OS_CATALOG[@]}" | tr ' ' '\n' | sed -n "${choice}p")
    IFS='|' read -r version date kernel dtb memory url <<< "${OS_CATALOG[$selected_key]}"
    
    local filename=$(basename "$url")
    local dest_file="${CACHE_DIR}/${filename}"
    
    if [ -f "$dest_file" ]; then
        if dialog --yesno "Image already downloaded. Re-download?" 8 40; then
            rm -f "$dest_file"
        else
            extract_and_prepare_image "$dest_file" "$selected_key"
            return
        fi
    fi
    
    # Get file size estimate
    local size_msg="Size: Unknown"
    if [[ "$filename" == *"jessie"* ]]; then
        size_msg="Size: ~300MB"
    elif [[ "$filename" == *"stretch"* ]] || [[ "$filename" == *"buster"* ]]; then
        size_msg="Size: ~400MB"
    elif [[ "$filename" == *"bullseye"* ]]; then
        size_msg="Size: ~500MB"
    fi
    
    # Simple download with activity indicator
    dialog --infobox "Starting download...\n\nFile: $filename\n$size_msg\n\nThis may take 5-10 minutes depending on your connection." 10 60
    
    # Download and show simple status
    clear
    echo "=================================================="
    echo " Downloading OS Image"
    echo "=================================================="
    echo ""
    echo "File: $filename"
    echo "$size_msg"
    echo ""
    echo "Download in progress. Please wait..."
    echo ""
    
    if command -v curl &> /dev/null; then
        echo "Using curl for download..."
        curl -L --progress-bar -o "$dest_file" "$url"
    else
        echo "Using wget for download..."
        wget --progress=bar:force -O "$dest_file" "$url"
    fi
    
    local download_status=$?
    
    # Return to dialog
    if [ $download_status -ne 0 ] || [ ! -f "$dest_file" ] || [ ! -s "$dest_file" ]; then
        dialog --msgbox "Download failed!\n\nPlease check:\n- Internet connection\n- Available disk space\n- URL validity" 12 50
        return 1
    fi
    
    dialog --msgbox "Download complete!\n\nFile saved to:\n$dest_file" 10 50
    extract_and_prepare_image "$dest_file" "$selected_key"
}

extract_and_prepare_image() {
    local archive=$1
    local os_key=$2
    
    IFS='|' read -r version date kernel dtb memory url <<< "${OS_CATALOG[$os_key]}"
    
    dialog --infobox "Extracting image..." 5 30
    
    local extracted_img=""
    
    if [[ "$archive" == *.xz ]]; then
        xz -dk "$archive"
        extracted_img="${archive%.xz}"
    elif [[ "$archive" == *.zip ]]; then
        unzip -o "$archive" -d "$TEMP_DIR/"
        extracted_img=$(find "$TEMP_DIR" -name "*.img" | head -1)
    fi
    
    if [ -z "$extracted_img" ] || [ ! -f "$extracted_img" ]; then
        dialog --msgbox "Failed to extract image!" 8 40
        return 1
    fi
    
    # Convert to qcow2 for better features
    local final_image="${IMAGES_DIR}/${os_key}.qcow2"
    
    # Simple progress indication without complex piping
    dialog --infobox "Converting to qcow2 format..." 5 40
    qemu-img convert -f raw -O qcow2 "$extracted_img" "$final_image"
    
    dialog --infobox "Resizing image to 8GB..." 5 40
    qemu-img resize "$final_image" 8G
    
    dialog --infobox "Creating initial snapshot..." 5 40
    qemu-img snapshot -c "fresh_install" "$final_image"
    
    # Download kernel and DTB
    download_kernel_files "$kernel" "$dtb"
    
register_image() {
    local os_key=$1
    local image_path=$2
    local kernel=$3
    local dtb=$4
    local memory=$5
    
    # Create or append to images registry
    echo "${os_key}|${image_path}|${kernel}|${dtb}|${memory}|$(date +%s)" >> "${CONFIGS_DIR}/images.db"
}
    
    dialog --msgbox "Image prepared successfully!\n\nLocation: $final_image" 10 50
    
    # Cleanup
    rm -f "$extracted_img"
}

download_kernel_files() {
    local kernel=$1
    local dtb=$2
    local version=$3
    
    local kernel_file="${KERNELS_DIR}/kernel-qemu-${kernel}-${version}"
    local dtb_file="${KERNELS_DIR}/${dtb}"
    
    if [ ! -f "$kernel_file" ]; then
        dialog --infobox "Downloading kernel..." 5 30
        wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-${kernel}-${version}" || \
        wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-${kernel}" || \
        wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34-jessie"
    fi
    
    if [ ! -f "$dtb_file" ]; then
        dialog --infobox "Downloading DTB..." 5 30
        wget -q -O "$dtb_file" "${KERNEL_REPO}/${dtb}" || \
        wget -q -O "$dtb_file" "${KERNEL_REPO}/versatile-pb.dtb"
    fi
}

# ==============================================================================
# INSTANCE MANAGEMENT
# ==============================================================================

create_instance() {
    local name
    name=$(dialog --inputbox "Instance name:" 8 40 "rpi-$(date +%Y%m%d)" 2>&1 >/dev/tty)
    [ -z "$name" ] && return
    
    # Select image
    local images=$(ls -1 "$IMAGES_DIR"/*.qcow2 2>/dev/null)
    if [ -z "$images" ]; then
        dialog --msgbox "No images available! Please download an OS image first." 8 50
        return
    fi
    
    local img_list=""
    local counter=1
    while IFS= read -r img; do
        local basename=$(basename "$img")
        img_list+="$counter \"$basename\" "
        ((counter++))
    done <<< "$images"
    
    local img_choice
    img_choice=$(eval dialog --title \"Select Image\" --menu \"Choose base image:\" 15 60 8 $img_list 2>&1 >/dev/tty)
    [ -z "$img_choice" ] && return
    
    local selected_image=$(echo "$images" | sed -n "${img_choice}p")
    
    # Configure instance
    local memory
    memory=$(dialog --inputbox "Memory (MB):" 8 40 "$DEFAULT_MEMORY" 2>&1 >/dev/tty)
    
    local ssh_port
    ssh_port=$(dialog --inputbox "SSH Port:" 8 40 "$DEFAULT_SSH_PORT" 2>&1 >/dev/tty)
    
    # Network mode selection
    local net_modes=""
    for mode in "${!NETWORK_PROFILES[@]}"; do
        net_modes+="\"$mode\" \"\" "
    done
    
    local net_choice
    net_choice=$(eval dialog --title \"Network Mode\" --menu \"Select network mode:\" 12 50 5 $net_modes 2>&1 >/dev/tty)
    
    # Create instance image (COW)
    local instance_img="${IMAGES_DIR}/${name}.qcow2"
    qemu-img create -f qcow2 -b "$selected_image" -F qcow2 "$instance_img" 2>&1 | \
        dialog --programbox "Creating instance..." 10 60
    
    # Register instance
    local instance_id=$(uuidgen | cut -d'-' -f1)
    echo "${instance_id}|${name}|${instance_img}|${memory}|${ssh_port}|${net_choice}|created|$(date +%s)" >> "$INSTANCES_DB"
    
    dialog --msgbox "Instance '$name' created successfully!\n\nID: $instance_id" 10 50
    
    # Offer to start immediately
    if dialog --yesno "Start instance now?" 8 30; then
        launch_instance "$instance_id"
    fi
}

list_instances() {
    local instances=""
    local counter=1
    
    while IFS='|' read -r id name image memory ssh_port net_mode status created; do
        [[ "$id" =~ ^# ]] && continue
        instances+="$counter \"$name [$status]\" "
        ((counter++))
    done < "$INSTANCES_DB"
    
    if [ -z "$instances" ]; then
        dialog --msgbox "No instances found!" 8 30
        return
    fi
    
    local choice
    choice=$(eval dialog --title \"Instances\" --menu \"Select instance:\" 15 60 8 $instances 2>&1 >/dev/tty)
    [ -z "$choice" ] && return
    
    manage_instance "$choice"
}

manage_instance() {
    local line_num=$1
    local instance_data=$(sed -n "$((line_num+1))p" "$INSTANCES_DB")
    IFS='|' read -r id name image memory ssh_port net_mode status created <<< "$instance_data"
    
    local action
    action=$(dialog --title "Instance: $name" --menu "Select action:" 15 50 8 \
        "1" "Start" \
        "2" "Stop" \
        "3" "Console (Serial)" \
        "4" "SSH Connect" \
        "5" "VNC Connect" \
        "6" "Snapshot" \
        "7" "Clone" \
        "8" "Delete" \
        "9" "Properties" \
        2>&1 >/dev/tty)
    
    case $action in
        1) launch_instance "$id" ;;
        2) stop_instance "$id" ;;
        3) connect_console "$id" ;;
        4) connect_ssh "$ssh_port" ;;
        5) connect_vnc "$id" ;;
        6) create_snapshot "$id" ;;
        7) clone_instance "$id" ;;
        8) delete_instance "$id" ;;
        9) show_properties "$id" ;;
    esac
}

# ==============================================================================
# QEMU LAUNCHER
# ==============================================================================

launch_instance() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id" "$INSTANCES_DB")
    
    if [ -z "$instance_data" ]; then
        dialog --msgbox "Instance not found!" 8 30
        return 1
    fi
    
    IFS='|' read -r id name image memory ssh_port net_mode status created <<< "$instance_data"
    
    # Check if already running
    if pgrep -f "$image" > /dev/null; then
        dialog --msgbox "Instance already running!" 8 30
        return
    fi
    
    # Find kernel and DTB
    local kernel=$(ls -1 "$KERNELS_DIR"/kernel-qemu-* | head -1)
    local dtb=$(ls -1 "$KERNELS_DIR"/*.dtb | head -1)
    
    if [ -z "$kernel" ] || [ -z "$dtb" ]; then
        dialog --msgbox "Kernel or DTB not found! Please download OS image first." 10 50
        return 1
    fi
    
    # Build network configuration - FIX the variable expansion
    local net_config
    if [ "$net_mode" = "NAT" ]; then
        net_config="user,id=net0,hostfwd=tcp::${ssh_port}-:22"
    elif [ "$net_mode" = "None" ]; then
        net_config="none"
    else
        net_config="user,id=net0,hostfwd=tcp::${ssh_port}-:22"  # Default to NAT
    fi
    
    # Build QEMU command
    local qemu_cmd="qemu-system-arm"
    qemu_cmd+=" -M versatilepb"
    qemu_cmd+=" -cpu arm1176"
    qemu_cmd+=" -m $memory"
    qemu_cmd+=" -kernel $kernel"
    qemu_cmd+=" -dtb $dtb"
    qemu_cmd+=" -append \"root=/dev/sda2 rootfstype=ext4 rw console=ttyAMA0\""
    qemu_cmd+=" -drive file=$image,format=qcow2,if=scsi"
    qemu_cmd+=" -netdev $net_config"
    qemu_cmd+=" -device rtl8139,netdev=net0"
    qemu_cmd+=" -serial mon:stdio"
    qemu_cmd+=" -monitor telnet::${DEFAULT_MONITOR_PORT},server,nowait"
    qemu_cmd+=" -vnc :1"
    #qemu_cmd+=" -daemonize"
    qemu_cmd+=" -pidfile ${TEMP_DIR}/${instance_id}.pid"
    
    # Launch in background with logging
    local log_file="${LOGS_DIR}/${name}-$(date +%Y%m%d-%H%M%S).log"
    
    dialog --infobox "Starting instance '$name'..." 5 40
    
    eval $qemu_cmd &> "$log_file" &
    local qemu_pid=$!
    
    sleep 3
    
    if kill -0 $qemu_pid 2>/dev/null; then
        # Update status
        sed -i "s/^${instance_id}|.*|created|/&running|/" "$INSTANCES_DB"
        
        dialog --msgbox "Instance started successfully!\n\nSSH: ssh -p $ssh_port pi@localhost\nVNC: vncviewer localhost:$DEFAULT_VNC_PORT\nMonitor: telnet localhost $DEFAULT_MONITOR_PORT" 12 60
    else
        dialog --msgbox "Failed to start instance!\nCheck logs: $log_file" 10 50
    fi
}

stop_instance() {
    local instance_id=$1
    local pid_file="${TEMP_DIR}/${instance_id}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -TERM "$pid" 2>/dev/null; then
            dialog --msgbox "Instance stopped." 8 30
            rm -f "$pid_file"
            sed -i "s/^${instance_id}|.*|running|/&stopped|/" "$INSTANCES_DB"
        else
            dialog --msgbox "Failed to stop instance!" 8 30
        fi
    else
        dialog --msgbox "Instance not running!" 8 30
    fi
}

connect_ssh() {
    local port=$1
    dialog --msgbox "Connecting to SSH on port $port...\n\nPress OK to continue" 10 50
    clear
    ssh -p "$port" -o StrictHostKeyChecking=no pi@localhost
    read -p "Press ENTER to return to menu..."
}

# ==============================================================================
# DIAGNOSTICS MODULE
# ==============================================================================

system_diagnostics() {
    local diag_info=""
    
    # Check QEMU version
    diag_info+="QEMU Version:\n"
    diag_info+="$(qemu-system-arm --version | head -1)\n\n"
    
    # Check KVM support
    diag_info+="KVM Support: "
    if [ -e /dev/kvm ]; then
        diag_info+="Available\n"
    else
        diag_info+="Not available\n"
    fi
    
    # Network interfaces
    diag_info+="\nNetwork Bridges:\n"
    diag_info+="$(ip link show type bridge 2>/dev/null || echo 'None')\n"
    
    # Running instances
    diag_info+="\nRunning Instances:\n"
    local running=$(pgrep -c qemu-system-arm || echo 0)
    diag_info+="Count: $running\n"
    
    # Disk usage
    diag_info+="\nDisk Usage:\n"
    diag_info+="Images: $(du -sh "$IMAGES_DIR" 2>/dev/null | awk '{print $1}')\n"
    diag_info+="Snapshots: $(du -sh "$SNAPSHOTS_DIR" 2>/dev/null | awk '{print $1}')\n"
    
    dialog --title "System Diagnostics" --msgbox "$diag_info" 20 60
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    # Initialize with error checking
    if ! init_workspace; then
        echo "Failed to initialize workspace"
        exit 1
    fi
    
    log_init
    
    if ! check_dialog; then
        echo "Dialog is required but not available"
        exit 1
    fi
    
    if ! check_requirements; then
        echo "Failed to check/install requirements"
        exit 1
    fi
    
    # Main loop
    while true; do
        choice=$(show_main_menu)
        
        case $choice in
            1) quick_start ;;
            2) create_instance ;;
            3) list_instances ;;
            4) download_os_image ;;
            5) kernel_management ;;
            6) network_configuration ;;
            7) advanced_settings ;;
            8) system_diagnostics ;;
            9) view_logs ;;
            0|"") break ;;
            *) dialog --msgbox "Invalid option!" 8 30 ;;
        esac
    done
    
    cleanup_and_exit
}

# ==============================================================================
# ADDITIONAL MODULES
# ==============================================================================

quick_start() {
    dialog --title "Quick Start" --infobox "Preparing quick start instance..." 5 50
    sleep 1
    
    # Check for available images
    local latest_image=$(ls -t "$IMAGES_DIR"/*.qcow2 2>/dev/null | head -1)
    
    if [ -z "$latest_image" ]; then
        dialog --msgbox "No images found!\n\nWill download default image..." 10 50
        
        # Auto-download jessie (smallest)
        download_default_image
        latest_image=$(ls -t "$IMAGES_DIR"/*.qcow2 2>/dev/null | head -1)
    fi
    
    if [ -z "$latest_image" ]; then
        dialog --msgbox "Failed to prepare image!" 8 40
        return
    fi
    
    # Create temporary instance
    local instance_name="quickstart-$(date +%H%M%S)"
    local instance_img="${TEMP_DIR}/${instance_name}.qcow2"
    
    # Create COW image
    qemu-img create -f qcow2 -b "$latest_image" -F qcow2 "$instance_img"
    
    # Find kernel and DTB
    local kernel=$(ls -1 "$KERNELS_DIR"/kernel-qemu-* 2>/dev/null | head -1)
    local dtb=$(ls -1 "$KERNELS_DIR"/*.dtb 2>/dev/null | head -1)
    
    if [ -z "$kernel" ]; then
        dialog --msgbox "Kernel not found! Image preparation may have failed." 10 50
        return
    fi
    
    # DTB is optional for some configurations
    local dtb_option=""
    if [ -n "$dtb" ] && [ -f "$dtb" ]; then
        dtb_option="-dtb $dtb"
    fi
    
    clear
    echo "=========================================="
    echo " Quick Start Instance"
    echo "=========================================="
    echo "Image: $(basename "$latest_image")"
    echo "Memory: ${DEFAULT_MEMORY}MB"
    echo "SSH Port: ${DEFAULT_SSH_PORT}"
    echo ""
    echo "Default credentials:"
    echo "Username: pi"
    echo "Password: raspberry"
    echo ""
    echo "To connect via SSH (after boot):"
    echo "ssh -p ${DEFAULT_SSH_PORT} pi@localhost"
    echo ""
    echo "IMPORTANT: Boot may take 2-3 minutes!"
    echo "The system will show a login prompt when ready."
    echo ""
    echo "To exit QEMU: Press Ctrl+A, then X"
    echo "=========================================="
    echo ""
    echo "Starting QEMU..."
    sleep 3
    
    # Launch QEMU interactively with proper settings
    qemu-system-arm \
        -M versatilepb \
        -cpu arm1176 \
        -m "${DEFAULT_MEMORY}" \
        -kernel "$kernel" \
        $dtb_option \
        -append "root=/dev/sda2 panic=1 rootfstype=ext4 rw console=ttyAMA0" \
        -drive "file=${instance_img},format=qcow2,if=scsi" \
        -netdev "user,id=net0,hostfwd=tcp::${DEFAULT_SSH_PORT}-:22" \
        -device "rtl8139,netdev=net0" \
        -serial stdio \
        -no-reboot
    
    local qemu_exit=$?
    
    # Cleanup
    rm -f "$instance_img"
    
    if [ $qemu_exit -ne 0 ]; then
        echo ""
        echo "QEMU exited with error code: $qemu_exit"
        echo "This might be normal if you used Ctrl+A X to exit."
    fi
    
    echo ""
    read -p "Press ENTER to return to menu..."
}

download_default_image() {
    local default_os="jessie_2017"
    IFS='|' read -r version date kernel dtb memory url <<< "${OS_CATALOG[$default_os]}"
    
    local filename=$(basename "$url")
    local dest_file="${CACHE_DIR}/${filename}"
    
    # Clean download without flickering
    clear
    echo "=================================================="
    echo " Downloading Default OS Image"
    echo "=================================================="
    echo ""
    echo "File: $filename"
    echo "Size: ~300MB"
    echo ""
    echo "This is a one-time download."
    echo "Please wait while downloading..."
    echo ""
    
    if command -v curl &> /dev/null; then
        curl -L --progress-bar -o "$dest_file" "$url"
    else
        wget --progress=bar:force -O "$dest_file" "$url"
    fi
    
    local download_status=$?
    
    # Verify download
    if [ $download_status -ne 0 ] || [ ! -f "$dest_file" ] || [ ! -s "$dest_file" ]; then
        dialog --msgbox "Download failed! Please check your internet connection." 8 50
        return 1
    fi
    
    echo ""
    echo "Download complete! Preparing image..."
    sleep 2
    
    extract_and_prepare_image "$dest_file" "$default_os"
}

kernel_management() {
    local choice
    choice=$(dialog --title "Kernel Management" --menu "Select action:" 15 50 6 \
        "1" "List installed kernels" \
        "2" "Download specific kernel" \
        "3" "Import custom kernel" \
        "4" "Build kernel from source" \
        "5" "Kernel compatibility matrix" \
        "6" "Back" \
        2>&1 >/dev/tty)
    
    case $choice in
        1) list_kernels ;;
        2) download_specific_kernel ;;
        3) import_custom_kernel ;;
        4) build_kernel_from_source ;;
        5) show_kernel_matrix ;;
        6) return ;;
    esac
}

list_kernels() {
    local kernel_list=""
    
    for kernel in "$KERNELS_DIR"/kernel-qemu-*; do
        if [ -f "$kernel" ]; then
            local basename=$(basename "$kernel")
            local size=$(du -h "$kernel" | cut -f1)
            kernel_list+="$basename ($size)\n"
        fi
    done
    
    if [ -z "$kernel_list" ]; then
        kernel_list="No kernels found!"
    fi
    
    dialog --title "Installed Kernels" --msgbox "$kernel_list" 15 60
}

network_configuration() {
    local choice
    choice=$(dialog --title "Network Configuration" --menu "Select action:" 15 50 7 \
        "1" "Setup NAT (Simple)" \
        "2" "Setup Bridge (Advanced)" \
        "3" "Setup TAP interface" \
        "4" "Configure port forwarding" \
        "5" "Network troubleshooting" \
        "6" "Test connectivity" \
        "7" "Back" \
        2>&1 >/dev/tty)
    
    case $choice in
        1) setup_nat_network ;;
        2) setup_network_bridge ;;
        3) configure_tap_network ;;
        4) configure_port_forwarding ;;
        5) network_troubleshooting ;;
        6) test_connectivity ;;
        7) return ;;
    esac
}

setup_nat_network() {
    dialog --title "NAT Network Setup" --msgbox \
        "NAT networking is the simplest option.\n\n\
Features:\n\
+ Easy setup\n\
+ Works out of the box\n\
+ Good for basic internet access\n\
- Limited to outbound connections\n\
- Port forwarding required for services\n\n\
This is already the default configuration." 16 60
}

configure_port_forwarding() {
    local ports
    ports=$(dialog --form "Port Forwarding Configuration" 15 60 5 \
        "SSH:"     1 1 "$DEFAULT_SSH_PORT"     1 15 10 0 \
        "HTTP:"    2 1 "8080"                  2 15 10 0 \
        "HTTPS:"   3 1 "8443"                  3 15 10 0 \
        "VNC:"     4 1 "$DEFAULT_VNC_PORT"     4 15 10 0 \
        "Custom:"  5 1 ""                      5 15 10 0 \
        2>&1 >/dev/tty)
    
    if [ -n "$ports" ]; then
        echo "PORT_FORWARDS=$ports" >> "$NETWORK_CONFIG"
        dialog --msgbox "Port forwarding configured!" 8 40
    fi
}

network_troubleshooting() {
    local diag=""
    
    # Check host networking
    diag+="=== Host Network Status ===\n\n"
    
    # Check internet connectivity
    if ping -c 1 8.8.8.8 &>/dev/null; then
        diag+="Internet: OK\n"
    else
        diag+="Internet: FAILED\n"
    fi
    
    # Check DNS
    if nslookup google.com &>/dev/null; then
        diag+="DNS: OK\n"
    else
        diag+="DNS: FAILED\n"
    fi
    
    # Check bridges
    local bridges=$(ip link show type bridge 2>/dev/null | grep -c "state UP")
    diag+="Active bridges: $bridges\n"
    
    # Check iptables
    local nat_rules=$(${SUDO_CMD} iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c MASQUERADE || echo "0")
    diag+="NAT rules: $nat_rules\n"
    
    # Check IP forwarding
    local ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
    diag+="IP forwarding: $([ "$ip_forward" = "1" ] && echo "Enabled" || echo "Disabled")\n"
    
    diag+="\n=== Common Fixes ===\n\n"
    diag+="1. Enable IP forwarding:\n"
    diag+="   sudo sysctl -w net.ipv4.ip_forward=1\n\n"
    diag+="2. Fix DNS in guest:\n"
    diag+="   echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf\n\n"
    diag+="3. Restart network in guest:\n"
    diag+="   sudo systemctl restart networking\n"
    
    dialog --title "Network Diagnostics" --msgbox "$diag" 20 70
}

test_connectivity() {
    local instance_port
    instance_port=$(dialog --inputbox "Enter SSH port of running instance:" 8 50 "$DEFAULT_SSH_PORT" 2>&1 >/dev/tty)
    
    [ -z "$instance_port" ] && return
    
    dialog --infobox "Testing connectivity..." 5 40
    
    local result=""
    
    # Test TCP connection
    if nc -zv localhost "$instance_port" 2>&1 | grep -q succeeded; then
        result+="TCP Port $instance_port: OPEN\n"
        
        # Try SSH connection
        if ssh -p "$instance_port" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
           pi@localhost "echo 'SSH connection successful'" 2>/dev/null; then
            result+="SSH Connection: SUCCESS\n"
            
            # Test internet from guest
            local inet_test=$(ssh -p "$instance_port" -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=no pi@localhost \
                "ping -c 1 8.8.8.8 &>/dev/null && echo 'OK' || echo 'FAILED'" 2>/dev/null)
            result+="Guest Internet: $inet_test\n"
        else
            result+="SSH Connection: FAILED (check credentials)\n"
        fi
    else
        result+="TCP Port $instance_port: CLOSED\n"
    fi
    
    dialog --title "Connectivity Test Results" --msgbox "$result" 12 50
}

advanced_settings() {
    local choice
    choice=$(dialog --title "Advanced Settings" --menu "Select category:" 15 50 8 \
        "1" "Performance tuning" \
        "2" "Storage options" \
        "3" "Display settings" \
        "4" "USB passthrough" \
        "5" "Audio configuration" \
        "6" "CPU/Memory hotplug" \
        "7" "Export/Import instances" \
        "8" "Back" \
        2>&1 >/dev/tty)
    
    case $choice in
        1) performance_tuning ;;
        2) storage_options ;;
        3) display_settings ;;
        4) usb_passthrough ;;
        5) audio_configuration ;;
        6) cpu_memory_hotplug ;;
        7) export_import_instances ;;
        8) return ;;
    esac
}

performance_tuning() {
    local current_settings=""
    current_settings+="Current Performance Settings:\n\n"
    current_settings+="CPU Cores: ${DEFAULT_CORES}\n"
    current_settings+="Memory: ${DEFAULT_MEMORY}MB\n"
    current_settings+="KVM: $([ -e /dev/kvm ] && echo "Available" || echo "Not available")\n"
    current_settings+="Balloon driver: Enabled\n"
    
    dialog --title "Performance Tuning" --msgbox "$current_settings" 12 50
    
    if dialog --yesno "Modify settings?" 8 30; then
        local new_cores
        new_cores=$(dialog --inputbox "CPU Cores (1-4):" 8 40 "$DEFAULT_CORES" 2>&1 >/dev/tty)
        
        local new_memory
        new_memory=$(dialog --inputbox "Memory (MB):" 8 40 "$DEFAULT_MEMORY" 2>&1 >/dev/tty)
        
        if [ -n "$new_cores" ] && [ -n "$new_memory" ]; then
            sed -i "s/DEFAULT_CORES=.*/DEFAULT_CORES=$new_cores/" "$CONFIG_FILE"
            sed -i "s/DEFAULT_MEMORY=.*/DEFAULT_MEMORY=$new_memory/" "$CONFIG_FILE"
            dialog --msgbox "Settings updated!" 8 30
        fi
    fi
}

storage_options() {
    local choice
    choice=$(dialog --title "Storage Options" --menu "Select action:" 12 50 5 \
        "1" "Create additional disk" \
        "2" "Attach USB storage" \
        "3" "Configure NFS share" \
        "4" "Manage snapshots" \
        "5" "Back" \
        2>&1 >/dev/tty)
    
    case $choice in
        1) create_additional_disk ;;
        2) attach_usb_storage ;;
        3) configure_nfs_share ;;
        4) manage_snapshots ;;
        5) return ;;
    esac
}

create_additional_disk() {
    local size
    size=$(dialog --inputbox "Disk size (GB):" 8 40 "4" 2>&1 >/dev/tty)
    [ -z "$size" ] && return
    
    local name
    name=$(dialog --inputbox "Disk name:" 8 40 "data-$(date +%Y%m%d)" 2>&1 >/dev/tty)
    [ -z "$name" ] && return
    
    local disk_file="${IMAGES_DIR}/${name}.qcow2"
    
    dialog --infobox "Creating ${size}GB disk..." 5 40
    qemu-img create -f qcow2 "$disk_file" "${size}G"
    
    dialog --msgbox "Disk created!\n\nPath: $disk_file\n\nAdd to instance with:\n-drive file=$disk_file,format=qcow2,if=scsi" 12 60
}

manage_snapshots() {
    local image_list=$(ls -1 "$IMAGES_DIR"/*.qcow2 2>/dev/null)
    
    if [ -z "$image_list" ]; then
        dialog --msgbox "No images found!" 8 30
        return
    fi
    
    local img_menu=""
    local counter=1
    while IFS= read -r img; do
        local basename=$(basename "$img")
        img_menu+="$counter \"$basename\" "
        ((counter++))
    done <<< "$image_list"
    
    local img_choice
    img_choice=$(eval dialog --title \"Select Image\" --menu \"Choose image:\" 15 60 8 $img_menu 2>&1 >/dev/tty)
    [ -z "$img_choice" ] && return
    
    local selected_image=$(echo "$image_list" | sed -n "${img_choice}p")
    
    local action
    action=$(dialog --title "Snapshot Management" --menu "Select action:" 12 50 4 \
        "1" "List snapshots" \
        "2" "Create snapshot" \
        "3" "Restore snapshot" \
        "4" "Delete snapshot" \
        2>&1 >/dev/tty)
    
    case $action in
        1)
            local snapshots=$(qemu-img snapshot -l "$selected_image" 2>&1)
            dialog --title "Snapshots" --msgbox "$snapshots" 15 70
            ;;
        2)
            local snap_name
            snap_name=$(dialog --inputbox "Snapshot name:" 8 40 "snapshot-$(date +%Y%m%d-%H%M%S)" 2>&1 >/dev/tty)
            if [ -n "$snap_name" ]; then
                qemu-img snapshot -c "$snap_name" "$selected_image"
                dialog --msgbox "Snapshot created!" 8 30
            fi
            ;;
        3)
            local snap_name
            snap_name=$(dialog --inputbox "Snapshot name to restore:" 8 40 2>&1 >/dev/tty)
            if [ -n "$snap_name" ]; then
                qemu-img snapshot -a "$snap_name" "$selected_image"
                dialog --msgbox "Snapshot restored!" 8 30
            fi
            ;;
        4)
            local snap_name
            snap_name=$(dialog --inputbox "Snapshot name to delete:" 8 40 2>&1 >/dev/tty)
            if [ -n "$snap_name" ]; then
                qemu-img snapshot -d "$snap_name" "$selected_image"
                dialog --msgbox "Snapshot deleted!" 8 30
            fi
            ;;
    esac
}

view_logs() {
    local log_files=$(ls -t "$LOGS_DIR"/*.log 2>/dev/null | head -20)
    
    if [ -z "$log_files" ]; then
        dialog --msgbox "No logs found!" 8 30
        return
    fi
    
    local log_menu=""
    local counter=1
    while IFS= read -r log; do
        local basename=$(basename "$log")
        local size=$(du -h "$log" | cut -f1)
        log_menu+="$counter \"$basename ($size)\" "
        ((counter++))
    done <<< "$log_files"
    
    local log_choice
    log_choice=$(eval dialog --title \"Select Log\" --menu \"Choose log file:\" 15 70 10 $log_menu 2>&1 >/dev/tty)
    [ -z "$log_choice" ] && return
    
    local selected_log=$(echo "$log_files" | sed -n "${log_choice}p")
    
    dialog --title "Log: $(basename "$selected_log")" --textbox "$selected_log" 20 80
}

export_import_instances() {
    local choice
    choice=$(dialog --title "Export/Import" --menu "Select action:" 10 50 3 \
        "1" "Export instance" \
        "2" "Import instance" \
        "3" "Back" \
        2>&1 >/dev/tty)
    
    case $choice in
        1) export_instance ;;
        2) import_instance ;;
        3) return ;;
    esac
}

export_instance() {
    local instances=""
    local counter=1
    
    while IFS='|' read -r id name image memory ssh_port net_mode status created; do
        [[ "$id" =~ ^# ]] && continue
        instances+="$counter \"$name\" "
        ((counter++))
    done < "$INSTANCES_DB"
    
    if [ -z "$instances" ]; then
        dialog --msgbox "No instances found!" 8 30
        return
    fi
    
    local choice
    choice=$(eval dialog --title \"Select Instance\" --menu \"Choose instance to export:\" 15 60 8 $instances 2>&1 >/dev/tty)
    [ -z "$choice" ] && return
    
    local instance_data=$(sed -n "$((choice+1))p" "$INSTANCES_DB")
    IFS='|' read -r id name image memory ssh_port net_mode status created <<< "$instance_data"
    
    local export_dir
    export_dir=$(dialog --inputbox "Export directory:" 8 50 "/tmp/qemu-export-$name" 2>&1 >/dev/tty)
    [ -z "$export_dir" ] && return
    
    mkdir -p "$export_dir"
    
    (
        echo "10" ; echo "# Copying image..."
        cp "$image" "$export_dir/"
        
        echo "40" ; echo "# Copying kernel..."
        cp "$KERNELS_DIR"/* "$export_dir/" 2>/dev/null
        
        echo "60" ; echo "# Creating metadata..."
        cat > "$export_dir/instance.json" <<EOF
{
    "name": "$name",
    "memory": "$memory",
    "ssh_port": "$ssh_port",
    "network_mode": "$net_mode",
    "created": "$created",
    "export_date": "$(date -Iseconds)"
}
EOF
        
        echo "80" ; echo "# Compressing..."
        tar czf "${export_dir}.tar.gz" -C "$(dirname "$export_dir")" "$(basename "$export_dir")"
        
        echo "100" ; echo "# Complete!"
    ) | show_progress "Exporting Instance" "Exporting $name..."
    
    dialog --msgbox "Instance exported to:\n${export_dir}.tar.gz" 10 50
}

cleanup_and_exit() {
    dialog --infobox "Cleaning up..." 5 30
    
    # Kill any remaining QEMU processes started by this script
    for pid_file in "$TEMP_DIR"/*.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            kill -TERM "$pid" 2>/dev/null || true
            rm -f "$pid_file"
        fi
    done
    
    # Clear dialog
    clear
    
    log INFO "QEMU RPi Manager terminated"
    echo "Thank you for using QEMU Raspberry Pi Manager!"
    exit 0
}

# ==============================================================================
# ERROR HANDLING
# ==============================================================================

handle_error() {
    local exit_code=$?
    local line_num=${1:-0}
    
    # Don't handle normal exits
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 130 ]; then
        return
    fi
    
    log ERROR "Error occurred at line $line_num with exit code $exit_code"
    
    # Only show dialog if it's available
    if command -v dialog &> /dev/null; then
        dialog --msgbox "An error occurred!\n\nLine: $line_num\nCode: $exit_code\n\nCheck logs for details." 10 50
    else
        echo "Error at line $line_num (exit code: $exit_code)"
    fi
}

trap 'handle_error $LINENO' ERR
trap 'cleanup_and_exit' EXIT INT TERM

# ==============================================================================
# ENTRY POINT
# ==============================================================================

# Initialize SUDO_CMD variable
SUDO_CMD=""
if [ "$EUID" -ne 0 ]; then
    SUDO_CMD="sudo"
fi

# Parse command line arguments FIRST before any other operations
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "QEMU Raspberry Pi Manager v2.0"
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -h, --help      Show this help"
            echo "  -v, --verbose   Enable verbose output"
            echo "  -d, --debug     Enable debug mode"
            echo "  --no-dialog     Use text mode instead of dialog"
            exit 0
            ;;
        -v|--verbose)
            export VERBOSE=1
            shift
            ;;
        -d|--debug)
            export DEBUG=1
            export VERBOSE=1
            shift
            ;;
        --no-dialog)
            export NO_DIALOG=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

# Now show banner if not root and sudo is needed
if [ "$EUID" -ne 0 ]; then
    # Test sudo access
    if ! sudo -n true 2>/dev/null; then
        echo "=================================================="
        echo " QEMU Raspberry Pi Manager v2.0"
        echo "=================================================="
        echo ""
        echo "This script needs sudo privileges for:"
        echo "  - Installing packages (if needed)"
        echo "  - Network configuration"
        echo "  - Bridge setup"
        echo ""
        echo "You will be prompted for your password when needed."
        echo ""
        echo "Press Enter to continue or Ctrl+C to exit..."
        read -r
    fi
fi

# Start main program
main "$@"