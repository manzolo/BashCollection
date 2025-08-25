#!/bin/bash

# Function to check if a file is in use
check_file_lock() {
    local file=$1
    
    log "Checking file lock for $file"
    if lsof "$file" >/dev/null 2>&1; then
        local processes=$(lsof "$file" 2>/dev/null | tail -n +2 | awk '{print $2 " (" $1 ")"}' | sort -u)
        whiptail --title "File in Use" --yesno "The file is currently in use by the following processes:\n\n$processes\n\nDo you want to terminate these processes and continue?" 15 70
        
        if [ $? -eq 0 ]; then
            lsof "$file" 2>/dev/null | tail -n +2 | awk '{print $2}' | sort -u | while read pid; do
                kill "$pid" 2>/dev/null
                sleep 1
                kill -9 "$pid" 2>/dev/null
            done
            sleep 2
            
            if lsof "$file" >/dev/null 2>&1; then
                log "Could not release file lock"
                whiptail --msgbox "Could not release the file. Please try again later." 8 60
                return 1
            fi
        else
            return 1
        fi
    fi
    
    log "File lock check passed"
    return 0
}

# Function to format file size in human readable format
format_size() {
    local size_bytes=$1
    if [ "$size_bytes" -lt 1024 ]; then
        echo "${size_bytes}B"
    elif [ "$size_bytes" -lt 1048576 ]; then
        echo "$((size_bytes / 1024))K"
    elif [ "$size_bytes" -lt 1073741824 ]; then
        echo "$((size_bytes / 1048576))M"
    else
        echo "$((size_bytes / 1073741824))G"
    fi
}

# Function to detect if file is a VM image
is_vm_image() {
    local file=$1
    local basename_file=$(basename "$file")
    
    # Check by extension
    if [[ "$basename_file" =~ \.(img|raw|qcow2|vmdk|vdi|iso|vhd|qed|vpc|parallels)$ ]]; then
        return 0
    fi
    
    # Check by file content (magic bytes)
    if command -v file >/dev/null 2>&1; then
        local file_type=$(file "$file" 2>/dev/null)
        if [[ "$file_type" =~ (QEMU|VMware|VirtualBox|disk|ISO|filesystem) ]]; then
            return 0
        fi
    fi
    
    return 1
}

# Function to get file type icon/prefix
get_file_prefix() {
    local file=$1
    local basename_file=$(basename "$file")
    
    if [ -d "$file" ]; then
        echo "[DIR]"
    elif is_vm_image "$file"; then
        # More specific VM image detection
        case "${basename_file,,}" in
            *.qcow2) echo "[QCOW2]" ;;
            *.vmdk) echo "[VMDK]" ;;
            *.vdi) echo "[VDI]" ;;
            *.iso) echo "[ISO]" ;;
            *.img) echo "[IMG]" ;;
            *.raw) echo "[RAW]" ;;
            *) echo "[DISK]" ;;
        esac
    else
        case "${basename_file,,}" in
            *.tar.gz|*.tgz) echo "[TGZ]" ;;
            *.tar.bz2|*.tbz2) echo "[TBZ]" ;;
            *.tar.xz|*.txz) echo "[TXZ]" ;;
            *.zip) echo "[ZIP]" ;;
            *.rar) echo "[RAR]" ;;
            *.7z) echo "[7Z]" ;;
            *.txt|*.md) echo "[TXT]" ;;
            *.log) echo "[LOG]" ;;
            *.conf|*.cfg) echo "[CFG]" ;;
            *.sh) echo "[SH]" ;;
            *.py) echo "[PY]" ;;
            *) echo "[FILE]" ;;
        esac
    fi
}

