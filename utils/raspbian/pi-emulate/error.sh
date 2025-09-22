# ==============================================================================
# ERROR HANDLING
# ==============================================================================

handle_error() {
    local exit_code=$?
    local line_num=${1:-0}
    
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 130 ]; then
        return
    fi
    
    log ERROR "Error occurred at line $line_num with exit code $exit_code"
    
    if command -v dialog &> /dev/null; then
        dialog --msgbox "An error occurred!\n\nLine: $line_num\nCode: $exit_code\n\nCheck logs for details." 10 50
    else
        echo "Error at line $line_num (exit code: $exit_code)"
    fi
}