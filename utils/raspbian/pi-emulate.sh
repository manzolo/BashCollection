#!/bin/bash

set -e

# ==============================================================================
# GLOBAL CONFIGURATION
# ==============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly WORK_DIR="${HOME}/.qemu-rpi-manager"
readonly IMAGES_DIR="${WORK_DIR}/images"
readonly KERNELS_DIR="${WORK_DIR}/kernels"
readonly SNAPSHOTS_DIR="${WORK_DIR}/snapshots"
readonly CONFIGS_DIR="${WORK_DIR}/configs"
readonly LOGS_DIR="${WORK_DIR}/logs"
readonly TEMP_DIR="${WORK_DIR}/temp"
readonly CACHE_DIR="${WORK_DIR}/cache"
readonly MOUNT_DIR="${WORK_DIR}/mount"

# Configuration files
readonly CONFIG_FILE="${CONFIGS_DIR}/qemu-rpi.conf"
readonly INSTANCES_DB="${CONFIGS_DIR}/instances.db"

# Logging
readonly LOG_FILE="${LOGS_DIR}/qemu-rpi-$(date +%Y%m%d-%H%M%S).log"

# QEMU defaults
readonly DEFAULT_MEMORY="256"
readonly DEFAULT_SSH_PORT="5022"

# OS Catalog
declare -A OS_CATALOG=(
    ["jessie_2017_full"]="jessie|2017-04-10|4.4.34|full|http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/2017-04-10-raspbian-jessie.zip"
    ["jessie_2017_lite"]="jessie|2017-04-10|4.4.34|lite|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2017-04-10/2017-04-10-raspbian-jessie-lite.zip"
    ["stretch_2018_full"]="stretch|2018-11-13|4.14.79|full|http://downloads.raspberrypi.org/raspbian/images/raspbian-2018-11-15/2018-11-13-raspbian-stretch.zip"
    ["stretch_2018_lite"]="stretch|2018-11-13|4.14.79|lite|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2018-11-15/2018-11-13-raspbian-stretch-lite.zip"
    ["buster_2020_full"]="buster|2020-02-13|4.19.118|full|http://downloads.raspberrypi.org/raspbian/images/raspbian-2020-02-14/2020-02-13-raspbian-buster.zip"
    ["buster_2020_lite"]="buster|2020-02-13|4.19.118|lite|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2020-02-14/2020-02-13-raspbian-buster-lite.zip"
    ["bullseye_2022_full"]="bullseye|2022-04-04|5.10.103|full|https://downloads.raspberrypi.org/raspios_armhf/images/raspios_armhf-2022-04-07/2022-04-04-raspios-bullseye-armhf.img.xz"
    ["bullseye_2022_lite"]="bullseye|2022-04-04|5.10.103|lite|https://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2022-04-07/2022-04-04-raspios-bullseye-armhf-lite.img.xz"
)

# Kernel repository
readonly KERNEL_REPO="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master"

# ==============================================================================
# LOGGING SYSTEM
# ==============================================================================

log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== QEMU RPi Manager Started: $(date) ===" >> "$LOG_FILE"
}

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    
    case $level in
        ERROR) echo -e "\033[0;31m[ERROR]\033[0m $message" >&2 ;;
        WARNING) echo -e "\033[1;33m[WARNING]\033[0m $message" >&2 ;;
        INFO) [ "${VERBOSE}" = "1" ] && echo -e "\033[0;32m[INFO]\033[0m $message" ;;
        DEBUG) [ "${DEBUG}" = "1" ] && echo -e "\033[0;34m[DEBUG]\033[0m $message" ;;
    esac
    return 0
}

# ==============================================================================
# DIALOG UI FUNCTIONS
# ==============================================================================

check_dialog() {
    if ! command -v dialog &> /dev/null; then
        echo "Installing dialog..."
        ${SUDO_CMD} apt-get update && ${SUDO_CMD} apt-get install -y dialog
    fi
    return 0
}

