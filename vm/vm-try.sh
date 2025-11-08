#!/bin/bash
# PKG_NAME: vm-try
# PKG_VERSION: 2.0.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), qemu-system-x86, dialog
# PKG_RECOMMENDS: ovmf, qemu-utils
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Interactive QEMU VM launcher with dialog interface
# PKG_LONG_DESCRIPTION: Launch and test QEMU virtual machines with interactive configuration.
#  .
#  Features:
#  - MBR/UEFI boot mode support
#  - Automatic disk format detection (qcow2, raw, vmdk, vdi, vhd)
#  - ISO boot support
#  - Interactive file browser with dialog
#  - Configurable RAM and CPU allocation
#  - KVM acceleration support
#  - Boot priority configuration (auto, hd, iso)
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# QEMU Virtual Machine Launcher with Dialog Interface
# Supports MBR/UEFI boot modes, automatic disk format detection, and ISO boot

# --- Default Configuration (customize here) ---
DEFAULT_BOOT_MODE="uefi"        # Default boot mode: mbr or uefi
DEFAULT_BOOT_PRIORITY="auto"    # Default priority: auto, hd, iso
DEFAULT_VM_RAM="4G"              # Default RAM
DEFAULT_VM_CPUS=2                # Default CPU cores
DEFAULT_SHOW_HIDDEN=false        # Show hidden files by default

# --- Script Configuration ---
VM_RAM="${DEFAULT_VM_RAM}"
VM_CPUS="${DEFAULT_VM_CPUS}"
QEMU_ACCEL_OPTS="-enable-kvm"
OVMF_CODE="/usr/share/ovmf/OVMF.fd"
OVMF_VARS="/tmp/OVMF_VARS.fd"

# --- Color codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Variables ---
DISK=""
ISO=""
BOOT_MODE="${DEFAULT_BOOT_MODE}"
BOOT_PRIORITY="${DEFAULT_BOOT_PRIORITY}"
SELECTED_FILE=""
SHOW_HIDDEN="${DEFAULT_SHOW_HIDDEN}"

# --- File Browser Functions ---

get_directory_content() {
    local dir="$1"
    local items=()
    
    # Add parent directory if not at root
    [[ "$dir" != "/" ]] && items+=("..")
    
    local ls_opts="-1"
    $SHOW_HIDDEN && ls_opts="${ls_opts}a"
    
    while IFS= read -r item; do
        [[ "$item" = "." || "$item" = ".." ]] && continue
        local full_path="$dir/$item"
        if [[ -d "$full_path" ]]; then
            # Directory - add trailing slash
            items+=("$item/")
        elif [[ -f "$full_path" ]]; then
            # Regular file
            items+=("$item")
        elif [[ -L "$full_path" ]]; then
            # Symbolic link - add @ suffix
            items+=("$item@")
        else
            # Special file
            items+=("$item?")
        fi
    done < <(ls $ls_opts "$dir" 2>/dev/null)
    
    printf '%s\n' "${items[@]}"
}

get_item_description() {
    local dir="$1"
    local item="$2"
    local clean_name="${item%/}"
    clean_name="${clean_name%@}"
    clean_name="${clean_name%\?}"
    
    if [[ "$item" == ".." ]]; then
        echo "[Parent Directory]"
        return
    fi
    
    local full_path="$dir/$clean_name"
    
    if [[ "$item" =~ /$ ]]; then
        # Directory
        local count=$(ls -1 "$full_path" 2>/dev/null | wc -l)
        echo "📁 Dir ($count items)"
    elif [[ "$item" =~ @$ ]]; then
        # Symbolic link
        local target=$(readlink "$full_path" 2>/dev/null || echo "???")
        echo "🔗 Link → $target"
    elif [[ "$item" =~ \?$ ]]; then
        # Special file
        echo "❓ Special"
    elif [[ -f "$full_path" ]]; then
        # Regular file
        local size=$(du -h "$full_path" 2>/dev/null | cut -f1)
        local icon="📄"
        case "${clean_name##*.}" in
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
            img|vhd|vhdx|qcow2|vmdk|raw|vpc|vdi|qed) icon="💾" ;;
            iso|ISO) icon="💿" ;;
        esac
        echo "$icon $size"
    else
        echo "❓ Unknown"
    fi
}

