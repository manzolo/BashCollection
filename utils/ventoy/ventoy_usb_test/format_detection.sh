# Enhanced image format detection and management for VHD/VPC and other virtual disk formats

# Advanced format detection using file signatures and qemu-img
# Simple and direct format detection with VHD priority
detect_image_format() {
    local file_path="$1"
    local detected_format=""
    
    # Return raw for block devices
    if [[ -b "$file_path" ]]; then
        echo "raw"
        return 0
    fi
    
    # Check if file exists and is readable
    if [[ ! -f "$file_path" ]] || [[ ! -r "$file_path" ]]; then
        echo "unknown"
        return 1
    fi
    
    # Special handling for VHD files - test with -f vpc first
    if [[ "${file_path##*.}" =~ ^(vhd|VHD|vpc|VPC)$ ]]; then
        if command -v qemu-img >/dev/null; then
            local vpc_test
            vpc_test=$(qemu-img info -f vpc "$file_path" 2>&1 || true)
            # If no error, it's a valid VPC/VHD file
            if [[ -n "$vpc_test" ]] && ! echo "$vpc_test" | grep -qi "could not open\|invalid\|error\|failed\|unknown"; then
                echo "vpc"
                return 0
            fi
        fi
    fi
    
    # Standard qemu-img detection for other formats
    if command -v qemu-img >/dev/null; then
        local qemu_output
        qemu_output=$(qemu-img info "$file_path" 2>/dev/null || true)
        
        if [[ -n "$qemu_output" ]]; then
            detected_format=$(echo "$qemu_output" | grep "file format:" | awk '{print $3}' | tr -d '[:space:]')
            if [[ -n "$detected_format" ]]; then
                echo "$detected_format"
                return 0
            fi
        fi
    fi
    
    # Fallback to file extension
    case "${file_path##*.}" in
        vhd|VHD|vpc|VPC) detected_format="vpc" ;;
        vmdk|VMDK) detected_format="vmdk" ;;
        qcow2|QCOW2) detected_format="qcow2" ;;
        qcow|QCOW) detected_format="qcow" ;;
        vdi|VDI) detected_format="vdi" ;;
        img|IMG) detected_format="raw" ;;
        iso|ISO) detected_format="raw" ;;
        *) detected_format="raw" ;;
    esac
    
    echo "$detected_format"
    return 0
}

# Get detailed image information
get_image_info() {
    local file_path="$1"
    local info_text=""
    
    if [[ -b "$file_path" ]]; then
        # Block device information
        local device_size device_model
        device_size=$(lsblk -d -o SIZE "$file_path" 2>/dev/null | tail -1 || echo "Unknown")
        device_model=$(lsblk -d -o MODEL "$file_path" 2>/dev/null | tail -1 || echo "Unknown")
        
        info_text="Type: Block Device\n"
        info_text+="Size: $device_size\n"
        info_text+="Model: $device_model\n"
        info_text+="Format: raw (physical device)"
        
    elif [[ -f "$file_path" ]]; then
        # File information
        local file_size file_format
        file_size=$(du -h "$file_path" 2>/dev/null | cut -f1 || echo "Unknown")
        file_format=$(detect_image_format "$file_path")
        
        info_text="Type: Virtual Disk Image\n"
        info_text+="File Size: $file_size\n"
        info_text+="Detected Format: $file_format\n"
        
        # Try to get detailed info with qemu-img
        if command -v qemu-img >/dev/null; then
            local detailed_info
            detailed_info=$(qemu-img info "$file_path" 2>/dev/null || true)
            
            if [[ -n "$detailed_info" ]]; then
                local virtual_size backing_file
                virtual_size=$(echo "$detailed_info" | grep "virtual size:" | cut -d'(' -f2 | cut -d')' -f1 || true)
                backing_file=$(echo "$detailed_info" | grep "backing file:" | cut -d':' -f2- | xargs || true)
                
                [[ -n "$virtual_size" ]] && info_text+="\nVirtual Size: $virtual_size"
                [[ -n "$backing_file" ]] && info_text+="\nBacking File: $backing_file"
                
                # Check for encryption
                if echo "$detailed_info" | grep -q "encrypted: yes"; then
                    info_text+="\nEncryption: Yes (may need password)"
                fi
            fi
        fi
        
        # Additional file type detection
        local file_type
        file_type=$(file "$file_path" 2>/dev/null | cut -d':' -f2- | xargs || echo "Unknown")
        info_text+="\nFile Type: $file_type"
    else
        info_text="Error: File does not exist or is not accessible"
    fi
    
    echo -e "$info_text"
}

