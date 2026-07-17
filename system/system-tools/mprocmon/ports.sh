# mprocmon module: port inspection (lsof and ss)
# Sourced by mprocmon.sh — do not execute directly.
show_ports_lsof() {
    local temp_file="$TEMP_DIR/port_choice"
    local output_file="$TEMP_DIR/port_output"
    
    log_message "INFO" "Starting lsof port scan"
    
    if ! whiptail --title "Port Scanner Options (lsof)" --menu "Choose scanning method:" 16 70 6 \
        "1" "All open ports with detailed info" \
        "2" "TCP ports only (listening + established)" \
        "3" "UDP ports only" \
        "4" "Specific port analysis" \
        "5" "Ports by specific process" \
        "6" "Export results to file" 2> "$temp_file"; then
        return 0
    fi

    local choice
    choice=$(cat "$temp_file")

    {
        print_color "$CYAN" "=== lsof Port Analysis ==="
        echo "Timestamp: $(date)"
        echo "Analysis type: Choice $choice"
        echo ""
        
        case $choice in
            1)
                print_color "$YELLOW" "Scanning all open ports..."
                if ! lsof -i -P -n | awk '
                    BEGIN {
                        printf "%-12s %-8s %-6s %-8s %-22s %-22s %s\n",
                               "COMMAND", "PID", "USER", "TYPE", "LOCAL_ADDRESS", "FOREIGN_ADDRESS", "STATE"
                        printf "%s\n", "="*90
                    }
                    NR>1 {
                        printf "%-12s %-8s %-6s %-8s %-22s %-22s %s\n",
                               substr($1,1,12), $2, $3, $5, $9, $10, $8
                    }' 2>/dev/null; then
                    print_color "$RED" "Failed to retrieve port information"
                fi
                ;;
            2)
                print_color "$YELLOW" "Scanning TCP ports..."
                lsof -i tcp -P -n | awk 'NR==1 {print} NR>1 {print | "sort -k9,9"}' 2>/dev/null || 
                    print_color "$RED" "Failed to retrieve TCP port information"
                ;;
            3)
                print_color "$YELLOW" "Scanning UDP ports..."
                lsof -i udp -P -n | awk 'NR==1 {print} NR>1 {print | "sort -k9,9"}' 2>/dev/null ||
                    print_color "$RED" "Failed to retrieve UDP port information"
                ;;
            4)
                local port
                port=$(whiptail --inputbox "Enter port number (1-65535):" 10 50 3>&1 1>&2 2>&3) || true
                if validate_port "$port"; then
                    print_color "$YELLOW" "Analyzing port $port..."
                    echo "Processes using port $port:"
                    lsof -i ":$port" -P -n 2>/dev/null || echo "No processes found using port $port"
                    echo ""
                    echo "Socket information:"
                    ss -tulpn | grep ":$port " || echo "No socket information found"
                else
                    print_color "$RED" "Invalid port number: $port"
                fi
                ;;
            5)
                local process_name
                process_name=$(whiptail --inputbox "Enter process name:" 10 50 3>&1 1>&2 2>&3) || true
                if [[ -n "$process_name" ]]; then
                    print_color "$YELLOW" "Finding ports used by: $process_name"
                    local pids
                    pids=$(pgrep "$process_name" 2>/dev/null)
                    if [[ -n "$pids" ]]; then
                        for pid in $pids; do
                            echo "--- Process: $process_name (PID: $pid) ---"
                            lsof -i -P -n -p "$pid" 2>/dev/null || echo "No network connections for PID $pid"
                            echo ""
                        done
                    else
                        print_color "$RED" "No running processes found matching: $process_name"
                    fi
                else
                    print_color "$RED" "No process name provided"
                fi
                ;;
            6)
                local export_file
                export_file="$LOG_DIR/ports_lsof_$(date +%Y%m%d_%H%M%S).txt"
                print_color "$YELLOW" "Exporting complete port analysis to: $export_file"
                {
                    echo "Complete lsof port analysis - $(date)"
                    echo "========================================"
                    echo ""
                    lsof -i -P -n
                } > "$export_file" 2>/dev/null
                print_color "$GREEN" "Export completed: $export_file"
                ;;
        esac
    } | tee "$output_file"
    
    echo ""
    print_color "$GREEN" "Analysis completed. Press Enter to continue..."
    read -r
    
    log_message "INFO" "lsof port scan completed - choice: $choice"
}

