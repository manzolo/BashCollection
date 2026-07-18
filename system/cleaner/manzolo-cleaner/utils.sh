# manzolo-cleaner module: logging, dependencies, terminal command runner
# Sourced by manzolo-cleaner.sh — do not execute directly.
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
}

# Function to check dependencies
check_dependencies() {
    local missing_deps=()
    
    # Check for dialog
    if ! command -v dialog &> /dev/null; then
        missing_deps+=("dialog")
    fi
    
    # Check for sudo
    if ! command -v sudo &> /dev/null; then
        missing_deps+=("sudo")
    fi

    # Check for bc (used in space calculation)
    if ! command -v bc &> /dev/null; then
        missing_deps+=("bc")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}Missing dependencies:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo "- $dep"
        done
        echo -e "\n${YELLOW}Please install the missing dependencies (e.g., sudo apt install dialog bc) before continuing.${NC}"
        exit 1
    fi
}

# Improved function to run commands and save output (fixed for multiline)
run_command_in_terminal() {
    local title="$1"
    local command="$2"
    local show_output="${3:-true}"
    local calculate_space="${4:-false}"  # New: Option to calculate space freed
    
    log_message "INFO" "Executing command: $command"

    # Cache sudo credentials on a clean screen BEFORE drawing any dialog:
    # otherwise the password prompt appears over the half-drawn TUI.
    if [[ $command == *sudo* ]] && ! sudo -n true 2>/dev/null; then
        clear
        echo "── $title ──"
        echo "This operation requires administrator privileges."
        echo
        if ! sudo -v; then
            dialog --title "$title" --msgbox "Authentication failed or cancelled.\nOperation aborted." 7 50
            return 1
        fi
    fi

    # Clear the temporary file before writing
    : > "$TEMP_OUTPUT"
    
    # For complex/multiline commands, write to a temp script file
    if [[ $command == *'{'* || $command == *';'* ]]; then
        echo "#!/bin/bash" > "$TEMP_COMMAND"
        echo "$command" >> "$TEMP_COMMAND"
        chmod +x "$TEMP_COMMAND"
        actual_cmd="$TEMP_COMMAND"
    else
        actual_cmd="$command"
    fi
    
    # Show a waiting message. Never print the raw command here: multi-line
    # pipelines overflow the box and read as garbage — the full command is
    # already recorded in $LOG_FILE.
    dialog --title "$title" --infobox "Executing: $title\n\nPlease wait — this may take a while..." 7 60
    
    # Execute the command and save the output
    local before_space=0
    if [ "$calculate_space" = "true" ]; then
        before_space=$(df / --output=used | tail -1 | sed 's/ //g')  # Bytes used on root
    fi
    
    if [ "$show_output" = "true" ]; then
        if [[ $command == *'{'* || $command == *';'* ]]; then
            # shellcheck disable=SC1090  # dynamic temp file built at runtime
            . "$TEMP_COMMAND" >> "$TEMP_OUTPUT" 2>&1
        else
            eval "$actual_cmd" >> "$TEMP_OUTPUT" 2>&1
        fi
    else
        if [[ $command == *'{'* || $command == *';'* ]]; then
            # shellcheck disable=SC1090
            . "$TEMP_COMMAND" >> "$LOG_FILE" 2>&1
        else
            eval "$actual_cmd" >> "$LOG_FILE" 2>&1
        fi
    fi
    local status=$?

    # Calculate space freed if requested
    local space_msg=""
    if [ "$calculate_space" = "true" ]; then
        local after_space
        after_space=$(df / --output=used | tail -1 | sed 's/ //g')
        local freed=$((before_space - after_space))
        if [ $freed -gt 0 ]; then
            space_msg="\nSpace freed: $(calculate_space_freed $freed)"
        fi
    fi
    
    # Log the output
    if [ "$show_output" = "true" ]; then
        cat "$TEMP_OUTPUT" >> "$LOG_FILE" 2>/dev/null
    fi
    
    # Clean up temp command file
    rm -f "$TEMP_COMMAND"
    
    # Show the output in a dialog window
    if [ "$show_output" = "true" ]; then
        if [ -s "$TEMP_OUTPUT" ]; then
            dialog --title "$title - Output" --textbox "$TEMP_OUTPUT" 20 80
        else
            dialog --title "$title" --msgbox "No output produced by the command." 6 50
        fi
    fi
    
    # Show status message with space info
    if [ $status -eq 0 ]; then
        dialog --title "$title" --msgbox "Operation completed successfully.$space_msg" 8 60
    else
        dialog --title "$title" --msgbox "Error during command execution.\nCheck the log: $LOG_FILE" 8 60
        log_message "ERROR" "Error executing: $command"
    fi
}

# Function to calculate space freed (unchanged, but now checked)
calculate_space_freed() {
    local freed="$1"
    
    if [ $freed -gt 1073741824 ]; then
        echo "$(echo "scale=2; $freed / 1073741824" | bc) GB"
    elif [ $freed -gt 1048576 ]; then
        echo "$(echo "scale=2; $freed / 1048576" | bc) MB"
    else
        echo "$(echo "scale=2; $freed / 1024" | bc) KB"
    fi
}

# Function to check if Docker is installed and running (unchanged)
