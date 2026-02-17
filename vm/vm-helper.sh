#!/usr/bin/env bash
# PKG_NAME: vm-helper
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), qemu-utils, whiptail
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Interactive TUI helper for VM and disk image operations
# PKG_LONG_DESCRIPTION: Whiptail-based menu to launch and manage VMs, clone
#  disks, convert image formats, test Ventoy USB drives, and run chroot
#  operations — without memorizing command-line arguments.
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
# VM Helper Script - whiptail/dialog version
# Author: Manzolo
# Description: Utility to manage VMs, disks, and ISOs interactively.

set -euo pipefail
IFS=$'\n\t'

# ================= CONFIGURATION =================
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/manzolo/vm_helper.conf"
HISTORY_FILE="$HOME/.manzolo_vm_helper_history"

# Default paths (overwritable by external config)
ISO_DIRS=("/home")
IMAGE_DIRS=("/home")

# Load custom configuration
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ================= PREREQUISITES =================
for cmd in qemu-img whiptail; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: Required command not found: $cmd"
        exit 1
    }
done

# ================= UTILITY FUNCTIONS =================

# Ask a yes/no question
ask-yes-no() {
    whiptail --yesno "$1" 10 60 --defaultno 3>&1 1>&2 2>&3
}

# Copy text to clipboard
copy-to-clipboard() {
    local text="$1" message=""
    if command -v wl-copy &>/dev/null; then
        echo "$text" | wl-copy
        message="Copied to clipboard (wl-copy)"
    elif command -v xclip &>/dev/null; then
        echo "$text" | xclip -selection clipboard
        message="Copied to clipboard (xclip)"
    else
        message="Clipboard not available"
    fi
    whiptail --msgbox "$message" 10 50
}

# Log a command to history file
log-command() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$HISTORY_FILE"
}

# Run a command with confirmation
run-command() {
    local command="$1"
    log-command "$command"

    if whiptail --title "Confirm Command" --yesno "Run this command?\n\n$command" 15 80; then
        ( eval "$command" )
    elif ask-yes-no "Copy to clipboard instead?"; then
        copy-to-clipboard "$command"
    fi
}

# ================= FILE/DIRECTORY SELECTION =================

