#!/bin/bash

# A script to launch a QEMU virtual machine with a virtual disk and an optional bootable ISO.
# It supports MBR and UEFI boot modes, automatically detects disk formats, and prioritizes
# booting from ISO if present, otherwise from the hard disk.

# --- Script Configuration ---
VM_RAM="4G"                # Default RAM for the VM
VM_CPUS=2                  # Number of CPU cores
QEMU_ACCEL_OPTS="-enable-kvm"  # Enable KVM hardware acceleration
OVMF_CODE="/usr/share/ovmf/OVMF.fd"  # UEFI firmware
OVMF_VARS="/tmp/OVMF_VARS.fd"  # Persistent NVRAM for UEFI boot entries

# --- Variable Initialization ---
DISK=""
ISO=""                     # Optional ISO file
BOOT_MODE="mbr"            # Default boot mode is MBR
BOOT_PRIORITY="auto"       # auto, hd, iso

# --- Functions ---

# Displays usage instructions.
show_help() {
    echo "Usage: $0 --hd <disk_path> [--iso <iso_path>] [--mbr|--uefi] [--boot-priority auto|hd|iso]"
    echo ""
    echo "  --hd <path>             Path to the virtual disk (e.g., /home/manzolo/Scrivania/Deb.vhd)"
    echo "  --iso <path>            Path to the ISO file to boot from (optional)"
    echo "  --mbr                   Configure for MBR boot mode (default)"
    echo "  --uefi                  Configure for UEFI boot mode"
    echo "  --boot-priority <mode>  Boot priority: auto (ISO first if present), hd, iso"
    echo "  --help                  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --hd /home/manzolo/Scrivania/Deb.vhd --uefi"
    echo "  $0 --hd /home/manzolo/Scrivania/Deb.vhd --iso /path/to/debian.iso --uefi"
    exit 0
}

# Checks if a command is installed.
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: Required command '$1' is not installed." >&2
        exit 1
    fi
}

# Checks if a file exists.
check_file_exists() {
    local file=$1
    if [ ! -f "$file" ]; then
        echo "Error: File not found at '$file'." >&2
        exit 1
    fi
}

# Prompts the user for a file path.
prompt_for_file() {
    local prompt_text="$1"
    local is_optional="$2"
    local file_path=""

    while true; do
        read -p "$prompt_text " file_path
        if [ -f "$file_path" ]; then
            echo "$file_path"
            return
        elif [ -z "$file_path" ] && [ "$is_optional" = "optional" ]; then
            echo ""
            return
        else
            echo "Error: File not found. Please try again."
        fi
    done
}

# Detects the disk format based on file extension and qemu-img info.
detect_disk_format() {
    local disk_file=$1
    local format=""
    
    local formats_to_test=("qcow2" "vmdk" "vdi" "vpc" "vhdx" "qed" "parallels")
    
    if command -v qemu-img &> /dev/null; then
        format=$(qemu-img info "$disk_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
        if [ -n "$format" ] && [ "$format" != "raw" ]; then
            echo "$format"
            return 0
        fi
        
        for test_format in "${formats_to_test[@]}"; do
            if qemu-img info -f "$test_format" "$disk_file" &>/dev/null; then
                detected=$(qemu-img info -f "$test_format" "$disk_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
                if [ "$detected" = "$test_format" ]; then
                    echo "$test_format"
                    return 0
                fi
            fi
        done
    fi
    
    if [ -r "$disk_file" ]; then
        if head -c 8 "$disk_file" 2>/dev/null | grep -q "vhdxfile"; then
            echo "vhdx"
            return 0
        fi
        if tail -c 512 "$disk_file" 2>/dev/null | grep -q "conectix"; then
            echo "vpc"
            return 0
        fi
        if head -c 4 "$disk_file" 2>/dev/null | xxd -p | grep -q "^514649fb"; then
            echo "qcow2"
            return 0
        fi
        if head -c 4 "$disk_file" 2>/dev/null | grep -q "KDMV"; then
            echo "vmdk"
            return 0
        fi
        if head -c 64 "$disk_file" 2>/dev/null | grep -q "Oracle VM VirtualBox Disk Image"; then
            echo "vdi"
            return 0
        fi
    fi

    if command -v qemu-img &> /dev/null; then
        format=$(qemu-img info "$disk_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
        if [ -n "$format" ] && [ "$format" != "raw" ]; then
            echo "$format"
            return 0
        fi
    fi
    
    local extension="${disk_file##*.}"
    case "${extension,,}" in
        qcow2) echo "qcow2" ;;
        vmdk)  echo "vmdk"  ;;
        vdi)   echo "vdi"   ;;
        vhd)   echo "vpc"   ;;
        vhdx)  echo "vhdx"  ;;
        raw|img|iso) echo "raw" ;;
        *) echo "raw" ;;
    esac
}

