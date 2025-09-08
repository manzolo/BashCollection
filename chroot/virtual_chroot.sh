#!/bin/bash

# Script to mount virtual disk images and chroot
# Supports vhd, qcow2, img, raw, vmdk

set -e

# Global variables
NBD_DEVICE=""
MOUNT_POINTS=()
BIND_MOUNTS=()
CHROOT_DIR=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Cleanup function on exit or error
cleanup() {
    log "Performing cleanup..."
    
    # Unmount bind mounts in reverse order
    for ((i=${#BIND_MOUNTS[@]}-1; i>=0; i--)); do
        local mount_point="${BIND_MOUNTS[i]}"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting bind mount: $mount_point"
            sudo umount "$mount_point" || warning "Error unmounting $mount_point"
        fi
    done
    
    # Unmount mount points in reverse order
    for ((i=${#MOUNT_POINTS[@]}-1; i>=0; i--)); do
        local mount_point="${MOUNT_POINTS[i]}"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting: $mount_point"
            sudo umount "$mount_point" || warning "Error unmounting $mount_point"
        fi
    done
    
    # Remove temporary directories
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if [[ "$mount_point" == /tmp/disk_mount_* ]]; then
            log "Removing directory: $mount_point"
            rmdir "$mount_point" 2>/dev/null || true
        fi
    done
    
    # Disconnect NBD
    if [[ -n "$NBD_DEVICE" ]]; then
        log "Disconnecting NBD device: $NBD_DEVICE"
        sudo qemu-nbd -d "$NBD_DEVICE" || warning "Error disconnecting $NBD_DEVICE"
    fi
    
    success "Cleanup complete"
}

# Trap for automatic cleanup
trap cleanup EXIT INT TERM

# Check dependencies
check_dependencies() {
    local deps=("qemu-nbd" "fdisk" "lsblk" "file" "dialog")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "Missing dependency: $dep"
            exit 1
        fi
    done
    
    # Check for nbd module
    if ! lsmod | grep -q nbd; then
        log "Loading nbd module..."
        sudo modprobe nbd max_part=16 || {
            error "Cannot load nbd module"
            exit 1
        }
    fi
}

# Find an available NBD device
find_available_nbd() {
    for i in {0..15}; do
        local nbd_dev="/dev/nbd$i"
        if [[ -e "$nbd_dev" ]]; then
            if ! sudo qemu-nbd -c -d "$nbd_dev" 2>/dev/null; then
                NBD_DEVICE="$nbd_dev"
                log "Available NBD device found: $NBD_DEVICE"
                return 0
            fi
        fi
    done
    
    error "No NBD device available"
    return 1
}

# Connect image to NBD
connect_nbd() {
    local image_file="$1"
    
    log "Connecting $image_file to $NBD_DEVICE..."
    
    local file_type=$(file "$image_file")
    local format=""
    
    if [[ "$image_file" == *.vhd ]]; then
        format="vpc"
    elif [[ "$file_type" == *"QEMU QCOW"* ]]; then
        format="qcow2"
    elif [[ "$file_type" == *"VDI disk image"* ]]; then
        format="vdi"
    elif [[ "$image_file" == *.img ]] || [[ "$image_file" == *.raw ]]; then
        format="raw"
    elif [[ "$image_file" == *.vmdk ]]; then
        format="vmdk"
    else
        format="raw"
    fi
    
    log "Format detected: $format"
    
    sudo qemu-nbd -c "$NBD_DEVICE" -f "$format" "$image_file"
    
    sleep 2
    sudo partprobe "$NBD_DEVICE" 2>/dev/null || true
    sleep 1
}

# Show available partitions
show_partitions() {
    log "Partitions found:"
    
    sudo fdisk -l "$NBD_DEVICE" | grep "^$NBD_DEVICE"
    
    echo ""
    log "Filesystem details:"
    
    for part in "$NBD_DEVICE"p*; do
        if [[ -e "$part" ]]; then
            local fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null || echo "unknown")
            local label=$(sudo blkid -o value -s LABEL "$part" 2>/dev/null || echo "")
            local size=$(lsblk -no SIZE "$part" 2>/dev/null || echo "unknown")
            
            echo "  $part: $fs_type, Size: $size, Label: $label"
        fi
    done
}

# Detect Linux and EFI partitions
detect_partitions() {
    local linux_part=""
    local efi_part=""
    
    for part in "$NBD_DEVICE"p*; do
        if [[ -e "$part" ]]; then
            local fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null)
            
            case "$fs_type" in
                "ext4"|"ext3"|"ext2"|"btrfs"|"xfs")
                    linux_part="$part"
                    ;;
                "vfat")
                    local part_type=$(sudo blkid -o value -s PTTYPE "$NBD_DEVICE" 2>/dev/null)
                    if [[ "$part_type" == "gpt" ]]; then
                        local gpt_type=$(sudo sgdisk -i "${part##*p}" "$NBD_DEVICE" 2>/dev/null | grep "Partition GUID code" | cut -d' ' -f4)
                        if [[ "$gpt_type" == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ]] || 
                           [[ "$gpt_type" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
                            efi_part="$part"
                        fi
                    else
                        local size_mb=$(lsblk -bno SIZE "$part" 2>/dev/null | awk '{print int($1/1024/1024)}')
                        if [[ $size_mb -lt 1000 ]]; then
                            efi_part="$part"
                        fi
                    fi
                    ;;
            esac
        fi
    done
    
    echo "$linux_part|$efi_part"
}

# Mount partition
mount_partition() {
    local partition="$1"
    local mount_point="$2"
    local fs_type="$3"
    
    log "Mounting $partition to $mount_point (type: $fs_type)"
    
    mkdir -p "$mount_point"
    
    case "$fs_type" in
        "vfat")
            sudo mount -t vfat "$partition" "$mount_point"
            ;;
        *)
            sudo mount "$partition" "$mount_point"
            ;;
    esac
    
    MOUNT_POINTS+=("$mount_point")
}

# Setup bind mounts for chroot
setup_bind_mounts() {
    local chroot_dir="$1"
    
    local bind_dirs=("proc" "sys" "dev" "dev/pts")
    
    for dir in "${bind_dirs[@]}"; do
        local target="$chroot_dir/$dir"
        mkdir -p "$target"
        
        log "Bind mounting: /$dir -> $target"
        
        case "$dir" in
            "proc")
                sudo mount -t proc proc "$target"
                ;;
            "sys")
                sudo mount -t sysfs sysfs "$target"
                ;;
            "dev")
                sudo mount --bind /dev "$target"
                ;;
            "dev/pts")
                sudo mount --bind /dev/pts "$target"
                ;;
        esac
        
        BIND_MOUNTS+=("$target")
    done
}