# Function to select a file or directory
select_file() {
    local current_dir=$(pwd)
    local show_hidden=false
    local show_all_files=false

    while true; do
        local items=()
        local paths=()

        # Add navigation and special options to the paths array first
        if [ "$current_dir" != "/" ]; then
            paths+=("GO_PARENT")
        fi
        paths+=("INFO")
        paths+=("OPTIONS")
        paths+=("MANUAL")
        paths+=("QUICK")
        paths+=("SEP")

        # Find and sort directories and files
        local find_args=("$current_dir" "-maxdepth" "1")
        [ "$show_hidden" = false ] && find_args+=("!" "-name" ".*")

        local sorted_items=()
        while IFS= read -r -d '' item; do
            [ "$item" != "$current_dir" ] && sorted_items+=("$item")
        done < <(find "${find_args[@]}" \( -type d -o -type f \) -print0 2>/dev/null | sort -z)
        
        # Add sorted items to the paths array
        for item in "${sorted_items[@]}"; do
            if [ -d "$item" ]; then
                paths+=("$item")
            else
                if [ "$show_all_files" = true ] || is_vm_image "$item"; then
                    paths+=("$item")
                fi
            fi
        done

        # Now, build the items array for whiptail from the paths array
        local counter=1
        for p in "${paths[@]}"; do
            case "$p" in
                "GO_PARENT")
                    items+=("$counter" "⬆️  .. (Parent Directory)")
                    ;;
                "INFO")
                    items+=("$counter" "📍 Current: $(basename "$current_dir")")
                    ;;
                "OPTIONS")
                    items+=("$counter" "⚙️  Options...")
                    ;;
                "MANUAL")
                    items+=("$counter" "📝 Enter path manually...")
                    ;;
                "QUICK")
                    items+=("$counter" "🔗 Quick locations...")
                    ;;
                "SEP")
                    items+=("$counter" "─────────────────────")
                    ;;
                *)
                    # This is a file or a directory
                    local base=$(basename "$p")
                    local prefix=$(get_file_prefix "$p")
                    if [ -d "$p" ]; then
                        local n=$(find "$p" -maxdepth 1 -type f 2>/dev/null | wc -l)
                        items+=("$counter" "$prefix $base/ ($n files)")
                    else
                        local size=$(stat -c%s "$p" 2>/dev/null || echo 0)
                        local human=$(format_size "$size")
                        local mod=$(stat -c%y "$p" 2>/dev/null | cut -d' ' -f1)
                        items+=("$counter" "$prefix $base ($human) [$mod]")
                    fi
                    ;;
            esac
            ((counter++))
        done

        # Menu height and title
        local title="File Browser - $(basename "$current_dir")"
        local h=$((${#items[@]} / 2)); (( h<8 )) && h=8; (( h>15 )) && h=15

        local choice
        choice=$(whiptail --title "$title" --menu "Select an item:" 25 90 $h "${items[@]}" 3>&1 1>&2 2>&3)

        local rc=$?
        if [ $rc -ne 0 ]; then
            log "File selection cancelled"
            return 1
        fi

        local idx=$((choice - 1))
        local selected_path="${paths[$idx]}"

        case "$selected_path" in
            GO_PARENT)
                current_dir=$(dirname "$current_dir")
                ;;
            INFO|SEP)
                : # ignore
                ;;
            OPTIONS)
                local opts=(
                    "1" "Show hidden: $([ "$show_hidden" = true ] && echo ON || echo OFF)"
                    "2" "File filter: $([ "$show_all_files" = true ] && echo 'All' || echo 'VM only')"
                    "3" "Update list"
                    "4" "Directory tree"
                    "5" "Back"
                )
                local oc
                oc=$(whiptail --title "Browser options" --menu "Select:" 15 60 5 "${opts[@]}" 3>&1 1>&2 2>&3) || true
                case "$oc" in
                    1) show_hidden=$([ "$show_hidden" = true ] && echo false || echo true) ;;
                    2) show_all_files=$([ "$show_all_files" = true ] && echo false || echo true) ;;
                    3) : ;;
                    4)
                        if command -v tree >/dev/null 2>&1; then
                            local tree_output=$(tree -L 2 "$current_dir" 2>/dev/null)
                            whiptail --title "Directory Tree" --scrolltext --textbox <(echo -e "$tree_output") 20 80
                        else
                            local simple_tree=$(find "$current_dir" -maxdepth 2 -type d 2>/dev/null | sed "s|$current_dir|.|")
                            whiptail --title "Directory Structure" --scrolltext --textbox <(echo -e "$simple_tree") 20 60
                        fi
                        ;;
                    *) : ;;
                esac
                ;;
            MANUAL)
                local manual
                manual=$(whiptail --inputbox "Enter file or directory path:" 10 70 "$current_dir" 3>&1 1>&2 2>&3) || { :; }
                if [ -n "$manual" ]; then
                    if [ -f "$manual" ]; then
                        echo "$manual"; return 0
                    elif [ -d "$manual" ]; then
                        current_dir="$manual"
                    else
                        whiptail --msgbox "Path does not exist: $manual" 8 60
                    fi
                fi
                ;;
            QUICK)
                local q=(
                    "1" "/var/lib/libvirt/images"
                    "2" "/home"
                    "3" "$HOME"
                    "4" "/tmp"
                    "5" "/mnt"
                    "6" "/media"
                    "7" "/"
                    "8" "$(dirname "$current_dir") (Parent)"
                    "9" "Back"
                )
                local qc
                qc=$(whiptail --title "Quick locations" --menu "Go to:" 18 70 9 "${q[@]}" 3>&1 1>&2 2>&3) || { :; }
                case "$qc" in
                    1) current_dir="/var/lib/libvirt/images" ;;
                    2) current_dir="/home" ;;
                    3) current_dir="$HOME" ;;
                    4) current_dir="/tmp" ;;
                    5) current_dir="/mnt" ;;
                    6) current_dir="/media" ;;
                    7) current_dir="/" ;;
                    8) current_dir="$(dirname "$current_dir")" ;;
                    *) : ;;
                esac
                [ -d "$current_dir" ] || current_dir=$(pwd)
                ;;
            *)
                if [ -d "$selected_path" ]; then
                    current_dir="$selected_path"
                elif [ -f "$selected_path" ]; then
                    if [ "$show_all_files" = true ] || is_vm_image "$selected_path"; then
                        echo "$selected_path"; return 0
                    else
                        if whiptail --yesno "File doesn't appear to be a VM image.\nDo you want to proceed anyway?" 10 70; then
                            echo "$selected_path"; return 0
                        fi
                    fi
                fi
                ;;
        esac
    done

    return 1
}

