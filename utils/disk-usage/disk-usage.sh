#!/bin/bash
# PKG_NAME: disk-usage
# PKG_VERSION: 2.1.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), coreutils (>= 8.0)
# PKG_RECOMMENDS: ncdu
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced disk usage analyzer with visual progress bars
# PKG_LONG_DESCRIPTION: Analyzes directory sizes and displays them with beautiful
#  colored progress bars and detailed statistics.
#  .
#  Features:
#  - Customizable depth levels for recursive analysis
#  - Support for hidden files and directories
#  - Top N largest files listing
#  - Beautiful colored output with progress bars
#  - Real-time size calculations
#  - Multiple sorting options
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Disk Usage Analyzer - Visualize folder sizes with progress bars
# Analyzes current directory and displays folder sizes graphically

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
MAX_DEPTH=1  # Default depth for folder analysis
BAR_WIDTH=20  # Width of progress bar
SHOW_HIDDEN=false  # Show hidden folders by default
SHOW_TOP_FILES=false  # Show top 10 largest files by default
TOP_FILES_COUNT=10  # Number of top files to display

# Function to display help
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [DIRECTORY]

Analyze and visualize folder sizes in the specified directory (or current directory).

OPTIONS:
    -d, --depth DEPTH       Maximum depth for folder analysis (default: 1)
    -w, --width WIDTH       Width of progress bar (default: 20)
    -a, --all               Include hidden folders
    -f, --files [N]         Show top N largest files (default: 10)
    -s, --sort TYPE         Sort by: size, name (default: size)
    -h, --help              Show this help message

EXAMPLES:
    $(basename "$0")                    # Analyze current directory
    $(basename "$0") /home/user         # Analyze specific directory
    $(basename "$0") -d 2 -a            # Show 2 levels deep, include hidden
    $(basename "$0") -w 30 /var/log     # Custom bar width for /var/log
    $(basename "$0") -f                 # Show top 10 largest files
    $(basename "$0") -f 20              # Show top 20 largest files

EOF
}

# Function to convert bytes to human readable format
human_readable() {
    local bytes=$1

    # Use awk for locale-independent formatting
    awk -v bytes="$bytes" 'BEGIN {
        units[0] = "B"
        units[1] = "K"
        units[2] = "M"
        units[3] = "G"
        units[4] = "T"
        units[5] = "P"

        size = bytes
        unit = 0

        while (size >= 1024 && unit < 5) {
            size = size / 1024
            unit++
        }

        # Format with comma as decimal separator for compatibility
        printf "%.1f%s", size, units[unit]
    }'
}

# Function to generate progress bar
generate_bar() {
    local percentage=$1
    local width=$2
    local filled=$(echo "scale=0; $percentage * $width / 100" | bc)
    local empty=$((width - filled))

    local bar=""

    # Filled portion
    for ((i=0; i<filled; i++)); do
        bar+="▓"
    done

    # Empty portion
    for ((i=0; i<empty; i++)); do
        bar+="░"
    done

    echo "$bar"
}

# Function to get color based on percentage
get_color() {
    local percentage=$1

    if (( $(echo "$percentage >= 90" | bc -l) )); then
        echo -e "$RED"
    elif (( $(echo "$percentage >= 70" | bc -l) )); then
        echo -e "$YELLOW"
    elif (( $(echo "$percentage >= 50" | bc -l) )); then
        echo -e "$CYAN"
    else
        echo -e "$GREEN"
    fi
}

# Function to display top largest files
show_top_files() {
    local target_dir="$1"
    local count="$2"
    local total_size="$3"

    echo
    echo -e "${BLUE}➤ Top $count Largest Files${NC}"
    echo "────────────────────────────────────────────"

    # Find top N largest files
    local temp_files=$(mktemp)

    if [ "$SHOW_HIDDEN" = true ]; then
        find "$target_dir" -type f -exec du -b {} + 2>/dev/null | sort -rn | head -n "$count" > "$temp_files"
    else
        find "$target_dir" -type f -not -path '*/\.*' -exec du -b {} + 2>/dev/null | sort -rn | head -n "$count" > "$temp_files"
    fi

    # Display each file
    local file_count=0
    while read -r size filepath; do
        if [ -n "$size" ] && [ -n "$filepath" ]; then
            local filename=$(basename "$filepath")
            local relative_path="${filepath#$target_dir/}"
            local human_size=$(human_readable "$size")
            local percentage=$(echo "scale=0; $size * 100 / $total_size" | bc)

            # Handle case where percentage is 0
            if [ "$percentage" = "0" ] || [ -z "$percentage" ]; then
                percentage="<1"
            fi

            local color=$(get_color "$percentage")

            echo -e "${CYAN}📄 $filename${NC}"
            echo -e "   Path: ${YELLOW}$relative_path${NC}"
            echo -e "   Size: ${GREEN}$human_size${NC} (${percentage}% of total)"
            echo

            ((file_count++))
        fi
    done < "$temp_files"

    if [ "$file_count" -eq 0 ]; then
        echo -e "${YELLOW}No files found in this directory.${NC}"
        echo
    fi

    # Cleanup
    rm -f "$temp_files"
}

