#!/bin/bash

# Disk Cloner with Proportional Resize
# Usage: ./disk_cloner.sh [--dry-run]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${YELLOW}DRY RUN MODE - No actual operations will be performed${NC}"
    echo
fi

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Function to get disk size in bytes
get_disk_size() {
    local disk="$1"
    blockdev --getsize64 "$disk" 2>/dev/null || echo "0"
}

# Function to get partition size in bytes
get_partition_size() {
    local partition="$1"
    blockdev --getsize64 "$partition" 2>/dev/null || echo "0"
}

# Function to get partition type
get_partition_type() {
    local partition="$1"
    lsblk -no FSTYPE "$partition" 2>/dev/null | head -n1
}

# Function to check if partition is EFI
is_efi_partition() {
    local partition="$1"
    local part_type=$(fdisk -l "$partition" 2>/dev/null | grep "EFI System" || true)
    local fs_type=$(get_partition_type "$partition")
    
    if [[ -n "$part_type" ]] || [[ "$fs_type" == "vfat" ]]; then
        # Additional check for EFI content
        if mount | grep -q "$partition"; then
            local mount_point=$(mount | grep "$partition" | awk '{print $3}' | head -n1)
            [[ -d "$mount_point/EFI" ]]
        else
            # Try to mount temporarily to check
            local temp_mount="/tmp/efi_check_$$"
            mkdir -p "$temp_mount"
            if mount "$partition" "$temp_mount" 2>/dev/null; then
                local is_efi=false
                [[ -d "$temp_mount/EFI" ]] && is_efi=true
                umount "$temp_mount"
                rmdir "$temp_mount"
                $is_efi
            else
                # Fallback: assume vfat small partitions are EFI
                [[ "$fs_type" == "vfat" ]]
            fi
        fi
    else
        false
    fi
}

# Function to list available disks
list_disks() {
    print_info "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | grep -v loop | while read -r line; do
        echo "  $line"
    done
}

# Function to select disk
select_disk() {
    local prompt="$1"
    local disk
    
    while true; do
        echo
        list_disks
        echo
        read -p "$prompt: " disk
        
        if [[ ! -b "$disk" ]]; then
            print_error "Invalid disk: $disk"
            continue
        fi
        
        if [[ "$disk" =~ [0-9]$ ]]; then
            print_error "Please specify the disk device (e.g., /dev/sda), not a partition"
            continue
        fi
        
        echo "$disk"
        break
    done
}

# Function to get partitions info
get_partitions_info() {
    local disk="$1"
    local -n partitions_ref=$2
    
    partitions_ref=()
    
    # Get partition list
    local part_list=$(lsblk -pno NAME "$disk" | grep -v "^$disk$" | grep "^${disk}[0-9]")
    
    for partition in $part_list; do
        local size=$(get_partition_size "$partition")
        local fs_type=$(get_partition_type "$partition")
        local is_efi=false
        
        if is_efi_partition "$partition"; then
            is_efi=true
        fi
        
        partitions_ref+=("$partition,$size,$fs_type,$is_efi")
    done
}

