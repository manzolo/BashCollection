#!/bin/bash

# Advanced VM image management script
# Supports: resizing, mounting, LUKS, LVM, QEMU testing, dependency management

# Check if whiptail is installed
if ! command -v whiptail &> /dev/null; then
    echo "Error: whiptail is not installed. Install it with 'sudo apt install whiptail' on Debian/Ubuntu."
    exit 1
fi

# Global variables
SCRIPT_NAME="VM Image Manager Pro"
NBD_DEVICE=""
MOUNTED_PATHS=()
LUKS_MAPPED=()
LVM_ACTIVE=()
VG_DEACTIVATED=()
QEMU_PID=""
INSTALLED_PACKAGES=()
CLEANUP_DONE=false
LOG_FILE="/tmp/vm_image_manager_log_$$.txt"
echo "Script started at $(date)" > "$LOG_FILE"

# Funzione helper per log
log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

# Comprehensive cleanup function
cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return 0
    fi
    
    log "Starting cleanup"
    echo "Cleaning up..."
    CLEANUP_DONE=true
    
    # Terminate QEMU if active
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        log "Terminating QEMU (PID: $QEMU_PID)"
        echo "Terminating QEMU (PID: $QEMU_PID)..."
        kill "$QEMU_PID" 2>/dev/null
        sleep 2
        kill -9 "$QEMU_PID" 2>/dev/null
    fi
    
    # Unmount all mounted paths
    for path in "${MOUNTED_PATHS[@]}"; do
        if mountpoint -q "$path" 2>/dev/null; then
            log "Unmounting $path"
            echo "Unmounting $path..."
            umount "$path" 2>/dev/null || fusermount -u "$path" 2>/dev/null
            rmdir "$path" 2>/dev/null
        fi
    done
    
    # Deactivate LVM
    for lv in "${LVM_ACTIVE[@]}"; do
        log "Deactivating LV $lv"
        echo "Deactivating LV $lv..."
        lvchange -an "$lv" 2>/dev/null
    done
    
    # Deactivate VG
    for vg in "${VG_DEACTIVATED[@]}"; do
        log "Deactivating VG $vg"
        echo "Deactivating VG $vg..."
        vgchange -an "$vg" 2>/dev/null
    done
    
    # Close LUKS
    for luks in "${LUKS_MAPPED[@]}"; do
        log "Closing LUKS $luks"
        echo "Closing LUKS $luks..."
        cryptsetup luksClose "$luks" 2>/dev/null
    done
    
    # Disconnect NBD with retries
    if [ -n "$NBD_DEVICE" ] && [ -b "$NBD_DEVICE" ]; then
        log "Disconnecting $NBD_DEVICE"
        echo "Disconnecting $NBD_DEVICE..."
        for i in {1..3}; do
            if qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null; then
                break
            fi
            sleep 1
        done
    fi
    
    # Disconnect all active NBD devices
    for nbd in /dev/nbd*; do
        if [ -b "$nbd" ] && [ -s "/sys/block/$(basename "$nbd")/pid" ] 2>/dev/null; then
            log "Disconnecting $nbd"
            echo "Disconnecting $nbd..."
            qemu-nbd --disconnect "$nbd" 2>/dev/null
        fi
    done
    
    # Remove NBD module if possible
    sleep 2
    if lsmod | grep -q nbd; then
        rmmod nbd 2>/dev/null
    fi
    
    # Remove installed packages if requested
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        if whiptail --title "Package Cleanup" --yesno "Do you want to remove the packages automatically installed by this script?\n\nPackages: ${INSTALLED_PACKAGES[*]}" 10 70; then
            apt-get remove -y "${INSTALLED_PACKAGES[@]}" 2>/dev/null
            apt-get autoremove -y 2>/dev/null
        fi
    fi
    
    log "Cleanup completed"
    echo "Cleanup completed."
}

# Trap for automatic cleanup on exit
trap cleanup EXIT INT TERM

# Function to check and install dependencies
check_and_install_dependencies() {
    local missing_essential=()
    local missing_optional=()
    
    # Essential dependencies with packages
    declare -A essential_deps=(
        ["qemu-img"]="qemu-utils"
        ["qemu-nbd"]="qemu-utils"
        ["parted"]="parted"
        ["wget"]="wget"
    )
    
    # Optional dependencies with packages
    declare -A optional_deps=(
        ["guestmount"]="libguestfs-tools"
        ["cryptsetup"]="cryptsetup"
        ["vgs"]="lvm2"
        ["sgdisk"]="gdisk"
        ["ntfsresize"]="ntfs-3g"
        ["e2fsck"]="e2fsprogs"
    )
    
    # Check essential dependencies
    for cmd in "${!essential_deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_essential+=("${essential_deps[$cmd]}")
        fi
    done
    
    # Check optional dependencies
    for cmd in "${!optional_deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_optional+=("${optional_deps[$cmd]}")
        fi
    done
    
    # Install essential dependencies if missing
    if [ ${#missing_essential[@]} -gt 0 ]; then
        local unique_essential=($(printf '%s\n' "${missing_essential[@]}" | sort -u))
        
        if whiptail --title "Missing Dependencies" --yesno "The following essential dependencies are missing: ${unique_essential[*]}\n\nDo you want to install them automatically?" 10 70; then
            (
                echo 0
                echo "# Updating package lists..."
                apt-get update >/dev/null 2>&1
                echo 50
                echo "# Installing essential dependencies..."
                apt-get install -y "${unique_essential[@]}" >/dev/null 2>&1
                echo 100
                echo "# Done!"
                sleep 1
            ) | whiptail --gauge "Installing essential dependencies..." 8 50 0
            if [ $? -eq 0 ]; then
                INSTALLED_PACKAGES+=("${unique_essential[@]}")
                whiptail --msgbox "Essential dependencies installed successfully." 8 60
            else
                whiptail --msgbox "Error installing essential dependencies." 8 60
                exit 1
            fi
        else
            whiptail --msgbox "The following essential dependencies are required: ${unique_essential[*]}\nInstall them manually and restart the script." 10 70
            exit 1
        fi
    fi
    
    # Offer to install optional dependencies
    if [ ${#missing_optional[@]} -gt 0 ]; then
        local unique_optional=($(printf '%s\n' "${missing_optional[@]}" | sort -u))
        
        if whiptail --title "Optional Dependencies" --yesno "The following optional dependencies are missing: ${unique_optional[*]}\n\nDo you want to install them for full functionality?" 12 80; then
            (
                echo 0
                echo "# Installing optional dependencies..."
                apt-get install -y "${unique_optional[@]}" >/dev/null 2>&1
                echo 100
                echo "# Done!"
                sleep 1
            ) | whiptail --gauge "Installing optional dependencies..." 8 50 0
            if [ $? -eq 0 ]; then
                INSTALLED_PACKAGES+=("${unique_optional[@]}")
                whiptail --msgbox "Optional dependencies installed." 8 60
            else
                whiptail --msgbox "Some optional dependencies were not installed." 8 60
            fi
        fi
    fi
}

# Function to check if a file is in use
check_file_lock() {
    local file=$1
    
    log "Checking file lock for $file"
    # Check if the file is open by any process
    if lsof "$file" >/dev/null 2>&1; then
        local processes=$(lsof "$file" 2>/dev/null | tail -n +2 | awk '{print $2 " (" $1 ")"}' | sort -u)
        whiptail --title "File in Use" --yesno "The file is currently in use by the following processes:\n\n$processes\n\nDo you want to terminate these processes and continue?" 15 70
        
        if [ $? -eq 0 ]; then
            # Terminate processes using the file
            lsof "$file" 2>/dev/null | tail -n +2 | awk '{print $2}' | sort -u | while read pid; do
                kill "$pid" 2>/dev/null
                sleep 1
                kill -9 "$pid" 2>/dev/null
            done
            sleep 2
            
            # Check again
            if lsof "$file" >/dev/null 2>&1; then
                log "Could not release file lock"
                whiptail --msgbox "Could not release the file. Please try again later." 8 60
                return 1
            fi
        else
            return 1
        fi
    fi
    
    log "File lock check passed"
    return 0
}

# Function to select a file using a file browser
select_file() {
    local current_dir=$(pwd)
    
    while true; do
        local items=()
        local counter=1
        
        # Add parent directory if not in root
        if [ "$current_dir" != "/" ]; then
            items+=("$counter" "[..] Parent directory")
            ((counter++))
        fi
        
        # Read directories and files in the current directory
        while IFS= read -r -d '' item; do
            if [ -d "$item" ]; then
                items+=("$counter" "[DIR] $(basename "$item")/")
            elif [ -f "$item" ]; then
                local basename_item=$(basename "$item")
                local size=$(du -h "$item" 2>/dev/null | cut -f1)
                if [[ "$basename_item" =~ \.(img|raw|qcow2|vmdk|vdi|iso|vhd)$ ]]; then
                    items+=("$counter" "[IMG] $basename_item ($size)")
                else
                    items+=("$counter" "[FILE] $basename_item ($size)")
                fi
            fi
            ((counter++))
        done < <(find "$current_dir" -maxdepth 1 \( -type d -o -type f \) ! -name ".*" -print0 2>/dev/null | sort -z)
        
        # Add special options
        items+=("$counter" "[MANUAL] Enter path manually")
        local manual_option=$counter
        ((counter++))
        items+=("$counter" "[QUICK] Common directories")
        local quick_option=$counter
        
        choice=$(whiptail --title "File Browser - $current_dir" --menu "Select a file or navigate:" 20 80 12 "${items[@]}" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            log "File selection cancelled"
            echo "Selection cancelled."
            return 1
        fi
        
        # Handle special choices
        if [ "$choice" -eq "$manual_option" ]; then
            manual_file=$(whiptail --title "Enter Path" --inputbox "Enter the full path to the file:" 10 70 3>&1 1>&2 2>&3)
            if [ $? -eq 0 ] && [ -n "$manual_file" ]; then
                log "Manually selected file: $manual_file"
                echo "$manual_file"
                return
            fi
            continue
        elif [ "$choice" -eq "$quick_option" ]; then
            quick_dirs=(
                "1" "/var/lib/libvirt/images"
                "2" "/home"
                "3" "$HOME"
                "4" "/tmp"
                "5" "/mnt"
                "6" "/media"
                "7" "Back to browser"
            )
            quick_choice=$(whiptail --title "Common Directories" --menu "Go to:" 15 60 7 "${quick_dirs[@]}" 3>&1 1>&2 2>&3)
            case $quick_choice in
                1) current_dir="/var/lib/libvirt/images" ;;
                2) current_dir="/home" ;;
                3) current_dir="$HOME" ;;
                4) current_dir="/tmp" ;;
                5) current_dir="/mnt" ;;
                6) current_dir="/media" ;;
                *) continue ;;
            esac
            if [ ! -d "$current_dir" ]; then
                whiptail --msgbox "The directory $current_dir does not exist." 8 50
                current_dir=$(pwd)
            fi
            continue
        fi
        
        # Navigate directories or select file
        local current_counter=1
        
        # Handle parent directory
        if [ "$current_dir" != "/" ] && [ "$choice" -eq "$current_counter" ]; then
            current_dir=$(dirname "$current_dir")
            continue
        elif [ "$current_dir" != "/" ]; then
            ((current_counter++))
        fi
        
        # Find the selected item
        while IFS= read -r -d '' item; do
            if [ "$choice" -eq "$current_counter" ]; then
                if [ -d "$item" ]; then
                    current_dir="$item"
                    break
                elif [ -f "$item" ]; then
                    log "Selected file: $item"
                    echo "$item"
                    return
                fi
            fi
            ((current_counter++))
        done < <(find "$current_dir" -maxdepth 1 \( -type d -o -type f \) ! -name ".*" -print0 2>/dev/null | sort -z)
    done
}

