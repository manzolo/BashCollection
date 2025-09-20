#!/bin/bash

# Manzolo Disk Cloner v2.4 - With Dry Run Support

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# -------------------- DRY RUN SUPPORT --------------------
DRY_RUN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|-n)
            DRY_RUN=true
            echo -e "${CYAN}🧪 DRY RUN MODE ENABLED - No destructive operations will be performed${NC}"
            shift
            ;;
        --help|-h)
            echo "Manzolo Disk Cloner v2.4"
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run, -n    Enable dry run mode (log commands without executing)"
            echo "  --help, -h       Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script requires root privileges${NC}"
    echo "Run with: sudo $0"
    exit 1
fi

# -------------------- LOGGING SETUP --------------------
LOGFILE="/var/log/clone_script.log"
if ! touch "$LOGFILE" 2>/dev/null; then
    LOGFILE="$(pwd)/clone_script.log"
fi
chmod 600 "$LOGFILE" 2>/dev/null || true

# Preserve original terminal fds
exec 3>&1 4>&2

log() {
    local ts
    ts="$(date '+%F %T')"
    printf '%s %s\n' "$ts" "$*" | tee -a "$LOGFILE" >&3
}

# 1. Improved error handling and logging
log_with_level() {
    local level="$1"
    shift
    local message="$*"
    local ts="$(date '+%F %T')"
    
    case "$level" in
        ERROR)
            printf '%s [ERROR] %s\n' "$ts" "$message" | tee -a "$LOGFILE" >&3
            ;;
        WARN)
            printf '%s [WARN]  %s\n' "$ts" "$message" | tee -a "$LOGFILE" >&3
            ;;
        INFO)
            printf '%s [INFO]  %s\n' "$ts" "$message" | tee -a "$LOGFILE" >&3
            ;;
        DEBUG)
            if [ "${DEBUG:-false}" = true ]; then
                printf '%s [DEBUG] %s\n' "$ts" "$message" | tee -a "$LOGFILE" >&3
            fi
            ;;
    esac
}

# 2. Better device size calculation with alignment
calculate_aligned_size() {
    local size="$1"
    local alignment="${2:-1048576}"  # Default 1MB alignment
    
    # Round up to nearest alignment boundary
    local aligned_size=$(( (size + alignment - 1) / alignment * alignment ))
    echo "$aligned_size"
}

# 3. Enhanced filesystem detection with multiple methods
detect_filesystem_robust() {
    local partition="$1"
    local fs_type=""
    
    # Method 1: lsblk
    fs_type=$(lsblk -no FSTYPE "$partition" 2>/dev/null | head -1)
    if [ -n "$fs_type" ] && [ "$fs_type" != "" ]; then
        echo "$fs_type"
        return 0
    fi
    
    # Method 2: blkid
    fs_type=$(blkid -o value -s TYPE "$partition" 2>/dev/null | head -1)
    if [ -n "$fs_type" ] && [ "$fs_type" != "" ]; then
        echo "$fs_type"
        return 0
    fi
    
    # Method 3: file command
    local file_output=$(file -s "$partition" 2>/dev/null)
    case "$file_output" in
        *"ext2 filesystem"*) echo "ext2" ;;
        *"ext3 filesystem"*) echo "ext3" ;;
        *"ext4 filesystem"*) echo "ext4" ;;
        *"NTFS"*) echo "ntfs" ;;
        *"FAT"*) echo "vfat" ;;
        *"XFS"*) echo "xfs" ;;
        *"Btrfs"*) echo "btrfs" ;;
        *"LUKS"*) echo "crypto_LUKS" ;;
        *"swap"*) echo "swap" ;;
        *) echo "" ;;
    esac
}

# 4. Improved progress monitoring
show_progress() {
    local operation="$1"
    local current="$2"
    local total="$3"
    
    if [ "$total" -gt 0 ]; then
        local percent=$((current * 100 / total))
        local progress_bar=""
        local filled=$((percent / 2))
        local empty=$((50 - filled))
        
        for i in $(seq 1 $filled); do progress_bar+="█"; done
        for i in $(seq 1 $empty); do progress_bar+="░"; done
        
        printf '\r%s: [%s] %d%% (%s/%s)' \
            "$operation" "$progress_bar" "$percent" \
            "$(numfmt --to=iec --suffix=B $current)" \
            "$(numfmt --to=iec --suffix=B $total)"
    fi
}

# 5. Better cleanup function
cleanup_resources() {
    log_with_level INFO "Cleaning up resources..."
    
    # Clean up loop devices
    for loop_dev in $(losetup -a | grep "$TEMP_PREFIX" | cut -d: -f1); do
        if [ -b "$loop_dev" ]; then
            log_with_level DEBUG "Detaching loop device: $loop_dev"
            if command -v kpartx >/dev/null 2>&1; then
                kpartx -dv "$loop_dev" 2>/dev/null || true
            fi
            losetup -d "$loop_dev" 2>/dev/null || true
        fi
    done
    
    # Clean up temporary files
    if [ -n "$TEMP_PREFIX" ]; then
        rm -f "${TEMP_PREFIX}"* 2>/dev/null || true
    fi
    
    # Sync filesystem
    sync 2>/dev/null || true
}

# 6. Enhanced error recovery for cloning operations
clone_with_retry() {
    local source="$1"
    local dest="$2"
    local block_size="${3:-4M}"
    local max_retries="${4:-3}"
    
    local attempt=1
    while [ $attempt -le $max_retries ]; do
        log_with_level INFO "Clone attempt $attempt of $max_retries"
        
        if [ "$DRY_RUN" = true ]; then
            log_with_level INFO "🧪 DRY RUN - Would clone: $source -> $dest (bs=$block_size)"
            return 0
        fi
        
        # Try different block sizes on retry
        local current_bs="$block_size"
        if [ $attempt -eq 2 ]; then
            current_bs="1M"
        elif [ $attempt -eq 3 ]; then
            current_bs="512K"
        fi
        
        if command -v pv >/dev/null 2>&1; then
            if pv "$source" | dd of="$dest" bs="$current_bs" conv=notrunc,noerror 2>/dev/null; then
                log_with_level INFO "✓ Clone successful on attempt $attempt"
                return 0
            fi
        else
            if dd if="$source" of="$dest" bs="$current_bs" status=progress conv=notrunc,noerror 2>/dev/null; then
                log_with_level INFO "✓ Clone successful on attempt $attempt"
                return 0
            fi
        fi
        
        log_with_level WARN "Clone attempt $attempt failed, retrying with smaller block size..."
        attempt=$((attempt + 1))
        sleep 2
    done
    
    log_with_level ERROR "All clone attempts failed"
    return 1
}

# 7. Improved device validation
validate_device_safety() {
    local device="$1"
    local operation="$2"  # "read" or "write"
    
    if [ ! -b "$device" ]; then
        log_with_level ERROR "Device $device is not a block device"
        return 1
    fi
    
    # Check if device exists and is accessible
    if ! blockdev --getsize64 "$device" >/dev/null 2>&1; then
        log_with_level ERROR "Cannot access device $device"
        return 1
    fi
    
    # For write operations, additional safety checks
    if [ "$operation" = "write" ]; then
        # Check if it's a system disk
        local root_device=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
        if [ "$device" = "$root_device" ]; then
            log_with_level ERROR "Cannot write to root device $device"
            return 1
        fi
        
        # Check if device is read-only
        if [ "$(blockdev --getro "$device" 2>/dev/null)" = "1" ]; then
            log_with_level ERROR "Device $device is read-only"
            return 1
        fi
        
        # Check for critical mounts
        if findmnt -n -o SOURCE | grep -q "^$device"; then
            local critical_mounts=$(findmnt -n -o SOURCE,TARGET | grep "^$device" | grep -E '/$|/boot|/home|/usr|/var')
            if [ -n "$critical_mounts" ]; then
                log_with_level WARN "Device contains critical system mounts:"
                echo "$critical_mounts" | while read line; do
                    log_with_level WARN "  $line"
                done
                return 1
            fi
        fi
    fi
    
    return 0
}

# 8. Better temporary file management
TEMP_PREFIX="/tmp/manzolo_clone_$$"

create_temp_file() {
    local suffix="$1"
    local temp_file="${TEMP_PREFIX}_${suffix}"
    
    if [ "$DRY_RUN" = true ]; then
        echo "$temp_file"
        return 0
    fi
    
    # Create with secure permissions
    touch "$temp_file" && chmod 600 "$temp_file"
    echo "$temp_file"
}

# Set trap for cleanup
trap cleanup_resources EXIT INT TERM

# Enhanced run_log function with dry-run support
run_log() {
    if [ $# -eq 0 ]; then return 1; fi
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would execute: $*"
        return 0
    fi
    
    if [ $# -eq 1 ]; then
        bash -c "set -o pipefail; $1" > >(tee -a "$LOGFILE" >&3) 2> >(tee -a "$LOGFILE" >&4)
        return $?
    else
        "$@" > >(tee -a "$LOGFILE" >&3) 2> >(tee -a "$LOGFILE" >&4)
        return $?
    fi
}

# New function for dry-run aware command execution
dry_run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would execute: $*"
        return 0
    else
        log "Executing: $*"
        "$@"
        return $?
    fi
}

log "=============================="
if [ "$DRY_RUN" = true ]; then
    log "🧪 Clone Script v2.4 - DRY RUN MODE - started at $(date)"
else
    log "🚀 Clone Script v2.4 - started at $(date)"
fi
log "Logfile: $LOGFILE"
log "=============================="

# -------------------- DEPENDENCY CHECK --------------------
for cmd in qemu-img dialog lsblk blockdev dd pv parted; do
    if ! command -v $cmd &> /dev/null; then
        log "Error: $cmd not found!"
        case $cmd in
            pv)
                echo "Install with: sudo apt-get install pv"
                ;;
            parted)
                echo "Install with: sudo apt-get install parted"
                ;;
            *)
                echo "Install with: sudo apt-get install qemu-utils dialog"
                ;;
        esac
        exit 1
    fi
done

# Check for GPT tools
if ! command -v sgdisk &> /dev/null; then
    log "Warning: sgdisk not found - GPT optimization disabled"
    log "For better GPT support, install with: sudo apt-get install gdisk"
    GPT_SUPPORT=false
else
    GPT_SUPPORT=true
    log "✅ GPT support enabled"
fi

check_partclone_tools() {
    local partclone_found=false
    local available_tools=()
    
    for tool in partclone.ext4 partclone.ext3 partclone.ext2 partclone.ntfs partclone.vfat partclone.btrfs partclone.xfs; do
        if command -v $tool &> /dev/null; then
            partclone_found=true
            available_tools+=("$tool")
        fi
    done
    
    if [ "$partclone_found" = false ]; then
        log "Warning: No partclone tools found!"
        log "For optimal cloning, install with: sudo apt-get install partclone"
        log "The script will work with basic dd cloning."
        sleep 2
    else
        log "✓ Partclone tools found: ${available_tools[*]}"
    fi
}

check_partclone_tools