show_main_menu() {
    dialog --clear --backtitle "QEMU Raspberry Pi Manager v2.0.3" \
        --title "[ Main Menu ]" \
        --menu "Select an option:" 18 65 11 \
        "1" "Quick Start (Jessie 2017)" \
        "2" "Create New Instance" \
        "3" "Manage Instances" \
        "4" "Download OS Images" \
        "5" "System Diagnostics" \
        "6" "View Logs" \
        "0" "Exit" \
        2>&1 >/dev/tty
}

# ==============================================================================
# SYSTEM INITIALIZATION
# ==============================================================================

init_workspace() {
    local dirs=("$WORK_DIR" "$IMAGES_DIR" "$KERNELS_DIR" "$SNAPSHOTS_DIR" 
                "$CONFIGS_DIR" "$LOGS_DIR" "$TEMP_DIR" "$CACHE_DIR" "$MOUNT_DIR")
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" || {
            log ERROR "Failed to create directory: $dir"
            return 1
        }
    done
    
    if [ ! -f "$INSTANCES_DB" ]; then
        cat > "$INSTANCES_DB" <<EOF
# Instance Database
# Format: ID|Name|Image|Kernel|Memory|Status|Created|LastRun
EOF
    fi
    
    return 0
}

check_requirements() {
    local missing=()
    local required_cmds=(qemu-system-arm qemu-img wget unzip xz fdisk dialog)
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Installing missing dependencies: ${missing[*]}"
        install_dependencies "${missing[@]}"
    fi
    
    return 0
}

install_dependencies() {
    local deps=("$@")
    local apt_packages=""
    
    for dep in "${deps[@]}"; do
        case $dep in
            qemu-system-arm) apt_packages+=" qemu-system qemu-utils" ;;
            xz) apt_packages+=" xz-utils" ;;
            *) apt_packages+=" $dep" ;;
        esac
    done
    
    echo "Installing: $apt_packages"
    ${SUDO_CMD} apt-get update
    ${SUDO_CMD} apt-get install -y $apt_packages
}

# ==============================================================================
# IMAGE MANAGEMENT
# ==============================================================================

