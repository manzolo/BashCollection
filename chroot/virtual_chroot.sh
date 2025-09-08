#!/bin/bash

# Script to mount virtual disk images and chroot
# Supports vhd, qcow2, img, raw, vmdk, LUKS+LVM, XFS

set -e

# Global variables
NBD_DEVICE=""
MOUNT_POINTS=()
BIND_MOUNTS=()
CHROOT_DIR=""
LUKS_MAPPINGS=()    # e.g. luks-nbd0p3
ACTIVATED_VGS=()    # names of activated volume groups
OPEN_LUKS_PARTS=()  # device paths opened by cryptsetup

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

    # Deactivate LVM VGs we activated
    for vg in "${ACTIVATED_VGS[@]}"; do
        log "Deactivating VG: $vg"
        sudo vgchange -an "$vg" 2>/dev/null || warning "Error deactivating VG $vg"
    done

    # Close opened LUKS mappings
    for name in "${LUKS_MAPPINGS[@]}"; do
        log "Closing LUKS mapping: $name"
        sudo cryptsetup luksClose "$name" 2>/dev/null || warning "Error closing LUKS $name"
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
    local deps=("qemu-nbd" "fdisk" "lsblk" "file" "dialog" "cryptsetup" "pvs" "vgs" "lvs")
    
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
    
    # Determine initial format based on file extension or type
    if [[ "$image_file" == *.vtoy ]]; then
        format="vpc"
    elif [[ "$image_file" == *.vhd ]]; then
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
    
    log "Attempting to connect with format: $format"
    
    # Try connecting with the detected format
    if ! sudo qemu-nbd -c "$NBD_DEVICE" -f "$format" "$image_file" 2>/dev/null; then
        warning "Failed to connect $image_file with format $format"
        
        # If the format was vpc, try falling back to raw
        if [[ "$format" == "vpc" ]]; then
            log "Falling back to raw format..."
            format="raw"
            if ! sudo qemu-nbd -c "$NBD_DEVICE" -f "$format" "$image_file"; then
                error "Failed to connect $image_file with raw format"
                exit 1
            fi
        else
            error "Failed to connect $image_file with format $format"
            exit 1
        fi
    fi
    
    log "Successfully connected with format: $format"
    
    sleep 2
    sudo partprobe "$NBD_DEVICE" 2>/dev/null || true
    sleep 1
}

# Show available partitions
show_partitions() {
    log "Partitions found:"
    
    sudo fdisk -l "$NBD_DEVICE" | grep "^$NBD_DEVICE" || true
    
    echo ""
    log "Filesystem details:"
    
    for part in ${NBD_DEVICE}p*; do
        if [[ -e "$part" ]]; then
            local fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null || echo "unknown")
            local label=$(sudo blkid -o value -s LABEL "$part" 2>/dev/null || echo "")
            local size=$(lsblk -no SIZE "$part" 2>/dev/null || echo "unknown")
            
            echo "  $part: $fs_type, Size: $size, Label: $label"
        fi
    done
}

# Detect Linux, EFI, LUKS, LVM partitions
detect_partitions() {
    local linux_part=""
    local efi_part=""
    local luks_parts=()
    local lvm_parts=()
    
    for part in ${NBD_DEVICE}p*; do
        if [[ -e "$part" ]]; then
            local fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null || echo "")
            if [[ "$fs_type" == "ext4" || "$fs_type" == "ext3" || "$fs_type" == "ext2" || "$fs_type" == "btrfs" || "$fs_type" == "xfs" ]]; then
                # consider as possible linux root (but might be small/boot)
                # prefer ext over small partitions
                # if size > 300M treat as potential root
                local size_mb=$(lsblk -bno SIZE "$part" 2>/dev/null | awk '{print int($1/1024/1024)}')
                if [[ -z "$linux_part" ]] || (( size_mb > 500 )); then
                    linux_part="$part"
                fi
            elif [[ "$fs_type" == "vfat" ]]; then
                # small vfat -> probably EFI
                local size_mb=$(lsblk -bno SIZE "$part" 2>/dev/null | awk '{print int($1/1024/1024)}')
                if [[ $size_mb -lt 1000 ]]; then
                    efi_part="$part"
                fi
            elif [[ "$fs_type" == "crypto_LUKS" || "$fs_type" == "LUKS" || "$fs_type" == "crypto_LUKS" ]]; then
                luks_parts+=("$part")
            elif [[ "$fs_type" == "LVM2_member" ]]; then
                lvm_parts+=("$part")
            fi
        fi
    done
    
    # Return pipe-separated lists: linux|efi|luks_csv|lvm_csv
    local luks_csv=$(IFS=,; echo "${luks_parts[*]}")
    local lvm_csv=$(IFS=,; echo "${lvm_parts[*]}")
    echo "$linux_part|$efi_part|$luks_csv|$lvm_csv"
}

