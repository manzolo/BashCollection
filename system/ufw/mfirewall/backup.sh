# mfirewall module: configuration backup and restore
# Sourced by mfirewall.sh — do not execute directly.
# =================== BACKUP AND RESTORE ===================

backup_configuration() {
    local backup_file
    backup_file="$BACKUP_DIR/ufw_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    show_progress "Creating UFW configuration backup..." 3
    
    if sudo tar -czf "$backup_file" /etc/ufw/ /lib/ufw/ 2>/dev/null; then
        show_message "Backup Created" "Backup created successfully:\n$backup_file" "success"
        log_action "BACKUP" "Created backup: $backup_file"
    else
        show_message "Backup Failed" "Failed to create backup" "error"
    fi
}

restore_configuration() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        show_message "No Backups" "No backups found in $BACKUP_DIR" "error"
        return
    fi
    
    # Build menu options
    local menu_options=()
    local i=1
    
    while IFS= read -r -d '' backup; do
        local filename
        filename=$(basename "$backup")
        menu_options+=("$i" "$filename")
        ((i++))
    done < <(find "$BACKUP_DIR" -name "*.tar.gz" -print0 | sort -z)
    
    if [ ${#menu_options[@]} -eq 0 ]; then
        show_message "No Backups" "No backup files found" "error"
        return
    fi
    
    local choice
    
    choice=$(whiptail --title "Restore Configuration" --menu "Select backup to restore:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT "${menu_options[@]}" 3>&1 1>&2 2>&3) || true
    if [ -n "$choice" ]; then
        local backup_file
        backup_file=$(find "$BACKUP_DIR" -name "*.tar.gz" | sort | sed -n "${choice}p")
        local filename
        filename=$(basename "$backup_file")
        if confirm_action "Restore from backup: $filename?\n\nThis will reset current UFW configuration!"; then
            show_progress "Restoring configuration..." 5
            sudo ufw --force reset >/dev/null 2>&1
            sudo tar -xzf "$backup_file" -C / 2>/dev/null
            sudo ufw reload >/dev/null 2>&1
            show_message "Restore Complete" "Configuration restored successfully from $filename" "success"
        fi
    fi
}