download_os_image() {
    local os_list=""
    local counter=1
    
    for key in "${!OS_CATALOG[@]}"; do
        IFS='|' read -r version date kernel type url <<< "${OS_CATALOG[$key]}"
        os_list+="$counter \"$key - Raspbian $version $type ($date)\" "
        ((counter++))
    done
    
    local choice
    choice=$(eval dialog --title \"Download OS Image\" --menu \"Select OS version:\" 20 80 12 $os_list 2>&1 >/dev/tty)
    
    [ -z "$choice" ] && return
    
    local selected_key=$(echo "${!OS_CATALOG[@]}" | tr ' ' '\n' | sed -n "${choice}p")
    IFS='|' read -r version date kernel type url <<< "${OS_CATALOG[$selected_key]}"
    
    download_and_prepare_image "$selected_key" "$url" "$kernel" "$version"
}

download_and_prepare_image() {
    local os_key=$1
    local url=$2
    local kernel_version=$3
    local os_version=$4
    
    local filename=$(basename "$url")
    local dest_file="${CACHE_DIR}/${filename}"
    
    if [ -f "$dest_file" ]; then
        if dialog --yesno "Image already downloaded. Re-download?" 8 40; then
            rm -f "$dest_file"
        else
            extract_and_prepare_image "$dest_file" "$os_key" "$kernel_version" "$os_version"
            return
        fi
    fi
    
    clear
    echo "=========================================="
    echo " Downloading OS Image"
    echo "=========================================="
    echo "File: $filename"
    echo "This may take several minutes..."
    echo ""
    
    if command -v curl &> /dev/null; then
        curl -L --progress-bar -o "$dest_file" "$url"
    else
        wget --progress=bar:force -O "$dest_file" "$url"
    fi
    
    if [ $? -ne 0 ] || [ ! -f "$dest_file" ] || [ ! -s "$dest_file" ]; then
        dialog --msgbox "Download failed! Check your internet connection." 8 50
        return 1
    fi
    
    extract_and_prepare_image "$dest_file" "$os_key" "$kernel_version" "$os_version"
}

extract_and_prepare_image() {
    local archive=$1
    local os_key=$2
    local kernel_version=$3
    local os_version=$4
    
    echo "Extracting image..."
    
    local extracted_img=""
    
    if [[ "$archive" == *.xz ]]; then
        echo "Extracting XZ archive..."
        xz -dk "$archive"
        extracted_img="${archive%.xz}"
    elif [[ "$archive" == *.zip ]]; then
        echo "Extracting ZIP archive..."
        unzip -o "$archive" -d "$TEMP_DIR/"
        extracted_img=$(find "$TEMP_DIR" -name "*.img" | head -1)
    fi
    
    if [ -z "$extracted_img" ] || [ ! -f "$extracted_img" ]; then
        dialog --msgbox "Failed to extract image!" 8 40
        return 1
    fi
    
    local final_image="${IMAGES_DIR}/${os_key}.img"
    
    echo "Preparing final image..."
    cp "$extracted_img" "$final_image"
    
    download_kernel "$kernel_version" "$os_version"
    
    echo "${os_key}|${final_image}|kernel-qemu-${kernel_version}-${os_version}|$(date +%s)" >> "${CONFIGS_DIR}/images.db"
    
    echo "Image prepared successfully: $final_image"
    sleep 2
    
    rm -f "$extracted_img"
    [ -d "$TEMP_DIR" ] && find "$TEMP_DIR" -name "*.img" -delete
}

download_kernel() {
    local kernel_version=$1
    local os_version=$2
    
    local kernel_file="${KERNELS_DIR}/kernel-qemu-${kernel_version}-${os_version}"
    
    if [ ! -f "$kernel_file" ]; then
        echo "Downloading kernel..."
        
        wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-${kernel_version}-${os_version}" || \
        wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-${kernel_version}" || \
        wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34-jessie"
        
        if [ ! -f "$kernel_file" ] || [ ! -s "$kernel_file" ]; then
            echo "Failed to download kernel!"
            return 1
        fi
    fi
    
    echo "Kernel ready: $kernel_file"
}

# ==============================================================================
# MOUNT LOGIC
# ==============================================================================

mount_image() {
    local img_file=$1
    
    log INFO "Mounting image: $img_file"
    
    START_OFFSET=$(fdisk -l "$img_file" | grep "${img_file}2" | awk '{print $2}')
    
    if [ -z "$START_OFFSET" ]; then
        log ERROR "Could not find partition 2 in image"
        return 1
    fi
    
    OFFSET=$((START_OFFSET * 512))
    
    log DEBUG "Mount offset: $OFFSET"
    
    ${SUDO_CMD} umount "$MOUNT_DIR" 2>/dev/null || true
    sleep 2
    
    ${SUDO_CMD} mount -v -o offset=$OFFSET -t ext4 "$img_file" "$MOUNT_DIR"
    
    if [ $? -eq 0 ]; then
        log INFO "Image mounted successfully at $MOUNT_DIR"
        return 0
    else
        log ERROR "Failed to mount image"
        return 1
    fi
}

unmount_image() {
    log INFO "Unmounting image"
    ${SUDO_CMD} umount "$MOUNT_DIR" 2>/dev/null || true
}

# ==============================================================================
# INSTANCE MANAGEMENT
# ==============================================================================

create_instance() {
    local name
    name=$(dialog --inputbox "Instance name:" 8 40 "rpi-$(date +%Y%m%d)" 2>&1 >/dev/tty)
    [ -z "$name" ] && return
    
    local images=$(ls -1 "$IMAGES_DIR"/*.img 2>/dev/null)
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
    
    local memory
    memory=$(dialog --inputbox "Memory (MB):" 8 40 "$DEFAULT_MEMORY" 2>&1 >/dev/tty)
    [ -z "$memory" ] && memory="$DEFAULT_MEMORY"
    
    local ssh_port
    ssh_port=$(dialog --inputbox "SSH Port:" 8 40 "$DEFAULT_SSH_PORT" 2>&1 >/dev/tty)
    [ -z "$ssh_port" ] && ssh_port="$DEFAULT_SSH_PORT"
    
    local instance_img="${IMAGES_DIR}/${name}.img"
    echo "Creating instance image..."
    cp "$selected_image" "$instance_img"
    
    local kernel_name=$(grep "$(basename "$selected_image" .img)" "${CONFIGS_DIR}/images.db" | cut -d'|' -f3)
    
    local instance_id=$(date +%s)
    echo "${instance_id}|${name}|${instance_img}|${kernel_name}|${memory}|${ssh_port}|created|$(date +%s)" >> "$INSTANCES_DB"
    
    dialog --msgbox "Instance '$name' created successfully!\n\nID: $instance_id" 10 50
    
    if dialog --yesno "Start instance now?" 8 30; then
        launch_instance "$instance_id"
    fi
}

list_instances() {
    local instances=""
    local counter=1
    
    while IFS='|' read -r id name image kernel memory ssh_port status created; do
        [[ "$id" =~ ^# ]] && continue
        instances+="$counter \"$name [$status] (Port: $ssh_port)\" "
        ((counter++))
    done < "$INSTANCES_DB"
    
    if [ -z "$instances" ]; then
        dialog --msgbox "No instances found!" 8 30
        return
    fi
    
    local choice
    choice=$(eval dialog --title \"Instances\" --menu \"Select instance:\" 15 70 8 $instances 2>&1 >/dev/tty)
    [ -z "$choice" ] && return
    
    manage_instance "$choice"
}

manage_instance() {
    local line_num=$1
    local instance_data=$(sed -n "$((line_num+1))p" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel memory ssh_port status created <<< "$instance_data"
    
    local action
    action=$(dialog --title "Instance: $name" --menu "Select action:" 15 50 6 \
        "1" "Start" \
        "2" "Stop" \
        "3" "SSH Connect" \
        "4" "Clone" \
        "5" "Delete" \
        "6" "Properties" \
        2>&1 >/dev/tty)
    
    case $action in
        1) launch_instance "$id" ;;
        2) stop_instance "$id" ;;
        3) connect_ssh "$ssh_port" ;;
        4) clone_instance "$id" ;;
        5) delete_instance "$id" ;;
        6) show_properties "$id" ;;
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
    
    IFS='|' read -r id name image kernel_name memory ssh_port status created <<< "$instance_data"
    
    if pgrep -f "$image" > /dev/null; then
        dialog --msgbox "Instance already running!" 8 30
        return
    fi
    
    local kernel_file="${KERNELS_DIR}/${kernel_name}"
    if [ ! -f "$kernel_file" ]; then
        kernel_file=$(ls -1 "$KERNELS_DIR"/kernel-qemu-* | head -1)
    fi
    
    if [ -z "$kernel_file" ] || [ ! -f "$kernel_file" ]; then
        dialog --msgbox "Kernel not found!" 8 30
        return 1
    fi
    
    if ! mount_image "$image"; then
        dialog --msgbox "Failed to mount image!" 8 30
        return 1
    fi
    
    clear
    echo "=========================================="
    echo " Starting Instance: $name"
    echo "=========================================="
    echo "Image: $(basename "$image")"
    echo "Kernel: $(basename "$kernel_file")"
    echo "Memory: ${memory}MB"
    echo "SSH Port: ${ssh_port}"
    echo ""
    echo "IMPORTANT: Boot may take 2-3 minutes!"
    echo "Default login: pi / raspberry"
    echo ""
    echo "To connect via SSH (after boot):"
    echo "ssh -p ${ssh_port} pi@localhost"
    echo ""
    echo "To exit QEMU: Press Ctrl+A, then X"
    echo "=========================================="
    echo ""
    echo "Starting QEMU..."
    sleep 3
    
    qemu-system-arm \
        -kernel "$kernel_file" \
        -cpu arm1176 \
        -m "$memory" \
        -M versatilepb \
        -serial stdio \
        -append "root=/dev/sda2 rootfstype=ext4 rw" \
        -hda "$image" \
        -nic user,hostfwd=tcp::"${ssh_port}"-:22 \
        -no-reboot
    
    local qemu_exit=$?
    
    unmount_image
    
    if [ $qemu_exit -ne 0 ]; then
        echo ""
        echo "QEMU exited with code: $qemu_exit"
    fi
    
    echo ""
    read -p "Press ENTER to return to menu..."
}

stop_instance() {
    local instance_id=$1
    
    local qemu_pids=$(pgrep -f "qemu-system-arm.*$(basename "$(grep "^$instance_id" "$INSTANCES_DB" | cut -d'|' -f3)")" || true)
    
    if [ -n "$qemu_pids" ]; then
        echo "$qemu_pids" | xargs kill -TERM 2>/dev/null || true
        dialog --msgbox "Instance stopped." 8 30
        unmount_image
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

clone_instance() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel_name memory ssh_port status created <<< "$instance_data"
    
    local new_name
    new_name=$(dialog --inputbox "Clone name:" 8 40 "${name}-clone" 2>&1 >/dev/tty)
    [ -z "$new_name" ] && return
    
    local new_image="${IMAGES_DIR}/${new_name}.img"
    echo "Cloning instance..."
    cp "$image" "$new_image"
    
    local new_id=$(date +%s)
    echo "${new_id}|${new_name}|${new_image}|${kernel_name}|${memory}|$((ssh_port + 1))|created|$(date +%s)" >> "$INSTANCES_DB"
    
    dialog --msgbox "Instance cloned successfully!" 8 40
}

delete_instance() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel_name memory ssh_port status created <<< "$instance_data"
    
    if dialog --yesno "Delete instance '$name'?\n\nThis will remove the image file!" 10 50; then
        rm -f "$image"
        sed -i "/^$instance_id/d" "$INSTANCES_DB"
        dialog --msgbox "Instance deleted!" 8 30
    fi
}

show_properties() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel_name memory ssh_port status created <<< "$instance_data"
    
    local props=""
    props+="Instance Properties:\n\n"
    props+="Name: $name\n"
    props+="ID: $id\n"
    props+="Image: $(basename "$image")\n"
    props+="Kernel: $kernel_name\n"
    props+="Memory: ${memory}MB\n"
    props+="SSH Port: $ssh_port\n"
    props+="Status: $status\n"
    props+="Created: $(date -d "@$created" 2>/dev/null || echo "$created")\n"
    
    if [ -f "$image" ]; then
        local size=$(du -h "$image" | cut -f1)
        props+="Image Size: $size\n"
    fi
    
    dialog --title "Properties" --msgbox "$props" 15 50
}

# ==============================================================================
# QUICK START
# ==============================================================================

quick_start() {
    dialog --title "Quick Start" --infobox "Preparing quick start..." 5 40
    
    local jessie_image="${IMAGES_DIR}/jessie_2017_full.img"
    local jessie_kernel="${KERNELS_DIR}/kernel-qemu-4.4.34-jessie"
    
    if [ ! -f "$jessie_image" ]; then
        dialog --msgbox "Jessie image not found. Downloading..." 8 50
        download_jessie_default
    fi
    
    if [ ! -f "$jessie_image" ]; then
        dialog --msgbox "Failed to prepare Jessie image!" 8 40
        return
    fi
    
    if [ ! -f "$jessie_kernel" ]; then
        dialog --msgbox "Kernel not found!" 8 30
        return
    fi
    
    if ! mount_image "$jessie_image"; then
        dialog --msgbox "Failed to mount image!" 8 30
        return
    fi
    
    clear
    echo "=========================================="
    echo " Quick Start - Raspbian Jessie 2017"
    echo "=========================================="
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
    echo "To exit QEMU: Press Ctrl+A, then X"
    echo "=========================================="
    echo ""
    echo "Starting QEMU..."
    sleep 3
    
    qemu-system-arm \
        -kernel "$jessie_kernel" \
        -cpu arm1176 \
        -m "$DEFAULT_MEMORY" \
        -M versatilepb \
        -serial stdio \
        -append "root=/dev/sda2 rootfstype=ext4 rw" \
        -hda "$jessie_image" \
        -nic user,hostfwd=tcp::"${DEFAULT_SSH_PORT}"-:22 \
        -no-reboot
    
    local qemu_exit=$?
    
    unmount_image
    
    if [ $qemu_exit -ne 0 ]; then
        echo ""
        echo "QEMU exited with code: $qemu_exit"
    fi
    
    echo ""
    read -p "Press ENTER to return to menu..."
}

download_jessie_default() {
    local url="http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/2017-04-10-raspbian-jessie.zip"
    download_and_prepare_image "jessie_2017_full" "$url" "4.4.34" "jessie"
}

# ==============================================================================
# UTILITIES
# ==============================================================================

system_diagnostics() {
    local diag_info=""
    
    diag_info+="QEMU Version:\n$(qemu-system-arm --version | head -1)\n\n"
    diag_info+="Running Instances: $(pgrep -c qemu-system-arm || echo 0)\n\n"
    diag_info+="Disk Usage:\n"
    diag_info+="Images: $(du -sh "$IMAGES_DIR" 2>/dev/null | awk '{print $1}')\n"
    diag_info+="Cache: $(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')\n\n"
    diag_info+="Available Images: $(ls -1 "$IMAGES_DIR"/*.img 2>/dev/null | wc -l)\n"
    diag_info+="Available Kernels: $(ls -1 "$KERNELS_DIR"/kernel-* 2>/dev/null | wc -l)\n"
    
    dialog --title "System Diagnostics" --msgbox "$diag_info" 18 60
}

view_logs() {
    local log_files=$(ls -t "$LOGS_DIR"/*.log 2>/dev/null | head -10)
    
    if [ -z "$log_files" ]; then
        dialog --msgbox "No logs found!" 8 30
        return
    fi
    
    local log_menu=""
    local counter=1
    while IFS= read -r log; do
        local basename=$(basename "$log")
        log_menu+="$counter \"$basename\" "
        ((counter++))
    done <<< "$log_files"
    
    local log_choice
    log_choice=$(eval dialog --title \"Select Log\" --menu \"Choose log file:\" 15 70 10 $log_menu 2>&1 >/dev/tty)
    [ -z "$log_choice" ] && return
    
    local selected_log=$(echo "$log_files" | sed -n "${log_choice}p")
    
    dialog --title "Log: $(basename "$selected_log")" --textbox "$selected_log" 20 80
}

cleanup_and_exit() {
    unmount_image
    
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
    
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 130 ]; then
        return
    fi
    
    log ERROR "Error occurred at line $line_num with exit code $exit_code"
    
    unmount_image
    
    if command -v dialog &> /dev/null; then
        dialog --msgbox "An error occurred!\n\nLine: $line_num\nCode: $exit_code\n\nCheck logs for details." 10 50
    else
        echo "Error at line $line_num (exit code: $exit_code)"
    fi
}

trap 'handle_error $LINENO' ERR
trap 'cleanup_and_exit' EXIT INT TERM

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
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
    
    while true; do
        choice=$(show_main_menu)
        
        case $choice in
            1) quick_start ;;
            2) create_instance ;;
            3) list_instances ;;
            4) download_os_image ;;
            5) system_diagnostics ;;
            6) view_logs ;;
            0|"") break ;;
            *) dialog --msgbox "Invalid option!" 8 30 ;;
        esac
    done
    
    cleanup_and_exit
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

SUDO_CMD=""
if [ "$EUID" -ne 0 ]; then
    SUDO_CMD="sudo"
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "QEMU Raspberry Pi Manager v2.0.3"
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -h, --help      Show this help"
            echo "  -v, --verbose   Enable verbose output"
            echo "  -d, --debug     Enable debug mode"
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
        *)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    if ! sudo -n true 2>/dev/null; then
        echo "=================================================="
        echo " QEMU Raspberry Pi Manager v2.0.3"
        echo "=================================================="
        echo ""
        echo "Sudo privileges are required for:"
        echo "  - Package installation"
        echo "  - Mounting/unmounting images"
        echo ""
        echo "Press ENTER to continue or Ctrl+C to exit..."
        read -r
    fi
fi

main "$@"