# Open LUKS partitions (asks for passphrase)
handle_luks_open() {
    local luks_csv="$1"
    IFS=, read -ra parts <<< "$luks_csv"
    local idx=0
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        local name="luks$(date +%s)_$idx"
        log "Opening LUKS partition $part as /dev/mapper/$name"
        if sudo cryptsetup luksOpen "$part" "$name"; then
            LUKS_MAPPINGS+=("$name")
            OPEN_LUKS_PARTS+=("/dev/mapper/$name")
        else
            warning "Failed to open LUKS partition: $part"
        fi
        idx=$((idx+1))
    done
}

# Activate LVM on physical volumes (including those inside LUKS mappings)
handle_lvm_activate() {
    # before activating, scan for physical volumes
    log "Scanning for LVM physical volumes"
    sudo pvscan --cache >/dev/null 2>&1 || true
    # Activate all volume groups
    local vgs
    vgs=$(sudo vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$vgs" ]]; then
        while read -r vg; do
            [[ -z "$vg" ]] && continue
            log "Activating VG: $vg"
            if sudo vgchange -ay "$vg"; then
                ACTIVATED_VGS+=("$vg")
            fi
        done <<< "$vgs"
    fi
}

# Find candidate root logical volume (search common names or any LV with filesystem)
find_root_lv() {
    # 1) Try find LV named root or similar
    local candidate=""
    local lvs_out
    lvs_out=$(sudo lvs --noheadings -o vg_name,lv_name,lv_path 2>/dev/null || true)
    while read -r line; do
        [[ -z "$line" ]] && continue
        local vg=$(echo "$line" | awk '{print $1}')
        local lv=$(echo "$line" | awk '{print $2}')
        local path=$(echo "$line" | awk '{print $3}')
        # try name heuristics
        if [[ "$lv" =~ root|rootlv|lvol0|system|ubuntu-root|centos-root ]]; then
            candidate="$path"
            break
        fi
        # otherwise check filesystem type
        local fstype=$(sudo blkid -o value -s TYPE "$path" 2>/dev/null || echo "")
        if [[ -n "$fstype" ]]; then
            candidate="$path"
            break
        fi
    done <<< "$lvs_out"

    # fallback: take first LV path
    if [[ -z "$candidate" ]]; then
        candidate=$(echo "$lvs_out" | head -n1 | awk '{print $3}' || true)
    fi

    echo "$candidate"
}

# Mount partition or LV
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
        "xfs")
            sudo mount -t xfs "$partition" "$mount_point"
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
        # Fai un backup solo se è un file normale, non un symlink
        if [[ -f "$chroot_dir/etc/resolv.conf" && ! -L "$chroot_dir/etc/resolv.conf" ]]; then
            sudo cp "$chroot_dir/etc/resolv.conf" "$chroot_dir/etc/resolv.conf.backup" 2>/dev/null || true
        fi

        # Sovrascrivi sempre, eliminando symlink eventuali
        sudo cp --remove-destination /etc/resolv.conf "$chroot_dir/etc/resolv.conf"
    fi

    success "Chroot environment prepared"
    echo ""
    echo "Entering chroot... Use 'exit' to leave."
    echo "Chroot directory: $chroot_dir"
    echo ""

    sudo chroot "$chroot_dir" /bin/bash --login

    # Ripristino eventuale backup
    if [[ -f "$chroot_dir/etc/resolv.conf.backup" ]]; then
        sudo mv "$chroot_dir/etc/resolv.conf.backup" "$chroot_dir/etc/resolv.conf"
    fi
}

