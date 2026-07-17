# manzolo-backup-home module: backup verification and retention
# Sourced by manzolo-backup-home.sh — do not execute directly.
verify_backup() {
    local source_dir="$1"
    local backup_dir="$2"
    local verify_method="${CONFIG[verify_method]:-smart}"
    
    case "$verify_method" in
        "none")
            return 0
            ;;
        "simple")
            # Simple verification: compare file counts (old method)
            local source_count backup_count
            source_count=$(find "$source_dir" -type f 2>/dev/null | wc -l)
            backup_count=$(find "$backup_dir" -type f 2>/dev/null | wc -l)
            
            if [ "$source_count" -eq "$backup_count" ]; then
                return 0
            else
                echo -e "  ${YELLOW}${WARNING} File count difference: source=$source_count, backup=$backup_count${NC}"
                return 1
            fi
            ;;
        "smart"|*)
            # Smart verification: check critical indicators
            local issues=0
            local warnings=()
            
            # 1. Check if backup directory was created and has content
            if [ ! -d "$backup_dir" ] || [ ! "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
                echo -e "  ${RED}${ERROR} Backup directory empty or missing${NC}"
                return 1
            fi
            
            # 2. Check for major file count discrepancies (>10% difference)
            local source_count backup_count
            source_count=$(find "$source_dir" -type f 2>/dev/null | wc -l)
            backup_count=$(find "$backup_dir" -type f 2>/dev/null | wc -l)
            
            if [ "$source_count" -gt 0 ]; then
                local diff_percentage=$(( (source_count - backup_count) * 100 / source_count ))
                # Use absolute value for percentage
                diff_percentage=${diff_percentage#-}
                
                if [ "$diff_percentage" -gt 10 ]; then
                    warnings+=("File count difference: ${diff_percentage}% (source=$source_count, backup=$backup_count)")
                    issues=$((issues + 1))
                fi
            fi
            
            # 3. Check for rsync errors in log file
            local log_file
            log_file="$backup_dir/../backup_$(date +%Y%m%d)*.log"
            if ls $log_file 2>/dev/null | head -1 | xargs grep -qi "error\|failed\|permission denied" 2>/dev/null; then
                warnings+=("Rsync reported errors (check log file)")
                issues=$((issues + 1))
            fi
            
            # 4. Check for essential directories (if backing up system dirs)
            case "$(basename "$source_dir")" in
                "etc")
                    for essential in "passwd" "group" "hosts" "fstab"; do
                        if [ -f "$source_dir/$essential" ] && [ ! -f "$backup_dir/$essential" ]; then
                            warnings+=("Missing essential file: $essential")
                            issues=$((issues + 1))
                        fi
                    done
                    ;;
                "opt")
                    # Check if major subdirectories exist
                    local opt_dirs=0 backup_dirs=0
                    opt_dirs=$(find "$source_dir" -maxdepth 1 -type d | wc -l)
                    backup_dirs=$(find "$backup_dir" -maxdepth 1 -type d | wc -l)
                    if [ "$opt_dirs" -gt 1 ] && [ "$backup_dirs" -eq 1 ]; then
                        warnings+=("No subdirectories found in /opt backup")
                        issues=$((issues + 1))
                    fi
                    ;;
            esac
            
            # 5. Check total size difference (if significant)
            local source_size backup_size
            source_size=$(du -sb "$source_dir" 2>/dev/null | cut -f1 || echo "0")
            backup_size=$(du -sb "$backup_dir" 2>/dev/null | cut -f1 || echo "0")
            
            if [ "$source_size" -gt 0 ] && [ "$backup_size" -gt 0 ]; then
                local size_diff_percentage=$(( (source_size - backup_size) * 100 / source_size ))
                size_diff_percentage=${size_diff_percentage#-}
                
                if [ "$size_diff_percentage" -gt 20 ]; then
                    warnings+=("Size difference: ${size_diff_percentage}% (may indicate incomplete backup)")
                    issues=$((issues + 1))
                fi
            fi
            
            # Report results
            if [ "$issues" -eq 0 ]; then
                return 0
            elif [ "$issues" -le 2 ]; then
                # Minor issues - log but don't fail
                for warning in "${warnings[@]}"; do
                    echo -e "  ${YELLOW}${WARNING} $warning${NC}"
                done
                echo -e "  ${BLUE}${INFO} Backup appears mostly successful despite minor issues${NC}"
                return 0
            else
                # Major issues
                echo -e "  ${RED}${ERROR} Multiple integrity issues detected:${NC}"
                for warning in "${warnings[@]}"; do
                    echo -e "    ${RED}• $warning${NC}"
                done
                return 1
            fi
            ;;
    esac
}

# Cleanup old backups
cleanup_old_backups() {
    local max_backups="${CONFIG[max_backups]}"
    
    echo -e "  ${GRAY}${INFO} Cleaning up old backups (keeping $max_backups)${NC}"
    
    # Find and remove old backups
    while IFS= read -r -d '' backup_dir; do
        local backup_count
        backup_count=$(find "$(dirname "$backup_dir")" -maxdepth 1 -name "$(basename "$backup_dir" | sed 's/_[0-9]\{8\}_[0-9]\{6\}$//')_*" -type d | wc -l)
        
        if [ "$backup_count" -gt "$max_backups" ]; then
            local oldest_backup
            oldest_backup=$(find "$(dirname "$backup_dir")" -maxdepth 1 -name "$(basename "$backup_dir" | sed 's/_[0-9]\{8\}_[0-9]\{6\}$//')_*" -type d | sort | head -1)
            echo -e "  ${GRAY}${INFO} Removing old backup: $(basename "$oldest_backup")${NC}"
            rm -rf "$oldest_backup"
        fi
    done < <(find "$DEST_DISK" -maxdepth 1 -name "backup_*_[0-9]*" -type d -print0)
}

# Send notification
