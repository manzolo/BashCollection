#!/bin/bash
# PKG_NAME: vm-clone
# PKG_VERSION: 1.5.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), qemu-system-x86
# PKG_RECOMMENDS: qemu-utils
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Clone and test QEMU virtual machines
# PKG_LONG_DESCRIPTION: Tool for cloning virtual machines and testing with
#  different boot media in QEMU with UEFI/BIOS support.
#  .
#  Features:
#  - Clone between different disk formats
#  - MBR and UEFI boot mode support
#  - Bootable ISO integration for cloning
#  - KVM hardware acceleration
#  - Support for multiple disk formats (qcow2, raw, vmdk, vdi, vhd)
#  - Configurable RAM and CPU allocation
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Script to launch a QEMU virtual machine for cloning virtual disks.
# It automatically detects virtual disk formats and supports both MBR and UEFI modes.
# Optimized for cloning operations with bootable ISOs.

# --- Script Configuration ---
VM_RAM="4G"                    # Default RAM for the VM
VM_CPUS=$(nproc)               # Use all available CPU cores
QEMU_ACCEL_OPTS="-enable-kvm"  # Enable KVM hardware acceleration

# --- Variable Initialization ---
DISK1=""          # Source disk
DISK2=""          # Destination disk  
ISO_PATH=""       # Bootable ISO for cloning
BOOT_MODE="mbr"   # Default boot mode is MBR
EXTRA_DISK=""     # Optional additional disk
VERBOSE=false     # Debug output

# --- Functions ---

# Displays the script's usage instructions and exits.
show_help() {
    echo "Usage: $0 --src <source_disk> --dst <destination_disk> --iso <bootable_iso> [options]"
    echo ""
    echo "Required arguments:"
    echo "  --src <path>    Source virtual disk to clone"
    echo "  --dst <path>    Destination virtual disk for the copy"
    echo "  --iso <path>    Bootable ISO for cloning (e.g., Clonezilla, SystemRescue)"
    echo ""
    echo "Options:"
    echo "  --extra <path>  Optional additional disk (third disk)"
    echo "  --mbr           Configure for MBR/BIOS boot (default)"
    echo "  --uefi          Configure for UEFI boot"
    echo "  --ram <size>    Specify VM RAM (default: 4G, e.g., 8G, 2048M)"
    echo "  --cpus <number> Number of virtual CPUs (default: all cores)"
    echo "  --verbose       Show detailed information about disk formats"
    echo "  --help          Show this help message"
    echo ""
    echo "Supported disk formats:"
    echo "  - qcow2 (QEMU Copy-On-Write)"
    echo "  - raw (Raw disk image)"
    echo "  - vmdk (VMware Virtual Disk)"
    echo "  - vdi (VirtualBox Disk Image)"
    echo "  - vhd/vhdx (Hyper-V Virtual Hard Disk)"
    echo ""
    echo "Examples:"
    echo "  $0 --src source.qcow2 --dst target.qcow2 --iso clonezilla.iso"
    echo "  $0 --src disk1.raw --dst disk2.raw --iso systemrescue.iso --uefi --ram 8G"
    echo "  $0 --src old.vmdk --dst new.vmdk --extra backup.qcow2 --iso clonezilla.iso"
    echo ""
    echo "Notes for cloning:"
    echo "  - The source disk can be mounted read-only for safety"
    echo "  - The destination disk should have sufficient space"
    echo "  - Use ISOs like Clonezilla or SystemRescue for cloning operations"
    exit 0
}

# Checks if a command is installed and exits with an error if it's not.
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: The command '$1' is not installed. Install it with:" >&2
        case "$1" in
            qemu-system-x86_64)
                echo "  Ubuntu/Debian: sudo apt install qemu-system-x86" >&2
                echo "  Fedora/RHEL: sudo dnf install qemu-system-x86" >&2
                echo "  Arch: sudo pacman -S qemu-system-x86" >&2
                ;;
            qemu-img)
                echo "  Ubuntu/Debian: sudo apt install qemu-utils" >&2
                echo "  Fedora/RHEL: sudo dnf install qemu-img" >&2
                echo "  Arch: sudo pacman -S qemu-img" >&2
                ;;
        esac
        exit 1
    fi
}

# Checks if a file exists and exits with an error if it does not.
check_file_exists() {
    local file=$1
    local description=$2
    if [ ! -f "$file" ]; then
        echo "Error: $description not found at '$file'." >&2
        exit 1
    fi
}

# Tests if a specific format is compatible with a disk file.
test_format_compatibility() {
    local disk_file=$1
    local format=$2
    if command -v qemu-img &> /dev/null; then
        qemu-img info -f "$format" "$disk_file" &>/dev/null
        return $?
    fi
    return 0 # Assume compatibility if qemu-img is not available
}