show_file_browser() {
    local current="$1"
    local select_type="${2:-file}"
    local file_filter="${3:-}"
    
    current=$(realpath "$current" 2>/dev/null || echo "$current")
    
    local content=$(get_directory_content "$current")
    [[ -z "$content" ]] && { 
        dialog --title "Error" --msgbox "Directory empty or not accessible: $current" 8 60
        return 2
    }

    local menu_items=()
    local temp_items=()
    
    # Collect all items first
    while IFS= read -r item; do
        if [[ -n "$item" ]]; then
            local clean_name="${item%/}"
            clean_name="${clean_name%@}"
            clean_name="${clean_name%\?}"
            
            # Apply filter if specified
            if [[ -n "$file_filter" ]]; then
                # Always include directories and parent
                if [[ "$item" =~ /$ ]] || [[ "$item" == ".." ]]; then
                    temp_items+=("$item")
                # Include files matching filter
                elif [[ "$clean_name" =~ \.($file_filter)$ ]]; then
                    temp_items+=("$item")
                fi
            else
                temp_items+=("$item")
            fi
        fi
    done <<< "$content"
    
    # Build menu with descriptions
    for item in "${temp_items[@]}"; do
        local desc=$(get_item_description "$current" "$item")
        menu_items+=("$item" "$desc")
    done

    # Add "Select this directory" option if in directory mode
    if [ "$select_type" = "dir" ] && [ "$current" != "/" ]; then
        menu_items+=("." "📍 [Select this directory]")
    fi

    local height=22
    local width=75
    local menu_height=14
    local display_path="$current"
    [ ${#display_path} -gt 55 ] && display_path="...${display_path: -52}"

    local instruction_msg=""
    if [ "$select_type" = "dir" ]; then
        instruction_msg="Select a directory or navigate with folders"
    else
        if [[ -n "$file_filter" ]]; then
            instruction_msg="Select a file (.$file_filter) or navigate directories"
        else
            instruction_msg="Select a file or navigate directories"
        fi
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
        clean_name="${clean_name%\?}"
        
        if [ "$selected" = ".." ]; then
            show_file_browser "$(dirname "$current")" "$select_type" "$file_filter"
            return $?
        elif [ "$selected" = "." ]; then
            SELECTED_FILE="$current"
            return 0
        elif [[ "$selected" =~ /$ ]]; then
            show_file_browser "$current/$clean_name" "$select_type" "$file_filter"
            return $?
        else
            if [ "$select_type" = "dir" ]; then
                dialog --title "Warning" --msgbox "Please select a directory, not a file!" 8 50
                show_file_browser "$current" "$select_type" "$file_filter"
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

# --- Utility Functions ---

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        dialog --title "Error" --msgbox "Required command '$1' is not installed." 8 50
        exit 1
    fi
}

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
    fi
    
    local extension="${disk_file##*.}"
    case "${extension,,}" in
        qcow2) echo "qcow2" ;;
        vmdk)  echo "vmdk"  ;;
        vdi)   echo "vdi"   ;;
        vhd)   echo "vpc"   ;;
        vhdx)  echo "vhdx"  ;;
        raw|img) echo "raw" ;;
        *) echo "raw" ;;
    esac
}

# --- Main Menu Functions ---

show_main_menu() {
    local menu_text="Current Configuration:\n"
    menu_text+="\n💾 Disk: ${DISK:-Not selected}"
    if [ -n "$DISK" ]; then
        local disk_format=$(detect_disk_format "$DISK")
        menu_text+=" (Format: $disk_format)"
    fi
    menu_text+="\n💿 ISO: ${ISO:-None}"
    menu_text+="\n🖥️  Boot Mode: $BOOT_MODE"
    menu_text+="\n🔄 Boot Priority: $BOOT_PRIORITY"
    menu_text+="\n💻 RAM: $VM_RAM | CPUs: $VM_CPUS"
    
    local choice
    choice=$(dialog --title "🚀 QEMU VM Launcher" \
        --menu "$menu_text" \
        22 70 12 \
        "1" "💾 Select Virtual Disk" \
        "2" "💿 Select ISO Image (Optional)" \
        "3" "🖥️  Change Boot Mode (MBR/UEFI)" \
        "4" "🔄 Change Boot Priority" \
        "5" "💻 VM Resources (RAM/CPU)" \
        "6" "🗑️  Clear ISO Selection" \
        "7" "👁️  Toggle Hidden Files" \
        "8" "▶️  Launch VM" \
        "9" "🚀 Launch VM with Boot Menu (F12)" \
        "0" "❌ Exit" \
        2>&1 >/dev/tty)
    
    echo "$choice"
}

