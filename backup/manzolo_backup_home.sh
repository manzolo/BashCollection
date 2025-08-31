#!/bin/bash

# ══════════════════════════════════════════════════════════════════════════════
# 🚀 ENHANCED MULTI-DIRECTORY BACKUP SCRIPT WITH RSYNC
# ══════════════════════════════════════════════════════════════════════════════
# Version: 2.1
# Author: Enhanced by Claude
# License: MIT
# Description: Professional backup solution with incremental backups,
#              error handling, notifications, and beautiful output
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'      # Secure Internal Field Separator

# ═══════════════════════════════════════════════════════════════════════════════
# 🎨 COLORS AND STYLING
# ═══════════════════════════════════════════════════════════════════════════════
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r PURPLE='\033[0;35m'
declare -r CYAN='\033[0;36m'
declare -r WHITE='\033[1;37m'
declare -r GRAY='\033[0;90m'
declare -r NC='\033[0m'

# Emoji and symbols
declare -r SUCCESS="✅"
declare -r ERROR="❌"
declare -r WARNING="⚠️"
declare -r INFO="ℹ️"
declare -r ROCKET="🚀"
declare -r FOLDER="📁"
declare -r DISK="💾"
declare -r CLOCK="⏰"
declare -r STATS="📊"

# ═══════════════════════════════════════════════════════════════════════════════
# 📋 CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════
declare -r SCRIPT_NAME="$(basename "$0")"
declare -r SCRIPT_VERSION="2.1"
declare -r SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r LOG_DIR="/var/log/backup"
declare -r CONFIG_FILE="$SCRIPT_DIR/backup.conf"

# Default configuration
declare -A CONFIG=(
    [max_backups]=1
    [compression]=true
    [notifications]=true
    [email_on_error]=""
    [bandwidth_limit]=""
    [parallel_jobs]=1
    [verify_integrity]=true
    [verify_method]="smart"
)

# Global variables
declare DEST_DISK=""
declare REAL_USER=""
declare DRY_RUN=false
declare VERBOSE=false
declare QUIET=false
declare FORCE=false
declare BACKUP_NAME=""
declare -a BACKUP_DIRS=("/etc" "/opt")
declare -a FAILED_BACKUPS=()
declare -a SUCCESS_BACKUPS=()

# ═══════════════════════════════════════════════════════════════════════════════
# 🛠️  UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Enhanced logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "$level" in
        "ERROR")   echo -e "${RED}${ERROR} [${timestamp}] ERROR: ${message}${NC}" ;;
        "WARN")    echo -e "${YELLOW}${WARNING} [${timestamp}] WARNING: ${message}${NC}" ;;
        "INFO")    echo -e "${BLUE}${INFO} [${timestamp}] INFO: ${message}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}${SUCCESS} [${timestamp}] SUCCESS: ${message}${NC}" ;;
        "DEBUG")   [ "$VERBOSE" = true ] && echo -e "${GRAY}🐛 [${timestamp}] DEBUG: ${message}${NC}" ;;
        *)         echo -e "${WHITE}📝 [${timestamp}] ${message}${NC}" ;;
    esac
    
    # Also log to file if log directory exists
    [ -d "$LOG_DIR" ] && echo "[${timestamp}] ${level}: ${message}" >> "$LOG_DIR/backup.log"
}

# Progress bar function
show_progress() {
    local current="$1"
    local total="$2"
    local source_dir="$3"
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))
    
    # Clear the line and show progress with current directory
    printf "\r\033[K${CYAN}["
    printf "%*s" "$completed" | tr ' ' '='
    printf "%*s" "$remaining" | tr ' ' '-'
    printf "] %d%% (%d/%d) ${WHITE}%s${NC}" "$percentage" "$current" "$total" "$(basename "$source_dir")"
}

