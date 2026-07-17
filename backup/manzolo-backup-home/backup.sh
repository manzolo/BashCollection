# manzolo-backup-home module: exclude list and rsync backup execution
# Sourced by manzolo-backup-home.sh — do not execute directly.
create_exclude_file() {
    local exclude_file="$1"
    
    cat > "$exclude_file" << 'EOF'
# Temporary files
*.tmp
*.temp
*.swp
*.swo
*~
.#*

# Cache directories
.cache/
.local/share/Trash/
.thumbnails/
.thumbnail/
__pycache__/
.pytest_cache/
.mypy_cache/
.tox/

# Browser caches
.mozilla/firefox/*/Cache/
.mozilla/firefox/*/cache2/
.mozilla/firefox/*/CachedTileData/
.config/google-chrome/*/Cache/
.config/chromium/*/Cache/
.config/*/Cache/
.config/*/CachedData/

# Development directories
node_modules/
.npm/
.yarn/
.gradle/cache/
.cargo/registry/
.cargo/git/
vendor/
.venv/
venv/
env/

# Media directories (optional - remove if you want to backup)
Downloads/
Videos/
Movies/
Music/

# System files
.DS_Store
._.DS_Store
Thumbs.db
desktop.ini
.Spotlight-V100/
.fseventsd/
.VolumeIcon.icns
.TemporaryItems/
.AppleDouble/
.LSOverride

# Version control
.git/objects/
.git/logs/
.svn/
.hg/

# Virtual filesystems
.gvfs
/proc/*
/sys/*
/dev/*
/run/*
/mnt/*
/media/*
/tmp/*
/var/tmp/*
/var/cache/*
/var/log/*
lost+found/
EOF
}

# Enhanced backup function with progress tracking
perform_backup() {
    local source_dir="$1"
    local dest_dir="$2"
    local log_file="$3"
    local dry_run_mode="$4"
    local rsync_options="$5"
    local exclude_file="$6"
    
    echo -e "  ${YELLOW}${CLOCK} Starting backup...${NC}"
    
    # Create destination directory
    mkdir -p "$dest_dir"
    
    # Incremental backup setup
    local link_dest_option=""
    local previous_backup
    previous_backup=$(find "$(dirname "$dest_dir")" -maxdepth 1 -name "$(basename "$dest_dir")_*" -type d 2>/dev/null | sort | tail -1)
    
    if [ -n "$previous_backup" ] && [ -d "$previous_backup" ]; then
        link_dest_option="--link-dest=$previous_backup"
        echo -e "  ${BLUE}${INFO} Using incremental backup with: $(basename "$previous_backup")${NC}"
    fi
    
    # Create timestamped backup directory
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local final_dest_dir="${dest_dir}_${timestamp}"
    
    # Perform the backup with proper signal handling
    local rsync_cmd="rsync $rsync_options $link_dest_option \"$source_dir/\" \"$final_dest_dir/\""
    
    local start_time
    start_time=$(date +%s)
    
    # Handle interruption gracefully
    local backup_pid
    if eval "$rsync_cmd" > "$log_file" 2>&1 & backup_pid=$!; then
        # Wait for backup to complete or be interrupted
        if wait $backup_pid; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            
            if [ "$dry_run_mode" = false ]; then
                # Create a "latest" symlink
                local latest_link="${dest_dir}_latest"
                rm -f "$latest_link"
                ln -s "$(basename "$final_dest_dir")" "$latest_link"
                
                # Set proper permissions for log file
                chown "$REAL_USER:$(id -gn "$REAL_USER")" "$log_file" 2>/dev/null || true
                
                # Verify backup if enabled
                if [ "${CONFIG[verify_integrity]}" = "true" ]; then
                    echo -e "  ${YELLOW}${INFO} Verifying backup integrity...${NC}"
                    if verify_backup "$source_dir" "$final_dest_dir"; then
                        echo -e "  ${GREEN}${SUCCESS} Backup integrity verified${NC}"
                    else
                        echo -e "  ${RED}${WARNING} Backup integrity issues detected${NC}"
                    fi
                fi
                
                echo -e "  ${GREEN}${SUCCESS} Backup completed in ${duration}s${NC}"
                SUCCESS_BACKUPS+=("$source_dir")
            else
                echo -e "  ${GREEN}${SUCCESS} Dry-run completed in ${duration}s${NC}"
            fi
            return 0
        else
            # Backup was interrupted
            echo -e "  ${RED}${ERROR} Backup interrupted${NC}"
            # Clean up partial backup
            [ -d "$final_dest_dir" ] && rm -rf "$final_dest_dir"
            FAILED_BACKUPS+=("$source_dir")
            return 1
        fi
    else
        echo -e "  ${RED}${ERROR} Backup failed to start${NC}"
        FAILED_BACKUPS+=("$source_dir")
        return 1
    fi
}

# Verify backup integrity