select_disk() {
    local start_dir="${1:-$PWD}"
    SELECTED_FILE=""
    
    show_file_browser "$start_dir" "file" "vhd|vhdx|qcow2|vmdk|vdi|raw|img|vpc|qed"
    
    if [ $? -eq 0 ] && [ -n "$SELECTED_FILE" ]; then
        if [ -f "$SELECTED_FILE" ]; then
            DISK="$SELECTED_FILE"
            dialog --title "Success" --msgbox "Virtual disk selected:\n$DISK" 8 60
        else
            dialog --title "Error" --msgbox "Selected file does not exist!" 8 50
        fi
    fi
}

select_iso() {
    local start_dir="${1:-$PWD}"
    SELECTED_FILE=""
    
    show_file_browser "$start_dir" "file" "iso|ISO"
    
    if [ $? -eq 0 ] && [ -n "$SELECTED_FILE" ]; then
        if [ -f "$SELECTED_FILE" ]; then
            ISO="$SELECTED_FILE"
            dialog --title "Success" --msgbox "ISO image selected:\n$ISO" 8 60
        else
            dialog --title "Error" --msgbox "Selected file does not exist!" 8 50
        fi
    fi
}

select_boot_mode() {
    local choice
    choice=$(dialog --title "Boot Mode" \
        --radiolist "Select boot mode:" \
        10 50 2 \
        "mbr" "MBR/Legacy Boot" $([ "$BOOT_MODE" = "mbr" ] && echo "on" || echo "off") \
        "uefi" "UEFI Boot" $([ "$BOOT_MODE" = "uefi" ] && echo "on" || echo "off") \
        2>&1 >/dev/tty)
    
    if [ $? -eq 0 ] && [ -n "$choice" ]; then
        BOOT_MODE="$choice"
        dialog --title "Success" --msgbox "Boot mode set to: $BOOT_MODE" 6 40
    fi
}

select_boot_priority() {
    local choice
    choice=$(dialog --title "Boot Priority" \
        --radiolist "Select boot priority:" \
        12 60 3 \
        "auto" "Auto (ISO first if present)" $([ "$BOOT_PRIORITY" = "auto" ] && echo "on" || echo "off") \
        "hd" "Hard Disk First" $([ "$BOOT_PRIORITY" = "hd" ] && echo "on" || echo "off") \
        "iso" "ISO First" $([ "$BOOT_PRIORITY" = "iso" ] && echo "on" || echo "off") \
        2>&1 >/dev/tty)
    
    if [ $? -eq 0 ] && [ -n "$choice" ]; then
        BOOT_PRIORITY="$choice"
        dialog --title "Success" --msgbox "Boot priority set to: $BOOT_PRIORITY" 6 40
    fi
}

configure_resources() {
    local temp_ram temp_cpus
    
    # RAM configuration
    temp_ram=$(dialog --title "VM Resources" \
        --inputbox "Enter RAM amount (e.g., 2G, 4G, 8G):" \
        8 50 "$VM_RAM" \
        2>&1 >/dev/tty)
    
    if [ $? -eq 0 ] && [ -n "$temp_ram" ]; then
        if [[ "$temp_ram" =~ ^[0-9]+[GMK]?$ ]]; then
            VM_RAM="$temp_ram"
        else
            dialog --title "Error" --msgbox "Invalid RAM format! Use format like: 2G, 4G, 512M" 8 50
            return
        fi
    fi
    
    # CPU configuration
    temp_cpus=$(dialog --title "VM Resources" \
        --inputbox "Enter number of CPU cores:" \
        8 50 "$VM_CPUS" \
        2>&1 >/dev/tty)
    
    if [ $? -eq 0 ] && [ -n "$temp_cpus" ]; then
        if [[ "$temp_cpus" =~ ^[0-9]+$ ]] && [ "$temp_cpus" -ge 1 ] && [ "$temp_cpus" -le 16 ]; then
            VM_CPUS="$temp_cpus"
            dialog --title "Success" --msgbox "Resources configured:\nRAM: $VM_RAM\nCPUs: $VM_CPUS" 8 40
        else
            dialog --title "Error" --msgbox "Invalid CPU count! Must be between 1 and 16" 8 50
        fi
    fi
}

