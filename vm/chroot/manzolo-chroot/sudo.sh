# Function to run a command with sudo, preserving environment
run_with_privileges() {
    local cmd_string="$*"
    
    # Log del comando che sta per essere eseguito
    debug "EXECUTING: $cmd_string"
    
    if [[ $EUID -eq 0 ]]; then
        debug "Running as root: $cmd_string"
        "$@" 2>&1 | while IFS= read -r line; do
            debug "OUTPUT: $line"
        done
        return ${PIPESTATUS[0]}
    fi
    
    # Preserva il log file e gestisce l'output senza interferire con stdout
    local temp_log=$(mktemp)
    local temp_out=$(mktemp)
    local exit_code
    
    debug "Running with sudo: $cmd_string"
    
    # Esegui il comando catturando sia stdout che stderr separatamente
    sudo -E "$@" >"$temp_out" 2>"$temp_log" && exit_code=0 || exit_code=$?
    
    # Log dell'output se presente
    if [[ -s "$temp_out" ]]; then
        while IFS= read -r line; do
            debug "STDOUT: $line"
        done < "$temp_out"
        # Passa stdout alla funzione chiamante
        cat "$temp_out"
    fi
    
    # Log degli errori se presenti
    if [[ -s "$temp_log" ]]; then
        while IFS= read -r line; do
            debug "STDERR: $line"
        done < "$temp_log"
    fi
    
    # Cleanup
    rm -f "$temp_log" "$temp_out"
    
    if [[ $exit_code -ne 0 ]]; then
        debug "Command failed with exit code: $exit_code"
    else
        debug "Command completed successfully"
    fi
    
    return $exit_code
}