# Function to get the new size
get_size() {
    local size_options=(
        "1" "1G - 1 Gigabyte"
        "2" "5G - 5 Gigabyte"
        "3" "10G - 10 Gigabyte"
        "4" "20G - 20 Gigabyte"
        "5" "50G - 50 Gigabyte"
        "6" "100G - 100 Gigabyte"
        "7" "200G - 200 Gigabyte"
        "8" "Enter custom size"
    )
    
    choice=$(whiptail --title "Image Size" --menu "Select the new size:" 18 60 8 "${size_options[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    case $choice in
        1) echo "1G" ;;
        2) echo "5G" ;;
        3) echo "10G" ;;
        4) echo "20G" ;;
        5) echo "50G" ;;
        6) echo "100G" ;;
        7) echo "200G" ;;
        8) 
            custom_size=$(whiptail --title "Custom Size" --inputbox "Enter the size (e.g., 15G, 500M, 1T):" 10 60 3>&1 1>&2 2>&3)
            if [ $? -eq 0 ] && [[ $custom_size =~ ^[0-9]+(\.[0-9]+)?[KMGT]?$ ]]; then
                echo "$custom_size"
            else
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

# Function to find a free NBD device
find_free_nbd() {
    for i in {0..15}; do
        local nbd_dev="/dev/nbd$i"
        if [ ! -s "/sys/block/nbd$i/pid" ] 2>/dev/null; then
            echo "$nbd_dev"
            return 0
        fi
    done
    echo "/dev/nbd0"  # Fallback
}

# Function to connect the image to NBD
connect_nbd() {
    local file=$1
    local format=${2:-raw}
    
    log "Starting connect_nbd for $file (format: $format)"
    
    # Check if the file is locked
    if ! check_file_lock "$file"; then
        log "File lock check failed"
        return 1
    fi
    
    # Load the NBD module
    if ! lsmod | grep -q nbd; then
        log "Loading nbd module"
        modprobe nbd max_part=16 || { log "Failed to load nbd module"; return 1; }
    fi
    
    # Find a free device
    NBD_DEVICE=$(find_free_nbd)
    
    # Connect with retries and progress
    local retries=3
    (
        for i in $(seq 1 $retries); do
            echo $(( (i-1)*33 ))  # Progresso: 0%, 33%, 66%
            echo "# Attempt $i/$retries: Connecting NBD..."
            log "Attempt $i/$retries: Connecting $NBD_DEVICE"
            if timeout 30 qemu-nbd --connect="$NBD_DEVICE" -f "$format" "$file" 2>>"$LOG_FILE"; then
                sleep 3  # Wait for it to be ready
                if [ -b "$NBD_DEVICE" ]; then
                    echo 100
                    echo "# Connected successfully!"
                    log "NBD connected successfully"
                    sleep 1
                    exit 0
                fi
            fi
            log "Attempt $i failed: $(tail -n 1 "$LOG_FILE")"
            qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null
            sleep 2
        done
        echo 100
        echo "# Failed after $retries attempts."
        log "All NBD attempts failed"
        sleep 2
        exit 1
    ) | whiptail --gauge "Connecting NBD device..." 8 50 0
    
    if [ $? -eq 0 ]; then
        return 0
    else
        whiptail --msgbox "NBD connection failed after retries. Check log: $LOG_FILE" 8 50
        return 1
    fi
}

# Function to safely disconnect NBD
safe_nbd_disconnect() {
    local device=${1:-$NBD_DEVICE}
    
    if [ -z "$device" ] || [ ! -b "$device" ]; then
        return 0
    fi
    
    log "Disconnecting NBD device $device"
    
    # Forcefully unmount any mount points
    for mount in $(mount | grep "$device" | awk '{print $3}'); do
        umount "$mount" 2>/dev/null || umount -f "$mount" 2>/dev/null
    done
    
    # Disconnect with retries
    for i in {1..5}; do
        if qemu-nbd --disconnect "$device" 2>/dev/null; then
            sleep 1
            if [ ! -s "/sys/block/$(basename "$device")/pid" ] 2>/dev/null; then
                log "NBD device $device disconnected"
                return 0
            fi
        fi
        sleep 1
    done
    
    log "Failed to disconnect $device"
    whiptail --msgbox "Warning: Could not completely disconnect $device.\nA reboot may be required." 10 60
    return 1
}