launch_vm() {
    if [ -z "$DISK" ]; then
        dialog --title "Error" --msgbox "No virtual disk selected!" 8 40
        return 1
    fi
    
    if [ ! -f "$DISK" ]; then
        dialog --title "Error" --msgbox "Virtual disk not found:\n$DISK" 8 60
        return 1
    fi
    
    if [ -n "$ISO" ] && [ ! -f "$ISO" ]; then
        dialog --title "Error" --msgbox "ISO file not found:\n$ISO" 8 60
        return 1
    fi
    
    # Detect disk format
    local disk_format=$(detect_disk_format "$DISK")
    
    # Configure UEFI if needed
    if [ "$BOOT_MODE" = "uefi" ]; then
        if [ ! -f "$OVMF_CODE" ]; then
            dialog --title "Error" --msgbox "UEFI firmware not found at:\n$OVMF_CODE" 8 60
            return 1
        fi
        rm -f "$OVMF_VARS" # Reset UEFI variables
        cp "$OVMF_CODE" "$OVMF_VARS"
    fi
    
    # Show launch summary with effective boot priority
    local summary="VM Configuration:\n\n"
    summary+="💾 Disk: $(basename "$DISK")\n"
    summary+="   Format: $disk_format\n"
    if [ -n "$ISO" ]; then
        summary+="💿 ISO: $(basename "$ISO")\n"
    fi
    summary+="🖥️  Boot Mode: $BOOT_MODE\n"
    summary+="🔄 Boot Priority: $BOOT_PRIORITY"
    
    local has_iso="false"
    [ -n "$ISO" ] && has_iso="true"
    local effective_priority="$BOOT_PRIORITY"
    if [ "$BOOT_PRIORITY" = "auto" ]; then
        if [ "$has_iso" = "true" ]; then
            effective_priority="iso"
        else
            effective_priority="hd"
        fi
    fi
    
    if [ "$effective_priority" != "$BOOT_PRIORITY" ]; then
        summary+=" → $effective_priority"
    fi
    summary+="\n"
    
    if [ "$effective_priority" = "iso" ] && [ -n "$ISO" ]; then
        summary+="   ⚡ Will boot from ISO first\n"
    elif [ "$effective_priority" = "hd" ]; then
        summary+="   ⚡ Will boot from Hard Disk first\n"
    fi
    
    summary+="💻 RAM: $VM_RAM | CPUs: $VM_CPUS\n"
    summary+="\nPress OK to launch the VM"
    
    dialog --title "Launch Confirmation" --yesno "$summary" 14 60
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Assemble QEMU command
    local QEMU_CMD="qemu-system-x86_64"
    QEMU_CMD+=" -m $VM_RAM"
    QEMU_CMD+=" -smp $VM_CPUS"
    QEMU_CMD+=" $QEMU_ACCEL_OPTS"
    QEMU_CMD+=" -machine q35"
    QEMU_CMD+=" -cpu host"
    QEMU_CMD+=" -vga virtio"
    QEMU_CMD+=" -display gtk,show-cursor=on"
    QEMU_CMD+=" -monitor vc"
    QEMU_CMD+=" -serial file:/tmp/qemu-serial.log"
    QEMU_CMD+=" -usb"
    QEMU_CMD+=" -device usb-tablet"
    
    # Add UEFI firmware if needed
    if [ "$BOOT_MODE" = "uefi" ]; then
        QEMU_CMD+=" -drive if=pflash,format=raw,unit=0,file=$OVMF_CODE,readonly=on"
        QEMU_CMD+=" -drive if=pflash,format=raw,unit=1,file=$OVMF_VARS"
    fi
    
    # Add disk
    QEMU_CMD+=" -drive file=$DISK,format=$disk_format,if=virtio,cache=writeback"
    
    # Add ISO if present
    if [ -n "$ISO" ]; then
        QEMU_CMD+=" -drive file=$ISO,format=raw,media=cdrom,readonly=on"
    fi
    
    # Configure boot priority
    if [ "$effective_priority" = "iso" ] && [ -n "$ISO" ]; then
        QEMU_CMD+=" -boot once=d,menu=on,splash-time=5000,strict=on"
    elif [ "$effective_priority" = "hd" ] && [ -n "$ISO" ]; then
        QEMU_CMD+=" -boot once=c,menu=on,splash-time=5000,strict=on"
    else
        QEMU_CMD+=" -boot order=c,menu=on"
    fi
    
    # Clear dialog screen
    clear
    
    # Show launch info with boot priority details
    echo -e "${GREEN}=== Launching QEMU VM ===${NC}"
    echo -e "${BLUE}Disk:${NC} $DISK"
    [ -n "$ISO" ] && echo -e "${BLUE}ISO:${NC} $ISO"
    echo -e "${BLUE}Boot Mode:${NC} $BOOT_MODE"
    echo -e "${BLUE}Boot Priority:${NC} $effective_priority"
    if [ "$effective_priority" = "iso" ] && [ -n "$ISO" ]; then
        echo -e "${YELLOW}→ Booting from ISO first${NC}"
    elif [ "$effective_priority" = "hd" ]; then
        echo -e "${YELLOW}→ Booting from Hard Disk first${NC}"
    fi
    echo -e "${BLUE}Resources:${NC} RAM=$VM_RAM, CPUs=$VM_CPUS"
    echo ""
    echo -e "${YELLOW}Starting VM...${NC}"
    echo -e "${YELLOW}Tip: Press F12 during boot for boot menu${NC}"
    echo ""
    
    # Debug: Show the actual command being run
    echo -e "${BLUE}Debug - QEMU Command:${NC}"
    echo "$QEMU_CMD"
    echo ""
    
    # Launch QEMU
    eval $QEMU_CMD
    
    if [ $? -ne 0 ]; then
        echo ""
        echo -e "${RED}Error: Failed to launch QEMU${NC}"
        echo "Press Enter to return to menu..."
        read -r
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}QEMU session ended.${NC}"
    echo "Press Enter to return to menu..."
    read -r
}

