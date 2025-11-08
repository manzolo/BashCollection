#!/bin/bash

# ═══════════════════════════════════════════════════════════════════
# Clone Utilities Module - Retry Logic and Helper Functions
# ═══════════════════════════════════════════════════════════════════

# Clone with retry logic for resilient copying
clone_with_retry() {
    local source="$1"
    local dest="$2"
    local block_size="${3:-4M}"
    local max_retries="${4:-3}"
    local attempt=1
    local error_log="/tmp/clone_error_$$.log"

    # Ensure temp directory has enough space
    local temp_dir="${TMPDIR:-/tmp}"
    if [ ! -w "$temp_dir" ] || [ "$(df -k "$temp_dir" | tail -1 | awk '{print $4}')" -lt 10485760 ]; then
        log_with_level ERROR "Insufficient space in $temp_dir (<10GB). Set TMPDIR to a directory with more space."
        return 1
    fi

    while [ $attempt -le $max_retries ]; do
        log_with_level INFO "Clone attempt $attempt of $max_retries (source: $source, dest: $dest, bs: $block_size)"

        if [ "$DRY_RUN" = true ]; then
            log_with_level INFO "🧪 DRY RUN - Would clone: $source -> $dest (bs=$block_size)"
            return 0
        fi

        # Try different block sizes on retry
        local current_bs="$block_size"
        if [ $attempt -eq 2 ]; then
            current_bs="1M"
        elif [ $attempt -eq 3 ]; then
            current_bs="512K"
        fi

        # Try cloning with pv if available
        if command -v pv >/dev/null 2>&1 && [ $attempt -le 2 ]; then
            log_with_level INFO "Using pv with block size $current_bs"
            if pv "$source" | dd of="$dest" bs="$current_bs" conv=notrunc,noerror 2>"$error_log"; then
                log_with_level INFO "✓ Clone successful on attempt $attempt with pv"
                sync
                rm -f "$error_log"
                return 0
            else
                log_with_level WARN "Clone attempt $attempt with pv failed: $(cat "$error_log")"
            fi
        else
            # Fallback to plain dd without pv
            log_with_level INFO "Using dd with block size $current_bs"
            if dd if="$source" of="$dest" bs="$current_bs" status=progress conv=notrunc,noerror 2>"$error_log"; then
                log_with_level INFO "✓ Clone successful on attempt $attempt with dd"
                sync
                rm -f "$error_log"
                return 0
            else
                log_with_level WARN "Clone attempt $attempt with dd failed: $(cat "$error_log")"
            fi
        fi

        log_with_level WARN "Clone attempt $attempt failed, retrying with smaller block size..."
        attempt=$((attempt + 1))
        sleep 2
    done

    # Final attempt with ddrescue for bad sector recovery
    if command -v ddrescue >/dev/null 2>&1; then
        log_with_level INFO "Trying ddrescue for bad sector recovery..."
        if [ "$DRY_RUN" = true ]; then
            log_with_level INFO "🧪 DRY RUN - Would run: ddrescue -d -r3 '$source' '$dest' rescue.log"
            return 0
        else
            ddrescue -d -r3 "$source" "$dest" "$temp_dir/rescue_$$.log" 2>"$error_log"
            if [ $? -eq 0 ]; then
                log_with_level INFO "✓ Recovered with ddrescue"
                sync
                rm -f "$error_log"
                return 0
            else
                log_with_level ERROR "ddrescue failed: $(cat "$error_log")"
            fi
        fi
    else
        log_with_level WARN "ddrescue not installed, skipping bad sector recovery (install with: apt install gddrescue)"
    fi

    log_with_level ERROR "All clone attempts failed"
    rm -f "$error_log"
    return 1
}

# Clone partition with intelligent method selection
smart_clone_partition() {
    local source="$1"
    local target="$2"
    local fs_type="${3:-}"
    
    log "Smart cloning partition: $source → $target"
    
    if [ -z "$fs_type" ]; then
        fs_type=$(detect_filesystem_robust "$source")
    fi
    
    log "  Filesystem type: ${fs_type:-unknown}"
    
    # Choose best method based on filesystem
    case "$fs_type" in
        ext2|ext3|ext4)
            if command -v e2image &> /dev/null; then
                log "  Using e2image for ext filesystem"
                if [ "$DRY_RUN" = true ]; then
                    log "🧪 DRY RUN - Would run: e2image -ra -p '$source' '$target'"
                    return 0
                fi
                
                e2fsck -f -y "$source" 2>/dev/null || true
                if e2image -ra -p "$source" "$target" 2>/dev/null; then
                    log "    ✓ Successfully cloned with e2image"
                    return 0
                fi
            fi
            ;;
            
        ntfs)
            if command -v ntfsclone &> /dev/null; then
                log "  Using ntfsclone for NTFS"
                if [ "$DRY_RUN" = true ]; then
                    log "🧪 DRY RUN - Would run: ntfsclone -f --overwrite '$target' '$source'"
                    return 0
                fi
                
                if ntfsclone -f --overwrite "$target" "$source" 2>/dev/null; then
                    log "    ✓ Successfully cloned with ntfsclone"
                    return 0
                fi
            fi
            ;;
            
        btrfs)
            if command -v btrfs &> /dev/null 2>/dev/null; then
                log "  Using Btrfs-specific cloning"
                if handle_btrfs_partition "$source" "$target" true; then
                    return 0
                fi
            fi
            ;;
            
        zfs_member)
            if command -v zfs &> /dev/null 2>/dev/null; then
                log "  Using ZFS-specific cloning"
                if clone_zfs "$source" "$target" "optimized"; then
                    return 0
                fi
            fi
            ;;
    esac
    
    # Fallback to clone_with_retry
    log "  Using generic clone with retry"
    clone_with_retry "$source" "$target" "4M" 3
}