# Automatically detects the format of a disk image
detect_disk_format() {
    local disk_file=$1
    local extension="${disk_file##*.}"
    local format=""

    # 1. Primary check: Use qemu-img's automatic detection
    if command -v qemu-img &> /dev/null; then
        format=$(qemu-img info "$disk_file" 2>/dev/null | awk '/^file format:/ {print $3}')
        # Only if the automatic detection finds a specific format (not raw)
        if [ -n "$format" ] && [ "$format" != "unknown" ] && [ "$format" != "raw" ] && test_format_compatibility "$disk_file" "$format"; then
            echo "$format"
            return 0
        fi
    fi
    
    # 2. Fallback: Check file extension for common formats
    case "${extension,,}" in
        qcow2) format="qcow2" ;;
        vmdk)  format="vmdk"  ;;
        vdi)   format="vdi"   ;;
        vhd)   format="vpc"   ;;
        vhdx)  format="vhdx"  ;;
        raw|img|iso|vtoy) format="raw" ;; # Ventoy files are often raw
        *) format="" ;; # Continue to final fallback
    esac

    # 3. Final verification and fallback
    if [ -n "$format" ]; then
        if [ "$format" != "raw" ] && ! test_format_compatibility "$disk_file" "$format"; then
            echo "Warning: Extension-based detection of '$format' failed verification. Falling back to 'raw'." >&2
            echo "raw"
            return 0
        fi
        echo "$format"
        return 0
    fi
    
    # 4. Ultimate fallback to 'raw'
    echo "raw"
    return 0
}

# Shows detailed information about disks
show_disk_info() {
    local disk=$1
    local label=$2

    if [ -f "$disk" ]; then
        echo "  $label: $disk"

        # Use the improved detection
        local format=$(detect_disk_format "$disk")

        # Get info by forcing the correct format
        if command -v qemu-img &> /dev/null; then
            local info=$(qemu-img info -f "$format" "$disk" 2>/dev/null)
            local virtual_size=$(echo "$info" | grep 'virtual size:' | awk '{print $3, $4}')
            local disk_size=$(echo "$info" | grep 'disk size:' | awk '{print $3, $4}')

            echo "    Format: $format"
            if [ -n "$virtual_size" ]; then
                echo "    Virtual size: $virtual_size"
            fi
            if [ -n "$disk_size" ]; then
                echo "    Disk size: $disk_size"
            fi
        fi
    fi
}

# Validates RAM size
validate_ram() {
    local ram=$1
    if [[ ! "$ram" =~ ^[0-9]+[GMK]?$ ]]; then
        echo "Error: Invalid RAM format '$ram'. Use formats like: 4G, 2048M, 512K" >&2
        exit 1
    fi
}

# --- Main Script Logic ---

# Check required dependencies
check_dependency qemu-system-x86_64
check_dependency qemu-img

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)
            DISK1="$2"
            shift 2
            ;;
        --dst)
            DISK2="$2"
            shift 2
            ;;
        --iso)
            ISO_PATH="$2"
            shift 2
            ;;
        --extra)
            EXTRA_DISK="$2"
            shift 2
            ;;
        --ram)
            VM_RAM="$2"
            validate_ram "$VM_RAM"
            shift 2
            ;;
        --cpus)
            VM_CPUS="$2"
            if ! [[ "$VM_CPUS" =~ ^[0-9]+$ ]] || [ "$VM_CPUS" -le 0 ]; then
                echo "Error: Invalid CPU number '$VM_CPUS'." >&2
                exit 1
            fi
            shift 2
            ;;
        --mbr)
            BOOT_MODE="mbr"
            shift
            ;;
        --uefi)
            BOOT_MODE="uefi"
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Error: Invalid option '$1'." >&2
            echo "Use '$0 --help' to see available options." >&2
            exit 1
            ;;
    esac
done

# Validate that all required parameters are provided
if [ -z "$DISK1" ] || [ -z "$DISK2" ] || [ -z "$ISO_PATH" ]; then
    echo "Error: Missing required arguments." >&2
    echo "Required: --src, --dst, --iso" >&2
    echo "Use '$0 --help' for more information." >&2
    exit 1
fi

# Validate that provided files exist
check_file_exists "$ISO_PATH" "ISO file"
check_file_exists "$DISK1" "Source disk"
check_file_exists "$DISK2" "Destination disk"
if [ -n "$EXTRA_DISK" ]; then
    check_file_exists "$EXTRA_DISK" "Additional disk"
fi

# Detect disk formats with improved detection
echo "Detecting disk formats..."
DISK1_FORMAT=$(detect_disk_format "$DISK1")
DISK2_FORMAT=$(detect_disk_format "$DISK2")
if [ -n "$EXTRA_DISK" ]; then
    EXTRA_FORMAT=$(detect_disk_format "$EXTRA_DISK")
fi

