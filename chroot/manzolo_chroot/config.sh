# Load configuration file
load_config() {
    if [[ "$USE_CONFIG" == true ]]; then
        if [[ -f "$CONFIG_FILE_PATH" ]]; then
            debug "Loading configuration from $CONFIG_FILE_PATH"
            source "$CONFIG_FILE_PATH"
        else
            error "Configuration file not found: $CONFIG_FILE_PATH"
            exit 1
        fi
    elif [[ -f "$CONFIG_FILE" ]] && [[ "$QUIET_MODE" == false ]]; then
        if dialog --title "Configuration" --yesno "Found config file. Load it?" 8 40; then
            debug "Loading default configuration file"
            source "$CONFIG_FILE"
        fi
    fi
}