# Function to calculate proportional sizes
calculate_proportional_sizes() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    local -n target_sizes_ref=$4
    
    local source_size=$(get_disk_size "$source_disk")
    local target_size=$(get_disk_size "$target_disk")
    
    target_sizes_ref=()
    
    print_info "Source disk size: $(numfmt --to=iec --suffix=B $source_size)"
    print_info "Target disk size: $(numfmt --to=iec --suffix=B $target_size)"
    
    if [[ $source_size -le $target_size ]]; then
        print_info "Target disk is larger or equal, keeping original sizes"
        for part_info in "${source_parts_ref[@]}"; do
            IFS=',' read -r partition size fs_type is_efi <<< "$part_info"
            target_sizes_ref+=("$size")
        done
        return
    fi
    
    print_info "Target disk is smaller, calculating proportional sizes..."
    
    # Reserve space for partition table (1MB at start and end)
    local usable_target_size=$((target_size - 2 * 1024 * 1024))
    local total_efi_size=0
    local total_other_size=0
    
    # Calculate total sizes
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi <<< "$part_info"
        if [[ "$is_efi" == "true" ]]; then
            total_efi_size=$((total_efi_size + size))
        else
            total_other_size=$((total_other_size + size))
        fi
    done
    
    # Check if EFI partitions fit
    if [[ $total_efi_size -gt $usable_target_size ]]; then
        print_error "EFI partitions ($total_efi_size bytes) don't fit in target disk"
        exit 1
    fi
    
    local remaining_size=$((usable_target_size - total_efi_size))
    
    # Calculate proportional sizes
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi <<< "$part_info"
        
        if [[ "$is_efi" == "true" ]]; then
            # Keep EFI partitions same size
            target_sizes_ref+=("$size")
        else
            # Scale other partitions proportionally
            local new_size=$((size * remaining_size / total_other_size))
            # Align to MB boundary
            new_size=$(((new_size / 1048576) * 1048576))
            target_sizes_ref+=("$new_size")
        fi
    done
}

# Function to show operation plan
show_plan() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    local -n target_sizes_ref=$4
    
    echo
    print_info "OPERATION PLAN:"
    print_warning "Target disk $target_disk will be completely wiped!"
    echo
    
    printf "%-15s %-12s %-10s %-6s -> %-12s\n" "SOURCE" "SIZE" "FS TYPE" "EFI" "NEW SIZE"
    echo "--------------------------------------------------------"
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi <<< "${source_parts_ref[$i]}"
        local target_size="${target_sizes_ref[$i]}"
        
        printf "%-15s %-12s %-10s %-6s -> %-12s\n" \
            "$partition" \
            "$(numfmt --to=iec --suffix=B $size)" \
            "${fs_type:-unknown}" \
            "$is_efi" \
            "$(numfmt --to=iec --suffix=B $target_size)"
    done
    echo
}

# Function to create partition table
create_partitions() {
    local target_disk="$1"
    local -n source_parts_ref=$2
    local -n target_sizes_ref=$3
    
    print_info "Creating GPT partition table on $target_disk"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        parted "$target_disk" --script mklabel gpt
    else
        echo "  Would run: parted $target_disk --script mklabel gpt"
    fi
    
    local start_sector="1MiB"
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi <<< "${source_parts_ref[$i]}"
        local target_size="${target_sizes_ref[$i]}"
        local target_partition="${target_disk}$((i+1))"
        
        # Calculate end sector
        local size_mb=$((target_size / 1048576))
        local end_sector="${size_mb}MiB"
        
        print_info "Creating partition ${target_partition} (${start_sector} to ${end_sector})"
        
        if [[ "$is_efi" == "true" ]]; then
            if [[ "$DRY_RUN" == "false" ]]; then
                parted "$target_disk" --script mkpart primary fat32 "$start_sector" "$end_sector"
                parted "$target_disk" --script set $((i+1)) esp on
            else
                echo "  Would run: parted $target_disk --script mkpart primary fat32 $start_sector $end_sector"
                echo "  Would run: parted $target_disk --script set $((i+1)) esp on"
            fi
        else
            if [[ "$DRY_RUN" == "false" ]]; then
                parted "$target_disk" --script mkpart primary "$start_sector" "$end_sector"
            else
                echo "  Would run: parted $target_disk --script mkpart primary $start_sector $end_sector"
            fi
        fi
        
        # Update start_sector for next partition
        start_sector="$end_sector"
    done
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Inform kernel of partition changes
        partprobe "$target_disk"
        sleep 2
    else
        echo "  Would run: partprobe $target_disk"
    fi
}