# Check UUID preservation tools
check_uuid_tools() {
    local missing_uuid_tools=()
    
    command -v sgdisk &> /dev/null || missing_uuid_tools+=("gdisk")
    command -v e2image &> /dev/null || missing_uuid_tools+=("e2fsprogs")
    command -v ntfsclone &> /dev/null || missing_uuid_tools+=("ntfs-3g")
    command -v tune2fs &> /dev/null || missing_uuid_tools+=("e2fsprogs")
    command -v xfs_admin &> /dev/null || missing_uuid_tools+=("xfsprogs")
    
    if [ ${#missing_uuid_tools[@]} -gt 0 ]; then
        log "Optional UUID tools not found: ${missing_uuid_tools[*]}"
        log "For complete UUID preservation, install: sudo apt-get install gdisk e2fsprogs ntfs-3g xfsprogs dosfstools mtools"
        UUID_SUPPORT="partial"
    else
        log "✅ Full UUID preservation support available"
        UUID_SUPPORT="full"
    fi
}

check_uuid_tools

# -------------------- SAFETY FUNCTIONS (enhanced with dry-run) --------------------

safe_unmount_device_partitions() {
    local device="$1"
    log "Safely unmounting partitions on $device..."
    
    local unmounted_any=false
    
    while IFS= read -r partition; do
        if [ -b "/dev/$partition" ]; then
            local mount_point=$(findmnt -n -o TARGET "/dev/$partition" 2>/dev/null)
            if [ -n "$mount_point" ]; then
                case "$mount_point" in
                    /|/proc|/sys|/dev|/run|/boot|/boot/efi)
                        log "  Skipping critical system mount: /dev/$partition -> $mount_point"
                        continue
                        ;;
                esac
                
                log "  Unmounting /dev/$partition from $mount_point..."
                if [ "$DRY_RUN" = true ]; then
                    log "  🧪 DRY RUN - Would unmount: /dev/$partition"
                    unmounted_any=true
                elif umount "/dev/$partition" 2>/dev/null; then
                    log "    ✓ Successfully unmounted /dev/$partition"
                    unmounted_any=true
                elif umount -l "/dev/$partition" 2>/dev/null; then
                    log "    ✓ Lazy unmount successful for /dev/$partition"
                    unmounted_any=true
                else
                    log "    ⚠ Failed to unmount /dev/$partition"
                fi
            fi
        fi
    done < <(lsblk -ln -o NAME "$device" | tail -n +2)
    
    if [ "$unmounted_any" = true ]; then
        log "  Waiting 3 seconds for unmount operations to complete..."
        if [ "$DRY_RUN" = false ]; then
            sleep 3
            sync
        fi
    fi
    
    return 0
}

check_device_safety() {
    local device="$1"
    
    local root_device=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
    
    if [ "$device" = "$root_device" ]; then
        log "❌ CRITICAL: Cannot clone the device containing the root filesystem!"
        dialog --title "Critical Error" \
            --msgbox "ERROR: You cannot clone the device ($device) that contains the root filesystem!\n\nThis would destroy the running system.\n\nPlease select a different device." 12 70
        return 1
    fi
    
    if findmnt -n -o SOURCE | grep -q "^$device"; then
        local mounted_parts=$(findmnt -n -o SOURCE,TARGET | grep "^$device" | grep -E '/$|/boot|/home|/usr|/var')
        if [ -n "$mounted_parts" ]; then
            log "⚠ WARNING: Device contains critical system partitions:"
            log "$mounted_parts"
            
            if ! dialog --title "⚠️ WARNING ⚠️" \
                --yesno "The selected device contains mounted system partitions:\n\n$mounted_parts\n\nCloning this device is dangerous and may crash the system.\n\nDo you want to continue anyway?" 14 70; then
                return 1
            fi
        fi
    fi
    
    return 0
}

# -------------------- FILE BROWSER (unchanged from original) --------------------

SELECTED_FILE=""
SELECTED_TYPE="file"
SHOW_HIDDEN=false

get_directory_content() {
    local dir="$1"
    local items=()
    
    [[ "$dir" != "/" ]] && items+=(".." "[Parent Directory]")
    
    local ls_opts="-1"
    $SHOW_HIDDEN && ls_opts="${ls_opts}a"
    
    while IFS= read -r item; do
        [[ "$item" = "." || "$item" = ".." ]] && continue
        local full_path="$dir/$item"
        if [[ -d "$full_path" ]]; then
            local count=$(ls -1 "$full_path" 2>/dev/null | wc -l)
            items+=("$item/" "📁 Dir ($count items)")
        elif [[ -f "$full_path" ]]; then
            local size=$(du -h "$full_path" 2>/dev/null | cut -f1)
            local icon="📄"
            case "${item##*.}" in
                txt|md|log) icon="📝" ;;
                pdf) icon="📕" ;;
                jpg|jpeg|png|gif|bmp) icon="🖼️" ;;
                mp3|wav|ogg|flac) icon="🎵" ;;
                mp4|avi|mkv|mov) icon="🎬" ;;
                zip|tar|gz|7z|rar) icon="📦" ;;
                sh|bash) icon="⚙️" ;;
                py) icon="🐍" ;;
                js|ts) icon="📜" ;;
                html|htm) icon="🌐" ;;
                img|vhd|vhdx|qcow2|vmdk|raw|vpc) icon="📼" ;;
                iso) icon="💿" ;;
            esac
            items+=("$item" "$icon File ($size)")
        elif [[ -L "$full_path" ]]; then
            local target=$(readlink "$full_path")
            items+=("$item@" "🔗 Link → $target")
        else
            items+=("$item" "❓ Special")
        fi
    done < <(ls $ls_opts "$dir" 2>/dev/null)
    
    printf '%s\n' "${items[@]}"
}

show_file_browser() {
    local current="$1"
    local select_type="${2:-file}"
    
    current=$(realpath "$current" 2>/dev/null || echo "$current")
    
    local content=$(get_directory_content "$current")
    [[ -z "$content" ]] && { 
        dialog --title "Error" --msgbox "Directory empty or not accessible: $current" 8 60
        return 2
    }

    local menu_items=()
    while IFS= read -r line; do 
        [[ -n "$line" ]] && menu_items+=("$line")
    done <<< "$content"

    local height=20
    local width=70
    local menu_height=12
    local display_path="$current"
    [ ${#display_path} -gt 50 ] && display_path="...${display_path: -47}"

    local instruction_msg=""
    if [ "$select_type" = "dir" ]; then
        instruction_msg="Select a directory or navigate with folders"
        [ "$current" != "/" ] && menu_items+=("." "📍 [Select this directory]")
    else
        instruction_msg="Select a file or navigate directories"
    fi

    local selected
    selected=$(dialog --title "📂 File Browser" \
        --menu "$instruction_msg\n\n📍 $display_path" \
        $height $width $menu_height \
        "${menu_items[@]}" 2>&1 >/dev/tty)
    
    local exit_status=$?

    if [ $exit_status -eq 0 ] && [ -n "$selected" ]; then
        local clean_name="${selected%/}"
        clean_name="${clean_name%@}"
        
        if [ "$selected" = ".." ]; then
            show_file_browser "$(dirname "$current")" "$select_type"
            return $?
        elif [ "$selected" = "." ]; then
            SELECTED_FILE="$current"
            return 0
        elif [[ "$selected" =~ /$ ]]; then
            show_file_browser "$current/$clean_name" "$select_type"
            return $?
        else
            if [ "$select_type" = "dir" ]; then
                dialog --title "Warning" --msgbox "Please select a directory, not a file!" 8 50
                show_file_browser "$current" "$select_type"
                return $?
            else
                SELECTED_FILE="$current/$clean_name"
                return 0
            fi
        fi
    else
        return 1
    fi
}

select_file() {
    local title="$1"
    local start_dir="${2:-$(pwd)}"
    
    SELECTED_FILE=""
    echo -e "${YELLOW}$title${NC}" >&2
    
    show_file_browser "$start_dir" "file"
    
    if [ $? -eq 0 ] && [ -n "$SELECTED_FILE" ]; then
        echo "$SELECTED_FILE"
        return 0
    fi
    return 1
}

select_directory() {
    local title="$1"
    local start_dir="${2:-$(pwd)}"
    
    SELECTED_FILE=""
    echo -e "${YELLOW}$title${NC}" >&2
    
    show_file_browser "$start_dir" "dir"
    
    if [ $? -eq 0 ] && [ -n "$SELECTED_FILE" ]; then
        echo "$SELECTED_FILE"
        return 0
    fi
    return 1
}

# -------------------- FILESYSTEM FUNCTIONS (enhanced with dry-run) --------------------

is_filesystem_supported() {
    local partition="$1"
    local fs_type=$(lsblk -no FSTYPE "$partition" 2>/dev/null)
    
    case "$fs_type" in
        ext2|ext3|ext4|ntfs|fat32|fat16|vfat|btrfs|xfs)
            echo "yes"
            ;;
        *)
            echo "no"
            ;;
    esac
}

get_filesystem_type() {
    local partition="$1"
    lsblk -no FSTYPE "$partition" 2>/dev/null
}

get_filesystem_used_space() {
    local partition="$1"
    local fs_type=$(get_filesystem_type "$partition")
    
    local temp_mount="/tmp/clone_check_$$"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would mount $partition to check used space"
        # Return a realistic estimate for dry run
        local part_size=$(blockdev --getsize64 "$partition" 2>/dev/null)
        echo $((part_size / 2))  # Assume 50% usage for dry run
        return
    fi
    
    mkdir -p "$temp_mount" 2>/dev/null
    
    if mount -o ro "$partition" "$temp_mount" 2>/dev/null; then
        local used=$(df -B1 "$temp_mount" | tail -1 | awk '{print $3}')
        umount "$temp_mount" 2>/dev/null
        rmdir "$temp_mount" 2>/dev/null
        echo "$used"
    else
        blockdev --getsize64 "$partition" 2>/dev/null
    fi
}

get_partition_table_type() {
    local device="$1"
    
    # First check with gdisk if available (most reliable for GPT)
    if command -v gdisk >/dev/null 2>&1; then
        local gdisk_output=$(echo 'p' | gdisk "$device" 2>/dev/null | head -20)
        if echo "$gdisk_output" | grep -qi "gpt\|guid partition table"; then
            echo "gpt"
            return
        fi
    fi
    
    # Check with parted
    local parted_output=$(parted "$device" print 2>/dev/null | head -10)
    if echo "$parted_output" | grep -qi "partition table: gpt"; then
        echo "gpt"
        return
    elif echo "$parted_output" | grep -qi "partition table: msdos\|partition table: dos"; then
        echo "mbr"
        return
    fi
    
    # Check with fdisk
    local fdisk_output=$(fdisk -l "$device" 2>/dev/null | head -10)
    if echo "$fdisk_output" | grep -qi "disklabel type: gpt"; then
        echo "gpt"
        return
    elif echo "$fdisk_output" | grep -qi "disklabel type: dos"; then
        echo "mbr"
        return
    fi
    
    # Binary check as fallback
    if dd if="$device" bs=1 count=8 skip=512 2>/dev/null | grep -q "EFI PART"; then
        echo "gpt"
    else
        echo "mbr"
    fi
}

copy_gpt_partition_table_safe() {
    local source_device="$1"
    local target_device="$2"
    
    log "Copying GPT partition table safely..."
    
    # Get actual device size to calculate backup GPT location correctly
    local device_size=$(blockdev --getsize64 "$source_device")
    local sector_size=512
    local total_sectors=$((device_size / sector_size))
    
    # Copy primary GPT (first 34 sectors)
    log "Copying primary GPT header and table..."
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would copy primary GPT: dd if='$source_device' of='$target_device' bs=512 count=34 conv=notrunc"
    else
        dd if="$source_device" of="$target_device" bs=512 count=34 conv=notrunc 2>/dev/null || {
            log "Error: Failed to copy primary GPT"
            return 1
        }
    fi
    
    # Instead of copying backup GPT directly, let sgdisk regenerate it
    log "Regenerating backup GPT header..."
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would regenerate backup GPT: sgdisk -e '$target_device'"
    else
        # Force regeneration of backup GPT
        sgdisk -e "$target_device" 2>/dev/null || {
            log "Warning: Could not regenerate backup GPT with sgdisk"
            # Fallback: use parted to fix the table
            parted "$target_device" --script print 2>/dev/null || true
        }
    fi
    
    # Verify the partition table
    log "Verifying GPT integrity..."
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would verify with: sgdisk -v '$target_device'"
    else
        if sgdisk -v "$target_device" >/dev/null 2>&1; then
            log "✓ GPT partition table is valid"
        else
            log "⚠ GPT partition table has issues, attempting repair..."
            sgdisk -e "$target_device" 2>/dev/null || true
        fi
    fi
    
    return 0
}

