# ==============================================================================
# WORKSPACE MANAGEMENT
# ==============================================================================

init_workspace() {
    local dirs=("$WORK_DIR" "$IMAGES_DIR" "$KERNELS_DIR" "$DTBS_DIR" "$SNAPSHOTS_DIR" 
                "$CONFIGS_DIR" "$LOGS_DIR" "$TEMP_DIR" "$CACHE_DIR" "$MOUNT_DIR")
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" || {
            log ERROR "Failed to create directory: $dir"
            return 1
        }
    done
    
    if [ ! -f "$INSTANCES_DB" ]; then
        cat > "$INSTANCES_DB" <<EOF
# Instance Database
# Format: ID|Name|Image|Kernel|Memory|SSH_Port|VNC_Port|Audio_Enabled|Audio_Backend|Status|Created
EOF
    fi
    
    return 0
}

clean_workspace() {
    if dialog --yesno "This will remove ALL data including:\n- Images\n- Instances\n- Cache\n- Logs\n\nAre you sure?" 12 50; then
        echo "Cleaning workspace..."
        
        pkill -f qemu-system-arm 2>/dev/null || true
        
        rm -rf "$WORK_DIR"
        
        dialog --msgbox "Workspace cleaned!\nExiting..." 8 40
        exit 0
    fi
}