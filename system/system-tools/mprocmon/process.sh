# mprocmon module: process analysis, file locks, file search
# Sourced by mprocmon.sh — do not execute directly.
analyze_process() {
    local pid
    pid=$(whiptail --inputbox "Enter PID:" 10 40 3>&1 1>&2 2>&3) || true
    
    if ! validate_pid "$pid"; then
        whiptail --msgbox "Invalid PID format: $pid" 8 40
        return 0
    fi
    
    if ! kill -0 "$pid" 2>/dev/null; then
        whiptail --msgbox "Process with PID $pid does not exist or access denied" 8 50
        return 0
    fi
    
    log_message "INFO" "Analyzing process PID: $pid"
    
    # Disabilita temporaneamente pipefail per evitare l'uscita da `less`
    set +o pipefail
    
    {
        print_color "$CYAN" "=== Complete Process Analysis for PID $pid ==="
        echo "Timestamp: $(date)"
        echo ""
        
        print_color "$YELLOW" "Basic Process Information:"
        ps -fp "$pid" 2>/dev/null || echo "Cannot retrieve process information"
        echo ""
        
        print_color "$YELLOW" "Process Tree:"
        ps -ejH | grep -E "(PPID|$pid)" | head -10 2>/dev/null || echo "Cannot retrieve process tree"
        echo ""
        
        print_color "$YELLOW" "Memory Usage:"
        ps -o pid,ppid,vsz,rss,pmem,comm -p "$pid" 2>/dev/null || echo "Cannot retrieve memory usage"
        echo ""
        
        print_color "$YELLOW" "Open Files (first 20):"
        lsof -p "$pid" 2>/dev/null | head -20 || echo "Cannot access open files for PID $pid"
        echo ""
        
        print_color "$YELLOW" "Network Connections:"
        lsof -i -a -p "$pid" 2>/dev/null || echo "No network connections found"
        echo ""
        
        print_color "$YELLOW" "Process Status:"
        if [[ -r "/proc/$pid/status" ]]; then
            cat "/proc/$pid/status" | head -20 2>/dev/null || echo "Cannot read /proc/$pid/status"
        else
            echo "Cannot read /proc/$pid/status"
        fi
        
    } | less -R  # Use -R to handle ANSI colors correctly
    
    # Riabilita pipefail
    set -o pipefail
    
    log_message "INFO" "Process analysis completed for PID: $pid"
    return 0
}

# Enhanced file lock checker
check_file_locks() {
    local file_path
    file_path=$(whiptail --inputbox "Enter file path:" 10 60 3>&1 1>&2 2>&3) || true

    if [[ -z "$file_path" ]]; then
        whiptail --msgbox "No file path provided" 8 40
        log_message "ERROR" "No file path provided"
        return 0
    fi

    log_message "INFO" "Checking file locks for: $file_path"
    
    # Verifica se lsof è disponibile
    if ! command -v lsof &> /dev/null; then
        whiptail --msgbox "Error: 'lsof' command not found" 8 40
        log_message "ERROR" "lsof command not found"
        return 0
    fi

    # Disabilita temporaneamente pipefail per evitare l'uscita da `less`
    set +o pipefail
    
    {
        print_color "$CYAN" "=== File Lock Analysis: $file_path ==="
        echo "Timestamp: $(date)"
        echo ""
        
        # Aggiungi un messaggio chiaro per l'utente in caso di file non trovato
        if [[ ! -e "$file_path" ]]; then
            print_color "$RED" "File does not exist or access denied: $file_path"
            echo ""
            log_message "ERROR" "File does not exist: $file_path"
        else
            print_color "$YELLOW" "File Information:"
            ls -la "$file_path" 2>/dev/null || echo "Cannot retrieve file information"
            echo ""

            print_color "$YELLOW" "File Type Analysis:"
            file "$file_path" 2>/dev/null || echo "Cannot determine file type"
            echo ""

            print_color "$YELLOW" "Processes Using This File:"
            # PROTEGGI il command substitution: evita che set -e termini lo script
            local lsof_result
            lsof_result=$(lsof "$file_path" 2>/dev/null || true)

            if [[ -n "$lsof_result" ]]; then
                echo "$lsof_result"
                echo ""

                print_color "$YELLOW" "Detailed Process Analysis:"
                local pids
                pids=$(echo "$lsof_result" | tail -n +2 | awk '{print $2}' | sort -u)
                for pid in $pids; do
                    print_color "$BLUE" "--- Process Details for PID $pid ---"
                    ps -fp "$pid" 2>/dev/null || echo "Process $pid no longer exists"

                    # Proteggi anche qui (lsof può fallire)
                    local write_mode
                    write_mode=$(lsof "$file_path" 2>/dev/null | awk -v pid="$pid" '$2==pid {print $4}' | grep -o 'w' || true)
                    if [[ -n "$write_mode" ]]; then
                        print_color "$RED" "  -> File is open for WRITING by this process"
                    fi
                    echo ""
                done
            else
                print_color "$GREEN" "No processes are currently using this file"
                echo ""
                print_color "$YELLOW" "Recent File Access (if available):"
                if command -v fuser &> /dev/null; then
                    # fuser può anche restituire non-zero: usiamo || true oppure || echo
                    fuser "$file_path" 2>/dev/null || echo "No processes accessing file (fuser)"
                fi
            fi

            if [[ -r /proc/locks ]]; then
                echo ""
                print_color "$YELLOW" "System File Locks:"
                grep "$file_path" /proc/locks 2>/dev/null || echo "No system locks found for this file"
            fi
        fi
    } > "$TEMP_DIR/file_locks.txt"

    # Mostra con less sul tty (fallback a whiptail)
    if ! less -R "$TEMP_DIR/file_locks.txt" </dev/tty >/dev/tty 2>/dev/tty; then
        whiptail --textbox "$TEMP_DIR/file_locks.txt" 25 90
    fi
    
    # Riabilita pipefail
    set -o pipefail

    log_message "INFO" "File lock analysis completed for: $file_path"
    return 0
}