setup_loop_device_safe() {
    local image_file="$1"
    
    if [ "$DRY_RUN" = true ]; then
        echo "/dev/loop99"  # Return simulated loop device
        return 0
    fi
    
    # Ensure loop module is loaded
    modprobe loop 2>/dev/null || true
    
    # Find available loop device
    local loop_dev
    loop_dev=$(losetup -f 2>/dev/null)
    if [ -z "$loop_dev" ]; then
        log "Error: No free loop devices available"
        return 1
    fi
    
    # Setup loop device
    if losetup "$loop_dev" "$image_file" 2>/dev/null; then
        echo "$loop_dev"
        return 0
    else
        log "Error: Failed to setup loop device"
        return 1
    fi
}

setup_partition_mappings() {
    local loop_dev="$1"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would setup partition mappings for $loop_dev"
        return 0
    fi
    
    log "Setting up partition mappings..."
    
    # Try partprobe first
    partprobe "$loop_dev" 2>/dev/null || true
    sleep 2
    
    # Try kpartx if available
    if command -v kpartx >/dev/null 2>&1; then
        kpartx -av "$loop_dev" 2>/dev/null || true
    fi
    
    # Try partx as fallback
    if command -v partx >/dev/null 2>&1; then
        partx -a "$loop_dev" 2>/dev/null || true
    fi
    
    # Wait for devices to appear with timeout
    local timeout=10
    local count=0
    while [ $count -lt $timeout ]; do
        if ls "${loop_dev}"p* 2>/dev/null | head -1 >/dev/null; then
            log "✓ Partition mappings created successfully"
            return 0
        fi
        sleep 1
        count=$((count + 1))
        partprobe "$loop_dev" 2>/dev/null || true
    done
    
    log "⚠ Warning: Partition mappings may not be available"
    return 0  # Don't fail completely
}

repair_filesystem() {
    local partition="$1"
    local fs_type="$2"
    
    log "  Checking and repairing filesystem on $partition ($fs_type)..."
    
    case "$fs_type" in
        ext2|ext3|ext4)
            log "    Running e2fsck..."
            if [ "$DRY_RUN" = true ]; then
                log "    🧪 DRY RUN - Would run: e2fsck -f -p $partition"
                return 0
            elif e2fsck -f -p "$partition" 2>/dev/null; then
                log "      ✓ Filesystem check passed"
                return 0
            else
                log "      ⚠ Filesystem had errors, attempting repair..."
                if e2fsck -f -y "$partition" 2>/dev/null; then
                    log "      ✓ Filesystem repaired successfully"
                    return 0
                else
                    log "      ❌ Filesystem repair failed"
                    return 1
                fi
            fi
            ;;
        vfat|fat32|fat16)
            if command -v fsck.fat &> /dev/null; then
                log "    Running fsck.fat..."
                if [ "$DRY_RUN" = true ]; then
                    log "    🧪 DRY RUN - Would run: fsck.fat -a $partition"
                    return 0
                elif fsck.fat -a "$partition" 2>/dev/null; then
                    log "      ✓ FAT filesystem check passed"
                    return 0
                else
                    log "      ⚠ FAT filesystem had issues"
                    return 1
                fi
            fi
            ;;
        ntfs)
            if command -v ntfsfix &> /dev/null; then
                log "    Running ntfsfix..."
                if [ "$DRY_RUN" = true ]; then
                    log "    🧪 DRY RUN - Would run: ntfsfix $partition"
                    return 0
                elif ntfsfix "$partition" 2>/dev/null; then
                    log "      ✓ NTFS check completed"
                    return 0
                else
                    log "      ⚠ NTFS check reported issues"
                    return 1
                fi
            fi
            ;;
        *)
            log "    No specific check available for $fs_type"
            return 0
            ;;
    esac
    
    return 0
}

create_sparse_image() {
    local file="$1"
    local size="$2"
    
    log "Creating sparse image of $(echo "scale=2; $size / 1073741824" | bc) GB..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would create sparse image: dd if=/dev/zero of='$file' bs=1 count=0 seek='$size'"
        return 0
    fi
    
    run_log dd if=/dev/zero of="$file" bs=1 count=0 seek="$size"
    
    return $?
}

analyze_device_usage() {
    local device="$1"
    local total_used=0
    local partition_info=""
    local can_optimize=true
    
    log "Analyzing device partitions and filesystems..."
    
    local pt_type=$(get_partition_table_type "$device")
    log "Partition table type: $pt_type"
    
    if [ "$pt_type" = "gpt" ]; then
        local table_size=$((2 * 1024 * 1024))
    else
        local table_size=$((512 * 1024))
    fi
    
    total_used=$table_size
    
    while IFS= read -r part; do
        if [ -b "/dev/$part" ]; then
            local fs_type=$(get_filesystem_type "/dev/$part")
            local part_size=$(blockdev --getsize64 "/dev/$part" 2>/dev/null)
            
            if [ -n "$fs_type" ] && [ "$fs_type" != "" ]; then
                local used_space=$(get_filesystem_used_space "/dev/$part")
                local used_gb=$(echo "scale=2; $used_space / 1073741824" | bc)
                local part_gb=$(echo "scale=2; $part_size / 1073741824" | bc)
                
                log "  /dev/$part: ${fs_type} - Used: ${used_gb}GB of ${part_gb}GB"
                partition_info="${partition_info}  /dev/$part: ${fs_type} - Used: ${used_gb}GB / Total: ${part_gb}GB\n"
                
                local part_with_overhead=$(echo "scale=0; $used_space * 1.1 / 1" | bc)
                total_used=$((total_used + part_with_overhead))
                
                if [ "$(is_filesystem_supported "/dev/$part")" = "no" ]; then
                    can_optimize=false
                    log "    Warning: $fs_type may not support optimization"
                fi
            else
                log "  /dev/$part: Unknown/No filesystem - Full size: $(echo "scale=2; $part_size / 1073741824" | bc)GB"
                total_used=$((total_used + part_size))
                can_optimize=false
            fi
        fi
    done < <(lsblk -ln -o NAME "$device" | tail -n +2)
    
    if [ "$total_used" -eq "$table_size" ]; then
        total_used=$(blockdev --getsize64 "$device" 2>/dev/null)
        partition_info="No partitions detected, using full disk size"
        can_optimize=false
    fi
    
    log ""
    log "Summary:"
    printf '%b' "$partition_info" | while read line; do log "$line"; done
    log "Total space needed (with overhead): $(echo "scale=2; $total_used / 1073741824" | bc)GB"
    
    if [ "$can_optimize" = true ]; then
        log "✓ Device can be optimized for space"
    else
        log "⚠ Some partitions cannot be optimized"
    fi
    
    echo "$total_used"
}

# -------------------- ENHANCED CLONING FROM V2.1 (enhanced with dry-run) --------------------

clone_physical_to_virtual_optimized() {
    local source_device="$1"
    local dest_file="$2"
    local dest_format="$3"
    
    log "Starting reliable cloning with filesystem preservation..."
    
    if ! validate_device_safety "$source_device" "read"; then
        return 1
    fi
    
    safe_unmount_device_partitions "$source_device"
    
    local temp_raw=$(create_temp_file "raw")
    local device_size=$(blockdev --getsize64 "$source_device")
    local pt_type=$(get_partition_table_type "$source_device")
    
    log "Device size: $((device_size / 1073741824)) GB"
    log "Partition table type: $pt_type"
    
    # Create temporary raw image with better error handling
    log "Creating temporary raw image..."
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would create temporary image: $temp_raw (size: $((device_size / 1073741824)) GB)"
    else
        if ! create_sparse_image "$temp_raw" "$device_size"; then
            log_with_level ERROR "Failed to create temporary image"
            return 1
        fi
    fi
    
    # Setup loop device with improved error handling
    local loop_dev
    if ! loop_dev=$(setup_loop_device_safe "$temp_raw"); then
        log_with_level ERROR "Failed to setup loop device"
        rm -f "$temp_raw"
        return 1
    fi
    
    log "Loop device: $loop_dev"
    
    # Copy partition table with improved GPT handling
    log "Copying partition table..."
    if [ "$pt_type" = "gpt" ]; then
        if ! copy_gpt_partition_table_safe "$source_device" "$loop_dev"; then
            log_with_level ERROR "Failed to copy GPT partition table"
            cleanup_resources
            return 1
        fi
    else
        # MBR partition table
        if [ "$DRY_RUN" = true ]; then
            log "🧪 DRY RUN - Would copy MBR: dd if='$source_device' of='$loop_dev' bs=512 count=1 conv=notrunc"
        else
            if ! dd if="$source_device" of="$loop_dev" bs=512 count=1 conv=notrunc 2>/dev/null; then
                log_with_level ERROR "Failed to copy MBR"
                cleanup_resources
                return 1
            fi
        fi
    fi
    
    # Setup partition mappings with improved error handling
    if ! setup_partition_mappings "$loop_dev"; then
        log_with_level WARN "Partition mappings failed, falling back to whole device copy"
        
        # Fallback to whole device copy
        log "Copying entire device..."
        if ! clone_with_retry "$source_device" "$loop_dev" "4M" 3; then
            log_with_level ERROR "Whole device copy failed"
            cleanup_resources
            return 1
        fi
    else
        # Partition-by-partition copy with improved error handling
        log "Found partition mappings, copying partition by partition..."
        
        local part_num=1
        local success_count=0
        local total_partitions=0
        
        while IFS= read -r source_part_name; do
            local source_part="/dev/$source_part_name"
            total_partitions=$((total_partitions + 1))
            
            # Find corresponding destination partition
            local dest_part=""
            for try_dest in "${loop_dev}p${part_num}" "/dev/mapper/$(basename $loop_dev)p${part_num}"; do
                if [ -b "$try_dest" ] || [ "$DRY_RUN" = true ]; then
                    dest_part="$try_dest"
                    break
                fi
            done
            
            if [ -z "$dest_part" ]; then
                log_with_level WARN "Cannot find destination partition for $source_part"
                part_num=$((part_num + 1))
                continue
            fi
            
            if [ -b "$source_part" ] && ([ -b "$dest_part" ] || [ "$DRY_RUN" = true ]); then
                local fs_type=$(detect_filesystem_robust "$source_part")
                
                log "Cloning partition $part_num: $source_part -> $dest_part"
                log "  Filesystem: ${fs_type:-unknown}"
                
                # Repair filesystem if needed
                if [ -n "$fs_type" ] && [ "$fs_type" != "" ] && [ "$fs_type" != "swap" ]; then
                    repair_filesystem "$source_part" "$fs_type" || true
                fi
                
                # Clone with retry logic
                if clone_with_retry "$source_part" "$dest_part" "4M" 2; then
                    log "    ✓ Partition cloned successfully"
                    success_count=$((success_count + 1))
                    
                    # Verify filesystem after cloning
                    if [ "$DRY_RUN" = false ]; then
                        sync
                        local dest_fs=$(detect_filesystem_robust "$dest_part")
                        if [ "$dest_fs" = "$fs_type" ]; then
                            log "    ✓ Filesystem verified: $dest_fs"
                        else
                            log "    ⚠ Filesystem mismatch: expected $fs_type, got $dest_fs"
                        fi
                    fi
                else
                    log_with_level ERROR "Partition clone failed for $source_part"
                fi
            fi
            
            part_num=$((part_num + 1))
        done < <(lsblk -ln -o NAME "$source_device" | tail -n +2)
        
        log "Partition cloning summary: $success_count/$total_partitions successful"
        
        # If too many partitions failed, consider it a failure
        if [ $success_count -eq 0 ] && [ $total_partitions -gt 0 ]; then
            log_with_level ERROR "All partition clones failed"
            cleanup_resources
            return 1
        fi
    fi
    
    if [ "$DRY_RUN" = false ]; then
        sync
        sleep 2
    fi
    
    # Clean up partition mappings
    if [ "$DRY_RUN" = false ]; then
        if command -v kpartx >/dev/null 2>&1; then
            kpartx -dv "$loop_dev" 2>/dev/null || true
        fi
        losetup -d "$loop_dev" 2>/dev/null || true
    fi
    
    # Convert to final format
    log "Converting to $dest_format format..."
    
    local convert_opts="-p"
    case "$dest_format" in
        qcow2)
            convert_opts="$convert_opts -c -o cluster_size=65536"
            ;;
        vmdk)
            convert_opts="$convert_opts -o adapter_type=lsilogic,subformat=streamOptimized"
            ;;
        vdi)
            convert_opts="$convert_opts -o static=off"
            ;;
    esac
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would convert with: qemu-img convert $convert_opts -O '$dest_format' '$temp_raw' '$dest_file'"
        log "✅ DRY RUN - Cloning simulation completed successfully!"
        return 0
    else
        if run_log "qemu-img convert $convert_opts -O '$dest_format' '$temp_raw' '$dest_file'"; then
            # Verification and cleanup
            log "Verifying cloned image..."
            qemu-img info "$dest_file" | tee -a "$LOGFILE"
            
            if [ "$dest_format" = "qcow2" ]; then
                qemu-img check "$dest_file" 2>&1 | tee -a "$LOGFILE"
            fi
            
            local final_size=$(stat -c%s "$dest_file" 2>/dev/null || echo 0)
            local final_gb=$(echo "scale=2; $final_size / 1073741824" | bc)
            local device_gb=$(echo "scale=2; $device_size / 1073741824" | bc)
            
            log "✅ Cloning completed successfully!"
            log "  Original device: ${device_gb}GB"
            log "  Final image: ${final_gb}GB"
            
            return 0
        else
            log_with_level ERROR "Conversion failed"
            return 1
        fi
    fi
}

