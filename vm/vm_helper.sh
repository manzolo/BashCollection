#!/usr/bin/env bash
# VM Helper Script - whiptail/dialog version

set -euo pipefail
IFS=$'\n\t'

# ================= CONFIG =================
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/manzolo/vm_helper.conf"

# Default paths (can be overwritten by external config)
ISO_DIRS=(
    "/home"
)
IMAGE_DIRS=(
    "/home"
)

HISTORY_FILE="$HOME/.manzolo_vm_helper_history"

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ================= UTILS =================
ask_yes_no() {
    whiptail --yesno "$1" 10 60 --defaultno 3>&1 1>&2 2>&3
}

copy_clipboard() {
    local text="$1"
    if command -v xclip &>/dev/null; then
        echo "$text" | xclip -selection clipboard
        whiptail --msgbox "Copied to clipboard (xclip)" 10 50 3>&1 1>&2 2>&3
    elif command -v wl-copy &>/dev/null; then
        echo "$text" | wl-copy
        whiptail --msgbox "Copied to clipboard (wl-copy)" 10 50 3>&1 1>&2 2>&3
    else
        whiptail --msgbox "Clipboard not available" 10 50 3>&1 1>&2 2>&3
    fi
}

log_command() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$HISTORY_FILE"
}

# Prerequisite check
for cmd in qemu-img whiptail; do
    command -v "$cmd" >/dev/null 2>&1 || {
        whiptail --msgbox "Error: command $cmd not found" 10 50
        exit 1
    }
done

