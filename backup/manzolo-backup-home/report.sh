# manzolo-backup-home module: notifications, usage, final stats
# Sourced by manzolo-backup-home.sh — do not execute directly.
send_notification() {
    local subject="$1"
    local message="$2"
    
    if [ "${CONFIG[notifications]}" = "true" ]; then
        # Try to send desktop notification with better error handling
        if command -v notify-send &>/dev/null && [ -n "${DISPLAY:-}" ] && [ -n "${SUDO_USER:-}" ]; then
            # Check if dbus is available and working
            if command -v dbus-launch &>/dev/null; then
                sudo -u "$REAL_USER" DISPLAY="$DISPLAY" notify-send "$subject" "$message" 2>/dev/null || {
                    log "DEBUG" "Desktop notification failed (dbus issue) - continuing without notification"
                }
            else
                log "DEBUG" "dbus-launch not available - skipping desktop notification"
            fi
        else
            log "DEBUG" "Desktop notification not available (missing DISPLAY or notify-send)"
        fi
        
        # Send email if configured
        if [ -n "${CONFIG[email_on_error]}" ] && command -v mail &>/dev/null; then
            echo "$message" | mail -s "$subject" "${CONFIG[email_on_error]}" 2>/dev/null || {
                log "DEBUG" "Email notification failed"
            }
        fi
    fi
}

# Show usage information - fixed alignment
show_usage() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} ${ROCKET} ${WHITE}ENHANCED MULTI-DIRECTORY BACKUP SCRIPT v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}Usage:${NC} sudo $SCRIPT_NAME <destination> [options]"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}Arguments:${NC}"
    echo -e "${BLUE}║${NC}   destination      Target backup directory"
    echo -e "${BLUE}║${NC}   [username]       Override detected username"
    echo -e "${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}Options:${NC}"
    echo -e "${BLUE}║${NC}   -h, --help       Show this help message"
    echo -e "${BLUE}║${NC}   -n, --dry-run    Simulation mode without copying"
    echo -e "${BLUE}║${NC}   -v, --verbose    Detailed output with progress"
    echo -e "${BLUE}║${NC}   -q, --quiet      Minimal output"
    echo -e "${BLUE}║${NC}   -f, --force      Skip confirmation prompts"
    echo -e "${BLUE}║${NC}   --name NAME      Custom backup name"
    echo -e "${BLUE}║${NC}   --config         Create default config file"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}Examples:${NC}"
    echo -e "${BLUE}║${NC}   sudo $SCRIPT_NAME /media/backup"
    echo -e "${BLUE}║${NC}   sudo $SCRIPT_NAME /mnt/usb --verbose"
    echo -e "${BLUE}║${NC}   sudo $SCRIPT_NAME /backup --dry-run username"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    exit "${1:-1}"
}

# Display final statistics - fixed alignment
show_final_stats() {
    local start_time="$1"
    local end_time="$2"
    local total_duration=$((end_time - start_time))
    
    echo -e "\n${PURPLE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC} ${STATS} ${WHITE}BACKUP STATISTICS${NC}"
    echo -e "${PURPLE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    
    # Success/Failure counts
    local success_count=${#SUCCESS_BACKUPS[@]}
    local failed_count=${#FAILED_BACKUPS[@]}
    local total_count=$((success_count + failed_count))
    
    echo -e "${PURPLE}║${NC} ${SUCCESS} Successful backups: $success_count/$total_count"
    if [ $failed_count -gt 0 ]; then
        echo -e "${PURPLE}║${NC} ${ERROR} Failed backups: $failed_count"
        for failed in "${FAILED_BACKUPS[@]}"; do
            echo -e "${PURPLE}║${NC}   ${RED}- $failed${NC}"
        done
    fi
    
    echo -e "${PURPLE}║${NC} ${CLOCK} Total time: $(printf '%02d:%02d:%02d' $((total_duration/3600)) $((total_duration%3600/60)) $((total_duration%60)))"
    
    # Disk usage
    if [ -d "$DEST_DISK" ]; then
        local disk_usage
        disk_usage=$(du -sh "$DEST_DISK"/backup_* 2>/dev/null | awk '{total+=$1} END {print total "B"}' 2>/dev/null || echo "N/A")
        echo -e "${PURPLE}║${NC} ${DISK} Backup size: $disk_usage"
        
        local free_space
        free_space=$(df -h "$DEST_DISK" 2>/dev/null | tail -1 | awk '{print $4 " available of " $2}' || echo "N/A")
        echo -e "${PURPLE}║${NC} ${DISK} Free space: $free_space"
    fi
    
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 🚀 MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