# -------------------- NEW: UUID PRESERVATION FUNCTIONS (enhanced with dry-run) --------------------

get_filesystem_uuid() {
    local partition="$1"
    blkid -s UUID -o value "$partition" 2>/dev/null || echo ""
}

get_partition_uuid() {
    local partition="$1"
    blkid -s PARTUUID -o value "$partition" 2>/dev/null || echo ""
}

get_disk_uuid() {
    local device="$1"
    blkid -s PTUUID -o value "$device" 2>/dev/null || echo ""
}

set_filesystem_uuid() {
    local partition="$1"
    local uuid="$2"
    local fs_type="$3"
    
    if [[ -z "$uuid" ]]; then
        log "Warning: No UUID to set for $partition"
        return 0
    fi
    
    case "$fs_type" in
        "ext2"|"ext3"|"ext4")
            log "Setting ext filesystem UUID: $uuid"
            dry_run_cmd tune2fs -U "$uuid" "$partition"
            ;;
        "vfat"|"fat32")
            log "Setting FAT filesystem UUID: $uuid"
            local fat_uuid=$(echo "$uuid" | tr -d '-' | cut -c1-8 | tr '[:lower:]' '[:upper:]')
            if command -v mlabel >/dev/null 2>&1; then
                if [ "$DRY_RUN" = true ]; then
                    log "🧪 DRY RUN - Would create mtools config and run: mlabel -N ${fat_uuid:0:8}"
                else
                    echo "drive z: file=\"$partition\"" > /tmp/mtools.conf.$
                    MTOOLSRC=/tmp/mtools.conf.$ mlabel -N "${fat_uuid:0:8}" z: 2>/dev/null || true
                    rm -f /tmp/mtools.conf.$
                fi
            else
                log "Warning: Cannot set FAT UUID - mlabel not available"
            fi
            ;;
        "ntfs")
            log "NTFS UUID preserved automatically by ntfsclone"
            ;;
        "swap")
            log "Setting swap UUID: $uuid"
            dry_run_cmd mkswap -U "$uuid" "$partition"
            ;;
        "xfs")
            log "Setting XFS UUID: $uuid"
            dry_run_cmd xfs_admin -U "$uuid" "$partition"
            ;;
        *)
            log "Warning: Cannot set UUID for filesystem type: $fs_type"
            ;;
    esac
}

set_partition_uuid() {
    local disk="$1"
    local part_num="$2"
    local part_uuid="$3"
    
    if [[ -z "$part_uuid" ]]; then
        log "Warning: No partition UUID to set for partition $part_num"
        return 0
    fi
    
    if command -v sgdisk >/dev/null 2>&1; then
        log "Setting partition UUID for partition $part_num: $part_uuid"
        dry_run_cmd sgdisk --partition-guid="$part_num:$part_uuid" "$disk"
    else
        log "Warning: sgdisk not available - cannot set partition UUID"
    fi
}

set_disk_uuid() {
    local disk="$1"
    local disk_uuid="$2"
    
    if [[ -z "$disk_uuid" ]]; then
        log "Warning: No disk UUID to set"
        return 0
    fi
    
    if command -v sgdisk >/dev/null 2>&1; then
        log "Setting disk UUID: $disk_uuid"
        dry_run_cmd sgdisk --disk-guid="$disk_uuid" "$disk"
    else
        log "Warning: sgdisk not available - cannot set disk UUID"
    fi
}

is_efi_partition() {
    local partition="$1"
    local part_num="${partition##*[a-z]}"
    local disk_path="${partition%$part_num}"
    
    local part_type=$(fdisk -l "$disk_path" 2>/dev/null | grep "^$partition" | grep -i "EFI\|ef00" || true)
    local fs_type=$(get_filesystem_type "$partition")
    
    if [[ -n "$part_type" ]] || [[ "$fs_type" == "vfat" && "$part_num" == "1" ]]; then
        if mount | grep -q "$partition"; then
            local mount_point=$(mount | grep "$partition" | awk '{print $3}' | head -n1)
            [[ -d "$mount_point/EFI" ]]
        else
            if [ "$DRY_RUN" = true ]; then
                log "🧪 DRY RUN - Would check if $partition contains EFI directory"
                [[ "$fs_type" == "vfat" && "$part_num" == "1" ]]
            else
                local temp_mount="/tmp/efi_check_$"
                mkdir -p "$temp_mount"
                if mount "$partition" "$temp_mount" 2>/dev/null; then
                    local is_efi=false
                    [[ -d "$temp_mount/EFI" ]] && is_efi=true
                    umount "$temp_mount" 2>/dev/null || true
                    rmdir "$temp_mount" 2>/dev/null || true
                    $is_efi
                else
                    [[ "$fs_type" == "vfat" && "$part_num" == "1" ]]
                fi
            fi
        fi
    else
        false
    fi
}

