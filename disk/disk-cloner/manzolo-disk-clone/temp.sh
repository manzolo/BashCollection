create_temp_file() {
    local suffix="$1"
    local temp_file="${TEMP_PREFIX}_${suffix}"
    
    if [ "$DRY_RUN" = true ]; then
        echo "$temp_file"
        return 0
    fi
    
    # Create with secure permissions
    touch "$temp_file" && chmod 600 "$temp_file"
    echo "$temp_file"
}