# ================= FILE SELECTION =================
# Function to select a directory from an array, with a clear menu title.
select_dir() {
    local title="$1"  # New parameter for a clear title
    local dirs=("${@:2}")
    local menu_items=()
    local counter=0

    if [[ ${#dirs[@]} -eq 0 ]]; then
        whiptail --msgbox "No directories configured." 10 50
        return 1
    fi
    
    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            menu_items+=("$counter" "$dir")
            ((counter++))
        fi
    done

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        whiptail --msgbox "No valid directories found." 10 50
        return 1
    fi

    local choice
    choice=$(whiptail --title "$title" --menu "Choose a directory:" 20 70 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1
    
    echo "${dirs[$choice]}"
}

# Simplified function for file selection with automatic filters
select_file() {
    local dir="$1"
    local description="$2"
    local file_type="$3"  # "iso", "image", or "all"
    
    if [[ ! -d "$dir" ]]; then
        whiptail --msgbox "Directory not found: $dir" 10 50 3>&1 1>&2 2>&3
        return 1
    fi

    local files=()
    local file_paths=()
    local counter=0
    
    if [[ "$file_type" == "iso" ]]; then
        while IFS= read -r -d '' file; do
            local filename=$(basename "$file")
            files+=("$counter" "$filename")
            file_paths+=("$file")
            ((counter++))
        done < <(find "$dir" -maxdepth 1 -type f -name "*.iso" -print0 | sort -z)
    elif [[ "$file_type" == "image" ]]; then
        while IFS= read -r -d '' file; do
            local filename=$(basename "$file")
            files+=("$counter" "$filename")
            file_paths+=("$file")
            ((counter++))
        done < <(find "$dir" -maxdepth 1 -type f -print0 | sort -z)
    else
        while IFS= read -r -d '' file; do
            local filename=$(basename "$file")
            files+=("$counter" "$filename")
            file_paths+=("$file")
            ((counter++))
        done < <(find "$dir" -maxdepth 1 -type f -print0 | sort -z)
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        local manual_path
        manual_path=$(whiptail --inputbox "No files found in $dir.\nEnter a manual path for $description:" 12 70 3>&1 1>&2 2>&3) || return 1
        echo "$manual_path"
        return 0
    fi

    local choice
    choice=$(whiptail --title "$description" --menu "Select a file:" 20 70 10 "${files[@]}" 3>&1 1>&2 2>&3) || return 1
    
    echo "${file_paths[$choice]}"
}

# ================= COMMAND BUILDERS =================
handle_vm_try_with_iso() {
    local hdd_dir hdd iso_dir iso uefi_flag=""
    
    echo "Selecting HDD directory..."
    hdd_dir=$(select_dir "Select Virtual Hard Disk Directory" "${IMAGE_DIRS[@]}") || return
    echo "HDD directory selected: $hdd_dir"

    echo "Selecting HDD..."
    hdd=$(select_file "$hdd_dir" "Select Virtual Hard Disk (HDD)" "image") || return
    echo "HDD selected: $hdd"
    
    echo "Selecting ISO directory..."
    iso_dir=$(select_dir "Select Bootable ISO Directory" "${ISO_DIRS[@]}") || return
    echo "ISO directory selected: $iso_dir"
    
    echo "Selecting ISO..."
    iso=$(select_file "$iso_dir" "Select Bootable ISO" "iso") || return
    echo "ISO selected: $iso"

    if ask_yes_no "Do you want to use UEFI mode?"; then
        uefi_flag=" --uefi"
    fi

    local command="vm_try --hd \"$hdd\" --iso \"$iso\"$uefi_flag"
    log_command "$command"

    if whiptail --title "Confirm Command" --yesno "Do you want to run this command?\n\n$command" 15 80 3>&1 1>&2 2>&3; then
        echo "Executing: $command"
        eval "$command"
    elif ask_yes_no "Do you want to copy it to clipboard?"; then
        copy_clipboard "$command"
    fi
}

handle_vm_try_without_iso() {
    local hdd_dir hdd uefi_flag=""
    
    echo "Selecting HDD directory..."
    hdd_dir=$(select_dir "Select Virtual Hard Disk Directory" "${IMAGE_DIRS[@]}") || return
    echo "HDD directory selected: $hdd_dir"

    echo "Selecting HDD..."
    hdd=$(select_file "$hdd_dir" "Select Virtual Hard Disk (HDD)" "image") || return
    echo "HDD selected: $hdd"

    if ask_yes_no "Do you want to use UEFI mode?"; then
        uefi_flag=" --uefi"
    fi

    local command="vm_try --hd \"$hdd\"$uefi_flag"
    log_command "$command"

    if whiptail --title "Confirm Command" --yesno "Do you want to run this command?\n\n$command" 15 80 3>&1 1>&2 2>&3; then
        echo "Executing: $command"
        eval "$command"
    elif ask_yes_no "Do you want to copy it to clipboard?"; then
        copy_clipboard "$command"
    fi
}

handle_vm_clone() {
    local iso_dir iso src_dir src dst_dir dst uefi_flag=""
    
    echo "Selecting ISO directory..."
    iso_dir=$(select_dir "Select ISO Directory for vm_clone" "${ISO_DIRS[@]}") || return
    echo "ISO directory selected: $iso_dir"

    echo "Selecting ISO..."
    iso=$(select_file "$iso_dir" "Select clone ISO" "iso") || return
    echo "ISO selected: $iso"
    
    echo "Selecting source directory..."
    src_dir=$(select_dir "Select Source Image Directory" "${IMAGE_DIRS[@]}") || return
    echo "Source directory selected: $src_dir"

    echo "Selecting source image..."
    src=$(select_file "$src_dir" "Select source image" "image") || return
    echo "Source selected: $src"

    echo "Selecting destination directory..."
    dst_dir=$(select_dir "Select Destination Image Directory" "${IMAGE_DIRS[@]}") || return
    echo "Destination directory selected: $dst_dir"

    echo "Selecting destination image..."
    dst=$(select_file "$dst_dir" "Select destination image" "image") || return
    echo "Destination selected: $dst"

    if ask_yes_no "Do you want to use UEFI mode?"; then
        uefi_flag=" --uefi"
    fi

    local command="vm_clone --iso \"$iso\" --src \"$src\" --dst \"$dst\"$uefi_flag"
    log_command "$command"

    if whiptail --title "Confirm Command" --yesno "Do you want to run this command?\n\n$command" 15 80 3>&1 1>&2 2>&3; then
        echo "Executing: $command"
        eval "$command"
    elif ask_yes_no "Do you want to copy it to clipboard?"; then
        copy_clipboard "$command"
    fi
}

handle_qemu_convert() {
    local src_dir src dst src_format dst_format dst_ext dst_options=""
    
    echo "Selecting source directory..."
    src_dir=$(select_dir "Select Source Directory for qemu-img" "${IMAGE_DIRS[@]}") || return
    echo "Source directory selected: $src_dir"

    echo "Selecting source image..."
    src=$(select_file "$src_dir" "Select source image" "image") || return
    echo "Source selected: $src"

    case "${src,,}" in
        *.vhd) src_format="vpc" ;;
        *.qcow2) src_format="qcow2" ;;
        *.raw) src_format="raw" ;;
        *) src_format=$(whiptail --inputbox "Source format (vpc/qcow2/raw):" 10 50 3>&1 1>&2 2>&3) || return ;;
    esac

    dst_format=$(whiptail --title "Destination Format" --menu "Select format:" 15 50 4 \
        "vpc" "VHD (vpc)" \
        "raw" "RAW" \
        "qcow2" "QCOW2" \
        3>&1 1>&2 2>&3) || return

    case $dst_format in
        vpc) dst_ext=".vhd"; dst_options="-o subformat=fixed" ;;
        raw) dst_ext=".raw" ;;
        qcow2) dst_ext=".qcow2" ;;
    esac

    dst="${src%.*}_converted$dst_ext"
    dst=$(whiptail --inputbox "Destination:" 10 70 "$dst" 3>&1 1>&2 2>&3) || return

    local command="qemu-img convert -p -f $src_format -O $dst_format $dst_options \"$src\" \"$dst\""
    log_command "$command"

    if whiptail --title "Confirm Command" --yesno "Do you want to run this command?\n\n$command" 15 80 3>&1 1>&2 2>&3; then
        echo "Executing: $command"
        eval "$command"
    elif ask_yes_no "Do you want to copy it to clipboard?"; then
        copy_clipboard "$command"
    fi
}