get_partitions_info_with_uuids() {
    local disk="$1"
    local -n partitions_ref=$2
    
    partitions_ref=()
    
    local disk_base=$(basename "$disk")
    local disk_uuid=$(get_disk_uuid "$disk")
    log "Source disk UUID: ${disk_uuid:-none}"
    
    local partitions_list
    partitions_list=$(lsblk -ln -o NAME "$disk" | grep "^${disk_base}[0-9]")
    
    if [[ -z "$partitions_list" ]]; then
        log "Warning: No partitions found on $disk"
        return 1
    fi
    
    while IFS= read -r partition_name; do
        local partition_path="/dev/$partition_name"
        
        if [[ ! -b "$partition_path" ]]; then
            log "Warning: Partition $partition_path does not exist, skipping"
            continue
        fi
        
        local size=$(blockdev --getsize64 "$partition_path" 2>/dev/null || echo "0")
        local fs_type=$(get_filesystem_type "$partition_path")
        local fs_uuid=$(get_filesystem_uuid "$partition_path")
        local part_uuid=$(get_partition_uuid "$partition_path")
        local is_efi=false
        
        if is_efi_partition "$partition_path"; then
            is_efi=true
        fi
        
        if [[ $size -gt 0 ]]; then
            partitions_ref+=("$partition_path,$size,$fs_type,$is_efi,$fs_uuid,$part_uuid,$disk_uuid")
            log "Found partition: $partition_path ($(numfmt --to=iec --suffix=B $size), $fs_type, EFI: $is_efi)"
            log "  FS UUID: ${fs_uuid:-none}, Part UUID: ${part_uuid:-none}"
        fi
    done <<< "$partitions_list"
    
    if [[ ${#partitions_ref[@]} -eq 0 ]]; then
        log "Error: No valid partitions found on $disk"
        return 1
    fi
    
    return 0
}

calculate_proportional_sizes() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    local -n target_sizes_ref=$4
    
    local source_size=$(blockdev --getsize64 "$source_disk" 2>/dev/null || echo "0")
    local target_size=$(blockdev --getsize64 "$target_disk" 2>/dev/null || echo "0")
    
    target_sizes_ref=()
    
    log "Source disk size: $(numfmt --to=iec --suffix=B $source_size)"
    log "Target disk size: $(numfmt --to=iec --suffix=B $target_size)"
    
    local total_partitions_size=0
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
        total_partitions_size=$((total_partitions_size + size))
    done
    
    log "Total partitions size: $(numfmt --to=iec --suffix=B $total_partitions_size)"
    
    local usable_target_size=$((target_size - 4 * 1024 * 1024))
    
    if [[ $total_partitions_size -le $usable_target_size ]]; then
        log "Target disk has enough space, keeping original sizes"
        for part_info in "${source_parts_ref[@]}"; do
            IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
            target_sizes_ref+=("$size")
        done
        return
    fi
    
    log "Target disk is smaller, calculating proportional sizes..."
    
    local total_efi_size=0
    local total_other_size=0
    
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
        if [[ "$is_efi" == "true" ]]; then
            total_efi_size=$((total_efi_size + size))
        else
            total_other_size=$((total_other_size + size))
        fi
    done
    
    if [[ $total_efi_size -gt $usable_target_size ]]; then
        log "Error: EFI partitions ($(numfmt --to=iec --suffix=B $total_efi_size)) don't fit in target disk"
        return 1
    fi
    
    local remaining_size=$((usable_target_size - total_efi_size))
    
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
        
        if [[ "$is_efi" == "true" ]]; then
            target_sizes_ref+=("$size")
        else
            if [[ $total_other_size -eq 0 ]]; then
                target_sizes_ref+=("$size")
            else
                local new_size=$((size * remaining_size / total_other_size))
                new_size=$(((new_size / 1048576) * 1048576))
                [[ $new_size -lt 1048576 ]] && new_size=1048576
                target_sizes_ref+=("$new_size")
            fi
        fi
    done
}

create_partitions_with_uuids() {
    local target_disk="$1"
    local -n source_parts_ref=$2
    local -n target_sizes_ref=$3
    
    log "Creating GPT partition table on $target_disk with UUID preservation"
    
    local source_disk_uuid=""
    if [[ ${#source_parts_ref[@]} -gt 0 ]]; then
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[0]}"
        source_disk_uuid="$disk_uuid"
    fi
    
    dry_run_cmd wipefs -af "$target_disk"
    dry_run_cmd parted "$target_disk" --script mklabel gpt
    
    if [[ -n "$source_disk_uuid" ]]; then
        set_disk_uuid "$target_disk" "$source_disk_uuid"
    fi
    
    local sector_size=512
    local start_sector=2048
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        local target_size="${target_sizes_ref[$i]}"
        local part_num=$((i+1))
        
        local size_sectors=$((target_size / sector_size))
        
        if [[ "$fs_type" == "crypto_LUKS" ]]; then
            local source_sectors=$((size / sector_size))
            if [[ $size_sectors -lt $source_sectors ]]; then
                size_sectors=$source_sectors
                log "Adjusting LUKS partition size to match source: $size_sectors sectors"
            fi
        fi
        
        if [[ "$fs_type" != "crypto_LUKS" ]]; then
            size_sectors=$(((size_sectors / 2048) * 2048))
        else
            size_sectors=$(((size_sectors + 2047) / 2048 * 2048))
        fi
        
        local end_sector=$((start_sector + size_sectors - 1))
        
        log "Creating partition ${part_num} (sectors ${start_sector} to ${end_sector}, size: $(numfmt --to=iec --suffix=B $((size_sectors * sector_size))))"
        
        if [[ "$is_efi" == "true" ]]; then
            dry_run_cmd parted "$target_disk" --script mkpart "EFI" fat32 "${start_sector}s" "${end_sector}s"
            dry_run_cmd parted "$target_disk" --script set $part_num esp on
        else
            local part_name="partition${part_num}"
            dry_run_cmd parted "$target_disk" --script mkpart "$part_name" "${start_sector}s" "${end_sector}s"
        fi
        
        target_sizes_ref[$i]=$((size_sectors * sector_size))
        
        start_sector=$((end_sector + 1))
        local remainder=$((start_sector % 2048))
        if [[ $remainder -ne 0 ]]; then
            start_sector=$((start_sector + 2048 - remainder))
        fi
    done
    
    dry_run_cmd partprobe "$target_disk"
    if [ "$DRY_RUN" = false ]; then
        sleep 3
    fi
    
    for i in "${!source_parts_ref[@]}"; do
        local target_partition="${target_disk}$((i+1))"
        
        if [ "$DRY_RUN" = true ]; then
            log "🧪 DRY RUN - Would wait for partition $target_partition to be created"
        else
            local count=0
            while [[ ! -b "$target_partition" && $count -lt 10 ]]; do
                sleep 1
                count=$((count + 1))
                partprobe "$target_disk" 2>/dev/null || true
            done
            
            if [[ ! -b "$target_partition" ]]; then
                log "Error: Failed to create partition $target_partition"
                return 1
            fi
        fi
        
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        if [[ -n "$part_uuid" ]]; then
            set_partition_uuid "$target_disk" "$((i+1))" "$part_uuid"
        fi
        
        if [ "$DRY_RUN" = true ]; then
            log "🧪 DRY RUN - Partition $target_partition would be created with size: $(numfmt --to=iec --suffix=B ${target_sizes_ref[$i]})"
        else
            local actual_size=$(blockdev --getsize64 "$target_partition" 2>/dev/null || echo "0")
            log "Partition $target_partition created with size: $(numfmt --to=iec --suffix=B $actual_size)"
        fi
    done
    
    dry_run_cmd partprobe "$target_disk"
    if [ "$DRY_RUN" = false ]; then
        sleep 2
    fi
    return 0
}

clone_partitions_with_uuid_preservation() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r source_partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        local target_partition="${target_disk}$((i+1))"
        
        log "Cloning $source_partition to $target_partition with UUID preservation"
        log "Filesystem type: ${fs_type:-unknown}, EFI: $is_efi"
        log "FS UUID: ${fs_uuid:-none}"
        
        if [[ ! -b "$source_partition" ]] || ([[ ! -b "$target_partition" ]] && [ "$DRY_RUN" = false ]); then
            log "Error: Source or target partition does not exist"
            continue
        fi
        
        local source_size=$(blockdev --getsize64 "$source_partition" 2>/dev/null || echo "0")
        local target_size
        if [ "$DRY_RUN" = true ]; then
            target_size=$source_size  # Assume same size for dry run
        else
            target_size=$(blockdev --getsize64 "$target_partition" 2>/dev/null || echo "0")
        fi
        
        log "Source size: $(numfmt --to=iec --suffix=B $source_size)"
        log "Target size: $(numfmt --to=iec --suffix=B $target_size)"
        
        local copy_size=$source_size
        local size_diff=$((source_size - target_size))
        local tolerance=$((1024 * 1024))

        if [[ $size_diff -gt $tolerance ]]; then
            copy_size=$target_size
            log "Warning: Target partition is significantly smaller, copying only $(numfmt --to=iec --suffix=B $copy_size)"
        elif [[ $target_size -lt $source_size ]]; then
            copy_size=$target_size
            log "Target partition slightly smaller due to alignment, copying $(numfmt --to=iec --suffix=B $copy_size)"
        fi
        
        local block_size=1048576
        local blocks_to_copy=$((copy_size / block_size))
        
        case "$fs_type" in
            "vfat"|"fat32")
                log "Using dd for FAT filesystem (copying $blocks_to_copy blocks of 1MB)"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                            log "Warning: dd with 1MB blocks failed, trying with 512KB"
                            local small_block_size=524288
                            local small_blocks_to_copy=$((copy_size / small_block_size))
                            dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress 
                        }
                    fi
                else
                    log "Warning: Partition too small, copying sector by sector"
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$((copy_size / 512)) status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress 
                    fi
                fi
                set_filesystem_uuid "$target_partition" "$fs_uuid" "$fs_type"
                ;;
            "ext2"|"ext3"|"ext4")
                log "Using e2image for ext filesystem"
                dry_run_cmd e2fsck -fy "$source_partition"
                if [ "$DRY_RUN" = true ]; then
                    log "🧪 DRY RUN - Would run: e2image -ra -p '$source_partition' '$target_partition'"
                    if [[ $target_size -gt $source_size ]]; then
                        log "🧪 DRY RUN - Would run: resize2fs '$target_partition'"
                    fi
                else
                    e2image -ra -p "$source_partition" "$target_partition" 2>/dev/null
                    if [[ $target_size -gt $source_size ]]; then
                        resize2fs "$target_partition" 2>/dev/null || true
                    fi
                fi
                log "UUID preserved by e2image: $fs_uuid"
                ;;
            "ntfs")
                if command -v ntfsclone >/dev/null 2>&1; then
                    log "Using ntfsclone for NTFS filesystem"
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: ntfsclone -f --overwrite '$target_partition' '$source_partition'"
                        if [[ $target_size -gt $source_size ]]; then
                            log "🧪 DRY RUN - Would run: ntfsresize -f '$target_partition'"
                        fi
                    else
                        ntfsclone -f --overwrite "$target_partition" "$source_partition" 2>/dev/null
                        if [[ $target_size -gt $source_size ]]; then
                            ntfsresize -f "$target_partition" 2>/dev/null || true
                        fi
                    fi
                    log "UUID preserved by ntfsclone: $fs_uuid"
                else
                    log "Warning: ntfsclone not available, using dd with size limit"
                    if [[ $blocks_to_copy -gt 0 ]]; then
                        if [ "$DRY_RUN" = true ]; then
                            log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                        else
                            dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                        fi
                    fi
                    log "Warning: UUID may not be preserved with dd copy"
                fi
                ;;
            "crypto_LUKS")
                local source_sectors=$((source_size / 512))
                local target_sectors=$((target_size / 512))
                
                if [[ $source_sectors -gt $target_sectors ]]; then
                    log "Error: LUKS partition cannot be truncated: source has $source_sectors sectors, target has $target_sectors"
                    continue
                fi
                
                log "Using dd with exact sector copy for LUKS container"
                local sectors_to_copy=$source_sectors
                
                if [ "$DRY_RUN" = true ]; then
                    log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$sectors_to_copy status=progress conv=noerror,sync"
                else
                    dd if="$source_partition" of="$target_partition" bs=512 count=$sectors_to_copy status=progress conv=noerror,sync
                fi
                
                if command -v cryptsetup >/dev/null 2>&1; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would verify LUKS header with: cryptsetup luksDump '$target_partition'"
                    elif cryptsetup luksDump "$target_partition" >/dev/null 2>&1; then
                        log "LUKS header verified successfully"
                    else
                        log "Error: LUKS header verification failed - partition may be corrupted"
                    fi
                else
                    log "Warning: cryptsetup not available - cannot verify LUKS integrity"
                fi
                
                log "LUKS UUID preserved in header: $fs_uuid"
                ;;
            "swap")
                log "Creating new swap partition with preserved UUID"
                if [[ -n "$fs_uuid" ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: mkswap -U '$fs_uuid' '$target_partition'"
                    else
                        mkswap -U "$fs_uuid" "$target_partition" 2>/dev/null
                    fi
                    log "Swap UUID set to: $fs_uuid"
                else
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: mkswap '$target_partition'"
                    else
                        mkswap "$target_partition" 2>/dev/null
                    fi
                    log "New swap partition created"
                fi
                ;;
            "xfs")
                log "Using dd for XFS filesystem"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                            log "Warning: dd with 1MB blocks failed, trying with 512KB"
                            local small_block_size=524288
                            local small_blocks_to_copy=$((copy_size / small_block_size))
                            dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                        }
                    fi
                else
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$((copy_size / 512)) status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                    fi
                fi
                if [[ -n "$fs_uuid" ]]; then
                    set_filesystem_uuid "$target_partition" "$fs_uuid" "$fs_type"
                fi
                ;;
            "")
                log "Warning: Unknown filesystem, attempting dd copy with size limit"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                            log "Warning: dd with 1MB blocks failed, trying with 512KB"
                            local small_block_size=524288
                            local small_blocks_to_copy=$((copy_size / small_block_size))
                            dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                        }
                    fi
                else
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$((copy_size / 512)) status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                    fi
                fi
                ;;
            *)
                log "Warning: Unsupported filesystem $fs_type, using dd with size limit"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                            log "Warning: dd with 1MB blocks failed, trying with 512KB"
                            local small_block_size=524288
                            local small_blocks_to_copy=$((copy_size / small_block_size))
                            dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                        }
                    fi
                else
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$((copy_size / 512)) status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                    fi
                fi
                if [[ -n "$fs_uuid" ]]; then
                    set_filesystem_uuid "$target_partition" "$fs_uuid" "$fs_type"
                fi
                ;;
        esac
        
        log "Successfully cloned $source_partition to $target_partition"
        
        if [ "$DRY_RUN" = true ]; then
            log "🧪 DRY RUN - Would verify UUID preservation"
        else
            local new_fs_uuid=$(get_filesystem_uuid "$target_partition")
            if [[ -n "$new_fs_uuid" && "$new_fs_uuid" == "$fs_uuid" ]]; then
                log "UUID correctly preserved: $new_fs_uuid"
            elif [[ -n "$new_fs_uuid" ]]; then
                log "Warning: UUID changed: $fs_uuid -> $new_fs_uuid"
            else
                log "Warning: No UUID found on target partition"
            fi
        fi
    done
}

# -------------------- DEVICE SELECTION --------------------