# Validates that the disk format is supported.
validate_disk_format() {
    local format=$1
    case "$format" in
        qcow2|raw|vmdk|vdi|vpc|qed|vhdx)
            return 0
            ;;
        *)
            echo "Warning: Disk format '$format' may not be fully supported." >&2
            echo "Proceeding anyway..." >&2
            return 0
            ;;
    esac
}

# Determines the effective boot priority.
determine_boot_priority() {
    local priority="$1"
    local has_iso="$2"
    
    case "$priority" in
        "auto")
            if [ "$has_iso" = "true" ]; then
                echo "iso"
            else
                echo "hd"
            fi
            ;;
        "hd"|"iso")
            echo "$priority"
            ;;
        *)
            echo "hd"  # Safe fallback
            ;;
    esac
}

# Configures storage and boot devices.
configure_storage_and_boot() {
    local disk="$1"
    local disk_format="$2"
    local iso="$3"
    local boot_mode="$4"
    local boot_priority="$5"
    
    local has_iso="false"
    if [ -n "$iso" ]; then
        has_iso="true"
    fi
    
    local effective_priority
    effective_priority=$(determine_boot_priority "$boot_priority" "$has_iso")
    
    local storage_opts=()
    local boot_opts=()
    
    # Configure disk with virtio interface (aligned with working command)
    storage_opts+=("-drive" "file=$disk,format=$disk_format,if=virtio,cache=writeback")
    
    # Configure ISO if provided
    if [ -n "$iso" ]; then
        storage_opts+=("-drive" "file=$iso,format=raw,media=cdrom,readonly=on")
    fi
    
    # Configure boot priority
    if [ "$effective_priority" = "iso" ] && [ -n "$iso" ]; then
        boot_opts+=("-boot" "order=dc,menu=on")  # Prioritize ISO, then disk
    else
        boot_opts+=("-boot" "order=c,menu=on")   # Boot from disk only
    fi
    
    printf '%s\n' "${storage_opts[@]}" "${boot_opts[@]}"
}

# Shows a summary of the boot configuration
show_boot_summary() {
    local disk="$1"
    local iso="$2"
    local boot_priority="$3"
    local boot_mode="$4"
    
    local has_iso="false"
    if [ -n "$iso" ]; then
        has_iso="true"
    fi
    
    local effective_priority
    effective_priority=$(determine_boot_priority "$boot_priority" "$has_iso")
    
    echo "=== BOOT CONFIGURATION ==="
    echo "Mode: $boot_mode"
    echo "Requested priority: $boot_priority"
    echo "Effective priority: $effective_priority"
    echo ""
    
    if [ "$effective_priority" = "iso" ] && [ -n "$iso" ]; then
        echo "✓ PRIMARY DEVICE: ISO ($iso)"
        echo "✓ SECONDARY DEVICE: Hard disk ($disk)"
        echo ""
        echo "The VM will boot from the ISO. If the ISO is not bootable, it will try the hard disk."
    else
        echo "✓ PRIMARY DEVICE: Hard disk ($disk)"
        if [ -n "$iso" ]; then
            echo "✓ SECONDARY DEVICE: ISO ($iso)"
            echo ""
            echo "The VM will boot from the hard disk. The ISO is available for installation or recovery."
        else
            echo ""
            echo "The VM will boot from the hard disk exclusively."
        fi
    fi
    
    if [ "$boot_mode" = "uefi" ]; then
        echo ""
        echo "ℹ  In UEFI mode, press F12 during startup to access the boot menu."
    fi
    echo "================================"
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
        --boot-priority)
            BOOT_PRIORITY="$2"
            case "$2" in
                auto|hd|iso)
                    shift 2
                    ;;
                *)
                    echo "Error: Invalid value for --boot-priority: '$2'" >&2
                    echo "Accepted values: auto, hd, iso" >&2
                    show_help
                    ;;
            esac
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

