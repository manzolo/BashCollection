# Enhanced cache management functions for block devices

# Clear caches more safely and thoroughly
clear_system_caches() {
    local device="$1"
    local verbose="${2:-false}"
    
    [[ "$verbose" == true ]] && log_info "Starting comprehensive cache clearing..."
    
    # 1. Sync all pending writes first
    sync
    [[ "$verbose" == true ]] && log_info "✓ Filesystem sync completed"
    
    # 2. If device is specified, clear device-specific caches
    if [[ -n "$device" && -b "$device" ]]; then
        # Clear device buffer cache (safer than global cache drop)
        if command -v blockdev >/dev/null; then
            sudo blockdev --flushbufs "$device" 2>/dev/null || true
            [[ "$verbose" == true ]] && log_info "✓ Device buffer cache flushed: $device"
        fi
        
        # Invalidate device cache
        if [[ -w "$device" ]]; then
            sudo dd if="$device" of=/dev/null bs=1M count=1 iflag=direct 2>/dev/null || true
            [[ "$verbose" == true ]] && log_info "✓ Device cache invalidated with direct I/O"
        fi
    fi
    
    # 3. Clear page cache only (safer than dropping all caches)
    echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    [[ "$verbose" == true ]] && log_info "✓ Page cache cleared"
    
    # 4. Small delay to ensure operations complete
    sleep 0.5
    
    # 5. Optional: Clear dentries and inodes if really needed
    # (Uncomment only if you experience specific caching issues)
    # echo 2 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    # [[ "$verbose" == true ]] && log_info "✓ Dentry and inode caches cleared"
    
    # 6. Final sync
    sync
    [[ "$verbose" == true ]] && log_info "✓ Final sync completed"
}

# Advanced cache management with device-specific optimizations
advanced_cache_clear() {
    local device="$1"
    local mode="${2:-standard}" # standard, aggressive, minimal
    
    log_info "Cache clearing mode: $mode"
    
    case "$mode" in
        "minimal")
            # Just sync and basic page cache clear
            sync
            echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
            log_info "✓ Minimal cache clear completed"
            ;;
            
        "standard")
            clear_system_caches "$device" true
            ;;
            
        "aggressive")
            log_info "Performing aggressive cache clearing..."
            
            # Unmount any auto-mounted partitions first
            if [[ -b "$device" ]]; then
                local mounted_parts
                mounted_parts=$(lsblk -no MOUNTPOINT "$device" 2>/dev/null | grep -v "^$" || true)
                
                for mount_point in $mounted_parts; do
                    if [[ "$mount_point" =~ ^/media/|^/mnt/|^/tmp/ ]]; then
                        log_info "Unmounting: $mount_point"
                        sudo umount "$mount_point" 2>/dev/null || true
                    fi
                done
            fi
            
            # Comprehensive cache clearing
            sync
            
            # Clear all cache types
            echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
            log_info "✓ All caches dropped (page, dentry, inode)"
            
            # Device-specific clearing
            if [[ -b "$device" ]]; then
                sudo blockdev --flushbufs "$device" 2>/dev/null || true
                
                # Force re-read partition table
                sudo partprobe "$device" 2>/dev/null || true
                log_info "✓ Partition table re-read"
                
                # Clear any remaining device buffers with hdparm if available
                if command -v hdparm >/dev/null; then
                    sudo hdparm -F "$device" 2>/dev/null || true
                    log_info "✓ Device cache flushed with hdparm"
                fi
            fi
            
            # Final operations
            sync
            sleep 1
            log_info "✓ Aggressive cache clear completed"
            ;;
    esac
}

# Smart cache management based on device type and usage
smart_cache_clear() {
    local device="$1"
    
    if [[ ! -b "$device" ]]; then
        log_info "Not a block device, using minimal cache clear"
        sync
        echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        return
    fi
    
    # Detect device type and adjust strategy
    local device_info
    device_info=$(udevadm info --query=property --name="$device" 2>/dev/null || true)
    
    local is_usb=false
    local is_ssd=false
    local is_removable=false
    
    if echo "$device_info" | grep -q "ID_BUS=usb"; then
        is_usb=true
    fi
    
    if echo "$device_info" | grep -q "ID_SSD=1"; then
        is_ssd=true
    fi
    
    if [[ "$(cat /sys/block/$(basename "$device")/removable 2>/dev/null || echo 0)" == "1" ]]; then
        is_removable=true
    fi
    
    # Choose appropriate clearing strategy
    if [[ "$is_usb" == true ]] || [[ "$is_removable" == true ]]; then
        log_info "USB/removable device detected - using standard cache clear"
        advanced_cache_clear "$device" "standard"
    elif [[ "$is_ssd" == true ]]; then
        log_info "SSD detected - using minimal cache clear (SSD-friendly)"
        advanced_cache_clear "$device" "minimal"
    else
        log_info "Traditional storage detected - using standard cache clear"
        advanced_cache_clear "$device" "standard"
    fi
}

# Memory pressure relief (useful before starting QEMU)
relieve_memory_pressure() {
    local target_free_mb="${1:-512}" # Target free memory in MB
    
    local current_free
    current_free=$(free -m | awk '/^Mem:/{print $7}')
    
    log_info "Current available memory: ${current_free}MB"
    
    if [[ $current_free -lt $target_free_mb ]]; then
        log_info "Low memory detected, performing memory cleanup..."
        
        # Clear caches progressively
        sync
        echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        sleep 1
        
        # Check again
        current_free=$(free -m | awk '/^Mem:/{print $7}')
        log_info "Available memory after page cache clear: ${current_free}MB"
        
        if [[ $current_free -lt $target_free_mb ]]; then
            # More aggressive clearing
            echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
            sleep 1
            
            current_free=$(free -m | awk '/^Mem:/{print $7}')
            log_info "Available memory after full cache clear: ${current_free}MB"
        fi
        
        # Compact memory if still needed
        if [[ $current_free -lt $target_free_mb ]] && [[ -w /proc/sys/vm/compact_memory ]]; then
            echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null 2>&1 || true
            log_info "Memory compaction triggered"
        fi
    else
        log_info "Sufficient memory available, no cleanup needed"
    fi
}

# Integration function for your confirm_and_run
prepare_system_for_qemu() {
    local disk="$1"
    local memory_mb="$2"
    
    log_info "=== Preparing system for QEMU ==="
    
    # 1. Memory management
    local required_memory=$((memory_mb + 512)) # QEMU memory + 512MB buffer
    relieve_memory_pressure "$required_memory"
    
    # 2. Cache management
    smart_cache_clear "$disk"
    
    # 3. System optimizations
    # Disable swap temporarily if low memory
    local total_memory
    total_memory=$(free -m | awk '/^Mem:/{print $2}')
    
    if [[ $total_memory -lt $((required_memory * 2)) ]]; then
        log_info "Low total memory detected, considering swap optimization..."
        # Only suggest, don't automatically disable swap
        log_warn "Consider temporarily disabling swap: sudo swapoff -a"
    fi
    
    # 4. Final sync
    sync
    
    log_info "=== System preparation completed ==="
}