# Function to detect Windows image
detect_windows_image() {
    local device=$1
    log "Detecting if $device is a Windows image"
    for part in "${device}"p*; do
        if [ -b "$part" ]; then
            local fs_type=$(blkid -o value -s TYPE "$part" 2>/dev/null)
            if [ "$fs_type" = "ntfs" ]; then
                # Mount temporaneo per check file (read-only)
                local temp_mount="/tmp/win_check_$$"
                mkdir -p "$temp_mount"
                if mount -o ro "$part" "$temp_mount" 2>/dev/null; then
                    if [ -f "$temp_mount/Windows/System32/config/SYSTEM" ] || [ -f "$temp_mount/bootmgr" ]; then
                        umount "$temp_mount"
                        rmdir "$temp_mount"
                        log "Windows image detected"
                        return 0  # È Windows
                    fi
                    umount "$temp_mount"
                fi
                rmdir "$temp_mount"
            fi
        fi
    done
    log "Not a Windows image"
    return 1  # Non Windows
}

# Function to analyze partitions
analyze_partitions() {
    local device=$1
    
    if [ ! -b "$device" ]; then
        log "Device $device not available"
        echo "Device $device not available"
        return 1
    fi
    
    log "Analyzing partitions on $device"
    echo "=== PARTITION ANALYSIS ==="
    parted "$device" print 2>/dev/null || {
        log "Error analyzing partitions"
        echo "Error analyzing partitions"
        return 1
    }
    
    echo ""
    echo "=== FILESYSTEMS ==="
    for part in "${device}"p*; do
        if [ -b "$part" ]; then
            local fs_info=$(blkid "$part" 2>/dev/null || echo "Unknown")
            echo "$(basename "$part"): $fs_info"
        fi
    done
    
    return 0
}

# Function to detect LUKS
detect_luks() {
    local device=$1
    local luks_parts=()
    
    for part in "${device}"p*; do
        if [ -b "$part" ] && cryptsetup isLuks "$part" 2>/dev/null; then
            luks_parts+=("$part")
        fi
    done
    
    printf '%s\n' "${luks_parts[@]}"
}

# Function to open LUKS
open_luks() {
    local luks_part=$1
    local mapper_name="luks_$(basename "$luks_part")_$$"
    
    log "Attempting to open LUKS on $luks_part"
    if whiptail --title "LUKS Detected" --yesno "LUKS partition: $luks_part\nDo you want to open it?" 10 60; then
        local password=$(whiptail --title "LUKS Password" --passwordbox "Password for $luks_part:" 10 60 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ] || [ -z "$password" ]; then
            log "LUKS password input cancelled"
            return 1
        fi
        
        if echo "$password" | cryptsetup luksOpen "$luks_part" "$mapper_name" 2>>"$LOG_FILE"; then
            LUKS_MAPPED+=("$mapper_name")
            log "LUKS opened: /dev/mapper/$mapper_name"
            echo "/dev/mapper/$mapper_name"
            return 0
        else
            log "Failed to open LUKS: $(tail -n 1 "$LOG_FILE")"
            whiptail --msgbox "Incorrect password or error opening LUKS." 8 50
            return 1
        fi
    fi
    return 1
}

# Function to handle LVM
handle_lvm() {
    log "Scanning for LVM"
    # Scan for LVM
    vgscan >/dev/null 2>&1
    pvscan >/dev/null 2>&1
    lvscan >/dev/null 2>&1
    
    local vgs=($(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' '))
    
    if [ ${#vgs[@]} -eq 0 ]; then
        log "No Volume Groups found"
        return 1
    fi
    
    local vg_items=()
    for i in "${!vgs[@]}"; do
        vg_items+=("$((i+1))" "${vgs[i]}")
    done
    
    local choice=$(whiptail --title "LVM Detected" --menu "Select Volume Group:" 15 60 8 "${vg_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$choice" ]; then
        log "LVM VG selection cancelled"
        return 1
    fi
    
    local selected_vg="${vgs[$((choice-1))]}"
    local lvs=($(lvs --noheadings -o lv_name "$selected_vg" 2>/dev/null | tr -d ' '))
    
    if [ ${#lvs[@]} -eq 0 ]; then
        log "No Logical Volumes found in $selected_vg"
        whiptail --msgbox "No Logical Volumes found in $selected_vg" 8 50
        return 1
    fi
    
    local lv_items=()
    for i in "${!lvs[@]}"; do
        lv_items+=("$((i+1))" "${lvs[i]}")
    done
    
    local lv_choice=$(whiptail --title "Logical Volumes" --menu "Select LV to resize:" 15 60 8 "${lv_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$lv_choice" ]; then
        log "Selected LV: $selected_vg/${lvs[$((lv_choice-1))]}"
        echo "$selected_vg/${lvs[$((lv_choice-1))]}"
        return 0
    fi
    
    log "LVM LV selection cancelled"
    return 1
}

# Function to resize LVM
resize_lvm() {
    local vg_lv=$1
    local luks_device=$2
    
    log "Resizing LVM: $vg_lv"
    (
        echo 0
        echo "# Resizing LVM..."
        if [ -n "$luks_device" ]; then
            echo 20
            echo "# Resizing PV..."
            pvresize "$luks_device" 2>>"$LOG_FILE" || {
                log "Error resizing PV: $(tail -n 1 "$LOG_FILE")"
                exit 1
            }
            local luks_name=$(basename "$luks_device" | sed 's|^mapper/||')
            echo 40
            echo "# Resizing LUKS..."
            cryptsetup resize "$luks_name" 2>>"$LOG_FILE" || {
                log "Error resizing LUKS: $(tail -n 1 "$LOG_FILE")"
                exit 1
            }
        fi
        echo 60
        echo "# Extending LV..."
        lvextend -l +100%FREE "/dev/$vg_lv" 2>>"$LOG_FILE" || {
            log "Error resizing LV: $(tail -n 1 "$LOG_FILE")"
            exit 1
        }
        echo 80
        echo "# Checking filesystem..."
        local fs_type=$(blkid -o value -s TYPE "/dev/$vg_lv" 2>/dev/null)
        case "$fs_type" in
            "ext2"|"ext3"|"ext4")
                e2fsck -f -y "/dev/$vg_lv" >/dev/null 2>&1 || true
                echo 90
                echo "# Resizing ext filesystem..."
                resize2fs -p "/dev/$vg_lv" >/dev/null 2>&1
                ;;
            "xfs")
                echo 100
                echo "# XFS detected, manual resize needed"
                exit 2
                ;;
        esac
        echo 100
        echo "# Done!"
        sleep 1
    ) | whiptail --gauge "Resizing LVM..." 8 50 0
    
    local result=$?
    if [ $result -eq 0 ]; then
        LVM_ACTIVE+=("/dev/$vg_lv")
        log "LVM resize completed successfully"
        whiptail --msgbox "LVM resizing completed successfully!" 8 50
        return 0
    elif [ $result -eq 2 ]; then
        log "XFS detected, manual resize suggested"
        whiptail --msgbox "XFS detected. After mounting, use:\nxfs_growfs /mount/path" 10 60
        return 0
    else
        log "LVM resize failed"
        whiptail --msgbox "Error resizing the LV. Check log: $LOG_FILE" 8 50
        return 1
    fi
}

# Function to test the VM with QEMU
test_vm_qemu() {
    local file=$1
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        whiptail --msgbox "qemu-system-x86_64 not found.\nInstall with: apt install qemu-system-x86" 10 60
        return 1
    fi
    
    # QEMU options
    local qemu_options=(
        "1" "Normal boot (2GB RAM)"
        "2" "Boot with 4GB RAM"
        "3" "Boot with 8GB RAM"
        "4" "Headless boot (no graphics)"
        "5" "Custom boot"
    )
    
    local choice=$(whiptail --title "Test VM with QEMU" --menu "Select boot mode:" 15 60 5 "${qemu_options[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local qemu_cmd="qemu-system-x86_64"
    local qemu_args=()
    
    case $choice in
        1)
            qemu_args=("-hda" "$file" "-m" "2048" "-enable-kvm")
            ;;
        2)
            qemu_args=("-hda" "$file" "-m" "4096" "-enable-kvm")
            ;;
        3)
            qemu_args=("-hda" "$file" "-m" "8192" "-enable-kvm")
            ;;
        4)
            qemu_args=("-hda" "$file" "-m" "1024" "-nographic" "-enable-kvm")
            whiptail --msgbox "Headless mode.\nUse Ctrl+A, X to exit QEMU." 10 60
            ;;
        5)
            local custom_args=$(whiptail --title "Custom Options" --inputbox "Enter additional arguments for QEMU:" 10 70 "-m 2048 -enable-kvm" 3>&1 1>&2 2>&3)
            if [ $? -eq 0 ] && [ -n "$custom_args" ]; then
                qemu_args=("-hda" "$file")
                IFS=' ' read -ra ADDR <<< "$custom_args"
                qemu_args+=("${ADDR[@]}")
            else
                return 1
            fi
            ;;
    esac
    
    # Check if the file is locked
    if ! check_file_lock "$file"; then
        return 1
    fi
    
    (
        echo 0
        echo "# Starting QEMU..."
        "$qemu_cmd" "${qemu_args[@]}" </dev/null &>/dev/null &
        QEMU_PID=$!
        sleep 3
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            echo 100
            echo "# QEMU started!"
            sleep 1
        else
            echo 100
            echo "# QEMU failed to start"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Starting QEMU..." 8 50 0
    
    if [ $? -eq 0 ]; then
        log "QEMU started: PID $QEMU_PID, Command: $qemu_cmd ${qemu_args[*]}"
        whiptail --msgbox "QEMU started successfully!\n\nPID: $QEMU_PID\nCommand: $qemu_cmd ${qemu_args[*]}\n\nClose the QEMU window or use the menu to terminate." 15 80
    else
        log "QEMU start failed"
        whiptail --msgbox "Error starting QEMU." 8 50
        QEMU_PID=""
        return 1
    fi
    
    return 0
}