# Fancy header
print_header() {
    local title="$1"
    local width=80
    
    echo -e "\n${PURPLE}$(printf '═%.0s' {1..80})${NC}"
    printf "${WHITE}%*s${NC}\n" $(((width + ${#title}) / 2)) "$title"
    echo -e "${PURPLE}$(printf '═%.0s' {1..80})${NC}\n"
}

# System information display - fixed alignment
show_system_info() {
    local hostname_str="$(hostname)"
    local datetime_str="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} ${ROCKET} ${WHITE}SYSTEM INFORMATION${NC}                                                     ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC} ${INFO} Host: ${hostname_str}"
    echo -e "${CYAN}│${NC} ${INFO} User: ${REAL_USER}"
    echo -e "${CYAN}│${NC} ${CLOCK} Time: ${datetime_str}"
    echo -e "${CYAN}│${NC} ${DISK} Dest: ${DEST_DISK}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${NC}"
}

# Load configuration file
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
check_prerequisites() {
    local missing_tools=()
    
    # Check required tools
    for tool in rsync find du df date; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "This script must be run with sudo to handle root files"
        echo -e "${YELLOW}Usage:${NC} sudo $0 $*"
        exit 1
    fi
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
}

# Determine real user
get_real_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        REAL_USER="$SUDO_USER"
    elif [ -n "${1:-}" ]; then
        REAL_USER="$1"
    else
        log "ERROR" "Cannot determine the real user. Specify username as parameter."
        exit 1
    fi
    
    # Validate user exists
    if ! id "$REAL_USER" &>/dev/null; then
        log "ERROR" "User '$REAL_USER' does not exist"
        exit 1
    fi
    
    # Add user's home to backup directories
    local user_home
    user_home=$(getent passwd "$REAL_USER" | cut -d: -f6)
    if [ ! -d "$user_home" ]; then
        log "ERROR" "Home directory '$user_home' for user '$REAL_USER' does not exist"
        exit 1
    fi
    BACKUP_DIRS+=("$user_home")
}

# Create comprehensive exclude file
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
            local log_file="$backup_dir/../backup_$(date +%Y%m%d)*.log"
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
    local base_dir="$1"
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
send_notification() {
    local subject="$1"
    local message="$2"
    
    if [ "${CONFIG[notifications]}" = "true" ]; then
        # Try to send desktop notification with better error handling
        if command -v notify-send &>/dev/null && [ -n "${DISPLAY:-}" ] && [ -n "${SUDO_USER:-}" ]; then
            # Check if dbus is available and working
            if command -v dbus-launch &>/dev/null; then
                sudo -u "$REAL_USER" DISPLAY="$DISPLAY" notify-send "$subject" "$message" 2>/dev/null || {
                    log "DEBUG" "Desktop notification failed (dbus issue) - continuing without notification"
                }
            else
                log "DEBUG" "dbus-launch not available - skipping desktop notification"
            fi
        else
            log "DEBUG" "Desktop notification not available (missing DISPLAY or notify-send)"
        fi
        
        # Send email if configured
        if [ -n "${CONFIG[email_on_error]}" ] && command -v mail &>/dev/null; then
            echo "$message" | mail -s "$subject" "${CONFIG[email_on_error]}" 2>/dev/null || {
                log "DEBUG" "Email notification failed"
            }
        fi
    fi
}

# Show usage information - fixed alignment
show_usage() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} ${ROCKET} ${WHITE}ENHANCED MULTI-DIRECTORY BACKUP SCRIPT v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}Usage:${NC} sudo $SCRIPT_NAME <destination> [options]"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}Arguments:${NC}"
    echo -e "${BLUE}║${NC}   destination      Target backup directory"
    echo -e "${BLUE}║${NC}   [username]       Override detected username"
    echo -e "${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}Options:${NC}"
    echo -e "${BLUE}║${NC}   -h, --help       Show this help message"
    echo -e "${BLUE}║${NC}   -n, --dry-run    Simulation mode without copying"
    echo -e "${BLUE}║${NC}   -v, --verbose    Detailed output with progress"
    echo -e "${BLUE}║${NC}   -q, --quiet      Minimal output"
    echo -e "${BLUE}║${NC}   -f, --force      Skip confirmation prompts"
    echo -e "${BLUE}║${NC}   --name NAME      Custom backup name"
    echo -e "${BLUE}║${NC}   --config         Create default config file"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}Examples:${NC}"
    echo -e "${BLUE}║${NC}   sudo $SCRIPT_NAME /media/backup"
    echo -e "${BLUE}║${NC}   sudo $SCRIPT_NAME /mnt/usb --verbose"
    echo -e "${BLUE}║${NC}   sudo $SCRIPT_NAME /backup --dry-run username"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    exit 1
}