# Verify clone integrity
verify_clone() {
    local source="$1"
    local target="$2"
    local fs_type="${3:-}"
    
    log "Verifying clone integrity..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would verify clone integrity"
        return 0
    fi
    
    # Basic size check
    local source_size=$(blockdev --getsize64 "$source" 2>/dev/null || stat -c%s "$source" 2>/dev/null)
    local target_size=$(blockdev --getsize64 "$target" 2>/dev/null || stat -c%s "$target" 2>/dev/null)
    
    if [ -n "$source_size" ] && [ -n "$target_size" ]; then
        local size_diff=$((source_size - target_size))
        
        if [ $size_diff -eq 0 ]; then
            log "  ✓ Size matches exactly"
        elif [ ${size_diff#-} -le 1048576 ]; then
            log "  ✓ Size matches (within tolerance)"
        else
            log "  ⚠ Size mismatch: source=$source_size, target=$target_size"
            return 1
        fi
    fi
    
    # Filesystem-specific verification
    if [ -z "$fs_type" ]; then
        fs_type=$(detect_filesystem_robust "$target")
    fi
    
    case "$fs_type" in
        ext2|ext3|ext4)
            if e2fsck -f -n "$target" &>/dev/null; then
                log "  ✓ Ext filesystem verified"
            else
                log "  ⚠ Ext filesystem needs checking"
                return 1
            fi
            ;;
            
        ntfs)
            if command -v ntfsfix &> /dev/null && ntfsfix --no-action "$target" &>/dev/null; then
                log "  ✓ NTFS filesystem verified"
            fi
            ;;
            
        btrfs)
            if command -v btrfs &> /dev/null && btrfs check --readonly "$target" &>/dev/null; then
                log "  ✓ Btrfs filesystem verified"
            fi
            ;;
            
        *)
            log "  ℹ No specific verification for $fs_type"
            ;;
    esac
    
    return 0
}

# Progress monitoring wrapper
monitor_clone_progress() {
    local source="$1"
    local target="$2"
    local operation="${3:-Cloning}"
    
    local source_size=$(blockdev --getsize64 "$source" 2>/dev/null || stat -c%s "$source" 2>/dev/null)
    
    if [ -n "$source_size" ] && command -v pv &> /dev/null; then
        log "$operation with progress monitoring..."
        pv -tpreb -s "$source_size" "$source" | dd of="$target" bs=4M conv=noerror,sync 2>/dev/null
    else
        log "$operation..."
        dd if="$source" of="$target" bs=4M conv=noerror,sync status=progress 2>/dev/null
    fi
}

# Safe clone with pre and post checks
safe_clone() {
    local source="$1"
    local target="$2"
    local fs_type="${3:-}"
    
    log "Starting safe clone operation..."
    
    # Pre-clone checks
    if [ -b "$source" ]; then
        sync
        blockdev --flushbufs "$source" 2>/dev/null || true
    fi
    
    if [ -b "$target" ]; then
        blockdev --flushbufs "$target" 2>/dev/null || true
    fi
    
    # Perform clone
    if smart_clone_partition "$source" "$target" "$fs_type"; then
        # Post-clone sync
        sync
        
        # Verify
        if verify_clone "$source" "$target" "$fs_type"; then
            log "✓ Clone completed and verified successfully"
            return 0
        else
            log "⚠ Clone completed but verification failed"
            return 1
        fi
    else
        log "❌ Clone operation failed"
        return 1
    fi
}

# Batch clone multiple partitions
batch_clone_partitions() {
    local -n sources=$1
    local -n targets=$2
    
    if [ ${#sources[@]} -ne ${#targets[@]} ]; then
        log "Error: Source and target arrays must have same length"
        return 1
    fi
    
    local total=${#sources[@]}
    local succeeded=0
    local failed=0
    
    log "Starting batch clone of $total partitions..."
    
    for i in "${!sources[@]}"; do
        local source="${sources[$i]}"
        local target="${targets[$i]}"
        
        log ""
        log "[$((i+1))/$total] Cloning: $source → $target"
        
        if safe_clone "$source" "$target"; then
            succeeded=$((succeeded + 1))
        else
            failed=$((failed + 1))
            log "  ⚠ Failed to clone partition $((i+1))"
        fi
    done
    
    log ""
    log "Batch clone complete: $succeeded succeeded, $failed failed"
    
    return $failed
}