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

# Enhanced file browser with better navigation and display
select_file() {
    local current_dir=$(pwd)
    local show_hidden=false
    local show_all_files=false  # Show all files, not just VM images
    
    while true; do
        local items=()
        local paths=()
        
        local counter=1
        
        # Navigation options
        if [ "$current_dir" != "/" ]; then
            items+=("$counter" "⬆️  .. (Parent Directory)")
            paths+=("..")
            ((counter++))
        fi
        
        items+=("$counter" "📍 Current: $(basename "$current_dir")")
        paths+=("current_dir_info") # Special token
        local current_indicator=$counter
        ((counter++))
        
        items+=("$counter" "⚙️  Options...")
        paths+=("options_menu") # Special token
        local options_item=$counter
        ((counter++))
        
        items+=("$counter" "📝 Enter path manually...")
        paths+=("manual_entry") # Special token
        local manual_option=$counter
        ((counter++))
        
        items+=("$counter" "🔗 Quick locations...")
        paths+=("quick_locations") # Special token
        local quick_option=$counter
        ((counter++))
        
        # Add separator
        items+=("$counter" "─────────────────────")
        paths+=("separator")
        ((counter++))
        
        # List directories first, then files
        local find_args=("$current_dir" "-maxdepth" "1" "-print0")
        if [ "$show_hidden" = false ]; then
            find_args+=("!" "-name" ".*")
        fi
        
        local sorted_items=()
        while IFS= read -r -d '' item; do
            if [ "$item" != "$current_dir" ]; then
                sorted_items+=("$item")
            fi
        done < <(find "${find_args[@]}" \( -type d -o -type f \) 2>/dev/null | sort -z)
        
        # Categorize and populate menu items
        for item in "${sorted_items[@]}"; do
            local basename_item=$(basename "$item")
            local prefix=$(get_file_prefix "$item")
            
            if [ -d "$item" ]; then
                local item_count=$(find "$item" -maxdepth 1 -type f 2>/dev/null | wc -l)
                items+=("$counter" "$prefix $basename_item/ ($item_count files)")
                paths+=("$item")
                ((counter++))
            elif [ -f "$item" ]; then
                if [ "$show_all_files" = true ] || is_vm_image "$item"; then
                    local size=$(stat -c%s "$item" 2>/dev/null || echo "0")
                    local size_formatted=$(format_size "$size")
                    local modified=$(stat -c%y "$item" 2>/dev/null | cut -d' ' -f1 || echo "?")
                    
                    items+=("$counter" "$prefix $basename_item ($size_formatted) [$modified]")
                    paths+=("$item")
                    ((counter++))
                fi
            fi
        done
        
        # Show status information and calculate menu height
        local status_info=""
        if [ "$show_hidden" = true ]; then
            status_info+="Hidden: ON  "
        fi
        if [ "$show_all_files" = true ]; then
            status_info+="All files: ON"
        else
            status_info+="VM images only: ON"
        fi
        
        local title_text="File Browser - $(basename "$current_dir")\n$status_info"
        local menu_height=$((${#items[@]} / 2))
        if [ $menu_height -gt 15 ]; then
            menu_height=15
        elif [ $menu_height -lt 8 ]; then
            menu_height=8
        fi
        
        local choice=$(whiptail --title "$title_text" --menu "Select file or navigate:" 25 90 $menu_height "${items[@]}" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            log "File selection cancelled"
            return 1
        fi
        
        # Map choice to path
        local selected_path=${paths[$choice - 1]}
        
        # Handle special choices
        case "$selected_path" in
            "options_menu")
                # ... (options menu logic, unchanged) ...
                local option_items=(
                    "1" "Toggle hidden files: $([ "$show_hidden" = true ] && echo "ON" || echo "OFF")"
                    "2" "Toggle file filter: $([ "$show_all_files" = true ] && echo "All files" || echo "VM images only")"
                    "3" "Refresh directory"
                    "4" "Show directory tree"
                    "5" "Back to browser"
                )
                
                local opt_choice=$(whiptail --title "Browser Options" --menu "Select option:" 15 60 5 "${option_items[@]}" 3>&1 1>&2 2>&3)
                
                case $opt_choice in
                    1) show_hidden=$([ "$show_hidden" = true ] && echo "false" || echo "true");;
                    2) show_all_files=$([ "$show_all_files" = true ] && echo "false" || echo "true");;
                    3) ;;
                    4)
                        if command -v tree >/dev/null 2>&1; then
                            local tree_output=$(tree -L 2 "$current_dir" 2>/dev/null | head -30)
                            whiptail --title "Directory Tree" --msgbox "$tree_output" 20 80
                        else
                            local simple_tree=$(find "$current_dir" -maxdepth 2 -type d 2>/dev/null | head -20 | sed "s|$current_dir|.|")
                            whiptail --title "Directory Structure" --msgbox "$simple_tree" 20 60
                        fi
                        ;;
                    *) ;;
                esac
                continue
                ;;
            "manual_entry")
                # ... (manual entry logic, unchanged) ...
                local manual_file=$(whiptail --title "Enter Path" --inputbox "Enter the full path to the file or directory:" 10 80 "$current_dir" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$manual_file" ]; then
                    if [ -f "$manual_file" ]; then
                        log "Manually selected file: $manual_file"
                        echo "$manual_file"
                        return 0
                    elif [ -d "$manual_file" ]; then
                        current_dir="$manual_file"
                    else
                        whiptail --msgbox "Path does not exist: $manual_file" 8 60
                    fi
                fi
                continue
                ;;
            "quick_locations")
                # ... (quick locations logic, unchanged) ...
                local quick_dirs=(
                    "1" "/var/lib/libvirt/images (Libvirt VMs)"
                    "2" "/home (User directories)"
                    "3" "$HOME (Your home)"
                    "4" "/tmp (Temporary files)"
                    "5" "/mnt (Mount points)"
                    "6" "/media (Removable media)"
                    "7" "/ (Root directory)"
                    "8" "$(dirname "$current_dir") (Parent of current)"
                    "9" "Back to browser"
                )
                local quick_choice=$(whiptail --title "Quick Locations" --menu "Go to:" 18 70 9 "${quick_dirs[@]}" 3>&1 1>&2 2>&3)
                case $quick_choice in
                    1) current_dir="/var/lib/libvirt/images" ;;
                    2) current_dir="/home" ;;
                    3) current_dir="$HOME" ;;
                    4) current_dir="/tmp" ;;
                    5) current_dir="/mnt" ;;
                    6) current_dir="/media" ;;
                    7) current_dir="/" ;;
                    8) current_dir="$(dirname "$current_dir")" ;;
                    *) continue ;;
                esac
                if [ ! -d "$current_dir" ]; then
                    whiptail --msgbox "Directory does not exist: $current_dir\nStaying in current location." 8 70
                    current_dir=$(pwd)
                fi
                continue
                ;;
            "separator"|"current_dir_info")
                continue # Ignore these
                ;;
            ".." )
                current_dir=$(dirname "$current_dir")
                continue
                ;;
            *)
                # Handle file or directory selection
                if [ -d "$selected_path" ]; then
                    current_dir="$selected_path"
                    continue
                elif [ -f "$selected_path" ]; then
                    if [ "$show_all_files" = true ] && ! is_vm_image "$selected_path"; then
                        if ! whiptail --title "Confirm Selection" --yesno "Selected file doesn't appear to be a VM image:\n\n$(basename "$selected_path")\n\nDo you want to proceed anyway?" 12 70; then
                            continue
                        fi
                    fi
                    
                    log "Selected file: $selected_path"
                    echo "$selected_path"
                    return 0
                fi
                ;;
        esac
    done
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