select_physical_device() {
    log "Scanning physical devices..."
    
    local devices=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            local name=$(echo "$line" | awk '{print $1}')
            local size=$(echo "$line" | awk '{print $2}')
            local model=$(echo "$line" | cut -d' ' -f3-)
            devices+=("/dev/$name" "$size - $model")
        fi
    done < <(lsblk -dn -o NAME,SIZE,MODEL | grep -E '^sd|^nvme|^vd')
    
    if [ ${#devices[@]} -eq 0 ]; then
        dialog --title "Error" --msgbox "No physical devices found!" 8 50
        return 1
    fi
    
    local selected
    selected=$(dialog --clear --title "Select Physical Device" \
        --menu "Select the device:" 20 70 10 \
        "${devices[@]}" \
        3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$selected" ]; then
        echo "$selected"
        return 0
    fi
    return 1
}

get_virtual_disk_info() {
    local file="$1"
    
    local info
    info=$(qemu-img info "$file" 2> >(tee -a "$LOGFILE" >&4))
    if [ $? -eq 0 ]; then
        echo "$info"
        return 0
    fi
    
    info=$(qemu-img info --format=vpc "$file" 2> >(tee -a "$LOGFILE" >&4))
    if [ $? -eq 0 ]; then
        echo "$info"
        return 0
    fi
    
    info=$(qemu-img info --format=vhdx "$file" 2> >(tee -a "$LOGFILE" >&4))
    if [ $? -eq 0 ]; then
        echo "$info"
        return 0
    fi
    
    return 1
}

# -------------------- NEW: PHYSICAL TO PHYSICAL CLONING FUNCTIONS (enhanced with dry-run) --------------------

clone_physical_to_physical_simple() {
    log "=== Physical to Physical Cloning (Simple Mode) ==="
    
    local source_device=$(select_physical_device)
    if [ -z "$source_device" ] || [ ! -b "$source_device" ]; then
        return 1
    fi
    
    local source_size=$(blockdev --getsize64 "$source_device" 2>/dev/null)
    log "Source: $source_device"
    log "Source Size: $((source_size / 1073741824)) GB"
    
    local target_device=$(select_physical_device)
    if [ -z "$target_device" ] || [ ! -b "$target_device" ]; then
        return 1
    fi
    
    if [ "$source_device" = "$target_device" ]; then
        dialog --title "Error" --msgbox "Source and target devices cannot be the same!" 8 60
        return 1
    fi
    
    local target_size=$(blockdev --getsize64 "$target_device" 2>/dev/null)
    log "Target: $target_device"
    log "Target Size: $((target_size / 1073741824)) GB"
    
    if [ "$target_size" -lt "$source_size" ]; then
        dialog --title "Error" \
            --msgbox "Target device is too small!\n\nSource: $((source_size / 1073741824)) GB\nTarget: $((target_size / 1073741824)) GB" 10 60
        return 1
    fi
    
    # Safety checks
    if ! check_device_safety "$source_device"; then
        return 1
    fi
    
    if ! check_device_safety "$target_device"; then
        return 1
    fi
    
    local warning_msg="This operation will COMPLETELY DESTROY ALL DATA on the target device!\n\nSource: $source_device ($((source_size / 1073741824)) GB)\nTarget: $target_device ($((target_size / 1073741824)) GB)\n\nThis action is IRREVERSIBLE!"
    if [ "$DRY_RUN" = true ]; then
        warning_msg="$warning_msg\n\n🧪 DRY RUN MODE: No actual changes will be made"
    fi
    
    if ! dialog --title "⚠️ CRITICAL WARNING ⚠️" \
        --yesno "$warning_msg\n\nType 'yes' to confirm:" 16 70; then
        return 1
    fi
    
    local confirm_text
    if [ "$DRY_RUN" = true ]; then
        confirm_text=$(dialog --clear --title "Final Confirmation (Dry Run)" \
            --inputbox "To proceed with this DRY RUN simulation, type exactly: SIMULATE" 10 70 \
            3>&1 1>&2 2>&3)
        
        if [ "$confirm_text" != "SIMULATE" ]; then
            dialog --title "Cancelled" --msgbox "Dry run cancelled - confirmation text did not match." 8 60
            return 1
        fi
    else
        confirm_text=$(dialog --clear --title "Final Confirmation" \
            --inputbox "To proceed with this DESTRUCTIVE operation, type exactly: DESTROY" 10 70 \
            3>&1 1>&2 2>&3)
        
        if [ "$confirm_text" != "DESTROY" ]; then
            dialog --title "Cancelled" --msgbox "Operation cancelled - confirmation text did not match." 8 60
            return 1
        fi
    fi
    
    clear
    
    if [ "$DRY_RUN" = true ]; then
        log "Starting DRY RUN simulation of physical to physical clone..."
    else
        log "Starting simple physical to physical clone..."
    fi
    log "This will copy the entire source device to the target device"
    
    # Unmount partitions safely
    safe_unmount_device_partitions "$source_device"
    safe_unmount_device_partitions "$target_device"
    
    # Perform the clone
    log "Cloning $source_device to $target_device..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would clone entire device:"
        if command -v pv &> /dev/null; then
            log "🧪 DRY RUN - Would run: pv -tpreb '$source_device' | dd of='$target_device' bs=4M conv=notrunc,noerror"
        else
            log "🧪 DRY RUN - Would run: dd if='$source_device' of='$target_device' bs=4M status=progress conv=notrunc,noerror"
        fi
        log "🧪 DRY RUN - Would run: sync"
        log "🧪 DRY RUN - Would run: partprobe '$target_device'"
        
        dialog --title "✅ Dry Run Complete" \
            --msgbox "DRY RUN simulation completed successfully!\n\nWould have cloned:\n$source_device → $target_device\n\nAll commands logged without execution." 12 70
        return 0
    else
        if command -v pv &> /dev/null; then
            log "Using pv for progress monitoring..."
            pv -tpreb "$source_device" | dd of="$target_device" bs=4M conv=notrunc,noerror 2>/dev/null
        else
            log "Using dd with progress..."
            dd if="$source_device" of="$target_device" bs=4M status=progress conv=notrunc,noerror 2>/dev/null
        fi
        
        if [ $? -eq 0 ]; then
            sync
            log "Verifying partition table on target device..."
            partprobe "$target_device" 2>/dev/null || true
            sleep 3
            
            dialog --title "✅ Success" \
                --msgbox "Simple cloning completed successfully!\n\n$source_device → $target_device\n\nAll data has been copied exactly." 12 70
            return 0
        else
            dialog --title "❌ Error" --msgbox "Error during cloning!" 8 50
            return 1
        fi
    fi
}

clone_physical_to_physical_with_uuid() {
    log "=== Physical to Physical Cloning (UUID Preservation Mode) ==="
    
    local source_device=$(select_physical_device)
    if [ -z "$source_device" ] || [ ! -b "$source_device" ]; then
        return 1
    fi
    
    local source_size=$(blockdev --getsize64 "$source_device" 2>/dev/null)
    log "Source: $source_device"
    log "Source Size: $((source_size / 1073741824)) GB"
    
    # Show source disk details
    echo
    log "Source disk partition layout:"
    lsblk "$source_device" | tee -a "$LOGFILE"
    
    local target_device
    while true; do
        target_device=$(select_physical_device)
        if [ -z "$target_device" ] || [ ! -b "$target_device" ]; then
            return 1
        fi
        
        if [ "$source_device" = "$target_device" ]; then
            dialog --title "Error" --msgbox "Source and target devices cannot be the same!" 8 60
            continue
        fi
        break
    done
    
    local target_size=$(blockdev --getsize64 "$target_device" 2>/dev/null)
    log "Target: $target_device"
    log "Target Size: $((target_size / 1073741824)) GB"
    
    # Show target disk details
    echo
    log "Target disk current layout:"
    lsblk "$target_device" | tee -a "$LOGFILE"
    
    # Safety checks
    if ! check_device_safety "$source_device"; then
        return 1
    fi
    
    if ! check_device_safety "$target_device"; then
        return 1
    fi
    
    # Get partitions info with UUIDs
    local source_partitions=()
    if ! get_partitions_info_with_uuids "$source_device" source_partitions; then
        dialog --title "Error" --msgbox "Failed to get partition information from source device!" 10 60
        return 1
    fi
    
    log "Found ${#source_partitions[@]} partitions on source disk"
    
    # Calculate target sizes (with proportional resize if needed)
    local target_sizes=()
    if ! calculate_proportional_sizes "$source_device" "$target_device" source_partitions target_sizes; then
        dialog --title "Error" --msgbox "Cannot fit source partitions on target device!" 10 60
        return 1
    fi
    
    # Show operation plan
    local plan_text="PHYSICAL TO PHYSICAL CLONING WITH UUID PRESERVATION\n\n"
    plan_text+="Source: $source_device ($(numfmt --to=iec --suffix=B $source_size))\n"
    plan_text+="Target: $target_device ($(numfmt --to=iec --suffix=B $target_size))\n\n"
    
    if [ "$DRY_RUN" = true ]; then
        plan_text+="🧪 DRY RUN MODE: NO ACTUAL CHANGES WILL BE MADE\n\n"
    else
        plan_text+="⚠️  TARGET DEVICE WILL BE COMPLETELY WIPED! ⚠️\n\n"
    fi
    
    plan_text+="Partitions to clone:\n"
    
    for i in "${!source_partitions[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_partitions[$i]}"
        local target_size="${target_sizes[$i]}"
        
        plan_text+="• $(basename $partition): ${fs_type:-unknown} "
        plan_text+="($(numfmt --to=iec --suffix=B $size) → $(numfmt --to=iec --suffix=B $target_size))"
        if [[ "$is_efi" == "true" ]]; then
            plan_text+=" [EFI]"
        fi
        plan_text+="\n"
    done
    
    plan_text+="\n✓ All UUIDs will be preserved\n"
    plan_text+="✓ Filesystem integrity maintained\n"
    plan_text+="✓ Bootloader compatibility preserved"
    
    if ! dialog --title "⚠️ DESTRUCTIVE OPERATION CONFIRMATION ⚠️" \
        --yesno "$plan_text" 22 80; then
        return 1
    fi
    
    local confirm_text
    if [ "$DRY_RUN" = true ]; then
        confirm_text=$(dialog --clear --title "Final Safety Check (Dry Run)" \
            --inputbox "This is a DRY RUN simulation!\n\nTo confirm, type exactly: SIMULATE" 12 80 \
            3>&1 1>&2 2>&3)
        
        if [ "$confirm_text" != "SIMULATE" ]; then
            dialog --title "Cancelled" --msgbox "Dry run cancelled - safety check failed." 8 60
            return 1
        fi
    else
        confirm_text=$(dialog --clear --title "Final Safety Check" \
            --inputbox "This will DESTROY all data on $target_device!\n\nTo confirm, type exactly: CLONE" 12 80 \
            3>&1 1>&2 2>&3)
        
        if [ "$confirm_text" != "CLONE" ]; then
            dialog --title "Cancelled" --msgbox "Operation cancelled - safety check failed." 8 60
            return 1
        fi
    fi
    
    clear
    
    if [ "$DRY_RUN" = true ]; then
        log "Starting DRY RUN simulation of physical to physical clone with UUID preservation..."
    else
        log "Starting physical to physical clone with UUID preservation..."
    fi
    
    # Unmount partitions safely
    safe_unmount_device_partitions "$source_device"
    safe_unmount_device_partitions "$target_device"
    
    # Create partitions with UUID preservation
    log "Step 1/2: Creating partition table and partitions..."
    if ! create_partitions_with_uuids "$target_device" source_partitions target_sizes; then
        log "Error: Failed to create partitions"
        dialog --title "❌ Error" --msgbox "Failed to create partition table!" 8 50
        return 1
    fi
    
    # Clone partitions with UUID preservation
    log "Step 2/2: Cloning partitions with UUID preservation..."
    clone_partitions_with_uuid_preservation "$source_device" "$target_device" source_partitions
    
    # Verification
    log "Verifying clone results..."
    if [ "$DRY_RUN" = false ]; then
        sync
        partprobe "$target_device" 2>/dev/null || true
        sleep 3
    fi
    
    # Show verification results
    local verify_text=""
    if [ "$DRY_RUN" = true ]; then
        verify_text="DRY RUN SIMULATION COMPLETED!\n\n"
    else
        verify_text="CLONING COMPLETED!\n\n"
    fi
    
    verify_text+="Source: $source_device\n"
    verify_text+="Target: $target_device\n\n"
    verify_text+="Partition verification:\n"
    
    local uuid_mismatches=0
    
    for i in "${!source_partitions[@]}"; do
        IFS=',' read -r source_partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_partitions[$i]}"
        local target_partition="${target_device}$((i+1))"
        
        if [ "$DRY_RUN" = true ]; then
            verify_text+="• $(basename $target_partition): ${fs_type:-unknown} ✓ UUID would be preserved"
            if [[ "$is_efi" == "true" ]]; then
                verify_text+=" [EFI]"
            fi
            verify_text+="\n"
        elif [[ -b "$target_partition" ]]; then
            local new_fs_uuid=$(get_filesystem_uuid "$target_partition")
            local new_part_uuid=$(get_partition_uuid "$target_partition")
            
            verify_text+="• $(basename $target_partition): ${fs_type:-unknown}"
            
            if [[ -n "$fs_uuid" && "$fs_uuid" == "$new_fs_uuid" ]]; then
                verify_text+=" ✓ UUID"
            elif [[ -n "$fs_uuid" ]]; then
                verify_text+=" ⚠ UUID changed"
                uuid_mismatches=$((uuid_mismatches + 1))
            else
                verify_text+=" - No UUID"
            fi
            
            if [[ "$is_efi" == "true" ]]; then
                verify_text+=" [EFI]"
            fi
            verify_text+="\n"
        else
            verify_text+="• Partition $((i+1)): ❌ Not found\n"
        fi
    done
    
    # Check disk UUID
    if [ "$DRY_RUN" = true ]; then
        verify_text+="\n✓ Disk UUID would be preserved"
    else
        local new_disk_uuid=$(get_disk_uuid "$target_device")
        local source_disk_uuid=""
        if [[ ${#source_partitions[@]} -gt 0 ]]; then
            IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_partitions[0]}"
            source_disk_uuid="$disk_uuid"
        fi
        
        if [[ -n "$source_disk_uuid" && "$source_disk_uuid" == "$new_disk_uuid" ]]; then
            verify_text+="\n✓ Disk UUID preserved"
        elif [[ -n "$source_disk_uuid" ]]; then
            verify_text+="\n⚠ Disk UUID changed"
        fi
    fi
    
    if [ "$DRY_RUN" = true ]; then
        verify_text+="\n\n✅ All UUIDs would be successfully preserved!"
        verify_text+="\nSystem would boot normally after real cloning."
    elif [[ $uuid_mismatches -gt 0 ]]; then
        verify_text+="\n\n⚠ Some UUIDs could not be preserved."
        verify_text+="\nYou may need to update /etc/fstab"
        verify_text+="\nand bootloader configuration."
    else
        verify_text+="\n\n✅ All UUIDs successfully preserved!"
        verify_text+="\nSystem should boot normally."
    fi
    
    local title="✅ Cloning Complete"
    if [ "$DRY_RUN" = true ]; then
        title="✅ Dry Run Complete"
    fi
    
    dialog --title "$title" \
        --msgbox "$verify_text" 20 70
    
    if [ "$DRY_RUN" = true ]; then
        log "Physical to physical cloning DRY RUN simulation completed!"
    else
        log "Physical to physical cloning with UUID preservation completed!"
    fi
    return 0
}

# -------------------- MAIN CLONING FUNCTIONS (enhanced with dry-run) --------------------

clone_physical_to_virtual() {
    log "=== Physical to Virtual Cloning ==="
    
    local source_device=$(select_physical_device)
    if [ -z "$source_device" ] || [ ! -b "$source_device" ]; then
        return 1
    fi
    
    local device_size=$(blockdev --getsize64 "$source_device")
    
    log "Source: $source_device"
    log "Physical Size: $((device_size / 1073741824)) GB"
    
    local optimized_size=$(analyze_device_usage "$source_device")
    local optimized_gb=$(echo "scale=2; $optimized_size / 1073741824" | bc)
    local device_gb=$((device_size / 1073741824))
    
    local clone_mode
    clone_mode=$(dialog --clear --title "Cloning Mode" \
        --menu "Choose cloning mode:\n\nPhysical size: ${device_gb}GB\nOptimized size: ${optimized_gb}GB (only used space + overhead)" 15 70 2 \
        "optimized" "🚀 Smart Mode - Create optimized image (~${optimized_gb}GB)" \
        "full" "📼 Full Mode - Clone entire disk (${device_gb}GB)" \
        3>&1 1>&2 2>&3)
    
    if [ -z "$clone_mode" ]; then
        return 1
    fi
    
    local dest_dir=$(select_directory "Select destination directory")
    
    if [ -z "$dest_dir" ]; then
        dialog --title "Error" --msgbox "Invalid or no directory selected!" 8 50
        return 1
    fi
    
    local filename
    filename=$(dialog --clear --title "File Name" \
        --inputbox "Name of the new virtual disk:" 10 60 \
        "clone_$(date +%Y%m%d_%H%M%S).qcow2" \
        3>&1 1>&2 2>&3)
    
    if [ -z "$filename" ]; then
        return 1
    fi
    
    local dest_file="$dest_dir/$filename"
    if [ -e "$dest_file" ] && [ "$DRY_RUN" = false ]; then
        dialog --title "Error" --msgbox "File already exists!" 8 50
        return 1
    fi
    
    local format
    format=$(dialog --clear --title "Disk Format" \
        --menu "Select format:" 12 60 5 \
        "qcow2" "QCOW2 - Best compression & features" \
        "vmdk" "VMDK - VMware (dynamic)" \
        "vdi" "VDI - VirtualBox (dynamic)" \
        "raw" "RAW - No compression (sparse file)" \
        "vpc" "VHD - Hyper-V" \
        3>&1 1>&2 2>&3)
    
    if [ -z "$format" ]; then
        return 1
    fi
    
    local size_info=""
    if [ "$clone_mode" = "optimized" ]; then
        size_info="Optimized size: ~${optimized_gb}GB (smart copy)"
    else
        size_info="Full size: ${device_gb}GB"
    fi
    
    local confirm_msg="Clone the device?\n\nSource: $source_device\nDestination: $dest_file\nFormat: $format\n$size_info\n\nMode: $clone_mode"
    if [ "$DRY_RUN" = true ]; then
        confirm_msg="$confirm_msg\n\n🧪 DRY RUN: No actual file will be created"
    fi
    
    if ! dialog --title "Confirm Cloning" \
        --yesno "$confirm_msg" 16 70; then
        return 1
    fi
    
    clear
    
    if [ "$clone_mode" = "optimized" ]; then
        if [ "$DRY_RUN" = true ]; then
            log "=== DRY RUN - OPTIMIZED CLONING MODE ==="
        else
            log "=== OPTIMIZED CLONING MODE ==="
        fi
        log "Creating space-efficient image with proper partition handling..."
        
        clone_physical_to_virtual_optimized "$source_device" "$dest_file" "$format"
    else
        if [ "$DRY_RUN" = true ]; then
            log "=== DRY RUN - FULL CLONING MODE ==="
        else
            log "=== FULL CLONING MODE ==="
        fi
        log "Cloning entire device..."
        
        if [ "$DRY_RUN" = true ]; then
            if [ "$format" = "qcow2" ]; then
                log "🧪 DRY RUN - Would run: qemu-img convert -p -c -O qcow2 '$source_device' '$dest_file'"
            else
                log "🧪 DRY RUN - Would run: qemu-img convert -p -O '$format' '$source_device' '$dest_file'"
            fi
            log "✅ DRY RUN - Full cloning simulation completed!"
            dialog --title "✅ Dry Run Success" \
                --msgbox "DRY RUN simulation completed successfully!\n\nWould have cloned:\n$source_device → $dest_file\n\nFormat: $format" 12 70
            return 0
        else
            if [ "$format" = "qcow2" ]; then
                run_log "qemu-img convert -p -c -O qcow2 '$source_device' '$dest_file'"
            else
                run_log "qemu-img convert -p -O '$format' '$source_device' '$dest_file'"
            fi
        fi
    fi
    
    if [ $? -eq 0 ]; then
        if [ "$DRY_RUN" = false ]; then
            sync
            local final_size=$(stat -c%s "$dest_file" 2>/dev/null || echo 0)
            dialog --title "✅ Success" \
                --msgbox "Cloning completed successfully!\n\n$source_device → $dest_file\n\nFile size: $((final_size / 1073741824)) GB" 12 70
        fi
        return 0
    else
        if [ "$DRY_RUN" = false ]; then
            dialog --title "❌ Error" \
                --msgbox "Error during cloning!" 8 50
            rm -f "$dest_file" 2>/dev/null
        fi
        return 1
    fi
}

clone_virtual_to_physical() {
    log "=== Virtual to Physical Cloning ==="
    
    local source_file=$(select_file "Select source virtual disk")
    
    if [ -z "$source_file" ] || [ ! -f "$source_file" ]; then
        dialog --title "Error" --msgbox "Invalid or no file selected!" 8 50
        return 1
    fi
    
    local file_info=$(get_virtual_disk_info "$source_file")
    if [ -z "$file_info" ]; then
        dialog --title "Error" --msgbox "Unable to read disk file!\n\nFile might be corrupted." 10 60
        return 1
    fi
    
    local format=$(echo "$file_info" | grep "file format:" | cut -d: -f2 | tr -d ' ')
    local virt_size=$(echo "$file_info" | grep "virtual size:" | grep -o '[0-9]*' | tail -1)
    
    log "Source: $source_file"
    log "Format: $format"
    log "Size: $((virt_size / 1073741824)) GB"
    
    local dest_device=$(select_physical_device)
    if [ -z "$dest_device" ] || [ ! -b "$dest_device" ]; then
        return 1
    fi
    
    local dest_size=$(blockdev --getsize64 "$dest_device" 2>/dev/null)
    
    if [ "$dest_size" -lt "$virt_size" ]; then
        dialog --title "Error" \
            --msgbox "Destination device is too small!\n\nSource: $((virt_size / 1073741824)) GB\nDestination: $((dest_size / 1073741824)) GB" 10 60
        return 1
    fi
    
    local warning_msg="WARNING: This operation will DESTROY ALL DATA on $dest_device!\n\nSource: $source_file\nDestination: $dest_device"
    if [ "$DRY_RUN" = true ]; then
        warning_msg="$warning_msg\n\n🧪 DRY RUN: No actual changes will be made"
    fi
    
    if ! dialog --title "⚠️ CONFIRM CLONING ⚠️" \
        --yesno "$warning_msg\n\nAre you SURE you want to continue?" 14 70; then
        return 1
    fi
    
    clear
    
    log "Cloning in progress..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: qemu-img convert -p -O raw '$source_file' '$dest_device'"
        log "✅ DRY RUN - Virtual to physical cloning simulation completed!"
        dialog --title "✅ Dry Run Success" \
            --msgbox "DRY RUN simulation completed successfully!\n\nWould have cloned:\n$source_file → $dest_device" 10 60
        return 0
    else
        run_log "qemu-img convert -p -O raw '$source_file' '$dest_device'"
        
        if [ $? -eq 0 ]; then
            sync
            dialog --title "✅ Success" \
                --msgbox "Cloning completed successfully!\n\n$source_file → $dest_device" 10 60
            return 0
        else
            dialog --title "❌ Error" --msgbox "Error during cloning!" 8 50
            return 1
        fi
    fi
}

clone_virtual_to_virtual() {
    log "=== Virtual to Virtual Cloning ==="
    
    local source_file=$(select_file "Select source virtual disk")
    if [ -z "$source_file" ] || [ ! -f "$source_file" ]; then
        dialog --title "Error" --msgbox "Invalid or no file selected!" 8 50
        return 1
    fi
    
    local file_info=$(get_virtual_disk_info "$source_file")
    if [ -z "$file_info" ]; then
        dialog --title "Error" --msgbox "Unable to read disk file!" 8 50
        return 1
    fi
    
    local src_format=$(echo "$file_info" | grep "file format:" | cut -d: -f2 | tr -d ' ')
    local virt_size=$(echo "$file_info" | grep "virtual size:" | grep -o '[0-9]*' | tail -1)
    local actual_size=$(echo "$file_info" | grep "disk size:" | cut -d: -f2 | tr -d ' ')
    
    log "Source: $source_file"
    log "Format: $src_format"
    log "Virtual Size: $((virt_size / 1073741824)) GB"
    log "Actual Size: $actual_size"
    
    local dest_choice
    dest_choice=$(dialog --clear --title "Destination Virtual Disk" \
        --menu "Choose destination option:" 12 60 2 \
        "new" "Create new virtual disk" \
        "existing" "Use existing virtual disk file" \
        3>&1 1>&2 2>&3)
    
    if [ -z "$dest_choice" ]; then
        return 1
    fi
    
    local dest_file=""
    local dest_format=""
    local USE_MAX_COMPRESS=false
    
    if [ "$dest_choice" = "new" ]; then
        local dest_dir=$(select_directory "Select destination directory")
        if [ -z "$dest_dir" ]; then
            dialog --title "Error" --msgbox "Invalid or no directory selected!" 8 50
            return 1
        fi
        
        local filename
        filename=$(dialog --clear --title "File Name" \
            --inputbox "Name of the new virtual disk:" 10 60 \
            "copy_$(date +%Y%m%d_%H%M%S).qcow2" \
            3>&1 1>&2 2>&3)
        
        if [ -z "$filename" ]; then
            return 1
        fi
        
        dest_file="$dest_dir/$filename"
        if [ -e "$dest_file" ] && [ "$DRY_RUN" = false ]; then
            dialog --title "Error" --msgbox "File already exists!" 8 50
            return 1
        fi
        
        dest_format=$(dialog --clear --title "Disk Format" \
            --menu "Select format (with optimization):" 14 65 6 \
            "qcow2" "QCOW2 - Best compression & features" \
            "qcow2-compress" "QCOW2 - Maximum compression (slower)" \
            "vmdk" "VMDK - VMware (dynamic/thin)" \
            "vdi" "VDI - VirtualBox (dynamic)" \
            "raw" "RAW - No compression (sparse)" \
            "vpc" "VHD - Hyper-V" \
            3>&1 1>&2 2>&3)
        
        if [ -z "$dest_format" ]; then
            return 1
        fi
        
        if [ "$dest_format" = "qcow2-compress" ]; then
            dest_format="qcow2"
            USE_MAX_COMPRESS=true
        fi
    else
        dest_file=$(select_file "Select destination virtual disk file")
        if [ -z "$dest_file" ] || [ ! -f "$dest_file" ]; then
            dialog --title "Error" --msgbox "Invalid or no file selected!" 8 50
            return 1
        fi
        
        if [ "$source_file" = "$dest_file" ]; then
            dialog --title "Error" --msgbox "Source and destination cannot be the same file!" 8 60
            return 1
        fi
        
        local dest_info=$(get_virtual_disk_info "$dest_file")
        if [ -z "$dest_info" ]; then
            dialog --title "Error" --msgbox "Unable to read destination disk file!" 8 50
            return 1
        fi
        
        local dest_size=$(echo "$dest_info" | grep "virtual size:" | grep -o '[0-9]*' | tail -1)
        dest_format=$(echo "$dest_info" | grep "file format:" | cut -d: -f2 | tr -d ' ')
        
        if [ "$dest_size" -lt "$virt_size" ]; then
            dialog --title "Error" \
                --msgbox "Destination file is too small!\n\nSource: $((virt_size / 1073741824)) GB\nDestination: $((dest_size / 1073741824)) GB" 10 60
            return 1
        fi
        
        local warning_msg="This will OVERWRITE the existing file:\n$dest_file"
        if [ "$DRY_RUN" = true ]; then
            warning_msg="$warning_msg\n\n🧪 DRY RUN: No actual changes will be made"
        fi
        
        if ! dialog --title "⚠️ WARNING ⚠️" \
            --yesno "$warning_msg\n\nAre you sure?" 12 70; then
            return 1
        fi
    fi
    
    local confirm_msg="Clone the virtual disk?\n\nSource: $source_file ($src_format)\nDestination: $dest_file ($dest_format)\n\nOptimization will be applied automatically."
    if [ "$DRY_RUN" = true ]; then
        confirm_msg="$confirm_msg\n\n🧪 DRY RUN: No actual file changes will be made"
    fi
    
    if ! dialog --title "Confirm Cloning" \
        --yesno "$confirm_msg" 14 70; then
        [ "$dest_choice" = "new" ] && [ "$DRY_RUN" = false ] && rm -f "$dest_file"
        return 1
    fi
    
    clear
    log "Cloning with optimization..."
    log "Converting from $src_format to $dest_format"
    
    local convert_cmd="qemu-img convert -p"
    
    case "$dest_format" in
        qcow2)
            if [ "$USE_MAX_COMPRESS" = true ]; then
                log "Using maximum compression (this will be slower)..."
                convert_cmd="$convert_cmd -c -o cluster_size=65536"
            else
                convert_cmd="$convert_cmd -c"
            fi
            ;;
        vmdk)
            convert_cmd="$convert_cmd -o adapter_type=lsilogic,subformat=streamOptimized"
            ;;
        vdi)
            convert_cmd="$convert_cmd -o static=off"
            ;;
        raw)
            convert_cmd="$convert_cmd -S 512k"
            ;;
    esac
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: $convert_cmd -O '$dest_format' '$source_file' '$dest_file'"
        if [ "$dest_format" = "qcow2" ]; then
            log "🧪 DRY RUN - Would run final optimization: qemu-img check -r all '$dest_file'"
        fi
        log "✅ DRY RUN - Virtual to virtual cloning simulation completed!"
        
        dialog --title "✅ Dry Run Success" \
            --msgbox "DRY RUN simulation completed!\n\nWould have cloned:\nSource: $(basename \"$source_file\") ($src_format)\nDestination: $(basename \"$dest_file\") ($dest_format)" 12 70
        return 0
    else
        run_log "set -o pipefail; $convert_cmd -O '$dest_format' '$source_file' '$dest_file'"
        
        if [ $? -eq 0 ]; then
            sync
            if [ "$dest_format" = "qcow2" ]; then
                log "Running final optimization..."
                run_log qemu-img check -r all "$dest_file" || true
            fi
            
            local src_actual=$(stat -c%s "$source_file" 2>/dev/null || echo 0)
            local dst_actual=$(stat -c%s "$dest_file" 2>/dev/null || echo 0)
            local src_gb=$(echo "scale=2; $src_actual / 1073741824" | bc)
            local dst_gb=$(echo "scale=2; $dst_actual / 1073741824" | bc)
            local saved=$(echo "scale=2; $src_gb - $dst_gb" | bc)
            
            dialog --title "✅ Success" \
                --msgbox "Cloning completed!\n\nSource: $(basename \"$source_file\") ($src_gb GB)\nDestination: $(basename \"$dest_file\") ($dst_gb GB)\n\nSpace saved: $saved GB" 12 70
            return 0
        else
            dialog --title "❌ Error" --msgbox "Error during cloning!" 8 50
            [ "$dest_choice" = "new" ] && rm -f "$dest_file"
            return 1
        fi
    fi
}

