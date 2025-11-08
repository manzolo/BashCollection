show_progress() {
    local operation="$1"
    local current="$2"
    local total="$3"
    
    if [ "$total" -gt 0 ]; then
        local percent=$((current * 100 / total))
        local progress_bar=""
        local filled=$((percent / 2))
        local empty=$((50 - filled))
        
        for i in $(seq 1 $filled); do progress_bar+="█"; done
        for i in $(seq 1 $empty); do progress_bar+="░"; done
        
        printf '\r%s: [%s] %d%% (%s/%s)' \
            "$operation" "$progress_bar" "$percent" \
            "$(numfmt --to=iec --suffix=B $current)" \
            "$(numfmt --to=iec --suffix=B $total)"
    fi
}