# If no disk path was provided, start interactive mode
if [ -z "$DISK" ]; then
    echo "=== VM Setup (Interactive Mode) ==="
    echo "Please provide the paths for your virtual disk and optional ISO."
    echo ""
    DISK=$(prompt_for_file "Enter the path for the VIRTUAL DISK (e.g., /home/manzolo/Scrivania/Deb.vhd):")
    
    read -p "Do you want to add a bootable ISO? (y/N): " add_iso_choice
    if [[ "$add_iso_choice" =~ ^[Yy]$ ]]; then
        ISO=$(prompt_for_file "Enter the path for the BOOTABLE ISO (e.g., /home/user/debian.iso):" "optional")
    fi

    read -p "Choose boot mode (MBR/UEFI) - [M]BR or [U]EFI: " boot_mode_choice
    case "$boot_mode_choice" in
        [Uu]*)
            BOOT_MODE="uefi"
            ;;
        *)
            BOOT_MODE="mbr"
            ;;
    esac
fi

# Validate that the provided files exist
check_file_exists "$DISK"
if [ -n "$ISO" ]; then
    check_file_exists "$ISO"
fi

# Detect the disk format
DISK_FORMAT=$(detect_disk_format "$DISK")
validate_disk_format "$DISK_FORMAT"

# Configure UEFI with persistent NVRAM if needed
if [ "$BOOT_MODE" = "uefi" ]; then
    check_file_exists "$OVMF_CODE"
    if [ ! -f "$OVMF_VARS" ]; then
        cp "$OVMF_CODE" "$OVMF_VARS"
    fi
fi

# Show boot configuration summary
show_boot_summary "$DISK" "$ISO" "$BOOT_PRIORITY" "$BOOT_MODE"
echo ""

# Assemble QEMU options
QEMU_OPTS=(
    "-m" "$VM_RAM"
    "-smp" "$VM_CPUS"
    "$QEMU_ACCEL_OPTS"
    "-machine" "q35"
    "-cpu" "host"
    "-vga" "virtio"
    "-display" "gtk,show-cursor=on"
    "-monitor" "vc"
    "-serial" "file:/tmp/qemu-serial.log"
    "-usb"
    "-device" "usb-tablet"
)

# Add UEFI firmware configuration
if [ "$BOOT_MODE" = "uefi" ]; then
    QEMU_OPTS+=("-drive" "if=pflash,format=raw,unit=0,file=$OVMF_CODE,readonly=on")
    QEMU_OPTS+=("-drive" "if=pflash,format=raw,unit=1,file=$OVMF_VARS")
else
    QEMU_OPTS+=("-bios" "$OVMF_CODE")
fi

# Configure storage and boot
mapfile -t STORAGE_BOOT_OPTS < <(configure_storage_and_boot "$DISK" "$DISK_FORMAT" "$ISO" "$BOOT_MODE" "$BOOT_PRIORITY")
QEMU_OPTS+=("${STORAGE_BOOT_OPTS[@]}")

# Show launch information
echo "Launching QEMU VM with the following configuration:"
echo "  RAM: $VM_RAM"
echo "  CPU: $VM_CPUS"
echo "  Boot mode: $BOOT_MODE"
echo "  Hard disk: $DISK (format: $DISK_FORMAT)"
if [ -n "$ISO" ]; then
    echo "  ISO: $ISO"
fi
if [ "$BOOT_MODE" = "uefi" ]; then
    echo "  UEFI firmware: $OVMF_CODE"
    echo "  UEFI NVRAM: $OVMF_VARS"
fi
echo ""

echo "Press ENTER to launch the VM, or Ctrl+C to cancel..."
read -r

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