# Function to clone partitions
clone_partitions() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r source_partition size fs_type is_efi <<< "${source_parts_ref[$i]}"
        local target_partition="${target_disk}$((i+1))"
        
        print_info "Cloning $source_partition to $target_partition"
        
        if [[ "$is_efi" == "true" ]]; then
            print_info "Using dd for EFI partition (exact copy)"
            if [[ "$DRY_RUN" == "false" ]]; then
                dd if="$source_partition" of="$target_partition" bs=1M status=progress
            else
                echo "  Would run: dd if=$source_partition of=$target_partition bs=1M status=progress"
            fi
        else
            case "$fs_type" in
                "ext2"|"ext3"|"ext4")
                    print_info "Using e2image for ext filesystem"
                    if [[ "$DRY_RUN" == "false" ]]; then
                        e2fsck -fy "$source_partition" || true
                        e2image -ra -p "$source_partition" "$target_partition"
                        resize2fs "$target_partition"
                    else
                        echo "  Would run: e2fsck -fy $source_partition"
                        echo "  Would run: e2image -ra -p $source_partition $target_partition"
                        echo "  Would run: resize2fs $target_partition"
                    fi
                    ;;
                "ntfs")
                    print_info "Using ntfsclone for NTFS filesystem"
                    if [[ "$DRY_RUN" == "false" ]]; then
                        ntfsclone -f --overwrite "$target_partition" "$source_partition"
                        ntfsresize -f "$target_partition"
                    else
                        echo "  Would run: ntfsclone -f --overwrite $target_partition $source_partition"
                        echo "  Would run: ntfsresize -f $target_partition"
                    fi
                    ;;
                *)
                    print_warning "Unknown filesystem $fs_type, using dd (may not resize properly)"
                    if [[ "$DRY_RUN" == "false" ]]; then
                        dd if="$source_partition" of="$target_partition" bs=1M status=progress
                    else
                        echo "  Would run: dd if=$source_partition of=$target_partition bs=1M status=progress"
                    fi
                    ;;
            esac
        fi
    done
}

# Main function
main() {
    print_info "Disk Cloner with Proportional Resize"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        check_root
    fi
    
    # Select source disk
    local source_disk=$(select_disk "Enter source disk (e.g., /dev/sda)")
    
    # Select target disk
    while true; do
        local target_disk=$(select_disk "Enter target disk (e.g., /dev/sdb)")
        
        if [[ "$source_disk" == "$target_disk" ]]; then
            print_error "Source and target disks cannot be the same"
            continue
        fi
        
        break
    done
    
    # Get partitions info
    local source_partitions=()
    get_partitions_info "$source_disk" source_partitions
    
    if [[ ${#source_partitions[@]} -eq 0 ]]; then
        print_error "No partitions found on source disk $source_disk"
        exit 1
    fi
    
    # Calculate target sizes
    local target_sizes=()
    calculate_proportional_sizes "$source_disk" "$target_disk" source_partitions target_sizes
    
    # Show plan
    show_plan "$source_disk" "$target_disk" source_partitions target_sizes
    
    # Confirm operation
    if [[ "$DRY_RUN" == "false" ]]; then
        echo -n "Are you sure you want to proceed? This will DESTROY all data on $target_disk [yes/NO]: "
        read -r confirm
        
        if [[ "$confirm" != "yes" ]]; then
            print_info "Operation cancelled"
            exit 0
        fi
    fi
    
    # Create partitions
    create_partitions "$target_disk" source_partitions target_sizes
    
    # Clone partitions
    clone_partitions "$source_disk" "$target_disk" source_partitions
    
    if [[ "$DRY_RUN" == "false" ]]; then
        print_success "Disk cloning completed successfully!"
        print_info "Final partition layout:"
        lsblk "$target_disk"
    else
        print_success "Dry run completed! No actual changes were made."
    fi
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    command -v lsblk >/dev/null || missing_deps+=("util-linux")
    command -v parted >/dev/null || missing_deps+=("parted")
    command -v e2image >/dev/null || missing_deps+=("e2fsprogs")
    command -v ntfsclone >/dev/null || missing_deps+=("ntfs-3g")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install with: apt-get install ${missing_deps[*]}"
        exit 1
    fi
}

# Run dependency check and main function
check_dependencies
main "$@"