#!/bin/bash

# Function to select a file or directory
select_file() {
    local current_dir

    if [ -f "$LAST_DIR_FILE" ]; then
        current_dir=$(cat "$LAST_DIR_FILE")
        [ -d "$current_dir" ] || current_dir=$(pwd)
    else
        current_dir=$(pwd)
    fi

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

        echo "$current_dir" > "$LAST_DIR_FILE"

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

    echo "$current_dir" > "$LAST_DIR_FILE"
    return 1
}