#!/bin/bash

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

# Automatically detects the format of a disk image with improved detection
detect_disk_format() {
    local disk_file=$1
    local format=""
    
    # List of formats to test in priority order
    local formats_to_test=("qcow2" "vmdk" "vdi" "vpc" "vhdx" "qed" "parallels")
    
    # First, try qemu-img's automatic detection
    if command -v qemu-img &> /dev/null; then
        format=$(qemu-img info "$disk_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
        # Only if the automatic detection finds a specific format (not raw/unknown)
        if [ -n "$format" ] && [ "$format" != "unknown" ]; then
            if [ "$format" = "raw" ]; then
                # Extra attempt: could be a VHD (vpc disguised as raw)
                local vpc_check=$(qemu-img info -f vpc "$disk_file" 2>/dev/null | grep "file format:")
                if echo "$vpc_check" | grep -q "vpc"; then
                    echo "vpc"
                    return 0
                fi
            else
                echo "$format"
                return 0
            fi
        fi
        
        # If qemu-img says "raw" or doesn't detect anything, try specific formats
        for test_format in "${formats_to_test[@]}"; do
            # Try to read the file with the specific format
            local test_output=$(qemu-img info -f "$test_format" "$disk_file" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$test_output" ]; then
                # Check if the detected format matches
                detected=$(echo "$test_output" | grep "file format:" | awk '{print $3}')
                if [ "$detected" = "$test_format" ]; then
                    echo "$test_format"
                    return 0
                fi
            fi
        done
    fi
    
    # Fallback: detection via magic numbers/header
    if command -v file &> /dev/null; then
        local file_output=$(file "$disk_file" 2>/dev/null)
        case "$file_output" in
            *"QEMU QCOW"*|*"qcow"*)
                echo "qcow2"
                return 0
                ;;
            *"VMware"*|*"VMDK"*)
                echo "vmdk"
                return 0
                ;;
            *"VirtualBox"*|*"VDI"*)
                echo "vdi"
                return 0
                ;;
            *"Microsoft Disk Image"*|*"VHD"*)
                echo "vpc"
                return 0
                ;;
        esac
    fi
    
    # Fallback: manual header check
    if [ -r "$disk_file" ]; then
        # QCOW2 magic: "QFI\xfb"
        if head -c 4 "$disk_file" 2>/dev/null | xxd -l 4 -p | grep -q "^514649fb"; then
            echo "qcow2"
            return 0
        fi
        
        # VMDK magic: "KDMV"  
        if head -c 4 "$disk_file" 2>/dev/null | grep -q "KDMV"; then
            echo "vmdk"
            return 0
        fi
        
        # VDI magic: "<<< Oracle VM VirtualBox Disk Image >>>"
        if head -c 64 "$disk_file" 2>/dev/null | grep -q "Oracle VM VirtualBox Disk Image"; then
            echo "vdi"
            return 0
        fi
        
        # VHD magic: "conectix" at offset 0 or "cxsparse" for dynamic VHD
        local vhd_magic=$(tail -c 512 "$disk_file" 2>/dev/null | head -c 8)
        if [ "$vhd_magic" = "conectix" ]; then
            echo "vpc"
            return 0
        fi
    fi
    
    # Final fallback: file extension
    local extension="${disk_file##*.}"
    case "${extension,,}" in # Convert to lowercase
        qcow2)
            echo "qcow2"
            ;;
        vmdk)
            echo "vmdk"
            ;;
        vdi)
            echo "vdi"
            ;;
        vhd|vhdx)
            echo "vpc"
            ;;
        raw|img|iso)
            echo "raw"
            ;;
        *)
            echo "raw" # Default to raw if unknown
            ;;
    esac
}

# Debug function to trace the detection process
debug_disk_format() {
    local disk_file=$1
    echo "=== Debug Detection for: $disk_file ===" >&2
    
    # Test qemu-img without format
    if command -v qemu-img &> /dev/null; then
        echo "Test qemu-img info (auto-detect):" >&2
        local auto_format=$(qemu-img info "$disk_file" 2>/dev/null | grep "file format:")
        echo "  Result: $auto_format" >&2
        
        # Test specific formats
        local formats_to_test=("qcow2" "vmdk" "vdi" "vpc" "vhdx" "qed" "parallels")
        echo "Test specific formats:" >&2
        for test_format in "${formats_to_test[@]}"; do
            echo -n "  Test $test_format: " >&2
            local test_output=$(qemu-img info -f "$test_format" "$disk_file" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$test_output" ]; then
                local detected=$(echo "$test_output" | grep "file format:" | awk '{print $3}')
                echo "SUCCESS - detected as $detected" >&2
                if [ "$detected" = "$test_format" ]; then
                    echo "  ✓ Matching format!" >&2
                else
                    echo "  ✗ Non-matching format!" >&2
                fi
            else
                echo "FAILED" >&2
            fi
        done
    fi
    
    # Test 'file' command
    if command -v file &> /dev/null; then
        echo "Test 'file' command:" >&2
        file "$disk_file" >&2
    fi
    
    echo "=================================" >&2
}

# Automatically detects the format of a disk image with optional verbose output
get_disk_format() {
    local disk_path=$1
    
    if [ "$VERBOSE" = true ]; then
        debug_disk_format "$disk_path"
    fi
    
    local format=$(detect_disk_format "$disk_path")
    
    if [ "$VERBOSE" = true ]; then
        echo "Final detected format for '$disk_path': $format" >&2
    fi
    
    echo "$format"
}

# Validates RAM size
validate_ram() {
    local ram=$1
    if [[ ! "$ram" =~ ^[0-9]+[GMK]?$ ]]; then
        echo "Error: Invalid RAM format '$ram'. Use formats like: 4G, 2048M, 512K" >&2
        exit 1
    fi
}

# Shows detailed information about disks
show_disk_info() {
    local disk=$1
    local label=$2

    if [ -f "$disk" ]; then
        echo "  $label: $disk"

        # Use the improved detection
        local format=$(get_disk_format "$disk")

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
DISK1_FORMAT=$(get_disk_format "$DISK1")
DISK2_FORMAT=$(get_disk_format "$DISK2")
if [ -n "$EXTRA_DISK" ]; then
    EXTRA_FORMAT=$(get_disk_format "$EXTRA_DISK")
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