# Select a directory from a list
select-directory() {
    local title="$1"; shift
    local dirs=("$@") menu_items=() counter=0

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] && menu_items+=("$counter" "$dir") && ((counter++))
    done

    [[ ${#menu_items[@]} -eq 0 ]] && {
        whiptail --msgbox "No valid directories found." 10 50
        return 1
    }

    local choice
    choice=$(whiptail --title "$title" --menu "Choose a directory:" 20 70 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1
    echo "${dirs[$choice]}"
}

# Select a file from a directory
select-file() {
    local dir="$1" description="$2" type="${3:-all}"
    local files=() file_paths=() counter=0

    [[ ! -d "$dir" ]] && {
        whiptail --msgbox "Directory not found: $dir" 10 50
        return 1
    }

    local pattern="*"
    [[ "$type" == "iso" ]] && pattern="*.iso"

    while IFS= read -r -d '' file; do
        files+=("$counter" "$(basename "$file")")
        file_paths+=("$file")
        ((counter++))
    done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -print0 | sort -z)

    if [[ ${#files[@]} -eq 0 ]]; then
        local manual_path
        manual_path=$(whiptail --inputbox "No $type files found.\nEnter manual path for $description:" 12 70 3>&1 1>&2 2>&3) || return 1
        echo "$manual_path"
    else
        local choice
        choice=$(whiptail --title "$description" --menu "Select a file:" 20 70 10 "${files[@]}" 3>&1 1>&2 2>&3) || return 1
        echo "${file_paths[$choice]}"
    fi
}

# ================= HANDLERS =================

# VM-related handlers
handle-vm-try-with-iso() {
    local hdd_dir hdd iso_dir iso uefi_flag=""
    hdd_dir=$(select-directory "Select HDD Directory" "${IMAGE_DIRS[@]}") || return
    hdd=$(select-file "$hdd_dir" "Select HDD" "image") || return
    iso_dir=$(select-directory "Select ISO Directory" "${ISO_DIRS[@]}") || return
    iso=$(select-file "$iso_dir" "Select Bootable ISO" "iso") || return
    ask-yes-no "Use UEFI mode?" && uefi_flag=" --uefi"

    run-command "vm-try --hd \"$hdd\" --iso \"$iso\"$uefi_flag"
}

handle-vm-try-without-iso() {
    local hdd_dir hdd uefi_flag=""
    hdd_dir=$(select-directory "Select HDD Directory" "${IMAGE_DIRS[@]}") || return
    hdd=$(select-file "$hdd_dir" "Select HDD" "image") || return
    ask-yes-no "Use UEFI mode?" && uefi_flag=" --uefi"

    run-command "vm-try --hd \"$hdd\"$uefi_flag"
}

handle-vm-clone() {
    local iso_dir iso src_dir src_image dst_dir dst_image uefi_flag=""
    iso_dir=$(select-directory "Select ISO Directory" "${ISO_DIRS[@]}") || return
    iso=$(select-file "$iso_dir" "Select ISO" "iso") || return
    src_dir=$(select-directory "Select Source Image Directory" "${IMAGE_DIRS[@]}") || return
    src_image=$(select-file "$src_dir" "Select Source Image" "image") || return
    dst_dir=$(select-directory "Select Destination Image Directory" "${IMAGE_DIRS[@]}") || return
    dst_image=$(select-file "$dst_dir" "Select Destination Image" "image") || return
    ask-yes-no "Use UEFI mode?" && uefi_flag=" --uefi"

    run-command "vm-clone --iso \"$iso\" --src \"$src_image\" --dst \"$dst_image\"$uefi_flag"
}

# qemu-img convert handler
handle-qemu-convert() {
    local src_dir src_image dst_image src_format dst_format dst_ext dst_opts=""
    src_dir=$(select-directory "Select Source Directory" "${IMAGE_DIRS[@]}") || return
    src_image=$(select-file "$src_dir" "Select Source Image" "image") || return

    case "${src_image,,}" in
        *.vhd) src_format="vpc" ;;
        *.qcow2) src_format="qcow2" ;;
        *.raw) src_format="raw" ;;
        *) src_format=$(whiptail --inputbox "Source format (vpc/qcow2/raw):" 10 50 3>&1 1>&2 2>&3) || return ;;
    esac

    dst_format=$(whiptail --title "Destination Format" --menu "Select format:" 15 50 4 \
        "vpc" "VHD" "raw" "RAW" "qcow2" "QCOW2" 3>&1 1>&2 2>&3) || return

    case $dst_format in
        vpc) dst_ext=".vhd"; dst_opts="-o subformat=fixed" ;;
        raw) dst_ext=".raw" ;;
        qcow2) dst_ext=".qcow2" ;;
    esac

    dst_image="${src_image%.*}_converted$dst_ext"
    dst_image=$(whiptail --inputbox "Destination file:" 10 70 "$dst_image" 3>&1 1>&2 2>&3) || return

    run-command "qemu-img convert -p -f $src_format -O $dst_format $dst_opts \"$src_image\" \"$dst_image\""
}

# Generic handlers
handle-custom() {
    local cmd
    cmd=$(whiptail --inputbox "Enter command (use \$ISO, \$VENTOY, \$VM):" 15 70 3>&1 1>&2 2>&3) || return
    cmd="${cmd//\$ISO/${ISO_DIRS[0]}}"
    cmd="${cmd//\$VENTOY/${IMAGE_DIRS[0]}}"
    run-command "$cmd"
}

handle-ventoy-usb-test() { ( sudo ventoy-usb-test ); }
handle-vm-create-disk() { ( vm-create-disk ); }
handle-vm-disk-manager() { ( sudo vm-disk-manager ); }
handle-chroot() { ( mchroot ); }
handle-virtual-chroot() { ( vchroot ); }

# ================= MAIN MENU =================
main-menu() {
    local menu_items=(
        1 "Start a VM with an ISO"
        2 "Start a VM without an ISO"
        3 "Clone a VM"
        4 "Test Ventoy USB"
        5 "Manage VM disks"
        6 "Create VM disk"
        7 "Chroot to a system"
        8 "Virtual Chroot"
        9 "Convert disk image format"
        10 "Run custom command"
        11 "Exit"
    )

    while true; do
        local choice
        choice=$(whiptail --title "VM Helper" --menu "Choose an operation:" 20 70 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 0

        case $choice in
            1) handle-vm-try-with-iso ;;
            2) handle-vm-try-without-iso ;;
            3) handle-vm-clone ;;
            4) handle-ventoy-usb-test ;;
            5) handle-vm-disk-manager ;;
            6) handle-vm-create-disk ;;
            7) handle-chroot ;;
            8) handle-virtual-chroot ;;
            9) handle-qemu-convert ;;
            10) handle-custom ;;
            11) exit 0 ;;
        esac
    done
}

# ================= SCRIPT START =================
main-menu