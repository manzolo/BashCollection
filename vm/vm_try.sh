#!/bin/bash
# A script to launch a QEMU virtual machine with disk drives and optional bootable ISO.
# Supports both MBR and UEFI boot modes and auto-detects disk formats.

# --- Script Configuration ---
# Default VM settings
VM_RAM="4G"                # Default RAM for the VM
VM_CPUS=2                  # Use 2 CPU cores
QEMU_ACCEL_OPTS="-enable-kvm"  # Enable KVM hardware acceleration

# --- Variable Initialization ---
DISK=""
ISO=""                     # Optional ISO file
BOOT_MODE="mbr"           # Default boot mode is MBR

# --- Functions ---

# Displays the script's usage instructions and exits.
show_help() {
    echo "Usage: $0 --hd <path_to_disk1> [--iso <path_to_iso>] [--mbr|--uefi]"
    echo ""
    echo "Options:"
    echo "  --hd <path>     Path to the virtual disk (supports qcow2, raw, vmdk, vdi)"
    echo "  --iso <path>    Path to ISO file to boot from (takes boot priority)"
    echo "  --mbr           Configure for MBR boot mode (default)"
    echo "  --uefi          Configure for UEFI boot mode"
    echo "  --help          Display this help message"
    echo ""
    echo "Supported disk formats:"
    echo "  - qcow2 (QEMU Copy-On-Write)"
    echo "  - raw (Raw disk image)"
    echo "  - vmdk (VMware Virtual Disk)"
    echo "  - vdi (VirtualBox Disk Image)"
    echo ""
    echo "Examples:"
    echo "  $0 --hd /path/to/disk.qcow2"
    echo "  $0 --hd /path/to/disk.raw --iso /path/to/installer.iso"
    echo "  $0 --hd /path/to/disk.vmdk --uefi"
    exit 0
}

# Checks if a command is installed and exits with an error if it's not.
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: Required command '$1' is not installed. Please install it." >&2
        exit 1
    fi
}

# Checks if a file exists and exits with an error if it doesn't.
check_file_exists() {
    local file=$1
    if [ ! -f "$file" ]; then
        echo "Error: File not found at '$file'." >&2
        exit 1
    fi
}

# Detects the disk format based on file extension and qemu-img info
detect_disk_format() {
    local disk_file=$1
    local format=""
    
    # First try to detect using qemu-img (most reliable)
    if command -v qemu-img &> /dev/null; then
        format=$(qemu-img info "$disk_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
        if [ -n "$format" ]; then
            echo "$format"
            return 0
        fi
    fi
    
    # Fallback to file extension
    local extension="${disk_file##*.}"
    case "${extension,,}" in  # Convert to lowercase
        qcow2)
            echo "qcow2"
            ;;
        raw|img)
            echo "raw"
            ;;
        vmdk)
            echo "vmdk"
            ;;
        vdi)
            echo "vdi"
            ;;
        vhd|vhdx)
            echo "vpc"  # QEMU format name for VHD
            ;;
        *)
            echo "raw"  # Default to raw if unknown
            ;;
    esac
}

# Validates that the disk format is supported
validate_disk_format() {
    local format=$1
    case "$format" in
        qcow2|raw|vmdk|vdi|vpc|qed|vhdx)
            return 0
            ;;
        *)
            echo "Warning: Disk format '$format' might not be fully supported." >&2
            echo "Proceeding anyway..." >&2
            return 0
            ;;
    esac
}

# --- Main Script Logic ---

# Check for required dependencies
check_dependency qemu-system-x86_64

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hd)
            DISK="$2"
            shift 2
            ;;
        --iso)
            ISO="$2"
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
        --help)
            show_help
            ;;
        *)
            echo "Error: Invalid option '$1'." >&2
            show_help
            ;;
    esac
done

# Validate that all required parameters are provided
if [ -z "$DISK" ]; then
    echo "Error: Missing required argument: --hd" >&2
    show_help
fi

# Validate that the provided files exist
check_file_exists "$DISK"
if [ -n "$ISO" ]; then
    check_file_exists "$ISO"
fi

# Detect disk format
DISK_FORMAT=$(detect_disk_format "$DISK")
validate_disk_format "$DISK_FORMAT"

# Assemble QEMU options
QEMU_OPTS=(
    "-m" "$VM_RAM"
    "-smp" "$VM_CPUS"
    "$QEMU_ACCEL_OPTS"
    "-drive" "file=$DISK,format=$DISK_FORMAT,media=disk"
    "-netdev" "user,id=net0"
    "-device" "virtio-net-pci,netdev=net0"
    "-vga" "virtio"
    "-display" "sdl"
)

# Add ISO drive if provided
if [ -n "$ISO" ]; then
    QEMU_OPTS+=("-drive" "file=$ISO,format=raw,media=cdrom,readonly=on")
fi

# Configure boot mode based on user selection
if [ "$BOOT_MODE" = "uefi" ]; then
    # Check for UEFI firmware (try common paths)
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
        echo "Error: OVMF firmware not found. Please install ovmf package." >&2
        echo "Searched in: ${OVMF_PATHS[*]}" >&2
        exit 1
    fi
    
    QEMU_OPTS+=("-bios" "$OVMF_PATH")
    # Set boot order: ISO first if provided, then hard drive
    if [ -n "$ISO" ]; then
        QEMU_OPTS+=("-boot" "order=d,menu=on")  # Boot only from CD-ROM with boot menu
    else
        QEMU_OPTS+=("-boot" "order=c")
    fi
else # MBR
    # Set boot order: ISO first if provided, then hard drive
    if [ -n "$ISO" ]; then
        QEMU_OPTS+=("-boot" "order=d,menu=on")  # Boot only from CD-ROM with boot menu
    else
        QEMU_OPTS+=("-boot" "order=c")
    fi
fi

# Display launch information
echo "Launching QEMU VM with the following configuration:"
echo "  RAM: $VM_RAM"
echo "  CPUs: $VM_CPUS"
echo "  Boot mode: $BOOT_MODE"
echo "  Hard disk: $DISK (format: $DISK_FORMAT)"
if [ -n "$ISO" ]; then
    echo "  ISO: $ISO (primary boot device)"
else
    echo "  Boot device: Hard disk"
fi
if [ "$BOOT_MODE" = "uefi" ]; then
    echo "  UEFI firmware: $OVMF_PATH"
fi
echo ""

# Launch QEMU
echo "Starting QEMU..."
qemu-system-x86_64 "${QEMU_OPTS[@]}"

# Check for QEMU launch errors
if [ $? -ne 0 ]; then
    echo "Error: Failed to launch QEMU." >&2
    exit 1
fi

echo "QEMU session ended."
exit 0