# Display final statistics - fixed alignment
show_final_stats() {
    local start_time="$1"
    local end_time="$2"
    local total_duration=$((end_time - start_time))
    
    echo -e "\n${PURPLE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC} ${STATS} ${WHITE}BACKUP STATISTICS${NC}"
    echo -e "${PURPLE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    
    # Success/Failure counts
    local success_count=${#SUCCESS_BACKUPS[@]}
    local failed_count=${#FAILED_BACKUPS[@]}
    local total_count=$((success_count + failed_count))
    
    echo -e "${PURPLE}║${NC} ${SUCCESS} Successful backups: $success_count/$total_count"
    if [ $failed_count -gt 0 ]; then
        echo -e "${PURPLE}║${NC} ${ERROR} Failed backups: $failed_count"
        for failed in "${FAILED_BACKUPS[@]}"; do
            echo -e "${PURPLE}║${NC}   ${RED}- $failed${NC}"
        done
    fi
    
    echo -e "${PURPLE}║${NC} ${CLOCK} Total time: $(printf '%02d:%02d:%02d' $((total_duration/3600)) $((total_duration%3600/60)) $((total_duration%60)))"
    
    # Disk usage
    if [ -d "$DEST_DISK" ]; then
        local disk_usage
        disk_usage=$(du -sh "$DEST_DISK"/backup_* 2>/dev/null | awk '{total+=$1} END {print total "B"}' 2>/dev/null || echo "N/A")
        echo -e "${PURPLE}║${NC} ${DISK} Backup size: $disk_usage"
        
        local free_space
        free_space=$(df -h "$DEST_DISK" 2>/dev/null | tail -1 | awk '{print $4 " available of " $2}' || echo "N/A")
        echo -e "${PURPLE}║${NC} ${DISK} Free space: $free_space"
    fi
    
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 🚀 MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local start_time
    start_time=$(date +%s)
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            --name)
                BACKUP_NAME="$2"
                shift 2
                ;;
            --config)
                create_default_config
                exit 0
                ;;
            -*)
                log "ERROR" "Unknown option: $1"
                show_usage
                ;;
            *)
                if [ -z "$DEST_DISK" ]; then
                    DEST_DISK="$1"
                else
                    get_real_user "$1"
                fi
                shift
                ;;
        esac
    done
    
    # Validate arguments
    if [ -z "$DEST_DISK" ]; then
        log "ERROR" "Destination disk path required"
        show_usage
    fi
    
    # Initialize
    check_prerequisites
    load_config
    [ -z "$REAL_USER" ] && get_real_user
    
    # Verify destination
    if [ ! -d "$DEST_DISK" ]; then
        log "ERROR" "Destination '$DEST_DISK' does not exist or is not mounted"
        exit 1
    fi
    
    if [ ! -w "$DEST_DISK" ]; then
        log "ERROR" "No write permissions on '$DEST_DISK'"
        exit 1
    fi
    
    # Show system information
    [ "$QUIET" = false ] && show_system_info
    
    # Confirmation prompt - fixed alignment
    if [ "$FORCE" = false ] && [ "$DRY_RUN" = false ]; then
        echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC} ${WARNING} ${WHITE}BACKUP CONFIRMATION${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${FOLDER} Directories to backup: ${#BACKUP_DIRS[@]}"
        for dir in "${BACKUP_DIRS[@]}"; do
            local dir_display="$dir"
            if [ ${#dir_display} -gt 70 ]; then
                dir_display="...${dir_display: -67}"
            fi
            echo -e "${CYAN}║${NC}   • ${dir_display}"
        done
        echo -e "${CYAN}║${NC} ${DISK} Destination: ${DEST_DISK}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${WHITE}Continue with backup? [y/N]:${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo -ne "${WHITE}Your choice: ${NC}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log "INFO" "Backup cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    # Create exclude file
    local exclude_file
    exclude_file=$(mktemp)
    create_exclude_file "$exclude_file"
    
    # Cleanup function
    cleanup() {
        if [ -n "${exclude_file:-}" ]; then
            rm -f "$exclude_file"
        fi
    }
    trap cleanup EXIT
    
    # Build rsync options
    local rsync_options="-ahAXS --delete --delete-excluded --exclude-from=$exclude_file"
    
    if [ "${CONFIG[compression]}" = "true" ]; then
        rsync_options="$rsync_options -z"
    fi
    
    if [ -n "${CONFIG[bandwidth_limit]}" ]; then
        rsync_options="$rsync_options --bwlimit=${CONFIG[bandwidth_limit]}"
    fi
    
    if [ "$VERBOSE" = true ]; then
        rsync_options="$rsync_options --progress --stats"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        rsync_options="$rsync_options --dry-run"
        log "WARN" "DRY RUN MODE ENABLED - No files will be copied"
    fi
    
    # Perform backups
    local current=0
    local total=${#BACKUP_DIRS[@]}
    
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC} ${ROCKET} ${WHITE}BACKUP IN PROGRESS${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    
    for source_dir in "${BACKUP_DIRS[@]}"; do
        current=$((current + 1))
        
        # Get base name for display
        local base_name_dir
        base_name_dir=$(basename "$source_dir")
        
        echo -e "\n${BLUE}╭─────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "${BLUE}│${NC} ${FOLDER} ${WHITE}Processing:${NC} ${base_name_dir} (${current}/${total})"
        echo -e "${BLUE}│${NC} ${INFO} ${GRAY}Source:${NC} $source_dir"
        
        # Create destination path
        local base_name
        base_name=$(basename "$source_dir" | sed 's/\//_/g')
        [ "$base_name" = "" ] && base_name="root"
        
        local dest_dir="$DEST_DISK/backup_${base_name}"
        local log_file="$dest_dir/backup_$(date +%Y%m%d_%H%M%S).log"
        
        echo -e "${BLUE}│${NC} ${DISK} ${GRAY}Destination:${NC} $dest_dir"
        echo -e "${BLUE}╰─────────────────────────────────────────────────────────────────────────────╯${NC}"
        
        # Create log directory
        mkdir -p "$dest_dir"
        
        # Perform backup
        perform_backup "$source_dir" "$dest_dir" "$log_file" "$DRY_RUN" "$rsync_options" "$exclude_file"
        
        # Cleanup old backups
        [ "$DRY_RUN" = false ] && cleanup_old_backups "$dest_dir"
        
        # Show completion for this directory
        echo -e "${GREEN}└─ ${SUCCESS} Backup completed for ${base_name_dir}${NC}\n"
    done
    
    # Show final statistics
    local end_time
    end_time=$(date +%s)
    [ "$QUIET" = false ] && show_final_stats "$start_time" "$end_time"
    
    # Send notifications
    if [ ${#FAILED_BACKUPS[@]} -gt 0 ]; then
        send_notification "Backup Completed with Errors" "Failed backups: ${FAILED_BACKUPS[*]}"
        exit 1
    else
        send_notification "Backup Completed Successfully" "All ${#SUCCESS_BACKUPS[@]} directories backed up successfully"
        log "SUCCESS" "All backups completed successfully!"
        exit 0
    fi
}

# Execute main function with all arguments
main "$@"