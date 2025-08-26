#!/bin/bash

# Enhanced file lock check with proper logging
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
    if [[ "$basename_file" =~ \.(img|raw|qcow2|vmdk|vdi|iso|vhd|vtoy|qed|vpc|parallels)$ ]]; then
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