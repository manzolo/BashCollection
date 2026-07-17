create_sparse_image() {
    local file="$1"
    local size="$2"
    
    log "Creating sparse image of $(echo "scale=2; $size / 1073741824" | bc) GB..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would create sparse image: dd if=/dev/zero of='$file' bs=1 count=0 seek='$size'"
        return 0
    fi
    
    run_log dd if=/dev/zero of="$file" bs=1 count=0 seek="$size"
    
    return $?
}