# -------------------- MAIN MENU (updated) --------------------

main_menu() {
    while true; do
        local menu_title="⚡ Manzolo Disk Cloner v2.4 ✨"
        if [ "$DRY_RUN" = true ]; then
            menu_title="🧪 Manzolo Disk Cloner v2.4 - DRY RUN MODE"
        fi
        
        local choice
        choice=$(dialog --clear --title "$menu_title" \
            --menu "Select cloning type:" 18 85 7 \
            "1" "📦 → 📼 Virtual to Physical" \
            "2" "📼 → 📦 Physical to Virtual" \
            "3" "💿 → 📦 Virtual to Virtual (Compress)" \
            "4" "📼 → 📼 Physical to Physical (Simple)" \
            "5" "📼 → 📼 Physical to Physical (UUID Preservation)" \
            "6" "📚  About & Features" \
            "0" "🚪 Exit" \
            3>&1 1>&2 2>&3)
        
        clear
        
        case $choice in
            1) clone_virtual_to_physical ;;
            2) clone_physical_to_virtual ;;
            3) clone_virtual_to_virtual ;;
            4) clone_physical_to_physical_simple ;;
            5) clone_physical_to_physical_with_uuid ;;
            6)
                local about_text="🚀 FEATURES:\n\n✓ Smart Cloning: Copies only used space\n✓ Physical to Physical: Direct device cloning\n✓ UUID Preservation: Maintains filesystem & partition UUIDs\n✓ Proportional Resize: Fits larger disks to smaller ones\n✓ LUKS Support: Safe encrypted partition handling\n✓ Safety Checks: Prevents system damage\n✓ Multiple Formats: qcow2, vmdk, vdi, raw, vhd\n✓ DRY RUN Mode: Test operations safely\n\n🔧 PHYSICAL TO PHYSICAL MODES:\n\n• Simple Mode: Fast sector-by-sector copy\n• UUID Mode: Smart cloning with ID preservation\n  - Filesystem UUIDs maintained\n  - Partition UUIDs preserved\n  - Disk GUID maintained\n  - Bootloader compatibility\n\n🧪 DRY RUN MODE:\n\n• Test all operations without making changes\n• Log all commands that would be executed\n• Verify operation plans before real execution\n• Safe testing of complex cloning scenarios"
                
                if [ "$DRY_RUN" = true ]; then
                    about_text="$about_text\n\n🧪 CURRENTLY IN DRY RUN MODE\nNo destructive operations will be performed!"
                fi
                
                dialog --title "About Manzolo Disk Cloner v2.4" \
                    --msgbox "$about_text" 26 85
                ;;
            0|"") break ;;
        esac
    done
}

