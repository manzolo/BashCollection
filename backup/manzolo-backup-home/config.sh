# manzolo-backup-home module: configuration loading and defaults
# Sourced by manzolo-backup-home.sh — do not execute directly.
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log "INFO" "Loading configuration from $CONFIG_FILE"
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            CONFIG["$key"]="$value"
        done < "$CONFIG_FILE"
    fi
}

# Create default configuration file
create_default_config() {
    cat > "$CONFIG_FILE" << 'EOF'
# ══════════════════════════════════════════════════════════════════════════════
# Enhanced Backup Script Configuration
# ══════════════════════════════════════════════════════════════════════════════

# Maximum number of backup versions to keep
max_backups=1

# Enable compression (true/false)
compression=true

# Enable notifications (true/false)
notifications=true

# Email address for error notifications (leave empty to disable)
email_on_error=

# Bandwidth limit (e.g., 1000k, 10m, leave empty for no limit)
bandwidth_limit=

# Number of parallel backup jobs
parallel_jobs=1

# Verify backup integrity after completion
verify_integrity=true

# Verification method: none, simple, smart
# - none: skip verification
# - simple: basic file count comparison (may give false positives)
# - smart: intelligent verification considering normal variations
verify_method=smart
EOF
    log "INFO" "Default configuration created at $CONFIG_FILE"
}

# Check prerequisites
