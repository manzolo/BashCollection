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

# Function to select a file using a file browser
select_file() {
    local current_dir=$(pwd)
    
    while true; do
        local items=()
        local counter=1
        
        if [ "$current_dir" != "/" ]; then
            items+=("$counter" "[..] Parent directory")
            ((counter++))
        fi
        
        while IFS= read -r -d '' item; do
            if [ -d "$item" ]; then
                items+=("$counter" "[DIR] $(basename "$item")/")
            elif [ -f "$item" ]; then
                local basename_item=$(basename "$item")
                local size=$(du -h "$item" 2>/dev/null | cut -f1)
                if [[ "$basename_item" =~ \.(img|raw|qcow2|vmdk|vdi|iso|vhd)$ ]]; then
                    items+=("$counter" "[IMG] $basename_item ($size)")
                else
                    items+=("$counter" "[FILE] $basename_item ($size)")
                fi
            fi
            ((counter++))
        done < <(find "$current_dir" -maxdepth 1 \( -type d -o -type f \) ! -name ".*" -print0 2>/dev/null | sort -z)
        
        items+=("$counter" "[MANUAL] Enter path manually")
        local manual_option=$counter
        ((counter++))
        items+=("$counter" "[QUICK] Common directories")
        local quick_option=$counter
        
        choice=$(whiptail --title "File Browser - $current_dir" --menu "Select a file or navigate:" 20 80 12 "${items[@]}" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            log "File selection cancelled"
            echo "Selection cancelled."
            return 1
        fi
        
        if [ "$choice" -eq "$manual_option" ]; then
            manual_file=$(whiptail --title "Enter Path" --inputbox "Enter the full path to the file:" 10 70 3>&1 1>&2 2>&3)
            if [ $? -eq 0 ] && [ -n "$manual_file" ]; then
                log "Manually selected file: $manual_file"
                echo "$manual_file"
                return
            fi
            continue
        elif [ "$choice" -eq "$quick_option" ]; then
            quick_dirs=(
                "1" "/var/lib/libvirt/images"
                "2" "/home"
                "3" "$HOME"
                "4" "/tmp"
                "5" "/mnt"
                "6" "/media"
                "7" "Back to browser"
            )
            quick_choice=$(whiptail --title "Common Directories" --menu "Go to:" 15 60 7 "${quick_dirs[@]}" 3>&1 1>&2 2>&3)
            case $quick_choice in
                1) current_dir="/var/lib/libvirt/images" ;;
                2) current_dir="/home" ;;
                3) current_dir="$HOME" ;;
                4) current_dir="/tmp" ;;
                5) current_dir="/mnt" ;;
                6) current_dir="/media" ;;
                *) continue ;;
            esac
            if [ ! -d "$current_dir" ]; then
                whiptail --msgbox "The directory $current_dir does not exist." 8 50
                current_dir=$(pwd)
            fi
            continue
        fi
        
        local current_counter=1
        if [ "$current_dir" != "/" ] && [ "$choice" -eq "$current_counter" ]; then
            current_dir=$(dirname "$current_dir")
            continue
        elif [ "$current_dir" != "/" ]; then
            ((current_counter++))
        fi
        
        while IFS= read -r -d '' item; do
            if [ "$choice" -eq "$current_counter" ]; then
                if [ -d "$item" ]; then
                    current_dir="$item"
                    break
                elif [ -f "$item" ]; then
                    log "Selected file: $item"
                    echo "$item"
                    return
                fi
            fi
            ((current_counter++))
        done < <(find "$current_dir" -maxdepth 1 \( -type d -o -type f \) ! -name ".*" -print0 2>/dev/null | sort -z)
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