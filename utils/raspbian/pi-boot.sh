#!/usr/bin/env bash
set -euo pipefail

# PiBoot - Boot Raspberry Pi images in QEMU
# Usage: sudo ./pi-boot.sh image.qcow2 [options]
# Requirements: qemu-nbd, kpartx, qemu-system-arm, qemu-system-aarch64, blockdev

VERSION="1.6"
SCRIPT_NAME="$(basename "$0")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { [[ "${DEBUG:-}" == "1" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2 || true; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }

# Show usage
show_help() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Boot Raspberry Pi images in QEMU

USAGE:
    sudo $SCRIPT_NAME <image_file> [options]

ARGUMENTS:
    image_file          Path to qcow2, img, or raw image file

OPTIONS:
    -h, --help          Show this help message
    -v, --version       Show version
    --nogui            Run without GUI (nographic mode)
    --mem <size>       Memory size in MB (default: 1024 for raspi, 2048 for virt)
    --cpu <type>       CPU type (default: auto-detect)
    --arch <arch>      Force architecture: arm, aarch64
    --machine <type>   QEMU machine type (default: raspi3b for aarch64, versatilepb for arm)
    --kernel <path>    Force kernel path
    --dtb <path>       Force device tree blob path
    --cmdline <args>   Custom kernel command line
    --ssh [port]       Enable SSH forwarding (default port: 2222)
    --vnc [display]    Enable VNC (default: :1)
    --usb              Enable USB support
    --audio            Enable audio support
    --debug            Enable debug output
    --dry-run          Show command without executing
    --keep-temp        Keep temporary files after exit
    --bios-boot        Force BIOS boot (skip kernel/dtb loading)
    --prefer-virt      Use virt machine instead of raspi (better compatibility)

EXAMPLES:
    sudo $SCRIPT_NAME raspios-lite.img --ssh
    sudo $SCRIPT_NAME pi-image.qcow2 --mem 1024 --nogui
    sudo $SCRIPT_NAME custom.img --arch aarch64 --vnc
    sudo $SCRIPT_NAME raspios.img --prefer-virt --bios-boot

NOTES:
    - Default uses raspi3b machine for best Pi compatibility
    - Use --prefer-virt for better performance but less Pi-specific hardware
    - SSH: Connect with 'ssh -p 2222 pi@localhost'
    - Ctrl+A X to exit QEMU, Ctrl+A C for monitor
EOF
}

# Default values
IMG=""
MEM=""  # Will be set based on machine type
CPU_TYPE=""
ARCH=""
MACHINE=""
KERNEL_PATH=""
DTB_PATH=""
CUSTOM_CMDLINE=""
NOGRAPHIC=false
ENABLE_SSH=false
SSH_PORT="2222"
ENABLE_VNC=false
VNC_DISPLAY=":1"
ENABLE_USB=false
ENABLE_AUDIO=false
DEBUG=false
DRY_RUN=false
KEEP_TEMP=false
BIOS_BOOT=false
PREFER_VIRT=false
EXTRA_QEMU_ARGS=()

# Global variables for cleanup
USED_NBD=""
MOUNT_POINT=""
TEMP_DIR=""
BOOT_PARTITION=""
TEMP_KERNEL=""
TEMP_DTB=""
TEMP_INITRD=""
KPARTX_MAPPINGS=()

# Parse arguments
parse_args() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi

    IMG="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -v|--version) echo "$SCRIPT_NAME version $VERSION"; exit 0 ;;
            --nogui) NOGRAPHIC=true; shift ;;
            --mem) MEM="$2"; shift 2 ;;
            --cpu) CPU_TYPE="$2"; shift 2 ;;
            --arch) ARCH="$2"; shift 2 ;;
            --machine) MACHINE="$2"; shift 2 ;;
            --kernel) KERNEL_PATH="$2"; shift 2 ;;
            --dtb) DTB_PATH="$2"; shift 2 ;;
            --cmdline) CUSTOM_CMDLINE="$2"; shift 2 ;;
            --prefer-virt) PREFER_VIRT=true; shift ;;
            --ssh)
                ENABLE_SSH=true
                if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                    SSH_PORT="$2"; shift 2
                else
                    shift
                fi ;;
            --vnc)
                ENABLE_VNC=true
                if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                    VNC_DISPLAY="$2"; shift 2
                else
                    shift
                fi ;;
            --usb) ENABLE_USB=true; shift ;;
            --audio) ENABLE_AUDIO=true; shift ;;
            --debug) DEBUG=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --keep-temp) KEEP_TEMP=true; shift ;;
            --bios-boot) BIOS_BOOT=true; shift ;;
            --) shift; EXTRA_QEMU_ARGS+=("$@"); break ;;
            -*) log_error "Unknown option: $1"; exit 1 ;;
            *) EXTRA_QEMU_ARGS+=("$1"); shift ;;
        esac
    done
}

