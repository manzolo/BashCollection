#!/bin/bash

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check arguments
if [ "$#" -ne 1 ]; then
    echo -e "${RED}Usage: $0 <cumulative_file>${NC}"
    exit 1
fi

input_file="$1"
temp_dir=".one2code_temp"
restore_dir="restored_$(date +%Y%m%d_%H%M%S)"

# Check if the file exists
if [ ! -f "$input_file" ]; then
    echo -e "${RED}Error: file '$input_file' does not exist.${NC}"
    exit 1
fi

# Create working directories
mkdir -p "$temp_dir" "$restore_dir"

echo -e "${YELLOW}Analyzing cumulative file...${NC}"

# Find all file paths and their line numbers
# The regular expression '^=== File: ' ensures it finds the start of the line
grep -n "^=== File: .* ===$" "$input_file" > "$temp_dir/file_list.txt"

# Process each file
while IFS=: read -r line_num_str filepath; do
    # Remove the prefix and suffix
    filepath=$(echo "$filepath" | sed -E 's/^=== File: (.*) ===$/\1/')
    
    # Find the start line of the next file
    next_file_line=$(grep -n "^=== File: .* ===$" "$input_file" | awk -F: '$1 > '"$line_num_str"' {print $1; exit}')

    content_start=$((line_num_str + 1))
    
    if [ -z "$next_file_line" ]; then
        # Last file: copy everything until the end
        tail -n +"$content_start" "$input_file" > "$temp_dir/content.tmp"
    else
        # Intermediate files: copy between the two marker lines
        content_end=$((next_file_line - 1))
        sed -n "${content_start},${content_end}p" "$input_file" > "$temp_dir/content.tmp"
    fi

    # Recreate the directory structure and the file
    mkdir -p "$restore_dir/$(dirname "$filepath")"
    mv "$temp_dir/content.tmp" "$restore_dir/$filepath"
    
    echo -e "${GREEN}RESTORED: $filepath${NC}"
    
done < "$temp_dir/file_list.txt"

# Cleanup and result
rm -rf "$temp_dir"
echo -e "${GREEN}\nOperation completed!${NC}"
echo -e "Files have been restored to: ${YELLOW}$restore_dir/${NC}"