# Enhanced process file search
search_files_by_process() {
    local process_input
    process_input=$(whiptail --inputbox "Enter process name or PID:" 10 50 3>&1 1>&2 2>&3) || true

    if [[ -z "$process_input" ]]; then
        whiptail --msgbox "No process identifier provided" 8 40
        log_message "ERROR" "No process identifier provided"
        return 0
    fi

    log_message "INFO" "Searching files for process: $process_input"

    # Verifica se lsof è disponibile
    if ! command -v lsof &> /dev/null; then
        whiptail --msgbox "Error: 'lsof' command not found" 8 40
        log_message "ERROR" "lsof command not found"
        return 0
    fi
    
    local pids=()
    local message=""

    if [[ "$process_input" =~ ^[0-9]+$ ]]; then
        # Input = PID
        log_message "DEBUG" "Checking PID: $process_input"
        if kill -0 "$process_input" 2>/dev/null; then
            pids=("$process_input")
            message="Found process with PID: $process_input"
            print_color "$GREEN" "$message"
        else
            message="Process with PID $process_input not found or access denied"
            whiptail --msgbox "$message" 8 50
            log_message "ERROR" "$message"
            return 0
        fi
    else
        # Input = nome processo
        log_message "DEBUG" "Running pgrep for process name: $process_input"
        mapfile -t pids < <(pgrep "$process_input" 2>/dev/null)
        if [[ ${#pids[@]} -eq 0 ]]; then
            message="No running processes found matching: $process_input"
            whiptail --msgbox "$message" 8 50
            log_message "ERROR" "$message"
            return 0
        else
            message="Found ${#pids[@]} process(es) matching: $process_input"
            print_color "$GREEN" "$message"
            log_message "DEBUG" "Found ${#pids[@]} process(es): ${pids[*]}"
        fi
    fi

    # Disabilita temporaneamente pipefail per evitare l'uscita da `less`
    set +o pipefail
    
    {
        print_color "$CYAN" "=== Files Analysis for: $process_input ==="
        echo "Timestamp: $(date)"
        echo ""

        if [[ ${#pids[@]} -eq 0 ]]; then
            print_color "$RED" "No processes to analyze."
            echo ""
        else
            for pid in "${pids[@]}"; do
                log_message "DEBUG" "Processing PID: $pid"
                
                # Ottiene il nome esatto del processo
                local specific_process_name
                specific_process_name=$(ps -o comm= -p "$pid" 2>/dev/null || echo "N/A")
                print_color "$BLUE" "=== Files for Process: $specific_process_name (PID: $pid) ==="

                # Info processo
                print_color "$YELLOW" "Process Information:"
                ps -fp "$pid" 2>/dev/null || {
                    print_color "$RED" "Cannot retrieve process information for PID $pid"
                    log_message "ERROR" "Cannot retrieve process information for PID $pid"
                    continue
                }
                echo ""

                # File aperti
                local temp_lsof="$TEMP_DIR/lsof_$pid"
                log_message "DEBUG" "Running lsof -p $pid"
                lsof -p "$pid" 2>/dev/null > "$temp_lsof" || {
                    print_color "$RED" "Cannot access files for PID $pid (check permissions)"
                    log_message "ERROR" "Cannot access files for PID $pid"
                    continue
                }

                print_color "$YELLOW" "File Categories:"

                # Regular files
                local reg_files
                reg_files=$(awk '$5=="REG" {print $9}' "$temp_lsof" | head -10)
                if [[ -n "$reg_files" ]]; then
                    echo "Regular Files (first 10):"
                    echo "$reg_files"
                    echo ""
                else
                    echo "Regular Files: None found"
                    echo ""
                fi

                # Network connections
                local net_connections
                net_connections=$(awk '$5~/IPv[46]/ {print $8, $9}' "$temp_lsof")
                if [[ -n "$net_connections" ]]; then
                    echo "Network Connections:"
                    echo "$net_connections"
                    echo ""
                else
                    echo "Network Connections: None found"
                    echo ""
                fi

                # Pipes e sockets
                local pipes_sockets
                pipes_sockets=$(awk '$5~/FIFO|unix|sock/ {print $5, $9}' "$temp_lsof")
                if [[ -n "$pipes_sockets" ]]; then
                    echo "Pipes and Sockets:"
                    echo "$pipes_sockets"
                    echo ""
                else
                    echo "Pipes and Sockets: None found"
                    echo ""
                fi

                rm -f "$temp_lsof" 2>/dev/null
                echo "----------------------------------------"
            done
        fi
        
        print_color "$GREEN" "Analysis completed. Press q to return to the main menu..."
    } | less -R

    # Riabilita pipefail
    set -o pipefail

    log_message "INFO" "File search completed for process: $process_input"
    return 0
}

# System overview with enhanced metrics
