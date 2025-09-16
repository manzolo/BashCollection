load_config() {
    if [[ "$USE_CONFIG" == true ]]; then
        if [[ -f "$CONFIG_FILE_PATH" ]]; then
            debug "Loading configuration from $CONFIG_FILE_PATH"
            source "$CONFIG_FILE_PATH"
            
            # Check if virtual image is specified in config
            if [[ -n "${VIRTUAL_IMAGE:-}" ]]; then
                VIRTUAL_MODE=true
            fi
        else
            error "Configuration file not found: $CONFIG_FILE_PATH"
            exit 1
        fi
    elif [[ -f "$CONFIG_FILE" ]] && [[ "$QUIET_MODE" == false ]]; then
        if command -v dialog &> /dev/null && dialog --title "Configuration" --yesno "Found config file. Load it?" 8 40; then
            debug "Loading default configuration file"
            source "$CONFIG_FILE"
            
            # Check if virtual image is specified in config
            if [[ -n "${VIRTUAL_IMAGE:-}" ]]; then
                VIRTUAL_MODE=true
            fi
        fi
    fi
}