# Function to get the new size
get_size() {
    local size_options=(
        "1" "1G - 1 Gigabyte"
        "2" "5G - 5 Gigabyte"
        "3" "10G - 10 Gigabyte"
        "4" "20G - 20 Gigabyte"
        "5" "50G - 50 Gigabyte"
        "6" "100G - 100 Gigabyte"
        "7" "200G - 200 Gigabyte"
        "8" "Enter custom size"
    )
    
    choice=$(whiptail --title "Image Size" --menu "Select the new size:" 18 60 8 "${size_options[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    case $choice in
        1) echo "1G" ;;
        2) echo "5G" ;;
        3) echo "10G" ;;
        4) echo "20G" ;;
        5) echo "50G" ;;
        6) echo "100G" ;;
        7) echo "200G" ;;
        8) 
            custom_size=$(whiptail --title "Custom Size" --inputbox "Enter the size (e.g., 15G, 500M, 1T):" 10 60 3>&1 1>&2 2>&3)
            if [ $? -eq 0 ] && [[ $custom_size =~ ^[0-9]+(\.[0-9]+)?[KMGT]?$ ]]; then
                echo "$custom_size"
            else
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

# Function to check free space before resizing
check_free_space() {
    local file=$1
    local new_size=$2
    
    local new_size_bytes=$(echo "$new_size" | awk '
        /[0-9]+\.[0-9]+[KMGTP]/ {printf "%.0f", $0 * 1024 * 1024 * 1024; exit}
        /[0-9]+[KMGTP]/ {printf "%.0f", $0 * 1024 * 1024 * 1024; exit}
        /[0-9]+\.[0-9]+/ {printf "%.0f", $0 * 1024 * 1024 * 1024; exit}
        {printf "%.0f", $0 * 1024 * 1024 * 1024}
    ' 2>/dev/null || echo 0)
    
    local current_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    local available_space=$(df --output=avail -B1 "$(dirname "$file")" | tail -1)
    
    local space_needed=$((new_size_bytes - current_size))
    
    if [ $space_needed -gt $available_space ]; then
        local needed_gb=$(echo "scale=2; $space_needed / 1024 / 1024 / 1024" | bc)
        local available_gb=$(echo "scale=2; $available_space / 1024 / 1024 / 1024" | bc)
        
        whiptail --msgbox "Insufficient disk space!\n\nNeeded: ${needed_gb}G additional\nAvailable: ${available_gb}G\n\nFree up space or choose another location." 12 70
        return 1
    fi
    
    return 0
}