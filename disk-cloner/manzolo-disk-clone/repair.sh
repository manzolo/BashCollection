#!/bin/bash

# ═══════════════════════════════════════════════════════════════════
# Enhanced Filesystem Repair Module with ZFS/Btrfs Support
# ═══════════════════════════════════════════════════════════════════

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
            
        xfs)
            if command -v xfs_repair &> /dev/null; then
                log "    Running xfs_repair..."
                if [ "$DRY_RUN" = true ]; then
                    log "    🧪 DRY RUN - Would run: xfs_repair -n $partition"
                    return 0
                else
                    # First run in check-only mode
                    if xfs_repair -n "$partition" 2>/dev/null; then
                        log "      ✓ XFS filesystem check passed"
                        return 0
                    else
                        log "      ⚠ XFS filesystem needs repair, attempting..."
                        if xfs_repair "$partition" 2>/dev/null; then
                            log "      ✓ XFS filesystem repaired"
                            return 0
                        else
                            log "      ❌ XFS repair failed"
                            return 1
                        fi
                    fi
                fi
            fi
            ;;
            
        btrfs)
            if command -v btrfs &> /dev/null; then
                log "    Running btrfs check..."
                if [ "$DRY_RUN" = true ]; then
                    log "    🧪 DRY RUN - Would run: btrfs check --readonly $partition"
                    return 0
                else
                    # First run read-only check
                    if btrfs check --readonly "$partition" 2>/dev/null; then
                        log "      ✓ Btrfs filesystem check passed"
                        return 0
                    else
                        log "      ⚠ Btrfs filesystem has issues"
                        
                        # Ask user before attempting repair
                        if dialog --title "Btrfs Repair Needed" \
                            --yesno "Btrfs filesystem on $partition has issues.\n\nAttempt repair? (This can take a while)" 10 60; then
                            
                            log "      Attempting Btrfs repair..."
                            if btrfs check --repair "$partition" 2>/dev/null; then
                                log "      ✓ Btrfs filesystem repaired"
                                return 0
                            else
                                log "      ❌ Btrfs repair failed"
                                
                                # Try scrub as alternative
                                log "      Attempting scrub instead..."
                                local temp_mount="/tmp/btrfs_scrub_$$"
                                mkdir -p "$temp_mount"
                                
                                if mount -t btrfs "$partition" "$temp_mount" 2>/dev/null; then
                                    btrfs scrub start -B -d "$temp_mount" 2>/dev/null
                                    local scrub_result=$?
                                    umount "$temp_mount" 2>/dev/null
                                    rmdir "$temp_mount" 2>/dev/null
                                    
                                    if [ $scrub_result -eq 0 ]; then
                                        log "      ✓ Scrub completed successfully"
                                        return 0
                                    fi
                                fi
                                
                                return 1
                            fi
                        else
                            log "      Skipping repair at user request"
                            return 1
                        fi
                    fi
                fi
            fi
            ;;
            
        zfs_member)
            if command -v zpool &> /dev/null; then
                log "    Checking ZFS pool member..."
                if [ "$DRY_RUN" = true ]; then
                    log "    🧪 DRY RUN - Would check ZFS pool status"
                    return 0
                else
                    # Find which pool this device belongs to
                    local pool_name=$(get_zfs_pool_info "$partition")
                    
                    if [ -n "$pool_name" ]; then
                        log "      Device is part of pool: $pool_name"
                        
                        # Check pool health
                        if check_zfs_health "$pool_name"; then
                            log "      ✓ ZFS pool is healthy"
                            
                            # Run scrub for thorough check
                            log "      Running ZFS scrub..."
                            if zpool scrub "$pool_name" 2>/dev/null; then
                                # Wait for scrub to complete (with timeout)
                                local timeout=60
                                local elapsed=0
                                
                                while [ $elapsed -lt $timeout ]; do
                                    local scrub_status=$(zpool status "$pool_name" 2>/dev/null | grep "scan:" | head -1)
                                    
                                    if echo "$scrub_status" | grep -q "scrub repaired"; then
                                        log "      ✓ ZFS scrub completed"
                                        break
                                    elif echo "$scrub_status" | grep -q "none requested"; then
                                        break
                                    fi
                                    
                                    sleep 2
                                    elapsed=$((elapsed + 2))
                                done
                                
                                return 0
                            else
                                log "      ⚠ Could not start ZFS scrub"
                                return 1
                            fi
                        else
                            log "      ❌ ZFS pool has issues"
                            
                            # Try to clear errors
                            log "      Attempting to clear ZFS errors..."
                            zpool clear "$pool_name" 2>/dev/null
                            
                            return 1
                        fi
                    else
                        log "      ⚠ Could not determine ZFS pool membership"
                        return 1
                    fi
                fi
            fi
            ;;
            
        crypto_LUKS)
            if command -v cryptsetup &> /dev/null; then
                log "    Checking LUKS header..."
                if [ "$DRY_RUN" = true ]; then
                    log "    🧪 DRY RUN - Would run: cryptsetup luksDump $partition"
                    return 0
                elif cryptsetup luksDump "$partition" &>/dev/null; then
                    log "      ✓ LUKS header is valid"
                    
                    # Check for backup header
                    if cryptsetup luksHeaderBackup "$partition" --header-backup-file "/tmp/luks_backup_$$.img" 2>/dev/null; then
                        log "      ✓ LUKS header backup successful"
                        rm -f "/tmp/luks_backup_$$.img"
                    fi
                    
                    return 0
                else
                    log "      ❌ LUKS header is corrupted"
                    return 1
                fi
            fi
            ;;
            
        swap)
            log "    Checking swap partition..."
            if [ "$DRY_RUN" = true ]; then
                log "    🧪 DRY RUN - Swap partition doesn't need repair"
                return 0
            else
                # Swap doesn't really need repair, just validation
                local swap_uuid=$(blkid -o value -s UUID "$partition" 2>/dev/null)
                if [ -n "$swap_uuid" ]; then
                    log "      ✓ Swap partition valid (UUID: $swap_uuid)"
                else
                    log "      ⚠ Swap partition has no UUID"
                fi
                return 0
            fi
            ;;
            
        *)
            log "    No specific check available for $fs_type"
            return 0
            ;;
    esac
    
    return 0
}

