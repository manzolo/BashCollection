select_image_file() {
    local current_dir="$PWD"
    local selected=""
    while true; do
        local menu_items=()
        [[ "$current_dir" != "/" ]] && menu_items+=(".." "Parent folder")
        while IFS= read -r -d '' item; do
            menu_items+=("💿 $(basename "$item")" "ISO file")
        done < <(find "$current_dir" -maxdepth 1 -type f -iname "*.iso" -print0 | sort -z)
        while IFS= read -r -d '' item; do
            [[ -d "$item" && "$item" != "$current_dir" && "$item" != "$current_dir/." ]] && menu_items+=("📁 $(basename "$item")" "Folder")
        done < <(find "$current_dir" -maxdepth 1 -type d -not -name ".*" -print0 2>/dev/null || true)
        [[ ${#menu_items[@]} -eq 0 ]] && error "No files or directories found in $current_dir"

        selected=$(whiptail --title "Select ISO file" --menu "Folder: $current_dir" 20 70 15 "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1
        local raw_name=$(echo "$selected" | sed 's/^[^ ]* //')
        if [[ "$selected" == ".." ]]; then
            current_dir=$(dirname "$current_dir")
        elif [[ "$selected" == 📁* ]]; then
            current_dir="$current_dir/$raw_name"
        elif [[ -f "$current_dir/$raw_name" ]]; then
            echo "$current_dir/$raw_name"
            return 0
        fi
    done
}