# Enhanced format validation and conversion suggestions
validate_and_suggest_format() {
    local file_path="$1"
    local current_format="$2"
    local suggested_format=""
    local validation_result="valid"
    local suggestions=""
    
    # Skip validation for block devices
    if [[ -b "$file_path" ]]; then
        echo "raw|valid|Block device - no conversion needed"
        return 0
    fi
    
    # Detect actual format with detailed logging
    local actual_format debug_info
    actual_format=$(detect_image_format "$file_path")
    
    # Get debug information
    debug_info=$(get_format_debug_info "$file_path" "$actual_format")
    
    # Compare current vs actual format
    if [[ "$current_format" != "$actual_format" ]]; then
        validation_result="mismatch"
        suggested_format="$actual_format"
        suggestions="Format mismatch detected. Actual: $actual_format, Current: $current_format"
        suggestions+="\n\nDebug Info:\n$debug_info"
    else
        suggested_format="$current_format"
    fi
    
    # Check for potential issues with both formats
    if command -v qemu-img >/dev/null; then
        # Test with detected format
        local qemu_check
        qemu_check=$(qemu-img check -f "$actual_format" "$file_path" 2>&1 || true)
        
        if echo "$qemu_check" | grep -qi "error\|corrupt"; then
            validation_result="error"
            suggestions+="\nImage appears corrupted or has errors (format: $actual_format)"
        elif echo "$qemu_check" | grep -qi "leaked"; then
            validation_result="warning"  
            suggestions+="\nImage has leaked clusters (consider repair)"
        fi
        
        # If original format was different, test that too
        if [[ "$current_format" != "$actual_format" ]] && [[ "$current_format" != "raw" ]]; then
            local original_check
            original_check=$(qemu-img check -f "$current_format" "$file_path" 2>&1 || true)
            if echo "$original_check" | grep -qi "could not open\|invalid"; then
                suggestions+="\nOriginal format ($current_format) is invalid for this file"
            fi
        fi
    fi
    
    # Performance suggestions based on format
    case "$actual_format" in
        "vpc")
            suggestions+="\nVPC/VHD format detected. Good compatibility with Hyper-V and QEMU"
            suggestions+="\nFor best performance, consider: -drive cache=writethrough"
            ;;
        "vmdk")
            suggestions+="\nVMDK format detected. Consider using 'vmdk=on' for better VMware compatibility"
            ;;
        "qcow2")
            suggestions+="\nQCOW2 format detected. Consider using cache=writeback for better performance"
            ;;
        "vdi")
            suggestions+="\nVDI format detected. VirtualBox native format"
            ;;
    esac
    
    echo "$suggested_format|$validation_result|$suggestions"
}