# Function to boot GParted Live ISO with QEMU
gparted_boot() {
    local file=$1
    local gparted_dir="${PWD}/gparted"
    local gparted_iso_url="https://sourceforge.net/projects/gparted/files/gparted-live-stable/1.7.0-8/gparted-live-1.7.0-8-amd64.iso/download"
    local gparted_iso_file="$gparted_dir/gparted-live-1.7.0-8-amd64.iso"
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        whiptail --msgbox "qemu-system-x86_64 not found.\nInstall with: apt install qemu-system-x86" 10 60
        return 1
    fi
    
    # Create temporary directory
    mkdir -p "$gparted_dir"
    
    # Download the ISO if it doesn't exist
    if [ ! -f "$gparted_iso_file" ]; then
        (
            echo 0
            echo "# Downloading GParted Live ISO..."
            wget -O "$gparted_iso_file" "$gparted_iso_url" 2>>"$LOG_FILE"
            echo 100
            echo "# Download complete!"
            sleep 1
        ) | whiptail --gauge "Downloading GParted Live ISO..." 8 50 0
        if [ $? -ne 0 ]; then
            log "Error downloading GParted ISO"
            whiptail --msgbox "Error downloading GParted ISO." 8 50
            return 1
        fi
    fi
    
    if ! check_file_lock "$file"; then
        return 1
    fi
    
    (
        echo 0
        echo "# Starting QEMU with GParted Live..."
        qemu-system-x86_64 -hda "$file" -cdrom "$gparted_iso_file" -boot d -m 2048 -enable-kvm </dev/null &>/dev/null &
        QEMU_PID=$!
        sleep 3
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            echo 100
            echo "# QEMU started!"
            sleep 1
        else
            echo 100
            echo "# QEMU failed to start"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Starting QEMU with GParted Live..." 8 50 0
    
    if [ $? -eq 0 ]; then
        log "GParted QEMU started: PID $QEMU_PID"
        whiptail --msgbox "QEMU started successfully!\n\nPID: $QEMU_PID\n\nYou can now use GParted Live to resize the partitions inside the VM.\nLogin password: live" 15 80
    else
        log "GParted QEMU start failed"
        whiptail --msgbox "Error starting QEMU." 8 50
        QEMU_PID=""
        return 1
    fi
    
    return 0
}

# Function to resize an ext filesystem
resize_ext_filesystem() {
    local target_partition=$1
    
    if ! command -v e2fsck &> /dev/null || ! command -v resize2fs &> /dev/null; then
        log "e2fsck or resize2fs not found"
        whiptail --msgbox "e2fsck or resize2fs not found.\nInstall with: sudo apt install e2fsprogs" 10 60
        return 1
    fi
    
    log "Resizing ext filesystem on $target_partition"
    (
        echo 0
        echo "# Checking ext filesystem consistency..."
        
        # First check only (no repair)
        e2fsck -n "$target_partition" >/tmp/ext_check_$$.log 2>&1
        local check_result=$?
        
        echo 20
        if [ $check_result -ge 4 ]; then
            echo "# Filesystem errors detected, repairing..."
            e2fsck -f -y -v "$target_partition" >>/tmp/ext_check_$$.log 2>&1
            if [ $? -ge 4 ]; then
                echo 100
                echo "# Critical filesystem errors!"
                log "Critical ext errors: $(tail -n 5 /tmp/ext_check_$$.log)"
                sleep 2
                exit 1
            fi
        else
            echo "# Filesystem check passed"
        fi
        
        echo 60
        echo "# Resizing ext filesystem..."
        resize2fs -p "$target_partition" >>/tmp/ext_check_$$.log 2>&1
        
        echo 80
        echo "# Final filesystem check..."
        e2fsck -n "$target_partition" >>/tmp/ext_check_$$.log 2>&1
        
        echo 100
        if [ $? -eq 0 ]; then
            echo "# Ext resize completed successfully!"
            log "Ext resize successful"
            sleep 1
        else
            echo "# Ext resize completed with warnings"
            log "Ext resize with warnings: $(tail -n 5 /tmp/ext_check_$$.log)"
            sleep 2
            exit 2
        fi
    ) | whiptail --gauge "Resizing ext filesystem..." 8 50 0
    
    local result=$?
    rm -f /tmp/ext_check_$$.log
    
    if [ $result -eq 0 ]; then
        whiptail --msgbox "Ext filesystem resized successfully!" 8 60
        return 0
    elif [ $result -eq 2 ]; then
        whiptail --msgbox "Ext resize completed with warnings.\nThe filesystem should be functional but consider a full check." 10 60
        return 0
    else
        whiptail --msgbox "Error resizing ext filesystem.\nThe filesystem may have errors that need manual repair." 10 60
        return 1
    fi
}

# Function to check free space before resizing
check_free_space() {
    local file=$1
    local new_size=$2
    
    # Convert new size to bytes
    local new_size_bytes=$(echo "$new_size" | awk '
        /[0-9]+\.[0-9]+[KMGTP]/ {printf "%.0f", $0 * 1024 * 1024 * 1024; exit}
        /[0-9]+[KMGTP]/ {printf "%.0f", $0 * 1024 * 1024 * 1024; exit}
        /[0-9]+\.[0-9]+/ {printf "%.0f", $0 * 1024 * 1024 * 1024; exit}
        {printf "%.0f", $0 * 1024 * 1024 * 1024}
    ' 2>/dev/null || echo 0)
    
    # Get current file size
    local current_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    
    # Get available disk space
    local available_space=$(df --output=avail -B1 "$(dirname "$file")" | tail -1)
    
    local space_needed=$((new_size_bytes - current_size))
    
    if [ $space_needed -gt $available_space ]; then
        local needed_gb=$(echo "scale=2; $space_needed / 1024 / 1024 / 1024" | bc)
        local available_gb=$(echo "scale=2; $available_space / 1024 / 1024 / 1024" | bc)
        
        whiptail --msgbox "Insufficient disk space!\n\nNeeded: ${needed_gb}G additional\nAvailable: ${available_gb}G\n\nFree up space or choose another location." 12 70
        return 1
    fi
    
    return 0
}

# Function for advanced image resizing
advanced_resize() {
    local file=$1
    local size=$2
    
    log "Starting advanced_resize for $file to $size"
    
    if ! check_file_lock "$file"; then
        log "File lock failed"
        return 1
    fi
    
    local format=$(qemu-img info "$file" 2>/dev/null | grep "file format:" | awk '{print $3}')
    if [ -z "$format" ]; then
        format="raw"
    fi
    
    # Optional backup
    if whiptail --title "Backup" --yesno "Do you want to create a backup before resizing?\n(Highly recommended)" 10 60; then
        (
            echo 0
            echo "# Creating backup..."
            cp "$file" "$file.backup.$(date +%Y%m%d_%H%M%S)"
            echo 100
            echo "# Backup created!"
            sleep 1
        ) | whiptail --gauge "Creating backup..." 8 50 0
        if [ $? -ne 0 ]; then
            log "Error creating backup"
            whiptail --msgbox "Error creating backup." 8 50
            return 1
        fi
    fi
    
    # Check free space before resizing
	if ! check_free_space "$file" "$size"; then
		return 1
	fi
    
    # Resize the image with progress
    (
        echo 0
        echo "# Resizing image to $size... This may take time."
        log "Resizing image with qemu-img"
        timeout 60 qemu-img resize -f "$format" "$file" "$size" 2>>"$LOG_FILE"
        echo 100
        if [ $? -eq 0 ]; then
            echo "# Resize completed!"
            log "Image resized successfully"
            sleep 1
        else
            echo "# Resize failed."
            log "Resize failed: $(tail -n 1 "$LOG_FILE")"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Resizing image..." 8 50 0
    
    if [ $? -ne 0 ]; then
        whiptail --msgbox "Error resizing the image. Check log: $LOG_FILE" 8 50
        return 1
    fi
    
    # Connect via NBD
    if ! connect_nbd "$file" "$format"; then
        whiptail --msgbox "NBD connection error." 8 50
        return 1
    fi
    
    sleep 2
    
    # Check if the NBD device exists
    if [ ! -b "$NBD_DEVICE" ]; then
        log "NBD device not found after connect"
        whiptail --msgbox "Error: The NBD device $NBD_DEVICE does not exist. Check the connection." 10 70
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    
    # Detect if Windows and warn
    if detect_windows_image "$NBD_DEVICE"; then
        log "Windows image warning shown"
        if whiptail --title "Windows Detected" --yesno "This appears to be a Windows image with potentially complex partitions (e.g., recovery at end).\nAutomatic resize may fail.\n\nProceed anyway, or use GParted Live?" 12 70; then
            # Proceed
            echo "continue"
        else
            log "User chose GParted for Windows image"
            safe_nbd_disconnect "$NBD_DEVICE"
            gparted_boot "$file"
            return 1
        fi
    fi
    
    # Use parted to get partition information with timeout
    log "Analyzing partitions with parted"
    local parted_output=$(timeout 30 parted "$NBD_DEVICE" print 2>>"$LOG_FILE")
    if [ $? -ne 0 ]; then
        log "Parted failed: $(tail -n 1 "$LOG_FILE")"
        whiptail --msgbox "Error while reading partitions with parted.\n\nDetails:\n$parted_output\nCheck log: $LOG_FILE" 15 70
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    log "Parted output: $parted_output"
    
    # Extract partitions from the parted output
    local partitions=($(echo "$parted_output" | grep "^ " | awk '{print $1}'))
    local partition_items=()
    for part in "${partitions[@]}"; do
        local part_info=$(echo "$parted_output" | grep "^ $part " | sed 's/^[[:space:]]*//')
        partition_items+=("$part" "$part_info")
    done
    
    if [ ${#partition_items[@]} -eq 0 ]; then
        whiptail --msgbox "No partitions were found on the disk. The `parted` command output was:\n\n$parted_output" 15 70
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    
    local partition_choice=$(whiptail --title "Select Partition" --menu "Select the partition to resize:" 20 80 12 "${partition_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        whiptail --msgbox "Partition selection cancelled." 8 60
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    
    local selected_partition="$partition_choice"
    
    # Check if selected partition is last (required for simple resize)
    local is_last_partition=false
    if [ "$selected_partition" = "${partitions[-1]}" ]; then
        is_last_partition=true
    fi
    
    (
        echo 0
        echo "# Resizing partition $selected_partition..."
        if [ "$is_last_partition" = false ] && detect_windows_image "$NBD_DEVICE"; then
            echo 100
            echo "# Non-last partition in Windows image, needs GParted"
            log "Non-last partition selected in Windows image"
            sleep 2
            exit 2
        fi
        
        local resize_success=false
        local partition_table=""
        if echo "$parted_output" | grep -q "gpt"; then
            partition_table="gpt"
        elif echo "$parted_output" | grep -q "msdos"; then
            partition_table="msdos"
        fi
        
        if [ "$partition_table" = "gpt" ] && command -v sgdisk &> /dev/null; then
            log "Using sgdisk for GPT"
            echo 50
            echo "# Resizing GPT partition..."
            sgdisk --move-second-header "$NBD_DEVICE" 2>>"$LOG_FILE"
            sgdisk --delete="$selected_partition" --new="$selected_partition":0:0 --typecode="$selected_partition":0700 "$NBD_DEVICE" 2>>"$LOG_FILE"
            if [ $? -eq 0 ]; then
                resize_success=true
            fi
        fi
        
        if [ "$resize_success" = false ]; then
            log "Fallback to parted resizepart"
            echo 50
            echo "# Fallback to parted..."
            parted --script "$NBD_DEVICE" resizepart "$selected_partition" 100% 2>>"$LOG_FILE"
            if [ $? -eq 0 ]; then
                resize_success=true
            fi
        fi
        
        if [ "$resize_success" = true ]; then
            echo 75
            echo "# Updating partition table..."
            partprobe "$NBD_DEVICE" 2>/dev/null
            sleep 2
            log "Partition resize success"
            echo 100
            echo "# Partition resized!"
            sleep 1
        else
            log "Partition resize failed: $(tail -n 1 "$LOG_FILE")"
            echo 100
            echo "# Partition resize failed"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Resizing partition..." 8 50 0
    
    local part_result=$?
    if [ $part_result -eq 2 ]; then
        whiptail --title "Complex Layout" --yesno "Selected partition is not the last one in a Windows image.\nUse GParted Live to move partitions?" 10 60
        if [ $? -eq 0 ]; then
            safe_nbd_disconnect "$NBD_DEVICE"
            gparted_boot "$file"
            return 1
        else
            safe_nbd_disconnect "$NBD_DEVICE"
            return 1
        fi
    elif [ $part_result -ne 0 ]; then
        whiptail --title "WARNING: Partition Resize Failed" --yesno "Automatic resizing failed (common for Windows layouts).\n\nLaunch GParted Live to resize manually?" 12 80
        if [ $? -eq 0 ]; then
            safe_nbd_disconnect "$NBD_DEVICE"
            gparted_boot "$file"
            return 1
        else
            safe_nbd_disconnect "$NBD_DEVICE"
            return 1
        fi
    fi
    
    # Handle LUKS if present
    local luks_parts=($(detect_luks "$NBD_DEVICE"))
    local luks_device=""
    
    if [ ${#luks_parts[@]} -gt 0 ]; then
        (
            echo 0
            echo "# Processing LUKS partitions..."
            for luks_part in "${luks_parts[@]}"; do
                luks_device=$(open_luks "$luks_part")
                if [ $? -eq 0 ] && [ -n "$luks_device" ]; then
                    echo 100
                    echo "# LUKS opened!"
                    sleep 1
                    break
                fi
            done
        ) | whiptail --gauge "Processing LUKS..." 8 50 0
    fi
    
    # Handle LVM if present
    local lvm_resized=false
    if command -v vgs &> /dev/null; then
        (
            echo 0
            echo "# Scanning for LVM..."
            local lvm_vg=$(handle_lvm)
            if [ $? -eq 0 ] && [ -n "$lvm_vg" ]; then
                echo 50
                echo "# Resizing LVM..."
                if resize_lvm "$lvm_vg" "$luks_device"; then
                    lvm_resized=true
                fi
            fi
            echo 100
            echo "# Done!"
            sleep 1
        ) | whiptail --gauge "Scanning LVM..." 8 50 0
    fi
    
    # Resize the filesystem if not LVM
    if [ "$lvm_resized" = false ] && [ -n "$selected_partition" ]; then
        local target_partition="${NBD_DEVICE}p${selected_partition}"
        
        # If LUKS is present, use the mapped device
        if [ -n "$luks_device" ]; then
            target_partition="$luks_device"
        fi
        
        if [ -b "$target_partition" ]; then
            local fs_type=$(blkid -o value -s TYPE "$target_partition" 2>/dev/null)
            
            case "$fs_type" in
                "ext2"|"ext3"|"ext4")
                    resize_ext_filesystem "$target_partition"
                    ;;
                "ntfs")
					if command -v ntfsresize &> /dev/null && command -v ntfsfix &> /dev/null; then
						(
							echo 0
							echo "# Checking NTFS consistency..."
							ntfsfix --clear-dirty "$target_partition" >/dev/null 2>&1
							
							echo 30
							echo "# Running chkdsk equivalent..."
							ntfsfix --no-action "$target_partition" >/tmp/ntfs_check_$$.log 2>&1
							
							echo 60
							echo "# Resizing NTFS..."
							local ntfs_output=$(ntfsresize --force --no-action "$target_partition" 2>&1)
							
							# Check if simulation was successful
							if echo "$ntfs_output" | grep -q "successfully would be resized"; then
								echo 80
								echo "# Applying resize..."
								local final_output=$(ntfsresize --force "$target_partition" 2>&1)
								echo 100
								if [ $? -eq 0 ]; then
									echo "# NTFS resized successfully!"
									log "NTFS resize successful: $final_output"
									sleep 1
								else
									echo "# NTFS resize failed"
									log "NTFS resize failed: $final_output"
									sleep 2
									exit 1
								fi
							else
								echo 100
								echo "# NTFS resize simulation failed"
								log "NTFS simulation failed: $ntfs_output"
								sleep 2
								exit 1
							fi
						) | whiptail --gauge "Resizing NTFS filesystem..." 8 50 0
						
						if [ $? -eq 0 ]; then
							whiptail --msgbox "NTFS resized successfully!" 8 60
						else
							local error_log=$(cat /tmp/ntfs_check_$$.log 2>/dev/null)
							rm -f /tmp/ntfs_check_$$.log
							whiptail --msgbox "Error resizing NTFS.\n\nDetails:\n$ntfs_output\n\nTry booting in Windows and running:\nchkdsk /f C:\n\nOr use GParted Live." 15 70
						fi
						rm -f /tmp/ntfs_check_$$.log
					else
						log "ntfs-3g tools missing"
						whiptail --msgbox "ntfs-3g tools missing. Install with:\nsudo apt install ntfs-3g" 10 60
					fi
					;;
                "xfs")
                    log "XFS detected, manual resize needed"
                    whiptail --msgbox "XFS detected. The partition has been extended, but the filesystem still needs to be resized.\n\nTo complete, use the 'Advanced Mount (NBD)' option, mount the partition, and run 'xfs_growfs <mount_point>'.\n\nAlternatively, you can boot the image with GParted Live to do it graphically." 20 80
                    ;;
                *)
                    if [ -n "$fs_type" ]; then
                        log "Unsupported filesystem: $fs_type"
                        whiptail --msgbox "Filesystem '$fs_type' is not supported for automatic resizing. You may need to use GParted Live." 10 70
                    else
                        log "Filesystem not recognized"
                        whiptail --msgbox "Filesystem not recognized. You may need to use GParted Live to verify and resize manually." 10 70
                    fi
                    ;;
                "btrfs")
					if command -v btrfs &> /dev/null; then
						(
							echo 0
							echo "# Checking btrfs filesystem..."
							btrfs check --repair --force "$target_partition" >/dev/null 2>&1 || true
							echo 50
							echo "# Resizing btrfs filesystem..."
							btrfs filesystem resize max "$target_partition" >/dev/null 2>&1
							echo 100
							echo "# Btrfs resize completed!"
							sleep 1
						) | whiptail --gauge "Resizing btrfs filesystem..." 8 50 0
						if [ $? -eq 0 ]; then
							whiptail --msgbox "Btrfs filesystem resized successfully!" 8 60
						else
							whiptail --msgbox "Error resizing btrfs. Try manual resize with:\nbtrfs filesystem resize max /mount/point" 10 60
						fi
					else
						whiptail --msgbox "btrfs tools not found. Install with:\nsudo apt install btrfs-progs" 10 60
					fi
					;;

				"xfs")
					whiptail --msgbox "XFS detected. The partition has been extended.\n\nTo resize the filesystem:\n1. Mount the partition\n2. Run: xfs_growfs /mount/point\n\nOr use GParted Live for graphical resize." 12 70
					;;
            esac
        fi
    fi
    
    # Automatic cleanup
    safe_nbd_disconnect "$NBD_DEVICE"
    NBD_DEVICE=""
    
    log "Resize completed for $file to $size"
    whiptail --msgbox "Resizing completed!\n\nFile: $(basename "$file")\nNew size: $size\n\nVerify the result with analysis or QEMU test." 12 70
    return 0
}

# Function to mount with guestmount
mount_with_guestmount() {
    local file=$1
    
    if ! command -v guestmount &> /dev/null; then
        log "guestmount not found"
        whiptail --msgbox "guestmount is not available.\nInstall with: apt install libguestfs-tools" 10 60
        return 1
    fi
    
    if ! check_file_lock "$file"; then
        return 1
    fi
    
    # Original user info
    local original_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
    local original_uid=${SUDO_UID:-$(id -u "$original_user" 2>/dev/null)}
    local original_gid=${SUDO_GID:-$(id -g "$original_user" 2>/dev/null)}
    
    # Mount point name with PID
    local mount_point="/mnt/vm_guest_$$"
    mkdir -p "$mount_point"
    
    (
        echo 0
        echo "# Mounting with guestmount..."
        # Mount with access options for the user
        local guestmount_opts=(--add "$file" -i --rw)
        if [ -n "$original_uid" ]; then
            guestmount_opts+=(--uid "$original_uid" --gid "$original_gid")
        fi
        guestmount_opts+=(-o allow_other)
        guestmount "${guestmount_opts[@]}" "$mount_point" 2>>"$LOG_FILE"
        echo 100
        if [ $? -eq 0 ]; then
            echo "# Mounted successfully!"
            sleep 1
        else
            echo "# Mount failed"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Mounting with guestmount..." 8 50 0
    
    if [ $? -eq 0 ]; then
        MOUNTED_PATHS+=("$mount_point")
        
        # Wait for the mount to be ready
        sleep 2
        
        # Change ownership of the mount point
        if [ -n "$original_uid" ] && [ -n "$original_gid" ]; then
            chown "$original_uid:$original_gid" "$mount_point" 2>/dev/null || true
            chmod 755 "$mount_point" 2>/dev/null || true
        fi
        
        # Check access
        local access_test="OK"
        if [ -n "$original_user" ]; then
            if ! su - "$original_user" -c "test -r '$mount_point'" 2>/dev/null; then
                access_test="LIMITED - Use sudo for full access"
            fi
        fi
        
        # Show mount information
        local space_info=$(df -h "$mount_point" 2>/dev/null | tail -1)
        local user_info=""
        if [ -n "$original_user" ]; then
            user_info="\nUser: $original_user\nAccess: $access_test"
        fi
        
        log "Mounted at $mount_point, access: $access_test"
        whiptail --msgbox "Image mounted successfully!\n\nPath: $mount_point$user_info\nSpace: $space_info\n\nCommands:\n- cd $mount_point\n- ls -la $mount_point\n- sudo -u $original_user ls $mount_point\n\nPress OK when you're done." 20 80
        
        # Unmount
        (
            echo 0
            echo "# Unmounting..."
            guestunmount "$mount_point" 2>/dev/null || fusermount -u "$mount_point" 2>/dev/null
            rmdir "$mount_point" 2>/dev/null
            echo 100
            echo "# Unmounted!"
            sleep 1
        ) | whiptail --gauge "Unmounting..." 8 50 0
        
        MOUNTED_PATHS=("${MOUNTED_PATHS[@]/$mount_point}")
        log "Unmounted $mount_point"
        whiptail --msgbox "Unmounting completed." 8 50
        return 0
    else
        rmdir "$mount_point" 2>/dev/null
        log "guestmount failed"
        whiptail --msgbox "Error mounting with guestmount.\nPossible causes:\n- Corrupted image\n- Unsupported filesystem\n- Insufficient permissions\nCheck log: $LOG_FILE" 12 70
        return 1
    fi
}

# Function to mount with NBD
mount_with_nbd() {
    local file=$1
    local format=$(qemu-img info "$file" 2>/dev/null | grep "file format:" | awk '{print $3}')
    
    if [ -z "$format" ]; then
        format="raw"
    fi
    
    if ! connect_nbd "$file" "$format"; then
        whiptail --msgbox "NBD connection error." 8 50
        return 1
    fi
    
    # List available partitions
    local part_items=()
    local counter=1
    
    for part in "${NBD_DEVICE}"p*; do
        if [ -b "$part" ]; then
            local fs_type=$(blkid -o value -s TYPE "$part" 2>/dev/null || echo "unknown")
            local size=$(lsblk -no SIZE "$part" 2>/dev/null || echo "?")
            part_items+=("$counter" "$(basename "$part") - $fs_type ($size)")
            ((counter++))
        fi
    done
    
    if [ ${#part_items[@]} -eq 0 ]; then
        whiptail --msgbox "No partitions found." 8 50
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    
    # Add special options
    part_items+=("$counter" "Full analysis (without mounting)")
    local analyze_option=$counter
    
    local choice=$(whiptail --title "NBD Mount" --menu "Select the partition to mount:" 18 70 10 "${part_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    
    # Handle analysis
    if [ "$choice" -eq "$analyze_option" ]; then
        local analysis=$(analyze_partitions "$NBD_DEVICE")
        local luks_info=""
        
        local luks_parts=($(detect_luks "$NBD_DEVICE"))
        if [ ${#luks_parts[@]} -gt 0 ]; then
            luks_info="\n\n=== LUKS PARTITIONS ===\n"
            for part in "${luks_parts[@]}"; do
                luks_info="$luks_info$(basename "$part")\n"
            done
        fi
        
        safe_nbd_disconnect "$NBD_DEVICE"
        NBD_DEVICE=""
        
        whiptail --title "Full Analysis" --msgbox "$analysis$luks_info" 20 80
        return 0
    fi
    
    # Find the selected partition
    local selected_part=""
    local current_counter=1
    for part in "${NBD_DEVICE}"p*; do
        if [ -b "$part" ] && [ "$choice" -eq "$current_counter" ]; then
            selected_part="$part"
            break
        fi
        ((current_counter++))
    done
    
    if [ -z "$selected_part" ]; then
        whiptail --msgbox "Selection error." 8 50
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    
    # Handle LUKS if necessary
    if cryptsetup isLuks "$selected_part" 2>/dev/null; then
        local luks_mapped=$(open_luks "$selected_part")
        if [ $? -eq 0 ] && [ -n "$luks_mapped" ]; then
            selected_part="$luks_mapped"
        else
            whiptail --msgbox "Cannot open the LUKS partition." 8 50
            safe_nbd_disconnect "$NBD_DEVICE"
            return 1
        fi
    fi
    
    local mount_point="/mnt/nbd_mount_$$"
    mkdir -p "$mount_point"
    
    # Original user info
    local original_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
    local original_uid=${SUDO_UID:-$(id -u "$original_user" 2>/dev/null)}
    local original_gid=${SUDO_GID:-$(id -g "$original_user" 2>/dev/null)}
    
    (
        echo 0
        echo "# Mounting $selected_part..."
        local mount_opts="-o"
        if [ -n "$original_uid" ]; then
            mount_opts="$mount_opts uid=$original_uid,gid=$original_gid,umask=022"
        else
            mount_opts="$mount_opts umask=022"
        fi
        mount "$mount_opts" "$selected_part" "$mount_point" 2>>"$LOG_FILE" || mount "$selected_part" "$mount_point" 2>>"$LOG_FILE"
        echo 100
        if [ $? -eq 0 ]; then
            echo "# Mounted successfully!"
            sleep 1
        else
            echo "# Mount failed"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Mounting partition..." 8 50 0
    
    if [ $? -eq 0 ]; then
        MOUNTED_PATHS+=("$mount_point")
        
        # Wait for the mount to be ready
        sleep 1
        
        # Change permissions after mounting
        if [ -n "$original_uid" ] && [ -n "$original_gid" ]; then
            chmod 755 "$mount_point" 2>/dev/null || true
            chown "$original_uid:$original_gid" "$mount_point" 2>/dev/null || true
        fi
        
        # Test user access
        local access_info="OK"
        if [ -n "$original_user" ]; then
            if ! su - "$original_user" -c "test -r '$mount_point'" 2>/dev/null; then
                access_info="Limited - use sudo if necessary"
                find "$mount_point" -maxdepth 1 -type d -exec chmod 755 {} \; 2>/dev/null || true
            fi
        fi
        
        local space_info=$(df -h "$mount_point" 2>/dev/null | tail -1)
        local user_info=""
        if [ -n "$original_user" ]; then
            user_info="\nUser: $original_user\nAccess: $access_info"
        fi
        
        # Create a helper script for the user
        local helper_script="/tmp/mount_helper_$$"
        cat > "$helper_script" << EOF
#!/bin/bash
echo "=== Mount Point: $mount_point ==="
echo "Contents:"
ls -la "$mount_point" 2>/dev/null || echo "Access denied, try with sudo"
echo ""
echo "Disk space:"
df -h "$mount_point" 2>/dev/null
echo ""
echo "To navigate: cd $mount_point"
echo "If you have permission issues: sudo -u $original_user bash"
EOF
        chmod +x "$helper_script"
        chown "$original_uid:$original_gid" "$helper_script" 2>/dev/null || true
        
        log "Mounted $selected_part at $mount_point, access: $access_info"
        whiptail --msgbox "Partition mounted!\n\nPartition: $(basename "$selected_part")\nPath: $mount_point\nSpace: $space_info$user_info\n\nUseful commands:\n- cd $mount_point\n- $helper_script\n- sudo -u $original_user ls -la $mount_point\n\nPress OK when you're done." 20 80
        
        # Clean up the helper script
        rm -f "$helper_script"
        
        # Unmount
        (
            echo 0
            echo "# Unmounting..."
            umount "$mount_point" 2>/dev/null
            rmdir "$mount_point" 2>/dev/null
            echo 100
            echo "# Unmounted!"
            sleep 1
        ) | whiptail --gauge "Unmounting..." 8 50 0
        
        MOUNTED_PATHS=("${MOUNTED_PATHS[@]/$mount_point}")
        safe_nbd_disconnect "$NBD_DEVICE"
        log "Unmounted $mount_point and disconnected NBD"
        whiptail --msgbox "Unmounting completed." 8 50
        return 0
    else
        rmdir "$mount_point" 2>/dev/null
        log "Mount failed for $selected_part"
        whiptail --msgbox "Error mounting $(basename "$selected_part").\nFilesystem may be corrupted or unsupported.\nCheck log: $LOG_FILE" 10 70
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
}

# Additional function to show active mount points
show_active_mounts() {
    local active_mounts=""
    local original_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
    
    for mount_point in "${MOUNTED_PATHS[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            local mount_info=$(df -h "$mount_point" 2>/dev/null | tail -1)
            local access_test="OK"
            
            # Test user access
            if [ -n "$original_user" ]; then
                if ! su - "$original_user" -c "test -r '$mount_point'" 2>/dev/null; then
                    access_test="LIMITED"
                fi
            fi
            
            active_mounts="$active_mounts$mount_point (Access: $access_test)\n$mount_info\n\n"
        fi
    done
    
    if [ -n "$active_mounts" ]; then
        whiptail --title "Active Mount Points" --msgbox "Currently active mount points:\n\n$active_mounts\nUseful commands:\n- sudo -u $original_user bash\n- sudo chmod -R 755 /mount/path\n- sudo chown -R $original_user:$original_user /mount/path" 20 80
    else
        whiptail --msgbox "No active mount points found at the moment." 8 50
    fi
}

# Function to fix permissions of existing mounts
fix_mount_permissions() {
    local original_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
    local original_uid=${SUDO_UID:-$(id -u "$original_user" 2>/dev/null)}
    local original_gid=${SUDO_GID:-$(id -g "$original_user" 2>/dev/null)}
    
    if [ ${#MOUNTED_PATHS[@]} -eq 0 ]; then
        whiptail --msgbox "No active mount points found." 8 50
        return 1
    fi
    
    # Select the mount point to fix
    local mount_items=()
    local counter=1
    
    for mount_point in "${MOUNTED_PATHS[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            mount_items+=("$counter" "$mount_point")
            ((counter++))
        fi
    done
    
    if [ ${#mount_items[@]} -eq 0 ]; then
        whiptail --msgbox "No active mount points." 8 50
        return 1
    fi
    
    mount_items+=("$counter" "All mount points")
    local all_option=$counter
    
    local choice=$(whiptail --title "Fix Permissions" --menu "Which mount point to fix?" 15 70 8 "${mount_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local target_mounts=()
    
    if [ "$choice" -eq "$all_option" ]; then
        target_mounts=("${MOUNTED_PATHS[@]}")
    else
        # Find the selected mount point
        local current_counter=1
        for mount_point in "${MOUNTED_PATHS[@]}"; do
            if mountpoint -q "$mount_point" 2>/dev/null && [ "$choice" -eq "$current_counter" ]; then
                target_mounts=("$mount_point")
                break
            fi
            ((current_counter++))
        done
    fi
    
    # Apply fixes
    local fixed_count=0
    for mount_point in "${target_mounts[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            (
                echo 0
                echo "# Fixing permissions for $mount_point..."
                timeout 30 chmod -R 755 "$mount_point" 2>/dev/null || true
                if [ -n "$original_uid" ] && [ -n "$original_gid" ]; then
                    timeout 30 chown -R "$original_uid:$original_gid" "$mount_point" 2>/dev/null || true
                fi
                echo 100
                echo "# Permissions fixed!"
                sleep 1
            ) | whiptail --gauge "Fixing permissions..." 8 50 0
            ((fixed_count++))
            log "Fixed permissions for $mount_point"
        fi
    done
    
    whiptail --msgbox "Permissions fixed for $fixed_count mount points.\n\nUser: $original_user\n\nNow you can try:\ncd $mount_point\nls -la $mount_point" 12 70
}

# Main menu
main_menu() {
    local file=$1
    local current_file="$file"

    while true; do
        local status_info=""
        
        # Add info about active QEMU processes
        if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
            status_info="🟢 QEMU active (PID: $QEMU_PID)"
        fi
        
        local menu_items=(
            "1" "🖼️ Change Image"
            "2" "📏 Resize Image"
            "3" "🗂️ Safe Mount (guestmount)"
            "4" "💾 Advanced Mount (NBD)"
            "5" "🔍 Analyze Structure"
            "6" "🚀 Test with QEMU"
            "7" "🔧 Launch GParted Live"
            "8" "ℹ️ File Information"
            "9" "🧹 Manual Cleanup"
            "10" "📋 Active Mount Points"
            "11" "🚪 Exit"
        )
        
        local menu_text="File: $(basename "$current_file")"
        if [ -n "$status_info" ]; then
            menu_text="$menu_text\n$status_info"
        fi
        menu_text="$menu_text\n\nWhat would you like to do?"
        
        local choice=$(whiptail --title "$SCRIPT_NAME" --menu "$menu_text" 20 70 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)
        
        case $choice in
            1)
                # Cleanup before changing file
                cleanup
                
                local new_file=$(select_file)
                if [ $? -eq 0 ] && [ -f "$new_file" ]; then
                    current_file="$new_file"
                    CLEANUP_DONE=false
                    NBD_DEVICE=""
                    MOUNTED_PATHS=()
                    LUKS_MAPPED=()
                    LVM_ACTIVE=()
                    VG_DEACTIVATED=()
                    QEMU_PID=""
                else
                    whiptail --msgbox "Selection cancelled. Staying on the current image." 8 60
                fi
                ;;
            2)
                local size=$(get_size)
                if [ $? -eq 0 ] && [ -n "$size" ]; then
                    if whiptail --title "Confirmation" --yesno "Resize to $size?\n\nWARNING: This operation is irreversible!\nMake sure you have a backup." 12 70; then
                        advanced_resize "$current_file" "$size"
                    fi
                fi
                ;;
            3)
                mount_with_guestmount "$current_file"
                ;;
            4)
                mount_with_nbd "$current_file"
                ;;
            5)
                local format=$(qemu-img info "$current_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
                [ -z "$format" ] && format="raw"
                
                if connect_nbd "$current_file" "$format"; then
                    local analysis=$(analyze_partitions "$NBD_DEVICE")
                    local luks_parts=($(detect_luks "$NBD_DEVICE"))
                    local luks_info=""
                    
                    if [ ${#luks_parts[@]} -gt 0 ]; then
                        luks_info="\n\n=== LUKS PARTITIONS ===\n"
                        for part in "${luks_parts[@]}"; do
                            luks_info="$luks_info$(basename "$part")\n"
                        done
                    fi
                    
                    safe_nbd_disconnect "$NBD_DEVICE"
                    NBD_DEVICE=""
                    
                    whiptail --title "Structure Analysis" --msgbox "$analysis$luks_info" 20 80
                else
                    whiptail --msgbox "Error analyzing the file." 8 50
                fi
                ;;
            6)
                test_vm_qemu "$current_file"
                ;;
            7)
                gparted_boot "$current_file"
                ;;
            8)
                local info=$(qemu-img info "$current_file" 2>/dev/null || echo "Could not read image information")
                local size=$(du -h "$current_file" 2>/dev/null | cut -f1 || echo "?")
                local format=$(echo "$info" | grep "file format:" | awk '{print $3}' || echo "Unknown")
                
                whiptail --title "File Information" --msgbox "File: $(basename "$current_file")\nFull path: $current_file\nSize on disk: $size\nFormat: $format\n\n=== qemu-img Details ===\n$info" 20 90
                ;;
            9)
                # Manual cleanup
                cleanup
                whiptail --msgbox "Manual cleanup completed." 8 50
                ;;
            10)
                # Display active mounts
                show_active_mounts
                ;;
            11|"")
                break
                ;;
        esac
    done
}

# Main script
if [ "$EUID" -ne 0 ]; then
    whiptail --title "Root Privileges Required" --msgbox "This script must be run as root.\n\nRun with: sudo $0" 10 60
    exit 1
fi

whiptail --title "$SCRIPT_NAME" --msgbox "WARNING: This script performs advanced operations on disk images.\n\nThese operations carry the risk of data loss.\n\nYou are solely responsible for any damage or data loss that may occur.\n\nALWAYS BACK UP YOUR DISK IMAGES BEFORE USING THIS SCRIPT.\n\nUSE AT YOUR OWN RISK." 15 70

echo "Checking dependencies..."
check_and_install_dependencies

echo "Starting interface..."
file=$(select_file)

if [ $? -ne 0 ] || [ ! -f "$file" ]; then
    whiptail --msgbox "No file selected or file not found. Exiting." 8 50
    exit 1
fi

main_menu "$file"

echo "Script terminated."
