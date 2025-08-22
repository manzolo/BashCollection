#!/bin/bash

# Multiple directory backup script with rsync (with sudo support for root files)
# Usage: sudo ./multi_backup.sh /path/to/destination/disk [username]

set -e # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to show usage
show_usage() {
    echo -e "${BLUE}Usage:${NC} sudo $0 <destination_disk> [username]"
    echo -e "${BLUE}Example:${NC} sudo $0 /media/backup"
    echo -e "${BLUE}Example:${NC} sudo $0 /mnt/usb_backup $USER"
    echo ""
    echo -e "${YELLOW}Available options:${NC}"
    echo "  -h, --help       Show this help message"
    echo "  -n, --dry-run    Perform a simulation without copying files"
    echo "  -v, --verbose    Detailed output"
    echo ""
    echo -e "${RED}NOTE: This script must be run with sudo to handle root files${NC}"
    exit 1
}

# Function to perform a single directory backup
perform_backup() {
    local source_dir="$1"
    local dest_dir="$2"
    local log_file="$3"
    local dry_run_mode="$4"
    local rsync_options="$5"
    local exclude_file="$6"

    # Create the destination directory if it doesn't exist
    mkdir -p "$dest_dir"

    # Add incremental backup if a previous backup exists
    local link_dest_option=""
    local previous_backup=$(find "$(dirname "$dest_dir")" -maxdepth 1 -name "$(basename "$dest_dir")" -type d 2>/dev/null | head -1)
    if [ -n "$previous_backup" ] && [ -d "$previous_backup" ]; then
        link_dest_option="--link-dest=$previous_backup"
        echo -e "${GREEN}Found previous backup for $source_dir, it will be used for incremental backup${NC}"
    fi

    echo -e "${YELLOW}Starting backup of ${source_dir} with root privileges...${NC}"

    if rsync $rsync_options $link_dest_option "$source_dir/" "$dest_dir/" 2>&1 | tee "$log_file"; then
        if [ "$dry_run_mode" = false ]; then
            echo -e "${GREEN}✓ Backup completed successfully for ${source_dir}!${NC}"
        else
            echo -e "${YELLOW}✓ Simulation completed for ${source_dir}${NC}"
        fi
        return 0
    else
        echo -e "${RED}✗ Error during backup of ${source_dir}${NC}"
        return 1
    fi
}

# Verify that the script is run with sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error:${NC} This script must be run with sudo to handle root files"
    echo -e "${YELLOW}Use:${NC} sudo $0 $*"
    exit 1
fi

# Determine the real user (who called sudo)
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    echo -e "${RED}Error:${NC} Cannot determine the real user. Specify the username as the second parameter."
    exit 1
fi

# Default variables
DRY_RUN=false
VERBOSE=false
BACKUP_DIRS=("/etc" "/opt") # Array of directories to backup, /etc as an example
EXCLUDE_FILE="/tmp/rsync_exclude_$$"

# Parse arguments
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
        -*)
            echo -e "${RED}Unknown option:${NC} $1"
            show_usage
            ;;
        *)
            if [ -z "$DEST_DISK" ]; then
                DEST_DISK="$1"
            elif [ -z "$OVERRIDE_USER" ]; then
                OVERRIDE_USER="$1"
                REAL_USER="$1"
            else
                echo -e "${RED}Too many arguments.${NC}"
                show_usage
            fi
            shift
            ;;
    esac
done

# Verify that a destination disk was specified
if [ -z "$DEST_DISK" ]; then
    echo -e "${RED}Error:${NC} Specify the destination disk path"
    show_usage
fi

# Add the user's home to the list of directories to backup
REAL_USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [ ! -d "$REAL_USER_HOME" ]; then
    echo -e "${RED}Error:${NC} The home directory '$REAL_USER_HOME' for user '$REAL_USER' does not exist"
    exit 1
fi
BACKUP_DIRS+=("$REAL_USER_HOME")

# Create rsync exclude file
cat > "$EXCLUDE_FILE" << EOF
.cache/
.local/share/Trash/
.thumbnails/
Downloads/
.gvfs
.mozilla/firefox/*/Cache/
.mozilla/firefox/*/cache2/
.config/google-chrome/*/Cache/
.config/chromium/*/Cache/
node_modules/
.npm/
.gradle/cache/
__pycache__/
*.tmp
*.temp
.DS_Store
Thumbs.db
EOF

# Cleanup function
cleanup() {
    rm -f "$EXCLUDE_FILE"
}
trap cleanup EXIT

echo -e "${BLUE}=== MULTIPLE DIRECTORY BACKUP (WITH SUDO) ===${NC}"
echo -e "${BLUE}User:${NC} $REAL_USER"
echo -e "${BLUE}Date/Time:${NC} $(date)"

# Verify that the destination disk exists and is writable
if [ ! -d "$DEST_DISK" ]; then
    echo -e "${RED}Error:${NC} The destination disk '$DEST_DISK' does not exist or is not mounted"
    exit 1
fi

if [ ! -w "$DEST_DISK" ]; then
    echo -e "${RED}Error:${NC} You do not have write permissions on '$DEST_DISK'"
    exit 1
fi

# Build rsync options with full permission preservation
RSYNC_OPTIONS="-ahAXS --delete --delete-excluded --exclude-from=$EXCLUDE_FILE"
if [ "$VERBOSE" = true ]; then
    RSYNC_OPTIONS="$RSYNC_OPTIONS --progress --stats"
fi
if [ "$DRY_RUN" = true ]; then
    RSYNC_OPTIONS="$RSYNC_OPTIONS --dry-run"
    echo -e "${YELLOW}SIMULATION MODE ENABLED${NC}"
fi

# Loop to backup each directory
for SOURCE_DIR in "${BACKUP_DIRS[@]}"; do
    # Create a unique destination directory name based on the source name
    BASE_DIR=$(basename "$SOURCE_DIR")
    DEST_DIR="$DEST_DISK/backup_$(echo $BASE_DIR | sed 's/\//_/g')"
    BACKUP_DATE=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="$DEST_DIR/backup_$BACKUP_DATE.log"

    echo -e "\n${BLUE}--- Backup of ${SOURCE_DIR} ---${NC}"
    echo -e "${BLUE}Source:${NC} $SOURCE_DIR"
    echo -e "${BLUE}Destination:${NC} $DEST_DIR"

    # Perform the backup
    if perform_backup "$SOURCE_DIR" "$DEST_DIR" "$LOG_FILE" "$DRY_RUN" "$RSYNC_OPTIONS" "$EXCLUDE_FILE"; then
        if [ "$DRY_RUN" = false ]; then
            # Set the correct permissions for the log file
            chown "$REAL_USER:$(id -gn "$REAL_USER")" "$LOG_FILE" 2>/dev/null || true
        fi
    fi
done

echo -e "\n${GREEN}=== All backups finished at $(date) ===${NC}"

# Show space statistics
echo -e "\n${BLUE}Space used by backups:${NC}"
du -sh "$DEST_DISK"/backup_* 2>/dev/null || echo "Unable to calculate used space"

# Show remaining free space
echo -e "${BLUE}Remaining free space on $DEST_DISK:${NC}"
df -h "$DEST_DISK" | tail -1 | awk '{print $4 " available of " $2}'

echo -e "\n${YELLOW}NOTE:${NC} Original permissions and ownership have been preserved"
