# Function to browse image files (ISO, IMG, QCOW2, etc.) using dialog
browse_image_files() {
    local start_dir="$PWD"
    local selected_file=""
    local current_dir="$start_dir"
    
    # Check if 'dialog' command is available
    if ! command -v dialog &>/dev/null; then
        whiptail --title "Error" --msgbox "The 'dialog' command is not installed. Install it to use this feature." 10 60
        return 1
    fi
    
    # Navigation loop
    while true; do
        # Get files and directories in the current folder
        local items=()
        
        # Add '..' to go back
        if [[ "$current_dir" != "/" ]]; then
            items+=(".." "Parent directory")
        fi
        
        # Find directories
        while IFS= read -r dir; do
            if [[ -n "$dir" ]]; then
                local dir_name="$(basename "$dir")"
                items+=("$dir_name" "Directory")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type d ! -path "$current_dir" -print 2>/dev/null | sort)
        
        # Find image files
        while IFS= read -r file; do
            if [[ -n "$file" ]]; then
                items+=("$(basename "$file")" "Image file")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type f \( -iname "*.iso" -o -iname "*.img" -o -iname "*.qcow2" -o -iname "*.vdi" -o -iname "*.vmdk" -o -iname "*.raw" \) -print 2>/dev/null | sort)
        
        # Show menu with options
        selected_file=$(dialog --title "Browse Image Files ($current_dir)" \
            --menu "Select a file or navigate to a folder:" \
            25 78 15 "${items[@]}" 3>&1 1>&2 2>&3)
        
        # Check dialog exit code
        if [ $? -ne 0 ]; then
            # User pressed Cancel or Exit
            echo ""
            return 1
        fi
        
        # Handle selection
        if [[ "$selected_file" == ".." ]]; then
            # Go to parent directory
            current_dir=$(dirname "$current_dir")
        elif [[ -d "$current_dir/$selected_file" ]]; then
            # Enter selected directory
            current_dir="$current_dir/$selected_file"
        elif [[ -f "$current_dir/$selected_file" ]]; then
            # File selected - build full path
            selected_file="$current_dir/$selected_file"
            break # Exit loop
        else
            # Item not found - retry
            continue
        fi
    done
    
    # Normalize path if a file was selected
    if [[ -n "$selected_file" ]]; then
        selected_file=$(realpath "$selected_file" 2>/dev/null || echo "$selected_file")
    fi
    
    # Check if file exists and is readable
    if [[ -f "$selected_file" && -r "$selected_file" ]]; then
        echo "$selected_file"
        return 0
    else
        whiptail --title "File Not Found" --msgbox \
            "The selected file does not exist or is not readable:\n$selected_file" \
            10 70
        echo ""
        return 1
    fi
}