# Function to select image file with navigation (unchanged)
select_image_file() {
    local current_dir="$PWD"
    local selected=""

    while true; do
        local menu_items=()

        if [[ "$current_dir" != "/" ]]; then
            menu_items+=(".." "Go to parent directory")
        fi

        while IFS= read -r -d '' item; do
            local name=$(basename "$item")
            if [[ -d "$item" ]]; then
                menu_items+=("📁 $name" "Directory")
            elif [[ "$name" == *.vhd || "$name" == *.vtoy || "$name" == *.qcow2 || "$name" == *.img || "$name" == *.raw || "$name" == *.vmdk ]]; then
                menu_items+=("💾 $name" "Disk image")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type d,f -not -path "$current_dir" -print0 | sort -z)

        if [[ ${#menu_items[@]} -eq 0 ]]; then
            error "No image files or directories found in $current_dir"
            return 1
        fi

        selected=$(dialog --title "Select image file or directory in $current_dir" --menu "Choose an option:" 20 60 12 "${menu_items[@]}" 2>&1 >/dev/tty)
        local dialog_status=$?

        if [[ $dialog_status -ne 0 ]]; then
            error "Selection canceled by user."
            return 1
        fi

        local raw_name=$(echo "$selected" | sed 's/^.\ //')

        if [[ "$selected" == ".." ]]; then
            current_dir=$(dirname "$current_dir")
        elif [[ -d "$current_dir/$raw_name" ]]; then
            current_dir="$current_dir/$raw_name"
        elif [[ -f "$current_dir/$raw_name" ]]; then
            case "$raw_name" in
                *.vhd|*.vtoy|*.qcow2|*.img|*.raw|*.vmdk)
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
    log "Script for mounting and chrooting virtual disk images (with LUKS/LVM support)"
    echo ""

    local image_file="$1"

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
    local luks_csv=$(echo "$partitions" | cut -d'|' -f3)
    local lvm_csv=$(echo "$partitions" | cut -d'|' -f4)

    [[ -n "$efi_part" ]] && log "EFI partition found: $efi_part"
    [[ -n "$luks_csv" ]] && log "LUKS partitions found: $luks_csv"
    [[ -n "$lvm_csv" ]] && log "LVM physical parts found: $lvm_csv"

    # If there's a LUKS partition, open it
    if [[ -n "$luks_csv" ]]; then
        handle_luks_open "$luks_csv"
    fi

    # After possibly opening LUKS, rescan devices so LVM can see PVs inside LUKS
    sudo partprobe 2>/dev/null || true
    sleep 1

    # Activate LVM (will scan inside opened LUKS maps)
    handle_lvm_activate

    # If linux_part wasn't detected but LVM exists, try find root LV
    if [[ -z "$linux_part" ]]; then
        # Try to find root LV inside LVM
        local root_lv
        root_lv=$(find_root_lv)
        if [[ -n "$root_lv" ]]; then
            linux_part="$root_lv"
            log "Using logical volume as linux partition: $linux_part"
        fi
    fi

    if [[ -z "$linux_part" ]]; then
        error "No Linux partition (ext4, ext3, ext2, btrfs, xfs) or suitable LV found"
        exit 1
    fi

    log "Linux partition found: $linux_part"
    [[ -n "$efi_part" ]] && log "EFI partition found: $efi_part"

    # Determine filesystem type for linux_part
    local linux_fs=$(sudo blkid -o value -s TYPE "$linux_part" 2>/dev/null || true)
    if [[ -z "$linux_fs" ]]; then
        # attempt to probe using file -s
        linux_fs=$(sudo file -sL "$linux_part" | awk -F', ' '{print $2}' | awk '{print $1}' || echo "")
    fi
    local linux_mount="/tmp/disk_mount_$(date +%s)"
    mount_partition "$linux_part" "$linux_mount" "$linux_fs"

    # Sanity check for typical distro layout: /etc plus /bin or /usr/bin
    if [[ ! -d "$linux_mount/etc" ]] || { [[ ! -d "$linux_mount/bin" ]] && [[ ! -d "$linux_mount/usr/bin" ]]; }; then
        warning "Mounted partition does not show typical root filesystem layout (missing /etc or /bin)."
        # But it might be a separate /boot or small filesystem. Try to find a real root LV if LVM present.
        if [[ ${#ACTIVATED_VGS[@]} -gt 0 ]]; then
            log "Attempting to locate alternate root LV inside activated VGs..."
            local alt_root
            alt_root=$(find_root_lv)
            if [[ -n "$alt_root" && "$alt_root" != "$linux_part" ]]; then
                log "Found alternate LV: $alt_root. Remounting..."
                # unmount previous
                sudo umount "$linux_mount" 2>/dev/null || true
                MOUNT_POINTS=("${MOUNT_POINTS[@]/$linux_mount}")
                rmdir "$linux_mount" 2>/dev/null || true
                linux_part="$alt_root"
                linux_fs=$(sudo blkid -o value -s TYPE "$linux_part" 2>/dev/null || echo "")
                linux_mount="/tmp/disk_mount_$(date +%s)"
                mount_partition "$linux_part" "$linux_mount" "$linux_fs"
            else
                error "Does not appear to be a valid Linux system (missing /etc or /bin)."
                exit 1
            fi
        else
            error "Does not appear to be a valid Linux system (missing /etc or /bin)."
            exit 1
        fi
    fi

    success "Linux system mounted in: $linux_mount"

    enter_chroot "$linux_mount" "$efi_part"
}

# Run script
main "$@"