# Enhanced port scanning with ss
show_ports_ss() {
    local temp_file="$TEMP_DIR/ss_choice"
    
    log_message "INFO" "Starting ss port scan"
    
    # Check if ss is executable and user has sufficient permissions
    if ! command -v ss &> /dev/null; then
        print_color "$RED" "Error: 'ss' command not found"
        log_message "ERROR" "ss command not found"
        return 1
    fi
    if ! ss -tuln &> /dev/null; then
        print_color "$RED" "Error: Insufficient permissions to run 'ss'. Try running as root."
        log_message "ERROR" "Insufficient permissions for ss"
        return 1
    fi
    
    if ! whiptail --title "SS Port Scanner Options" --menu "Choose scanning method:" 16 70 6 \
        "1" "All listening ports (detailed)" \
        "2" "TCP listening ports with processes" \
        "3" "UDP listening ports with processes" \
        "4" "All connections with statistics" \
        "5" "Specific port/service analysis" \
        "6" "Network interface statistics" 2> "$temp_file"; then
        return 0
    fi
    
    local choice
    choice=$(cat "$temp_file")
    
    {
        print_color "$CYAN" "=== ss Network Analysis ==="
        echo "Timestamp: $(date)"
        echo "Analysis type: Choice $choice"
        echo ""
        
        case $choice in
            1)
                print_color "$YELLOW" "Retrieving all listening ports..."
                ss -tulpn -o | column -t 2>/dev/null || 
                    print_color "$RED" "Failed to retrieve listening ports"
                ;;
            2)
                print_color "$YELLOW" "TCP listening ports with process information..."
                ss -tlpn -o | awk 'BEGIN {print "State\tLocal Address:Port\tProcess"} 
                                   NR>1 {print $1 "\t" $4 "\t" $7}' | column -t 2>/dev/null || 
                    print_color "$RED" "Failed to retrieve TCP listening ports"
                ;;
            3)
                print_color "$YELLOW" "UDP listening ports with process information..."
                ss -ulpn -o | awk 'BEGIN {print "State\tLocal Address:Port\tProcess"} 
                                   NR>1 {print $1 "\t" $4 "\t" $7}' | column -t 2>/dev/null || 
                    print_color "$RED" "Failed to retrieve UDP listening ports"
                ;;
            4)
                print_color "$YELLOW" "All connections with statistics..."
                ss -tupln -i -e | head -n 50 2>/dev/null || 
                    print_color "$RED" "Failed to retrieve connections"
                echo ""
                echo "Connection summary:"
                ss -s 2>/dev/null || print_color "$RED" "Failed to retrieve connection summary"
                ;;
            5)
                local port
                port=$(whiptail --inputbox "Enter port number or service name:" 10 50 3>&1 1>&2 2>&3) || true
                if [[ -n "$port" ]]; then
                    print_color "$YELLOW" "Analyzing port/service: $port"
                    ss -tulpn | grep -i -- "$port" 2>/dev/null || echo "No connections found for: $port"
                    echo ""
                    echo "Netstat comparison:"
                    netstat -tulpn 2>/dev/null | grep -i -- "$port" || echo "No netstat data found"
                fi
                ;;
            6)
                print_color "$YELLOW" "Network interface statistics..."
                ss -i 2>/dev/null || print_color "$RED" "Failed to retrieve interface statistics"
                echo ""
                echo "Interface summary:"
                ip -s link show 2>/dev/null || print_color "$RED" "Failed to retrieve interface summary"
                ;;
        esac
    } | less -R  # Use -R to handle ANSI colors correctly
    
    log_message "INFO" "ss port scan completed - choice: $choice"
}

# Enhanced process analysis