# Check prerequisites
check_requirements() {
    local missing=()
    
    for cmd in qemu-nbd kpartx blkid file blockdev; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if ! command -v qemu-system-arm >/dev/null 2>&1 && ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
        missing+=("qemu-system-arm or qemu-system-aarch64")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install with: apt-get install qemu-system-arm qemu-system-aarch64 qemu-utils kpartx util-linux"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges (use sudo)"
        exit 1
    fi

    if [[ ! -f "$IMG" ]]; then
        log_error "Image file not found: $IMG"
        exit 1
    fi
}

# Robust cleanup function
cleanup() {
    log_debug "Starting cleanup..."
    local exit_code=$?
    set +e  # Don't exit on errors during cleanup
    
    # Unmount if mounted
    if [[ -n "$MOUNT_POINT" ]] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_debug "Unmounting $MOUNT_POINT"
        umount "$MOUNT_POINT" 2>/dev/null || {
            log_debug "Force unmounting $MOUNT_POINT"
            umount -f "$MOUNT_POINT" 2>/dev/null || true
        }
    fi
    
    # Remove kpartx mappings
    if [[ -n "$USED_NBD" ]] && [[ ${#KPARTX_MAPPINGS[@]} -gt 0 ]]; then
        log_debug "Removing kpartx mappings for $USED_NBD"
        kpartx -d "$USED_NBD" >/dev/null 2>&1 || true
        sleep 1
    fi
    
    # Disconnect NBD device
    if [[ -n "$USED_NBD" ]] && [[ -b "$USED_NBD" ]]; then
        log_debug "Disconnecting NBD device $USED_NBD"
        local attempts=3
        for ((i=1; i<=attempts; i++)); do
            if qemu-nbd --disconnect "$USED_NBD" >/dev/null 2>&1; then
                log_debug "NBD device $USED_NBD disconnected successfully"
                break
            elif [[ $i -eq $attempts ]]; then
                log_debug "Failed to disconnect $USED_NBD after $attempts attempts"
            else
                log_debug "NBD disconnect attempt $i failed, retrying..."
                sleep 1
            fi
        done
    fi
    
    # Remove mount point
    if [[ -n "$MOUNT_POINT" ]] && [[ -d "$MOUNT_POINT" ]]; then
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
    
    # Handle temporary directory
    if [[ -n "$TEMP_DIR" ]]; then
        if [[ "$KEEP_TEMP" == false ]]; then
            log_debug "Removing temporary directory $TEMP_DIR"
            rm -rf "$TEMP_DIR" 2>/dev/null || true
        else
            log_info "Temporary files kept in: $TEMP_DIR"
        fi
    fi
    
    log_debug "Cleanup completed"
    exit $exit_code
}

# Find available NBD device
find_free_nbd() {
    log_debug "Looking for free NBD device"
    
    # Load NBD module if not loaded
    if ! lsmod | grep -q nbd; then
        log_debug "Loading NBD module"
        modprobe nbd nbds_max=32 max_part=16 2>/dev/null || {
            log_error "Failed to load nbd module"
            return 1
        }
    fi
    
    # Check devices 0-31
    for nbd_num in {0..31}; do
        local nbd_dev="/dev/nbd${nbd_num}"
        log_debug "Checking NBD device: $nbd_dev"
        
        # Create device node if missing
        if [[ ! -b "$nbd_dev" ]]; then
            log_debug "Creating device node $nbd_dev"
            mknod "$nbd_dev" b 43 $nbd_num 2>/dev/null || continue
        fi
        
        # Check if device is free (size = 0)
        local size
        size=$(blockdev --getsize64 "$nbd_dev" 2>/dev/null || echo -1)
        log_debug "$nbd_dev size: $size bytes"
        if [[ $size -eq 0 ]]; then
            log_debug "Found free NBD device: $nbd_dev"
            echo "$nbd_dev"
            return 0
        else
            log_debug "$nbd_dev is in use (size: $size)"
        fi
    done
    
    log_error "No free NBD device found. Check running processes with: ps aux | grep qemu-nbd"
    log_error "Or increase nbds_max in modprobe (e.g., modprobe nbd nbds_max=64)"
    return 1
}

# Setup NBD connection
setup_nbd() {
    log_info "Setting up NBD device for $IMG"
    
    # Find free NBD device
    USED_NBD=$(find_free_nbd) || {
        log_error "Cannot find free NBD device"
        exit 1
    }
    
    log_debug "Using NBD device: $USED_NBD"
    
    # Connect image to NBD device
    local max_attempts=5
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        log_debug "NBD connection attempt $attempt"
        if qemu-nbd --connect="$USED_NBD" "$IMG" --cache=writeback --aio=threads; then
            log_debug "NBD connection successful"
            break
        elif [[ $attempt -eq $max_attempts ]]; then
            log_error "Failed to connect $IMG to $USED_NBD after $max_attempts attempts"
            exit 1
        else
            log_debug "Connection failed, retrying in 2 seconds..."
            sleep 2
        fi
    done
    
    # Wait for device to be ready
    local timeout=15
    log_debug "Waiting for NBD device to be ready..."
    while [[ $timeout -gt 0 ]]; do
        if [[ -b "$USED_NBD" ]] && blockdev --getsize64 "$USED_NBD" >/dev/null 2>&1; then
            log_debug "NBD device ready"
            break
        fi
        sleep 1
        ((timeout--))
    done
    
    if [[ $timeout -eq 0 ]]; then
        log_error "NBD device $USED_NBD not ready after 15 seconds"
        exit 1
    fi

    # Create partition mappings
    log_info "Creating partition mappings"
    if kpartx -av "$USED_NBD" >/dev/null 2>&1; then
        # Store mapping info for cleanup
        mapfile -t KPARTX_MAPPINGS < <(kpartx -l "$USED_NBD" 2>/dev/null | awk '{print $1}' || true)
        log_debug "Created ${#KPARTX_MAPPINGS[@]} partition mappings"
    else
        log_warn "kpartx failed, trying partprobe..."
        partprobe "$USED_NBD" >/dev/null 2>&1 || {
            log_error "Failed to create partition mappings"
            exit 1
        }
    fi
    
    sleep 3  # Give time for mappings to settle
    log_success "NBD setup completed successfully"
}

# Find and mount boot partition
find_boot_partition() {
    if [[ "$BIOS_BOOT" == true ]]; then
        log_info "BIOS boot mode enabled, skipping boot partition analysis"
        return 0
    fi
    
    log_info "Searching for boot partition"
    
    # Create unique mount point
    MOUNT_POINT="/mnt/piboot_$$"
    mkdir -p "$MOUNT_POINT"
    
    # Look for partition mappings
    local parts=()
    local base_name
    base_name=$(basename "$USED_NBD")
    
    # Check for mapper devices first
    if [[ -d /dev/mapper ]]; then
        mapfile -t parts < <(ls -1 /dev/mapper/ 2>/dev/null | grep -E "^${base_name}p[0-9]+$" || true)
    fi
    
    # Fallback: direct partition devices
    if [[ ${#parts[@]} -eq 0 ]]; then
        log_debug "No mapper devices found, checking direct partitions"
        for p in {1..8}; do
            local dev="${USED_NBD}p${p}"
            if [[ -b "$dev" ]]; then
                parts+=("$(basename "$dev")")
                log_debug "Found partition: $dev"
            fi
        done
    fi
    
    if [[ ${#parts[@]} -eq 0 ]]; then
        log_error "No partitions found in image"
        return 1
    fi
    
    log_debug "Found ${#parts[@]} partitions: ${parts[*]}"
    
    # Find boot partition (prefer FAT filesystem)
    local boot_part=""
    for mapper in "${parts[@]}"; do
        local dev=""
        if [[ -b "/dev/mapper/$mapper" ]]; then
            dev="/dev/mapper/$mapper"
        elif [[ -b "/dev/$mapper" ]]; then
            dev="/dev/$mapper"
        else
            continue
        fi
        
        local fstype
        fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || echo "unknown")
        log_debug "Partition $dev: filesystem=$fstype"
        
        # Prefer FAT (typical Raspberry Pi boot partition)
        if [[ "$fstype" =~ ^(vfat|fat32|fat16)$ ]]; then
            boot_part="$dev"
            log_info "Found FAT boot partition: $dev"
            break
        fi
    done
    
    # If no FAT partition, search for boot files
    if [[ -z "$boot_part" ]]; then
        log_debug "No FAT partition found, searching for boot files"
        for mapper in "${parts[@]}"; do
            local dev=""
            if [[ -b "/dev/mapper/$mapper" ]]; then
                dev="/dev/mapper/$mapper"
            elif [[ -b "/dev/$mapper" ]]; then
                dev="/dev/$mapper"
            else
                continue
            fi
            
            log_debug "Checking for boot files in $dev"
            if mount -o ro "$dev" "$MOUNT_POINT" 2>/dev/null; then
                if ls "$MOUNT_POINT"/kernel* >/dev/null 2>&1 || 
                   ls "$MOUNT_POINT"/*.img >/dev/null 2>&1 || 
                   [[ -f "$MOUNT_POINT/cmdline.txt" ]] || 
                   [[ -f "$MOUNT_POINT/config.txt" ]]; then
                    boot_part="$dev"
                    log_info "Found boot files in: $dev"
                    umount "$MOUNT_POINT"
                    break
                fi
                umount "$MOUNT_POINT"
            fi
        done
    fi
    
    if [[ -z "$boot_part" ]]; then
        log_error "Could not find boot partition"
        return 1
    fi
    
    # Mount boot partition
    log_info "Mounting boot partition: $boot_part"
    if ! mount -o ro "$boot_part" "$MOUNT_POINT"; then
        log_error "Failed to mount boot partition"
        return 1
    fi
    
    BOOT_PARTITION="$boot_part"
    return 0
}

# Detect Pi model and analyze boot files
analyze_boot() {
    if [[ "$BIOS_BOOT" == true ]]; then
        echo "|||unknown|"
        return 0
    fi
    
    log_info "Analyzing boot partition contents"
    
    # Detect Pi model
    local pi_model="unknown"
    if [[ -f "$MOUNT_POINT/kernel8.img" ]]; then
        if [[ -f "$MOUNT_POINT/kernel7l.img" ]]; then
            pi_model="pi4"
        else
            pi_model="pi3"
        fi
    elif [[ -f "$MOUNT_POINT/kernel7.img" ]]; then
        pi_model="pi2"
    elif [[ -f "$MOUNT_POINT/kernel.img" ]]; then
        pi_model="pi1"
    fi
    
    if [[ "$pi_model" != "unknown" ]]; then
        log_info "Detected Raspberry Pi model: $pi_model"
    fi
    
    # Find kernel
    local kernel=""
    local kernel_candidates=(
        "$MOUNT_POINT/kernel8.img"
        "$MOUNT_POINT/kernel7l.img"
        "$MOUNT_POINT/kernel7.img"
        "$MOUNT_POINT/kernel.img"
        "$MOUNT_POINT/Image"
        "$MOUNT_POINT/Image.gz"
    )
    
    for candidate in "${kernel_candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            kernel="$candidate"
            log_info "Found kernel: $(basename "$candidate")"
            break
        fi
    done
    
    # Find DTB
    local dtb=""
    local dtb_candidates=()
    
    case "$pi_model" in
        pi4)
            dtb_candidates+=(
                "$MOUNT_POINT/bcm2711-rpi-4-b.dtb"
                "$MOUNT_POINT/bcm2711-rpi-400.dtb"
            ) ;;
        pi3)
            dtb_candidates+=(
                "$MOUNT_POINT/bcm2710-rpi-3-b-plus.dtb"
                "$MOUNT_POINT/bcm2710-rpi-3-b.dtb"
                "$MOUNT_POINT/bcm2837-rpi-3-b.dtb"
            ) ;;
        pi2)
            dtb_candidates+=(
                "$MOUNT_POINT/bcm2709-rpi-2-b.dtb"
                "$MOUNT_POINT/bcm2710-rpi-2-b.dtb"
            ) ;;
        *)
            dtb_candidates+=(
                "$MOUNT_POINT/bcm2708-rpi-b.dtb"
                "$MOUNT_POINT/bcm2708-rpi-b-plus.dtb"
            ) ;;
    esac
    
    # Add generic DTB search
    for dtb_file in "$MOUNT_POINT"/*.dtb; do
        if [[ -f "$dtb_file" ]]; then
            dtb_candidates+=("$dtb_file")
        fi
    done
    
    for dtb_path in "${dtb_candidates[@]}"; do
        if [[ -f "$dtb_path" ]]; then
            dtb="$dtb_path"
            log_info "Found DTB: $(basename "$dtb")"
            break
        fi
    done
    
    # Find initrd
    local initrd=""
    for initrd_candidate in "$MOUNT_POINT"/initramfs* "$MOUNT_POINT"/initrd*; do
        if [[ -f "$initrd_candidate" ]]; then
            initrd="$initrd_candidate"
            log_info "Found initrd: $(basename "$initrd")"
            break
        fi
    done
    
    # Read cmdline
    local cmdline=""
    if [[ -f "$MOUNT_POINT/cmdline.txt" ]]; then
        cmdline=$(tr -d '\r\n' < "$MOUNT_POINT/cmdline.txt")
        log_info "Cmdline from image: $cmdline"
    fi
    
    echo "$kernel|$dtb|$cmdline|$pi_model|$initrd"
}

# Copy boot files to temp directory
copy_boot_files() {
    local kernel="$1"
    local dtb="$2"
    local initrd="$3"
    
    TEMP_DIR="/tmp/piboot_$$"
    mkdir -p "$TEMP_DIR"
    
    if [[ -n "$kernel" && -f "$kernel" ]]; then
        log_info "Copying kernel to temporary location"
        cp "$kernel" "$TEMP_DIR/kernel"
        TEMP_KERNEL="$TEMP_DIR/kernel"
    fi
    
    if [[ -n "$dtb" && -f "$dtb" ]]; then
        log_info "Copying DTB to temporary location"
        cp "$dtb" "$TEMP_DIR/dtb"
        TEMP_DTB="$TEMP_DIR/dtb"
    fi
    
    if [[ -n "$initrd" && -f "$initrd" ]]; then
        log_info "Copying initrd to temporary location"
        cp "$initrd" "$TEMP_DIR/initrd"
        TEMP_INITRD="$TEMP_DIR/initrd"
    fi
}

# Detect architecture
detect_architecture() {
    local kernel="$1"
    local pi_model="$2"
    
    if [[ -n "$ARCH" ]]; then
        echo "$ARCH"
        return
    fi
    
    case "$pi_model" in
        pi4|pi3) echo "aarch64" ;;
        pi2|pi1) echo "arm" ;;
        *)
            if [[ -n "$kernel" && -f "$kernel" ]]; then
                local file_output
                file_output=$(file -b "$kernel" 2>/dev/null || echo "unknown")
                if echo "$file_output" | grep -qi 'aarch64\|arm64'; then
                    echo "aarch64"
                elif echo "$file_output" | grep -qi 'arm'; then
                    echo "arm"
                else
                    echo "aarch64"
                fi
            else
                echo "aarch64"
            fi ;;
    esac
}

# Process cmdline for QEMU
process_cmdline() {
    local cmdline="$1"
    local machine="$2"
    
    # Replace serial console
    cmdline="${cmdline//console=serial0/console=ttyAMA0}"
    
    # Fix root device based on machine
    if [[ "$machine" =~ raspi ]]; then
        cmdline=$(echo "$cmdline" | sed -E 's/root=PARTUUID=[^ ]+/root=\/dev\/mmcblk0p2/')
    else
        cmdline=$(echo "$cmdline" | sed -E 's/root=PARTUUID=[^ ]+/root=\/dev\/vda2/')
    fi
    
    # Remove problematic options
    cmdline="${cmdline//plymouth.ignore-serial-consoles/}"
    cmdline="${cmdline//splash/}"
    if [[ "$DEBUG" != true ]]; then
        cmdline="${cmdline//quiet/}"
    fi
    
    # Add console if missing
    if [[ ! "$cmdline" =~ console= ]]; then
        cmdline="console=ttyAMA0,115200 $cmdline"
    fi
    
    # Clean up spaces
    cmdline=$(echo "$cmdline" | tr -s ' ' | sed 's/^ *//; s/ *$//')
    
    echo "$cmdline"
}

# Build QEMU command
build_qemu_command() {
    local kernel="$1"
    local dtb="$2"
    local cmdline="$3"
    local arch="$4"
    local pi_model="$5"
    local initrd="$6"
    
    local cmd=()
    local selected_machine=""
    
    # Choose QEMU binary and default machine
    if [[ "$arch" == "aarch64" ]]; then
        cmd+=("qemu-system-aarch64")
        if [[ "$PREFER_VIRT" == true || "$BIOS_BOOT" == true ]]; then
            selected_machine="virt"
        else
            selected_machine="raspi3b"
        fi
    else
        cmd+=("qemu-system-arm")
        selected_machine="versatilepb"
    fi
    
    # Override with user-specified machine
    if [[ -n "$MACHINE" ]]; then
        selected_machine="$MACHINE"
    fi
    
    cmd+=("-M" "$selected_machine")
    
    # CPU selection
    if [[ -n "$CPU_TYPE" ]]; then
        cmd+=("-cpu" "$CPU_TYPE")
    elif [[ ! "$selected_machine" =~ raspi ]]; then
        if [[ "$arch" == "aarch64" ]]; then
            cmd+=("-cpu" "cortex-a72")
        else
            cmd+=("-cpu" "arm1176")
        fi
    fi
    # Note: raspi machines have their own CPU defaults, don't override
    
    # Memory configuration
    if [[ -n "$MEM" ]]; then
        # User specified memory
        if [[ "$selected_machine" == "versatilepb" && "$MEM" -gt 256 ]]; then
            log_warn "versatilepb machine limited to 256MB, adjusting memory"
            MEM=256
        elif [[ "$selected_machine" =~ raspi.*(2|3)b && "$MEM" -gt 1024 ]]; then
            log_warn "Limiting memory to 1024MB for $selected_machine"
            MEM=1024
        fi
    else
        # Auto-select memory based on machine
        case "$selected_machine" in
            versatilepb) MEM=256 ;;
            raspi*) MEM=1024 ;;
            *) MEM=2048 ;;
        esac
    fi
    cmd+=("-m" "$MEM")
    
    # Storage configuration
    if [[ "$selected_machine" =~ raspi ]]; then
        cmd+=("-drive" "file=$IMG,if=sd,format=qcow2")
    else
        cmd+=("-drive" "file=$IMG,if=none,format=qcow2,id=hd0")
        if [[ "$selected_machine" == "versatilepb" ]]; then
            cmd+=("-device" "virtio-blk-pci,drive=hd0")
        else
            cmd+=("-device" "virtio-blk-device,drive=hd0")
        fi
    fi
    
    # Network configuration
    if [[ "$ENABLE_SSH" == true ]]; then
        if [[ "$selected_machine" =~ raspi ]]; then
            cmd+=("-netdev" "user,id=net0,hostfwd=tcp::$SSH_PORT-:22")
            cmd+=("-device" "usb-net,netdev=net0")
        elif [[ "$selected_machine" == "versatilepb" ]]; then
            cmd+=("-netdev" "user,id=mynet,hostfwd=tcp::$SSH_PORT-:22")
            cmd+=("-device" "rtl8139,netdev=mynet")
        else
            cmd+=("-netdev" "user,id=mynet,hostfwd=tcp::$SSH_PORT-:22")
            cmd+=("-device" "virtio-net-device,netdev=mynet")
        fi
    else
        if [[ "$selected_machine" =~ raspi ]]; then
            cmd+=("-netdev" "user,id=net0")
            cmd+=("-device" "usb-net,netdev=net0")
        elif [[ "$selected_machine" == "versatilepb" ]]; then
            cmd+=("-netdev" "user,id=mynet")
            cmd+=("-device" "rtl8139,netdev=mynet")
        else
            cmd+=("-netdev" "user,id=mynet")
            cmd+=("-device" "virtio-net-device,netdev=mynet")
        fi
    fi
    
    # Boot configuration
    if [[ "$BIOS_BOOT" != true && -n "$kernel" ]]; then
        cmd+=("-kernel" "$kernel")
        
        # DTB only for non-raspi machines
        if [[ -n "$dtb" && ! "$selected_machine" =~ raspi ]]; then
            cmd+=("-dtb" "$dtb")
        fi
        
        if [[ -n "$initrd" ]]; then
            cmd+=("-initrd" "$initrd")
        fi
        
        # Command line
        local processed_cmdline
        if [[ -n "$CUSTOM_CMDLINE" ]]; then
            processed_cmdline="$CUSTOM_CMDLINE"
        else
            processed_cmdline=$(process_cmdline "$cmdline" "$selected_machine")
        fi
        
        if [[ -n "$processed_cmdline" ]]; then
            cmd+=("-append" "$processed_cmdline")
        fi
    fi
    
    # Display options - FIXED: No more stdio conflicts!
    if [[ "$NOGRAPHIC" == true ]]; then
        cmd+=("-nographic")
    elif [[ "$ENABLE_VNC" == true ]]; then
        cmd+=("-vnc" "$VNC_DISPLAY" "-display" "none")
    else
        # Only add serial stdio if NOT using nographic
        if [[ ! "$selected_machine" =~ raspi ]]; then
            cmd+=("-serial" "stdio")
        fi
    fi
    
    # USB support
    if [[ "$ENABLE_USB" == true && ! "$selected_machine" =~ raspi ]]; then
        cmd+=("-device" "qemu-xhci")
    fi
    
    # Audio
    if [[ "$ENABLE_AUDIO" == true ]]; then
        cmd+=("-audiodev" "pa,id=audio0" "-device" "intel-hda" "-device" "hda-duplex,audiodev=audio0")
    fi
    
    # Extra arguments
    cmd+=("${EXTRA_QEMU_ARGS[@]}")
    
    # Output command
    printf '%q ' "${cmd[@]}"
    echo
}

# Main execution
main() {
    parse_args "$@"
    
    log_info "Raspberry Pi QEMU Boot Script v$VERSION"
    log_info "Image: $IMG"
    
    check_requirements
    
    # Set up cleanup trap
    trap cleanup EXIT INT TERM
    
    # Skip NBD setup for BIOS boot
    local boot_info="|||unknown|"
    local kernel="" dtb="" cmdline="" pi_model="unknown" initrd=""
    
    if [[ "$BIOS_BOOT" != true ]]; then
        setup_nbd
        
        if find_boot_partition; then
            boot_info=$(analyze_boot)
            IFS='|' read -r kernel dtb cmdline pi_model initrd <<< "$boot_info"
            
            # Override with command line options
            [[ -n "$KERNEL_PATH" ]] && kernel="$KERNEL_PATH"
            [[ -n "$DTB_PATH" ]] && dtb="$DTB_PATH"
            
            # Copy boot files before cleanup
            copy_boot_files "$kernel" "$dtb" "$initrd"
            
            # Use temp files if available
            [[ -n "$TEMP_KERNEL" ]] && kernel="$TEMP_KERNEL"
            [[ -n "$TEMP_DTB" ]] && dtb="$TEMP_DTB"  
            [[ -n "$TEMP_INITRD" ]] && initrd="$TEMP_INITRD"
        else
            log_warn "Failed to analyze boot partition, falling back to BIOS boot"
            BIOS_BOOT=true
        fi
        
        # Clean up NBD before starting QEMU
        log_info "Releasing NBD device to unlock image..."
        if [[ -n "$MOUNT_POINT" ]] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            umount "$MOUNT_POINT" || umount -f "$MOUNT_POINT"
        fi
        if [[ -n "$USED_NBD" ]]; then
            kpartx -d "$USED_NBD" >/dev/null 2>&1 || true
            qemu-nbd --disconnect "$USED_NBD" >/dev/null 2>&1 || true
            USED_NBD=""  # Clear so cleanup doesn't try again
        fi
    fi
    
    local arch
    arch=$(detect_architecture "$kernel" "$pi_model")
    
    log_info "========================================="
    log_info "System Detection Results:"
    log_info "  Boot Mode: $([ "$BIOS_BOOT" == true ] && echo "BIOS" || echo "Direct Kernel")"
    log_info "  Architecture: $arch"
    log_info "  Pi Model: $pi_model"
    log_info "  Machine Type: $(if [[ -n "$MACHINE" ]]; then echo "$MACHINE"; elif [[ "$arch" == "aarch64" ]]; then if [[ "$PREFER_VIRT" == true || "$BIOS_BOOT" == true ]]; then echo "virt"; else echo "raspi3b"; fi; else echo "versatilepb"; fi)"
    log_info "  Kernel: ${kernel:-'(BIOS boot - using bootloader)'}"
    log_info "  DTB: ${dtb:-'(not found or not needed)'}"
    log_info "  Initrd: ${initrd:-'(not found)'}"
    
    # Show memory that will be used
    local mem_display="$MEM"
    if [[ -z "$MEM" ]]; then
        if [[ "$arch" == "aarch64" ]]; then
            if [[ "$PREFER_VIRT" == true || "$BIOS_BOOT" == true ]]; then
                mem_display="2048 (auto)"
            else
                mem_display="1024 (auto)"
            fi
        else
            mem_display="256 (auto)"
        fi
    fi
    log_info "  Memory: ${mem_display}MB"
    
    if [[ "$ENABLE_SSH" == true ]]; then
        log_info "  SSH: localhost:$SSH_PORT -> guest:22"
        log_info "  Connect with: ssh -p $SSH_PORT pi@localhost"
    fi
    
    if [[ "$ENABLE_VNC" == true ]]; then
        log_info "  VNC Display: $VNC_DISPLAY"
    fi
    log_info "========================================="
    
    local qemu_command
    qemu_command=$(build_qemu_command "$kernel" "$dtb" "$cmdline" "$arch" "$pi_model" "$initrd")
    
    echo
    log_info "Generated QEMU command:"
    echo -e "${YELLOW}$qemu_command${NC}"
    echo
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Dry run mode - not executing QEMU"
        exit 0
    fi
    
    # Provide helpful tips
    log_info "Tips:"
    log_info "  - Press Ctrl-A X to exit QEMU"
    log_info "  - Press Ctrl-A C for QEMU monitor console"
    if [[ "$ENABLE_SSH" == false ]]; then
        log_info "  - Add --ssh to enable SSH forwarding"
    fi
    if [[ "$BIOS_BOOT" != true ]]; then
        log_info "  - If boot fails, try: --bios-boot"
    fi
    if [[ ! "$NOGRAPHIC" == true && ! "$ENABLE_VNC" == true ]]; then
        log_info "  - Add --nogui for text-only mode"
    fi
    echo
    
    read -p "Start QEMU now? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        log_info "Starting QEMU..."
        echo
        
        # Execute QEMU command
        if eval "$qemu_command"; then
            log_success "QEMU session ended normally"
        else
            local exit_code=$?
            log_error "QEMU exited with error code: $exit_code"
            
            echo
            log_info "Troubleshooting suggestions:"
            if [[ "$BIOS_BOOT" != true ]]; then
                log_info "  1. Try BIOS boot mode: --bios-boot"
                log_info "  2. Try virt machine: --prefer-virt"
            fi
            log_info "  3. Try different architecture: --arch arm"
            log_info "  4. Enable debug output: --debug"
            log_info "  5. Try nographic mode: --nogui"
            log_info "  6. Check image compatibility"
            echo
            log_info "Common issues:"
            log_info "  - Black screen: Wait 2-3 minutes for boot"
            log_info "  - Kernel panic: Try --bios-boot"
            log_info "  - No display: Try --vnc or --nogui"
            log_info "  - Memory issues: Try --prefer-virt for more memory"
            
            exit $exit_code
        fi
    else
        log_info "Cancelled by user"
    fi
}

# Run main function with all arguments
main "$@"