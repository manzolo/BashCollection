create_snapshot() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    
    IFS='|' read -r id name image kernel memory ssh_port vnc_port audio_enabled audio_backend status created <<< "$instance_data"
    
    local snapshot_name="${name}-snapshot-$(date +%Y%m%d-%H%M%S)"
    local snapshot_file="${SNAPSHOTS_DIR}/${snapshot_name}.img"
    
    dialog --infobox "Creating snapshot...\nThis may take a moment." 5 40
    
    cp "$image" "$snapshot_file"
    
    if [ $? -eq 0 ]; then
        dialog --msgbox "Snapshot created:\n$snapshot_name" 8 50
    else
        dialog --msgbox "Failed to create snapshot!" 8 40
    fi
}