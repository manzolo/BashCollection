#!/bin/bash

# Function to get simplified file information
get_file_info() {
    local file=$1
    local info_text=""
    
    # Get basic file size on disk
    local file_size=$(sudo du -h "$file" 2>/dev/null | cut -f1 || echo "?")
    
    # Virtual image information using qemu-img
    local virtual_size="?"
    local format="?"
    
    if command -v qemu-img &> /dev/null; then
        local qemu_info=$(sudo qemu-img info --output=json "$file" 2>/dev/null)
        if [ -n "$qemu_info" ]; then
            virtual_size=$(echo "$qemu_info" | jq -r '.["virtual-size"]' 2>/dev/null | numfmt --to=iec-i --suffix=B 2>/dev/null || echo "?")
            format=$(echo "$qemu_info" | jq -r '.format' 2>/dev/null || echo "?")
        fi
    fi
    
    echo "$file_size" "$virtual_size" "$format"
}

# Function to show detailed file info in a separate dialog
# Function to show detailed file info in a separate dialog
show_detailed_info() {
    local file=$1
    local info_text="=== FILE INFORMATION ===\n"
    
    # Get basic file info
    local file_path=$(readlink -f "$file" 2>/dev/null || echo "?")
    local file_size=$(sudo du -h "$file" 2>/dev/null | cut -f1 || echo "?")
    local last_modified=$(sudo stat -c %y "$file" 2>/dev/null | cut -d'.' -f1 || echo "?")
    
    info_text+="\nFile: $(basename "$file")"
    info_text+="\nFull Path: $file_path"
    info_text+="\nSize on disk: $file_size"
    info_text+="\nLast Modified: $last_modified"
    
    # Get qemu-img info
    if command -v qemu-img &> /dev/null; then
        local qemu_info=$(sudo qemu-img info --output=json "$file" 2>/dev/null)
        if [ -n "$qemu_info" ]; then
            local virtual_size=$(echo "$qemu_info" | jq -r '.["virtual-size"]' 2>/dev/null | numfmt --to=iec-i --suffix=B 2>/dev/null || echo "?")
            local format=$(echo "$qemu_info" | jq -r '.format' 2>/dev/null || echo "?")
            local backing_file=$(echo "$qemu_info" | jq -r '.["backing-filename"]' 2>/dev/null || echo "None")
            local snapshots="No"
            
            if echo "$qemu_info" | jq -e '.snapshots | length > 0' >/dev/null 2>&1; then
                local snapshot_count=$(echo "$qemu_info" | jq -r '.snapshots | length')
                if [ "$snapshot_count" -eq 1 ]; then
                    snapshots="Yes (Name: $(echo "$qemu_info" | jq -r '.snapshots[0].name'))"
                else
                    snapshots="Yes ($snapshot_count snapshot(s))"
                fi
            fi
            
            info_text+="\n\n=== VIRTUAL IMAGE INFO ==="
            info_text+="\nVirtual Size: $virtual_size"
            info_text+="\nFormat: $format"
            info_text+="\nBacking File: $backing_file"
            info_text+="\nSnapshots: $snapshots"
            info_text+="\n\nFull qemu-img info:\n"
            info_text+=$(sudo qemu-img info "$file" 2>/dev/null)
        else
            info_text+="\n\nCould not get qemu-img info."
        fi
    else
        info_text+="\n\nqemu-img command not found."
    fi
    
    # Filesystem detection (heavy operation, only for detailed view)
    info_text+="\n\n=== FILESYSTEMS ==="
    if command -v blkid &> /dev/null; then
        local format_for_nbd=$(sudo qemu-img info --output=json "$file" | jq -r '.format')
        local nbd_dev=$(find_free_nbd)
        if [ -n "$nbd_dev" ] && connect_nbd "$file" "$format_for_nbd" >/dev/null 2>&1; then
            local filesystems_info=$(analyze_partitions "$nbd_dev")
            info_text+="\n$filesystems_info"
            safe_nbd_disconnect "$nbd_dev" >/dev/null 2>&1
        else
            info_text+="\nCould not mount file to analyze filesystems."
        fi
    else
        info_text+="\nblkid command not found."
    fi
    
    whiptail --title "Detailed File Information - $(basename "$file")" --msgbox "$info_text" 25 100
}

# Function to safely get a numeric size for resizing
get_size() {
    local size_input=$(whiptail --title "Resize Image" --inputbox "Enter new size (e.g., 20G, 50M):" 8 60 3>&1 1>&2 2>&3)
    local result=$?
    
    if [ $result -ne 0 ]; then
        return 1
    fi
    
    # Convert to bytes
    local size_bytes=$(numfmt --from=iec "$size_input" 2>/dev/null)
    if [ -z "$size_bytes" ]; then
        whiptail --msgbox "Invalid size format. Please use a format like 20G or 50M." 8 60
        return 1
    fi
    
    echo "$size_input"
}