# Function to run a command with sudo, preserving environment
run_with_privileges() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
        return $?
    fi
    
    if [[ "$QUIET_MODE" == false ]] && command -v dialog &> /dev/null; then
        clear
        echo "Administrative privileges required for: $*"
        echo "Please enter your password when prompted..."
        echo
    fi
    
    sudo -E "$@"
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        debug "Failed to execute privileged command: $*"
        return 1
    fi
    return 0
}