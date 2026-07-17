get_directory_content() {
    local dir="$1"
    local items=()
    
    [[ "$dir" != "/" ]] && items+=(".." "[Parent Directory]")
    
    local ls_opts="-1"
    $SHOW_HIDDEN && ls_opts="${ls_opts}a"
    
    while IFS= read -r item; do
        [[ "$item" = "." || "$item" = ".." ]] && continue
        local full_path="$dir/$item"
        if [[ -d "$full_path" ]]; then
            local count=$(ls -1 "$full_path" 2>/dev/null | wc -l)
            items+=("$item/" "📁 Dir ($count items)")
        elif [[ -f "$full_path" ]]; then
            local size=$(du -h "$full_path" 2>/dev/null | cut -f1)
            local icon="📄"
            case "${item##*.}" in
                txt|md|log) icon="📝" ;;
                pdf) icon="📕" ;;
                jpg|jpeg|png|gif|bmp) icon="🖼️" ;;
                mp3|wav|ogg|flac) icon="🎵" ;;
                mp4|avi|mkv|mov) icon="🎬" ;;
                zip|tar|gz|7z|rar) icon="📦" ;;
                sh|bash) icon="⚙️" ;;
                py) icon="🐍" ;;
                js|ts) icon="📜" ;;
                html|htm) icon="🌐" ;;
                img|vhd|vhdx|qcow2|vmdk|raw|vpc) icon="📼" ;;
                iso) icon="💿" ;;
            esac
            items+=("$item" "$icon File ($size)")
        elif [[ -L "$full_path" ]]; then
            local target=$(readlink "$full_path")
            items+=("$item@" "🔗 Link → $target")
        else
            items+=("$item" "❓ Special")
        fi
    done < <(ls $ls_opts "$dir" 2>/dev/null)
    
    printf '%s\n' "${items[@]}"
}

show_file_browser() {
    local current="$1"
    local select_type="${2:-file}"
    
    current=$(realpath "$current" 2>/dev/null || echo "$current")
    
    local content=$(get_directory_content "$current")
    [[ -z "$content" ]] && { 
        dialog --title "Error" --msgbox "Directory empty or not accessible: $current" 8 60
        return 2
    }

    local menu_items=()
    while IFS= read -r line; do 
        [[ -n "$line" ]] && menu_items+=("$line")
    done <<< "$content"

    local height=20
    local width=70
    local menu_height=12
    local display_path="$current"
    [ ${#display_path} -gt 50 ] && display_path="...${display_path: -47}"

    local instruction_msg=""
    if [ "$select_type" = "dir" ]; then
        instruction_msg="Select a directory or navigate with folders"
        [ "$current" != "/" ] && menu_items+=("." "📍 [Select this directory]")
    else
        instruction_msg="Select a file or navigate directories"
    fi

    local selected
    selected=$(dialog --title "📂 File Browser" \
        --menu "$instruction_msg\n\n📍 $display_path" \
        $height $width $menu_height \
        "${menu_items[@]}" 2>&1 >/dev/tty)
    
    local exit_status=$?

    if [ $exit_status -eq 0 ] && [ -n "$selected" ]; then
        local clean_name="${selected%/}"
        clean_name="${clean_name%@}"
        
        if [ "$selected" = ".." ]; then
            show_file_browser "$(dirname "$current")" "$select_type"
            return $?
        elif [ "$selected" = "." ]; then
            SELECTED_FILE="$current"
            return 0
        elif [[ "$selected" =~ /$ ]]; then
            show_file_browser "$current/$clean_name" "$select_type"
            return $?
        else
            if [ "$select_type" = "dir" ]; then
                dialog --title "Warning" --msgbox "Please select a directory, not a file!" 8 50
                show_file_browser "$current" "$select_type"
                return $?
            else
                SELECTED_FILE="$current/$clean_name"
                return 0
            fi
        fi
    else
        return 1
    fi
}

select_file() {
    local title="$1"
    local start_dir="${2:-$(pwd)}"
    
    SELECTED_FILE=""
    echo -e "${YELLOW}$title${NC}" >&2
    
    show_file_browser "$start_dir" "file"
    
    if [ $? -eq 0 ] && [ -n "$SELECTED_FILE" ]; then
        echo "$SELECTED_FILE"
        return 0
    fi
    return 1
}

select_directory() {
    local title="$1"
    local start_dir="${2:-$(pwd)}"
    
    SELECTED_FILE=""
    echo -e "${YELLOW}$title${NC}" >&2
    
    show_file_browser "$start_dir" "dir"
    
    if [ $? -eq 0 ] && [ -n "$SELECTED_FILE" ]; then
        echo "$SELECTED_FILE"
        return 0
    fi
    return 1
}