# Enter chroot
enter_chroot() {
    local chroot_dir="$1"
    local efi_mount="$2"
    
    CHROOT_DIR="$chroot_dir"
    
    if [[ -n "$efi_mount" ]]; then
        local efi_target="$chroot_dir/boot/efi"
        if [[ -d "$efi_target" ]]; then
            log "Mounting EFI partition to $efi_target"
            sudo mount "$efi_mount" "$efi_target"
            MOUNT_POINTS+=("$efi_target")
        else
            warning "/boot/efi directory not found in chroot, skipping EFI mount"
        fi
    fi
    
    setup_bind_mounts "$chroot_dir"
    
    if [[ -f /etc/resolv.conf ]]; then
        sudo cp /etc/resolv.conf "$chroot_dir/etc/resolv.conf.backup" 2>/dev/null || true
        sudo cp /etc/resolv.conf "$chroot_dir/etc/resolv.conf"
    fi
    
    success "Chroot environment prepared"
    echo ""
    echo "Entering chroot... Use 'exit' to leave."
    echo "Chroot directory: $chroot_dir"
    echo ""
    
    sudo chroot "$chroot_dir" /bin/bash --login
    
    if [[ -f "$chroot_dir/etc/resolv.conf.backup" ]]; then
        sudo mv "$chroot_dir/etc/resolv.conf.backup" "$chroot_dir/etc/resolv.conf"
    fi
}