# Assemble QEMU options
QEMU_OPTS=(
    "-m" "$VM_RAM"
    "-smp" "$VM_CPUS"
    "$QEMU_ACCEL_OPTS"
    "-netdev" "user,id=net0"
    "-device" "virtio-net-pci,netdev=net0"
    "-vga" "virtio"
    "-display" "sdl"
    "-usb"
    "-device" "usb-tablet"  # Better mouse control
)

# Add disks in a specific order for booting
if [ "$BOOT_MODE" = "uefi" ]; then
    # For UEFI: ISO must be the FIRST drive to have priority
    QEMU_OPTS+=("-drive" "file=$ISO_PATH,format=raw,media=cdrom,readonly=on,if=none,id=cd0")
    QEMU_OPTS+=("-device" "ide-cd,drive=cd0,bootindex=0")  # CD-ROM on IDE primary master
    
    # Disks with SATA controller to avoid IDE conflicts
    QEMU_OPTS+=("-drive" "file=$DISK1,format=$DISK1_FORMAT,media=disk,if=none,id=hd0")
    QEMU_OPTS+=("-device" "ahci,id=ahci")  # AHCI/SATA controller
    QEMU_OPTS+=("-device" "ide-hd,drive=hd0,bus=ahci.0,bootindex=1")  # First disk on SATA
    QEMU_OPTS+=("-drive" "file=$DISK2,format=$DISK2_FORMAT,media=disk,if=none,id=hd1")
    QEMU_OPTS+=("-device" "ide-hd,drive=hd1,bus=ahci.1,bootindex=2")  # Second disk on SATA
else
    # For MBR: traditional order
    QEMU_OPTS+=("-drive" "file=$ISO_PATH,format=raw,media=cdrom,readonly=on")
    QEMU_OPTS+=("-drive" "file=$DISK1,format=$DISK1_FORMAT,media=disk")
    QEMU_OPTS+=("-drive" "file=$DISK2,format=$DISK2_FORMAT,media=disk")
fi

# Add additional disk if specified
if [ -n "$EXTRA_DISK" ]; then
    if [ "$BOOT_MODE" = "uefi" ]; then
        QEMU_OPTS+=("-drive" "file=$EXTRA_DISK,format=$EXTRA_FORMAT,media=disk,if=none,id=hd2")
        QEMU_OPTS+=("-device" "ide-hd,drive=hd2,bus=ahci.2,bootindex=3")  # Third disk on SATA
    else
        QEMU_OPTS+=("-drive" "file=$EXTRA_DISK,format=$EXTRA_FORMAT,media=disk")
    fi
fi

# Configure boot mode
if [ "$BOOT_MODE" = "uefi" ]; then
    # Search for UEFI firmware in common paths
    OVMF_PATHS=(
        "/usr/share/ovmf/OVMF.fd"
        "/usr/share/OVMF/OVMF.fd"
        "/usr/share/edk2-ovmf/OVMF.fd"
        "/usr/share/qemu/OVMF.fd"
    )
    
    OVMF_PATH=""
    for path in "${OVMF_PATHS[@]}"; do
        if [ -f "$path" ]; then
            OVMF_PATH="$path"
            break
        fi
    done
    
    if [ -z "$OVMF_PATH" ]; then
        echo "Error: OVMF firmware not found. Install the ovmf package:" >&2
        echo "  Ubuntu/Debian: sudo apt install ovmf" >&2
        echo "  Fedora/RHEL: sudo dnf install edk2-ovmf" >&2
        echo "Paths searched: ${OVMF_PATHS[*]}" >&2
        exit 1
    fi
    
    QEMU_OPTS+=("-bios" "$OVMF_PATH")
    # For UEFI, boot order is already handled by bootindex
else # MBR
    QEMU_OPTS+=("-boot" "order=d,menu=on,strict=on")  # Boot ONLY from CD with menu
fi

# Display startup information
echo ""
echo "=== Starting QEMU VM for Disk Cloning ==="
echo "Configuration:"
echo "  RAM: $VM_RAM"
echo "  CPU: $VM_CPUS cores"
echo "  Boot mode: $BOOT_MODE"
echo "  Bootable ISO: $ISO_PATH"
echo ""
echo "Configured disks:"
show_disk_info "$DISK1" "Source"
show_disk_info "$DISK2" "Destination"
if [ -n "$EXTRA_DISK" ]; then
    show_disk_info "$EXTRA_DISK" "Additional disk"
fi
if [ "$BOOT_MODE" = "uefi" ]; then
    echo "  UEFI Firmware: $OVMF_PATH"
fi
echo ""
echo "WARNING: Make sure you have backups of your data before proceeding."
echo "Press ESC during boot to access the boot menu."
echo ""

# Start QEMU
echo "Starting QEMU..."
qemu-system-x86_64 "${QEMU_OPTS[@]}"

# Check for QEMU startup errors
if [ $? -ne 0 ]; then
    echo "Error: Failed to start QEMU." >&2
    exit 1
fi

echo "QEMU session ended."
exit 0