# --- Main Script ---

# Check dependencies
check_dependency dialog
check_dependency qemu-system-x86_64

# Parse command line arguments if provided
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
            shift 2
            ;;
        --help)
            clear
            echo "QEMU VM Launcher with Dialog Interface"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --hd <path>             Path to virtual disk"
            echo "  --iso <path>            Path to ISO file (optional)"
            echo "  --mbr                   Use MBR boot mode"
            echo "  --uefi                  Use UEFI boot mode"
            echo "  --boot-priority <mode>  Boot priority: auto|hd|iso"
            echo "  --help                  Show this help"
            echo ""
            echo "If no options are provided, interactive mode will start."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Main loop
while true; do
    choice=$(show_main_menu)
    
    case "$choice" in
        1) select_disk ;;
        2) select_iso ;;
        3) select_boot_mode ;;
        4) select_boot_priority ;;
        5) configure_resources ;;
        6) 
            ISO=""
            dialog --title "Success" --msgbox "ISO selection cleared" 6 40
            ;;
        7)
            if $SHOW_HIDDEN; then
                SHOW_HIDDEN=false
                dialog --title "File Browser" --msgbox "Hidden files: OFF" 6 40
            else
                SHOW_HIDDEN=true
                dialog --title "File Browser" --msgbox "Hidden files: ON" 6 40
            fi
            ;;
        8) launch_vm "false" ;;
        9) launch_vm "true" ;;
        0|"") 
            clear
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0
            ;;
    esac
done