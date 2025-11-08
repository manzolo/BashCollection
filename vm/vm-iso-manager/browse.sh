select_image_file() {
    local current_dir="$PWD"
    local selected=""

    while true; do
        local menu_items=()
        local iso_count=0
        local dir_count=0

        # Navigation options
        [[ "$current_dir" != "/" ]] && menu_items+=(".." "⬆️  Go to parent directory")
        menu_items+=("~" "🏠 Go to home directory")
        menu_items+=("/" "💾 Go to root directory")

        # Add separator
        menu_items+=("" "────────────────────────────────────")

        # Collect directories (sorted alphabetically)
        local dirs=()
        while IFS= read -r -d '' item; do
            local dirname=$(basename "$item")
            [[ "$dirname" == "." || "$dirname" == ".." ]] && continue
            dirs+=("$item")
            ((dir_count++))
        done < <(find "$current_dir" -maxdepth 1 -type d -not -name ".*" -print0 2>/dev/null | sort -z)

        # Add directories to menu
        for dir in "${dirs[@]}"; do
            local dirname=$(basename "$dir")
            local item_count=$(find "$dir" -maxdepth 1 -type f -iname "*.iso" 2>/dev/null | wc -l)
            if [[ $item_count -gt 0 ]]; then
                menu_items+=("📁 $dirname" "($item_count ISO files)")
            else
                menu_items+=("📁 $dirname" "(Directory)")
            fi
        done

        # Collect ISO files (sorted alphabetically) with size
        local isos=()
        while IFS= read -r -d '' item; do
            isos+=("$item")
            ((iso_count++))
        done < <(find "$current_dir" -maxdepth 1 -type f -iname "*.iso" -print0 2>/dev/null | sort -z)

        # Add ISOs to menu with size and date
        for iso in "${isos[@]}"; do
            local isoname=$(basename "$iso")
            local size=$(du -h "$iso" 2>/dev/null | cut -f1)
            local date=$(stat -c "%y" "$iso" 2>/dev/null | cut -d' ' -f1)
            menu_items+=("💿 $isoname" "Size: $size | Date: $date")
        done

        # Check if directory is empty
        if [[ $iso_count -eq 0 && $dir_count -eq 0 ]]; then
            menu_items+=("" "")
            menu_items+=("(empty)" "No ISO files or directories found")
        fi

        # Build title with stats
        local title="📂 ISO Browser"
        local subtitle="Path: $current_dir\nISO files: $iso_count | Directories: $dir_count"

        # Show menu
        selected=$(whiptail --title "$title" \
            --menu "$subtitle\n\nSelect an ISO file or navigate:" \
            24 90 16 \
            "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1

        # Handle selection
        case "$selected" in
            "")
                # Empty selection or separator, ignore
                continue
                ;;
            "(empty)")
                # Empty directory, ignore
                continue
                ;;
            "..")
                # Go to parent directory
                current_dir=$(dirname "$current_dir")
                ;;
            "~")
                # Go to home directory
                current_dir="$HOME"
                ;;
            "/")
                # Go to root directory
                current_dir="/"
                ;;
            📁*)
                # Navigate into directory
                local raw_name=$(echo "$selected" | sed 's/^📁 //')
                current_dir="$current_dir/$raw_name"
                ;;
            💿*)
                # ISO file selected
                local raw_name=$(echo "$selected" | sed 's/^💿 //')
                local full_path="$current_dir/$raw_name"

                # Show ISO info and confirm selection
                local iso_size=$(du -h "$full_path" 2>/dev/null | cut -f1)
                local iso_date=$(stat -c "%y" "$full_path" 2>/dev/null | cut -d' ' -f1)
                local iso_type="Unknown"

                # Try to detect ISO type
                if file "$full_path" | grep -q "ISO 9660"; then
                    iso_type="ISO 9660"
                fi

                if whiptail --title "Confirm ISO Selection" \
                    --yesno "Do you want to select this ISO?\n\nFile: $raw_name\nSize: $iso_size\nDate: $iso_date\nType: $iso_type\n\nPath: $full_path" \
                    15 80; then
                    echo "$full_path"
                    return 0
                fi
                ;;
            *)
                # Unknown selection
                continue
                ;;
        esac
    done
}