get_format_debug_info() {
    local file_path="$1"  
    local detected_format="$2"
    local debug_info=""
    
    # Basic file info
    local file_size file_ext
    file_size=$(stat -c%s "$file_path" 2>/dev/null || echo "0")
    file_ext="${file_path##*.}"
    
    debug_info="File: $(basename "$file_path")\n"
    debug_info+="Extension: .$file_ext\n"
    debug_info+="Size: $(numfmt --to=iec "$file_size" 2>/dev/null || echo "$file_size bytes")\n"
    debug_info+="Detected Format: $detected_format\n\n"
    
    # qemu-img info comparison
    if command -v qemu-img >/dev/null; then
        debug_info+="QEMU Detection Results:\n"
        
        # Without format specification
        local auto_detect
        auto_detect=$(qemu-img info "$file_path" 2>&1 | grep "file format:" | awk '{print $3}' || echo "failed")
        debug_info+="- Auto-detect: $auto_detect\n"
        
        # With format specification (if different)
        if [[ "$detected_format" != "raw" ]] && [[ "$detected_format" != "$auto_detect" ]]; then
            local forced_detect
            forced_detect=$(qemu-img info -f "$detected_format" "$file_path" 2>&1 | head -3 || echo "failed")
            if ! echo "$forced_detect" | grep -qi "error\|could not"; then
                debug_info+="- With -f $detected_format: Success\n"
            else
                debug_info+="- With -f $detected_format: Failed\n"
            fi
        fi
    fi
    
    # VHD-specific debug for VPC format
    if [[ "$detected_format" == "vpc" ]] || [[ "$file_ext" =~ ^(vhd|VHD)$ ]]; then
        debug_info+="\nVHD/VPC Analysis:\n"
        
        # Check for conectix signature
        if tail -c 512 "$file_path" 2>/dev/null | strings | grep -q "conectix"; then
            debug_info+="- Footer signature: Found (standard VHD)\n"
        elif head -c 512 "$file_path" 2>/dev/null | strings | grep -q "conectix"; then
            debug_info+="- Header signature: Found (unusual VHD)\n"  
        else
            debug_info+="- Signature: Not found in standard locations\n"
        fi
        
        # Check alignment
        if [[ $((file_size % 512)) -eq 0 ]]; then
            debug_info+="- Size alignment: 512-byte aligned ✓\n"
        else
            debug_info+="- Size alignment: Not 512-byte aligned\n"
        fi
    fi
    
    echo -e "$debug_info"
}

# Show detailed image information dialog
show_image_details_dialog() {
    local file_path="$1"
    local info_text
    info_text=$(get_image_info "$file_path")
    
    # Get validation results
    local validation_info
    validation_info=$(validate_and_suggest_format "$file_path" "$FORMAT")
    
    local suggested_format validation_status suggestions
    IFS='|' read -r suggested_format validation_status suggestions <<< "$validation_info"
    
    # Update format if suggestion is different
    if [[ "$suggested_format" != "$FORMAT" ]] && [[ "$validation_status" == "mismatch" ]]; then
        FORMAT="$suggested_format"
    fi
    
    # Prepare dialog content
    local dialog_content="SELECTED IMAGE INFORMATION\n\n"
    dialog_content+="$info_text\n"
    
    if [[ -n "$suggestions" ]]; then
        dialog_content+="\n--- ANALYSIS ---\n"
        dialog_content+="$suggestions"
    fi
    
    dialog_content+="\n\nDetected Format: $FORMAT"
    
    # Color-code validation status for display
    case "$validation_status" in
        "valid") dialog_content+="\nStatus: Valid ✓" ;;
        "warning") dialog_content+="\nStatus: Warning ⚠" ;;
        "mismatch") dialog_content+="\nStatus: Format corrected ⚠" ;;
        "error") dialog_content+="\nStatus: Error detected ✗" ;;
    esac
    
    whiptail --title "Image Details" --scrolltext \
        --msgbox "$dialog_content" 20 80
}

