repair_filesystem() {
    local partition="$1"
    local fs_type="$2"
    
    log "  Checking and repairing filesystem on $partition ($fs_type)..."
    
    case "$fs_type" in
        ext2|ext3|ext4)
            log "    Running e2fsck..."
            if [ "$DRY_RUN" = true ]; then
                log "    🧪 DRY RUN - Would run: e2fsck -f -p $partition"
                return 0
            elif e2fsck -f -p "$partition" 2>/dev/null; then
                log "      ✓ Filesystem check passed"
                return 0
            else
                log "      ⚠ Filesystem had errors, attempting repair..."
                if e2fsck -f -y "$partition" 2>/dev/null; then
                    log "      ✓ Filesystem repaired successfully"
                    return 0
                else
                    log "      ❌ Filesystem repair failed"
                    return 1
                fi
            fi
            ;;
        vfat|fat32|fat16)
            if command -v fsck.fat &> /dev/null; then
                log "    Running fsck.fat..."
                if [ "$DRY_RUN" = true ]; then
                    log "    🧪 DRY RUN - Would run: fsck.fat -a $partition"
                    return 0
                elif fsck.fat -a "$partition" 2>/dev/null; then
                    log "      ✓ FAT filesystem check passed"
                    return 0
                else
                    log "      ⚠ FAT filesystem had issues"
                    return 1
                fi
            fi
            ;;
        ntfs)
            if command -v ntfsfix &> /dev/null; then
                log "    Running ntfsfix..."
                if [ "$DRY_RUN" = true ]; then
                    log "    🧪 DRY RUN - Would run: ntfsfix $partition"
                    return 0
                elif ntfsfix "$partition" 2>/dev/null; then
                    log "      ✓ NTFS check completed"
                    return 0
                else
                    log "      ⚠ NTFS check reported issues"
                    return 1
                fi
            fi
            ;;
        *)
            log "    No specific check available for $fs_type"
            return 0
            ;;
    esac
    
    return 0
}