# Function to select image file with navigation
select_image_file() {
    local current_dir="$PWD"
    local selected=""
    
    while true; do
        # Build menu with directories, .. and image files
        local menu_items=()
        local index=1
        
        # Add ".." if not in the root directory
        if [[ "$current_dir" != "/" ]]; then
            menu_items+=(".." "Go to parent directory")
        fi
        
        # Find directories and image files in the current directory
        while IFS= read -r -d '' item; do
            local name=$(basename "$item")
            if [[ -d "$item" ]]; then
                # Add icon for directories
                menu_items+=("📁 $name" "Directory")
            elif [[ "$name" == *.vhd || "$name" == *.qcow2 || "$name" == *.img || "$name" == *.raw || "$name" == *.vmdk ]]; then
                # Add icon for image files (floppy disk)
                menu_items+=("💾 $name" "Disk image")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type d,f -not -path "$current_dir" -print0 | sort -z)
        
        if [[ ${#menu_items[@]} -eq 0 ]]; then
            error "No image files or directories found in $current_dir"
            return 1
        fi
        
        # Show menu with dialog
        selected=$(dialog --title "Select image file or directory in $current_dir" --menu "Choose an option:" 20 60 12 "${menu_items[@]}" 2>&1 >/dev/tty)
        local dialog_status=$?
        
        if [[ $dialog_status -ne 0 ]]; then
            error "Selection canceled by user."
            return 1
        fi
        
        # Handle selection (remove the icon from the selected name)
        local raw_name=$(echo "$selected" | sed 's/^.\ //')
        
        if [[ "$selected" == ".." ]]; then
            current_dir=$(dirname "$current_dir")
        elif [[ -d "$current_dir/$raw_name" ]]; then
            current_dir="$current_dir/$raw_name"
        elif [[ -f "$current_dir/$raw_name" ]]; then
            # Check if it's a valid image file
            case "$raw_name" in
                *.vhd|*.qcow2|*.img|*.raw|*.vmdk)
                    echo "$current_dir/$raw_name"
                    return 0
                    ;;
                *)
                    error "The selected file is not a valid image (.vhd, .qcow2, .img, .raw, .vmdk)."
                    ;;
            esac
        fi
    done
}

# Main function
main() {
    log "Script for mounting and chrooting virtual disk images"
    echo ""

    local image_file="$1"

    # If no parameter is provided, use select_image_file to navigate
    if [[ -z "$image_file" ]]; then
        if ! command -v dialog &> /dev/null; then
            error "Dialog is not installed. Please install dialog or specify the file as an argument."
            exit 1
        fi
        log "No image file specified. Opening file selection menu..."
        
        image_file=$(select_image_file)
        if [[ $? -ne 0 ]]; then
            exit 1
        fi
    fi

    if [[ ! -f "$image_file" ]]; then
        error "File not found: $image_file"
        exit 1
    fi
    
    log "Selected image file: $image_file"
    
    check_dependencies
    find_available_nbd
    connect_nbd "$image_file"
    show_partitions
    local partitions
    partitions=$(detect_partitions)
    local linux_part=$(echo "$partitions" | cut -d'|' -f1)
    local efi_part=$(echo "$partitions" | cut -d'|' -f2)
    
    if [[ -z "$linux_part" ]]; then
        error "No Linux partition (ext4, ext3, ext2, btrfs, xfs) found"
        exit 1
    fi
    
    log "Linux partition found: $linux_part"
    [[ -n "$efi_part" ]] && log "EFI partition found: $efi_part"
    
    local linux_fs=$(sudo blkid -o value -s TYPE "$linux_part")
    local linux_mount="/tmp/disk_mount_$(date +%s)"
    mount_partition "$linux_part" "$linux_mount" "$linux_fs"
    
    if [[ ! -d "$linux_mount/etc" ]] || [[ ! -d "$linux_mount/bin" ]] && [[ ! -d "$linux_mount/usr/bin" ]]; then
        error "Does not appear to be a valid Linux system (missing /etc or /bin)"
        exit 1
    fi
    
    success "Linux system mounted in: $linux_mount"
    
    enter_chroot "$linux_mount" "$efi_part"
}

# Run script
main "$@"