# Enhanced validation for selected disk
validate_selected_disk_enhanced() {
    local disk_path="$1"
    
    if [[ -b "$disk_path" ]]; then
        # Block device validation (existing logic)
        local info
        info=$(lsblk "$disk_path" -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null || echo "Information not available")
        
        # Safety check for mounted critical filesystems
        local mounted_critical=false
        while read -r mount; do
            [[ -z "$mount" ]] && continue
            if [[ "$mount" =~ ^(/|/boot|/home|/usr|/var|/opt|/root)$ ]]; then
                mounted_critical=true
                break
            fi
        done < <(lsblk -no MOUNTPOINT "$disk_path" 2>/dev/null | grep -v "^$")
        
        if [[ "$mounted_critical" == true ]]; then
            whiptail --title "SAFETY WARNING" --msgbox \
                "CRITICAL DEVICE DETECTED!\n\nThe device $disk_path contains mounted system filesystems.\n\nFor safety, its use is blocked.\n\nSelect an external USB device." \
                15 70
            DISK=""
            return 1
        fi
        
        whiptail --title "Selected Device" --msgbox \
            "Device: $disk_path\n\nInformation:\n$info\n\nSafety checks: OK" \
            18 80
        return 0
        
    elif [[ -f "$disk_path" ]]; then
        # Enhanced file validation
        local validation_info
        validation_info=$(validate_and_suggest_format "$disk_path" "$FORMAT")
        
        local suggested_format validation_status suggestions
        IFS='|' read -r suggested_format validation_status suggestions <<< "$validation_info"
        
        case "$validation_status" in
            "error")
                whiptail --title "Image Error" --msgbox \
                    "The image file has errors:\n\n$suggestions\n\nProceeding may cause issues." \
                    15 70
                # Ask if user wants to continue anyway
                if ! whiptail --title "Continue?" --yesno \
                    "Continue with potentially corrupted image?" 8 50; then
                    DISK=""
                    return 1
                fi
                ;;
            "warning")
                whiptail --title "Image Warning" --msgbox \
                    "Image validation warning:\n\n$suggestions\n\nImage should work but may have minor issues." \
                    15 70
                ;;
        esac
        
        return 0
    else
        whiptail --title "Path Error" --msgbox \
            "The specified path does not exist or is not accessible:\n\n$disk_path" \
            12 70
        DISK=""
        return 1
    fi
}

# Enhanced file browser with format preview
browse_image_files_enhanced() {
    local start_dir="$PWD"
    local selected_file=""
    local current_dir="$start_dir"
    
    if ! command -v dialog &>/dev/null; then
        whiptail --title "Error" --msgbox "The 'dialog' command is not installed." 10 60
        return 1
    fi
    
    while true; do
        local items=()
        
        if [[ "$current_dir" != "/" ]]; then
            items+=(".." "📁 Parent directory")
        fi
        
        # Find directories
        while IFS= read -r dir; do
            if [[ -n "$dir" ]]; then
                items+=("$(basename "$dir")" "📁 Directory")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type d ! -path "$current_dir" -print 2>/dev/null | sort)
        
        # Find image files with format detection
        while IFS= read -r file; do
            if [[ -n "$file" ]]; then
                local basename_file format_info
                basename_file="$(basename "$file")"
                
                # Quick format detection for display
                case "${file##*.}" in
                    vhd|VHD|vpc|VPC) format_info="💾 VHD/VPC image" ;;
                    vmdk|VMDK) format_info="💾 VMDK image" ;;
                    qcow2|QCOW2) format_info="💾 QCOW2 image" ;;
                    vdi|VDI) format_info="💾 VDI image" ;;
                    iso|ISO) format_info="💿 ISO image" ;;
                    img|IMG) format_info="💾 Disk image" ;;
                    *) format_info="💾 Image file" ;;
                esac
                
                # Add file size
                local file_size
                file_size=$(du -h "$file" 2>/dev/null | cut -f1 || echo "?")
                format_info+=" (${file_size})"
                
                items+=("$basename_file" "$format_info")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type f \( \
            -iname "*.iso" -o -iname "*.img" -o -iname "*.qcow2" -o \
            -iname "*.vdi" -o -iname "*.vmdk" -o -iname "*.vhd" -o \
            -iname "*.vpc" -o -iname "*.raw" \) -print 2>/dev/null | sort)
        
        selected_file=$(dialog --title "Browse Images ($current_dir)" \
            --menu "Select a file or navigate:" \
            25 90 15 "${items[@]}" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            echo ""
            return 1
        fi
        
        if [[ "$selected_file" == ".." ]]; then
            current_dir=$(dirname "$current_dir")
        elif [[ -d "$current_dir/$selected_file" ]]; then
            current_dir="$current_dir/$selected_file"
        elif [[ -f "$current_dir/$selected_file" ]]; then
            selected_file="$current_dir/$selected_file"
            break
        fi
    done
    
    if [[ -f "$selected_file" && -r "$selected_file" ]]; then
        echo "$selected_file"
        return 0
    else
        echo ""
        return 1
    fi
}