# Comprehensive filesystem check before cloning
pre_clone_filesystem_check() {
    local device="$1"
    
    log "Running pre-clone filesystem checks on $device..."
    
    local has_errors=false
    
    # Check each partition
    while IFS= read -r part; do
        if [ -b "/dev/$part" ]; then
            local fs_type=$(get_filesystem_type "/dev/$part")
            
            if [ -n "$fs_type" ] && [ "$fs_type" != "" ]; then
                log "  Checking /dev/$part ($fs_type)..."
                
                if ! repair_filesystem "/dev/$part" "$fs_type"; then
                    has_errors=true
                    log "    ⚠ Filesystem has unresolved issues"
                fi
            fi
        fi
    done < <(lsblk -ln -o NAME "$device" | tail -n +2)
    
    if [ "$has_errors" = true ]; then
        if ! dialog --title "⚠ Filesystem Issues Detected" \
            --yesno "Some filesystems have unresolved issues.\n\nContinuing may result in corrupted clones.\n\nDo you want to continue anyway?" 12 60; then
            return 1
        fi
    else
        log "✓ All filesystem checks passed"
    fi
    
    return 0
}

# Post-clone filesystem verification
post_clone_filesystem_verify() {
    local device="$1"
    
    log "Verifying cloned filesystems on $device..."
    
    local all_good=true
    
    # Verify each partition
    while IFS= read -r part; do
        if [ -b "/dev/$part" ]; then
            local fs_type=$(get_filesystem_type "/dev/$part")
            
            if [ -n "$fs_type" ] && [ "$fs_type" != "" ]; then
                log "  Verifying /dev/$part ($fs_type)..."
                
                case "$fs_type" in
                    ext2|ext3|ext4)
                        if e2fsck -f -n "/dev/$part" &>/dev/null; then
                            log "    ✓ Filesystem verified"
                        else
                            log "    ⚠ Filesystem needs checking"
                            all_good=false
                        fi
                        ;;
                    btrfs)
                        if btrfs check --readonly "/dev/$part" &>/dev/null; then
                            log "    ✓ Btrfs verified"
                        else
                            log "    ⚠ Btrfs needs checking"
                            all_good=false
                        fi
                        ;;
                    zfs_member)
                        log "    ℹ ZFS verification requires pool import"
                        ;;
                    *)
                        log "    ℹ No verification for $fs_type"
                        ;;
                esac
            fi
        fi
    done < <(lsblk -ln -o NAME "$device" | tail -n +2)
    
    if [ "$all_good" = true ]; then
        log "✓ All cloned filesystems verified successfully"
    else
        log "⚠ Some filesystems may need additional checking"
    fi
    
    return 0
}