# Function to analyze directory
analyze_directory() {
    local target_dir="$1"
    local depth=$2

    # Check if directory exists
    if [ ! -d "$target_dir" ]; then
        echo -e "${RED}Error: Directory '$target_dir' does not exist!${NC}"
        exit 1
    fi

    # Get absolute path
    target_dir=$(realpath "$target_dir")

    echo -e "${BLUE}➤ Folder Analysis: ${CYAN}$target_dir${NC}"
    echo "────────────────────────────────────────────"

    # Get total size of the directory
    echo -e "${YELLOW}⏳ Calculating sizes...${NC}"
    local total_size
    total_size=$(du -sb "$target_dir" 2>/dev/null | cut -f1)

    if [ -z "$total_size" ] || [ "$total_size" = "0" ]; then
        echo -e "${RED}Error: Cannot calculate directory size (permission denied?)${NC}"
        exit 1
    fi

    # Clear the calculating message
    echo -e "\033[1A\033[K"

    # Get subdirectories with their sizes
    local temp_file=$(mktemp)

    if [ "$SHOW_HIDDEN" = true ]; then
        find "$target_dir" -maxdepth $depth -mindepth 1 -type d 2>/dev/null | while read -r dir; do
            local size=$(du -sb "$dir" 2>/dev/null | cut -f1)
            if [ -n "$size" ]; then
                echo "$size|$dir"
            fi
        done | sort -t'|' -k1 -rn > "$temp_file"
    else
        find "$target_dir" -maxdepth $depth -mindepth 1 -type d -not -path '*/\.*' 2>/dev/null | while read -r dir; do
            local size=$(du -sb "$dir" 2>/dev/null | cut -f1)
            if [ -n "$size" ]; then
                echo "$size|$dir"
            fi
        done | sort -t'|' -k1 -rn > "$temp_file"
    fi

    # Display each subdirectory
    local count=0
    while IFS='|' read -r size dir; do
        if [ -n "$size" ] && [ -n "$dir" ]; then
            local dir_name=$(basename "$dir")
            local human_size=$(human_readable "$size")
            local percentage=$(echo "scale=0; $size * 100 / $total_size" | bc)

            local color=$(get_color "$percentage")
            local bar=$(generate_bar "$percentage" "$BAR_WIDTH")

            echo -e "${CYAN}📁 $dir_name${NC}"
            echo -e "   Size: ${GREEN}$human_size${NC} (${percentage}% of parent)"
            echo -e "   ${color}[$bar]${NC} ${percentage}%"
            echo

            ((count++))
        fi
    done < "$temp_file"

    # Show total
    echo "────────────────────────────────────────────"
    local human_total=$(human_readable "$total_size")
    echo -e "${BLUE}📊 Total: ${GREEN}$human_total${NC}"
    echo -e "${BLUE}📂 Folders analyzed: ${GREEN}$count${NC}"

    # Show top files if requested
    if [ "$SHOW_TOP_FILES" = true ]; then
        show_top_files "$target_dir" "$TOP_FILES_COUNT" "$total_size"
    fi

    # Cleanup
    rm -f "$temp_file"
}

# Parse command line arguments
TARGET_DIR="."
SORT_TYPE="size"

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--depth)
            MAX_DEPTH="$2"
            shift 2
            ;;
        -w|--width)
            BAR_WIDTH="$2"
            shift 2
            ;;
        -a|--all)
            SHOW_HIDDEN=true
            shift
            ;;
        -f|--files)
            SHOW_TOP_FILES=true
            # Check if next argument is a number
            if [[ $2 =~ ^[0-9]+$ ]]; then
                TOP_FILES_COUNT="$2"
                shift 2
            else
                shift
            fi
            ;;
        -s|--sort)
            SORT_TYPE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            # Assume it's the target directory
            if [ -d "$1" ]; then
                TARGET_DIR="$1"
            else
                echo -e "${RED}Error: Unknown option or invalid directory: $1${NC}"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# Run the analysis
analyze_directory "$TARGET_DIR" "$MAX_DEPTH"
