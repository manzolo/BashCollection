handle_luks_open() {
    local luks_parts="$1"
    IFS=',' read -ra parts <<< "$luks_parts"
    local idx=0
    
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        local name="luks$(date +%s)_$idx"
        log "Opening LUKS partition $part as /dev/mapper/$name"
        if run_with_privileges cryptsetup luksOpen "$part" "$name"; then
            LUKS_MAPPINGS+=("$name")
            OPEN_LUKS_PARTS+=("/dev/mapper/$name")
        else
            warning "Failed to open LUKS partition: $part"
        fi
        idx=$((idx+1))
    done
}

handle_lvm_activate() {
    log "Scanning for LVM physical volumes"
    sudo pvscan --cache >/dev/null 2>&1 || true
    
    local vgs
    vgs=$(sudo vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' || true)
    
    if [[ -n "$vgs" ]]; then
        while read -r vg; do
            [[ -z "$vg" ]] && continue
            log "Activating VG: $vg"
            if sudo vgchange -ay "$vg"; then
                ACTIVATED_VGS+=("$vg")
            fi
        done <<< "$vgs"
    fi
}