check_optional_tools() {
    local missing_tools=()
    for tool in partclone.ext4 partclone.ntfs zerofree; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "Optional optimization tools not found:"
        log "  ${missing_tools[*]}"
        log "For best results, install with: sudo apt-get install partclone zerofree"
        log "The script will work without them but with reduced optimization."
        sleep 3
    fi
}

# -------------------- MAIN EXECUTION --------------------

clear
log "╔═══════════════════════════════════════╗"
if [ "$DRY_RUN" = true ]; then
    log "║   🧪 Manzolo Disk Cloner v2.4 🧪      ║"
    log "║        DRY RUN MODE ENABLED          ║"
else
    log "║   🚀 Manzolo Disk Cloner v2.4 🚀      ║"
fi
log "╚═══════════════════════════════════════╝"

if [ "$DRY_RUN" = true ]; then
    log ""
    log "🧪 DRY RUN MODE: All destructive operations will be simulated"
    log "   Commands will be logged but not executed"
    log "   Safe for testing and verification"
    log ""
fi

check_optional_tools
main_menu

log "=============================="
if [ "$DRY_RUN" = true ]; then
    log "✅ Clone Script DRY RUN finished at $(date)"
else
    log "✅ Clone Script finished at $(date)"
fi
log "=============================="

exit 0