# disk-usage module: directory analysis and top files
# Sourced by disk-usage.sh — do not execute directly.
show_top_files() {
    local target_dir="$1" count="$2" total_size="$3"
    echo
    echo -e "${BLUE}➤ Top $count Largest Files${NC}"
    echo "────────────────────────────────────────────"
    local tmp; tmp=$(mktemp)
    if [ "$SHOW_HIDDEN" = true ]; then
        find "$target_dir" -type f -exec du -b {} + 2>/dev/null | sort -rn | head -n "$count" > "$tmp"
    else
        find "$target_dir" -type f -not -path '*/\.*' -exec du -b {} + 2>/dev/null | sort -rn | head -n "$count" > "$tmp"
    fi
    local fc=0
    while read -r size filepath; do
        [ -z "$size" ] || [ -z "$filepath" ] && continue
        local name rel human pct
        name=$(basename "$filepath")
        rel="${filepath#"$target_dir"/}"
        human=$(human_readable "$size")
        pct=$(echo "scale=0; $size * 100 / $total_size" | bc)
        [ "$pct" = "0" ] || [ -z "$pct" ] && pct="<1"
        echo -e "${CYAN}📄 $name${NC}"
        echo -e "   Path: ${YELLOW}$rel${NC}"
        echo -e "   Size: ${GREEN}$human${NC} (${pct}% of total)"
        echo
        ((fc++))
    done < "$tmp"
    [ "$fc" -eq 0 ] && echo -e "${YELLOW}No files found.${NC}"
    rm -f "$tmp"
}

analyze_directory() {
    local target_dir="$1" depth="$2"
    [ ! -d "$target_dir" ] && { echo -e "${RED}Error: '$target_dir' does not exist!${NC}"; exit 1; }
    target_dir=$(realpath "$target_dir")

    echo -e "${BLUE}➤ Folder Analysis: ${CYAN}$target_dir${NC}"
    echo "────────────────────────────────────────────"
    echo -e "${YELLOW}⏳ Calculating sizes...${NC}"

    local total_size
    total_size=$(du -sb "$target_dir" 2>/dev/null | cut -f1)
    [ -z "$total_size" ] || [ "$total_size" = "0" ] && { echo -e "${RED}Error: cannot calculate size${NC}"; exit 1; }
    echo -e "\033[1A\033[K"

    local tmp; tmp=$(mktemp)
    if [ "$SHOW_HIDDEN" = true ]; then
        find "$target_dir" -maxdepth "$depth" -mindepth 1 -type d 2>/dev/null
    else
        find "$target_dir" -maxdepth "$depth" -mindepth 1 -type d -not -path '*/\.*' 2>/dev/null
    fi | while read -r dir; do
        local sz; sz=$(du -sb "$dir" 2>/dev/null | cut -f1)
        [ -n "$sz" ] && echo "$sz|$dir"
    done | sort -t'|' -k1 -rn > "$tmp"

    local count=0
    while IFS='|' read -r size dir; do
        [ -z "$size" ] || [ -z "$dir" ] && continue
        local dn human pct color bar
        dn=$(basename "$dir")
        human=$(human_readable "$size")
        pct=$(echo "scale=0; $size * 100 / $total_size" | bc)
        color=$(get_color "$pct")
        bar=$(generate_bar "$pct" "$BAR_WIDTH")
        echo -e "${CYAN}📁 $dn${NC}"
        echo -e "   Size: ${GREEN}$human${NC} (${pct}% of parent)"
        echo -e "   ${color}[$bar]${NC} ${pct}%"
        echo
        ((count++))
    done < "$tmp"

    echo "────────────────────────────────────────────"
    echo -e "${BLUE}📊 Total: ${GREEN}$(human_readable "$total_size")${NC}"
    echo -e "${BLUE}📂 Folders analyzed: ${GREEN}$count${NC}"
    [ "$SHOW_TOP_FILES" = true ] && show_top_files "$target_dir" "$TOP_FILES_COUNT" "$total_size"
    rm -f "$tmp"
}

# ─── HTML Report ──────────────────────────────────────────────────────────────