handle_custom() {
    local cmd
    cmd=$(whiptail --inputbox "Enter command (you can use \$ISO, \$VENTOY, \$VM):" 15 70 3>&1 1>&2 2>&3) || return

    cmd="${cmd//\$ISO/$ISO_DIRS[0]}"
    cmd="${cmd//\$VENTOY/$IMAGE_DIRS[0]}"
    cmd="${cmd//\$VM/$VM_DIRS[0]}"

    log_command "$cmd"

    if whiptail --title "Confirm Command" --yesno "Do you want to run this command?\n\n$cmd" 15 80 3>&1 1>&2 2>&3; then
        echo "Executing: $cmd"
        eval "$cmd"
    elif ask_yes_no "Do you want to copy it to clipboard?"; then
        copy_clipboard "$cmd"
    fi
}

handle_vm_ventoy_usb_test(){
    sudo ventoy_usb_test
}

handle_vm_vm_create_disk(){
    vm_create_disk
}

handle_vm_vm_disk_manager(){
    sudo vm_disk_manager
}

handle_chroot(){
    mchroot
}
handle_virtual_chroot(){
    vchroot
}

# ================= MENU =================
main_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "VM Helper" --menu "Choose an operation:" 20 70 10 \
            1 "vm_try with ISO" \
            2 "vm_try without ISO" \
            3 "vm_clone" \
            4 "ventoy_usb_test" \
            5 "vm_disk_manager" \
            6 "vm_create_disk" \
            7 "Chroot" \
            8 "Virtual Chroot" \
            9 "qemu-img convert" \
            10 "Custom command" \
            11 "Exit" \
            3>&1 1>&2 2>&3) || exit 0

        case $choice in
            1) handle_vm_try_with_iso ;;
            2) handle_vm_try_without_iso ;;
            3) handle_vm_clone ;;
            4) handle_vm_ventoy_usb_test ;;
            5) handle_vm_vm_disk_manager ;;
            6) handle_vm_vm_create_disk ;;
            7) handle_chroot ;;
            8) handle_virtual_chroot ;;
            9) handle_qemu_convert ;;
            10) handle_custom ;;
            11) exit 0 ;;
        esac
    done
}

# ================= MAIN =================
main_menu