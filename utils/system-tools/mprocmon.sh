#!/bin/bash
# PKG_NAME: mprocmon
# PKG_VERSION: 2.0.1
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), inotify-tools, net-tools, lsof
# PKG_RECOMMENDS: iftop, nethogs, iotop
# PKG_ALIASES: manzolo-process-monitor
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced network and file system monitor
# PKG_LONG_DESCRIPTION: Interactive tool for monitoring network connections
#  and file system changes in real-time.
#  .
#  Features:
#  - Real-time network connection monitoring
#  - File system change detection with inotify
#  - Process monitoring and tracking
#  - Bandwidth usage statistics
#  - Connection filtering and analysis
#  - Logging and reporting
#  - Interactive TUI interface
#  - Configuration file support
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Network and File Monitor Script
# Author: System Administrator
# Version: 2.0
# Description: Advanced interactive tool for network and file system monitoring
# Last Updated: $(date +%Y-%m-%d)

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Global configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.0"
readonly LOG_DIR="/tmp/${SCRIPT_NAME%.*}_logs"
readonly LOG_FILE="${LOG_DIR}/monitor_$(date +%Y%m%d_%H%M%S).log"
readonly CONFIG_FILE="$HOME/.netmonitor.conf"
readonly TEMP_DIR="/tmp/${SCRIPT_NAME%.*}_$$"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# Initialize environment
init_environment() {
    # Create necessary directories
    mkdir -p "$LOG_DIR" "$TEMP_DIR"
    
    # Set trap for cleanup
    trap cleanup EXIT INT TERM
    
    # Initialize log file
    log_message "INFO" "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    log_message "INFO" "PID: $$, User: $(whoami), Date: $(date)"
}

# Cleanup function
cleanup() {
    local exit_code=$?
    log_message "INFO" "Cleaning up temporary files"
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    exit $exit_code
}

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Print colored output
print_color() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Error handling function
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"
    
    print_color "$RED" "ERROR: $error_message"
    log_message "ERROR" "$error_message"
    
    whiptail --title "Error" --msgbox "$error_message" 10 60
    exit "$exit_code"
}

# Check dependencies
check_dependencies() {
    local dependencies=("whiptail" "lsof" "ss" "netstat" "ps")
    local missing_deps=()
    
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        local install_msg="Missing dependencies: ${missing_deps[*]}\n\n"
        install_msg+="Installation commands:\n"
        install_msg+="Ubuntu/Debian: sudo apt-get install whiptail lsof iproute2 net-tools procps\n"
        install_msg+="CentOS/RHEL: sudo yum install newt lsof iproute net-tools procps-ng\n"
        install_msg+="Fedora: sudo dnf install newt lsof iproute net-tools procps-ng"
        
        handle_error "$install_msg"
    fi
    
    log_message "INFO" "All dependencies satisfied"
}

# Validate input functions
validate_pid() {
    local pid="$1"
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" -le 0 ]]; then
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        return 1
    fi
    return 0
}

validate_file_path() {
    local path="$1"
    if [[ -z "$path" ]] || [[ ! "$path" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
        return 1
    fi
    return 0
}

# Enhanced port scanning with lsof
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
    
    local choice=$(cat "$temp_file")
    
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
                port=$(whiptail --inputbox "Enter port number (1-65535):" 10 50 3>&1 1>&2 2>&3)
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
                process_name=$(whiptail --inputbox "Enter process name:" 10 50 3>&1 1>&2 2>&3)
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
                local export_file="$LOG_DIR/ports_lsof_$(date +%Y%m%d_%H%M%S).txt"
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
                port=$(whiptail --inputbox "Enter port number or service name:" 10 50 3>&1 1>&2 2>&3)
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
analyze_process() {
    local pid
    pid=$(whiptail --inputbox "Enter PID:" 10 40 3>&1 1>&2 2>&3)
    
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
    file_path=$(whiptail --inputbox "Enter file path:" 10 60 3>&1 1>&2 2>&3)

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
    process_input=$(whiptail --inputbox "Enter process name or PID:" 10 50 3>&1 1>&2 2>&3)

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
show_system_overview() {
    log_message "INFO" "Generating system overview"
    
    {
        print_color "$CYAN" "=== System Overview ==="
        echo "Generated: $(date)"
        echo "Hostname: $(hostname)"
        echo "Uptime: $(uptime)"
        echo ""
        
        print_color "$YELLOW" "Network Summary:"
        echo "Active listening ports: $(ss -tln 2>/dev/null | wc -l)"
        echo "Established connections: $(ss -t state established 2>/dev/null | wc -l)"
        echo "Active interfaces:"
        ip -o link show 2>/dev/null | awk '{print $2, $3}' | column -t || echo "Cannot retrieve interface information"
        echo ""
        
        print_color "$YELLOW" "Top Network Processes:"
        lsof -i -P -n 2>/dev/null | awk 'NR>1 {count[$1]++} END {for(cmd in count) printf "%-15s %d\n", cmd, count[cmd]}' | sort -k2 -nr | head -5 || echo "Cannot retrieve network processes"
        echo ""
        
        print_color "$YELLOW" "Memory Usage Summary:"
        free -h 2>/dev/null || echo "Cannot retrieve memory usage"
        echo ""
        
        print_color "$YELLOW" "Top Processes by CPU:"
        ps aux --sort=-%cpu --no-headers 2>/dev/null | head -5 | awk '{printf "%-12s %5s %5s %s\n", $11, $3"%", $4"%", $2}' || echo "Cannot retrieve CPU usage"
        echo ""
        
        print_color "$YELLOW" "Top Processes by Memory:"
        ps aux --sort=-%mem --no-headers 2>/dev/null | head -5 | awk '{printf "%-12s %5s %5s %s\n", $11, $3"%", $4"%", $2}' || echo "Cannot retrieve memory usage"
        echo ""
        
        print_color "$YELLOW" "Disk Usage:"
        df -h 2>/dev/null | head -5 || echo "Cannot retrieve disk usage"
        echo ""
        
        print_color "$YELLOW" "Load Average and Process Count:"
        echo "Load: $(cat /proc/loadavg 2>/dev/null || echo "Cannot read load average")"
        echo "Running processes: $(ps aux 2>/dev/null | wc -l)"
        echo "Zombie processes: $(ps aux 2>/dev/null | awk '$8 ~ /^Z/ {count++} END {print count+0}')"
        
    } | less -R  # Use -R to handle ANSI colors correctly
    
    log_message "INFO" "System overview completed"
}

# Show help information
show_help() {
    whiptail --title "Manzolo Network & File Monitor - Help" --msgbox \
"Network and File Monitor v$SCRIPT_VERSION

FEATURES:
• Advanced port scanning with lsof and ss
• Comprehensive process analysis
• File lock detection and monitoring
• Process-file relationship mapping
• logging and error handling
• Data export capabilities

MENU OPTIONS:
1. lsof Port Analysis - Detailed network connection analysis
2. ss Network Analysis - Fast socket statistics
3. Process Analysis - Complete process information
4. File Lock Analysis - Check file usage and locks
5. Process File Search - Find files used by processes
6. System Overview - Comprehensive system status
7. Log Viewer - View application logs
8. Configuration - Adjust settings

TIPS:
• All activities are logged in $LOG_DIR
• Use export functions to save analysis results
• Requires appropriate permissions for full functionality
• Use Ctrl+C to interrupt long operations

REQUIREMENTS:
• whiptail, lsof, ss, netstat, ps, ip commands
• Read permissions for /proc filesystem
• Network monitoring capabilities

LOG LOCATION: $LOG_FILE" 25 75
}

# Configuration management
manage_configuration() {
    local temp_file="$TEMP_DIR/config_choice"
    
    if whiptail --title "Configuration Management" --menu "Choose option:" 15 60 4 \
        "1" "View current configuration" \
        "2" "Reset to defaults" \
        "3" "View log directory" \
        "4" "Clear old logs" 2> "$temp_file"; then
        
        local choice=$(cat "$temp_file")
        
        case $choice in
            1)
                {
                    echo "Current Configuration:"
                    echo "====================="
                    echo "Script Version: $SCRIPT_VERSION"
                    echo "Log Directory: $LOG_DIR"
                    echo "Config File: $CONFIG_FILE"
                    echo "Temp Directory: $TEMP_DIR"
                    echo "Current User: $(whoami)"
                    echo "System: $(uname -a)"
                } | whiptail --textbox /dev/stdin 20 70
                ;;
            2)
                whiptail --yesno "Reset all configuration to defaults?" 8 40 && {
                    rm -f "$CONFIG_FILE"
                    whiptail --msgbox "Configuration reset to defaults" 8 40
                }
                ;;
            3)
                ls -la "$LOG_DIR" | whiptail --textbox /dev/stdin 20 80
                ;;
            4)
                local old_logs
                old_logs=$(find "$LOG_DIR" -name "*.log" -mtime +7 2>/dev/null | wc -l)
                if [[ "$old_logs" -gt 0 ]]; then
                    if whiptail --yesno "Delete $old_logs log files older than 7 days?" 8 50; then
                        find "$LOG_DIR" -name "*.log" -mtime +7 -delete
                        whiptail --msgbox "Old log files deleted" 8 30
                    fi
                else
                    whiptail --msgbox "No old log files found" 8 30
                fi
                ;;
        esac
    fi
}

# View logs function
view_logs() {
    local log_files=()
    
    # Get list of log files
    while IFS= read -r -d '' file; do
        log_files+=("$(basename "$file")" "$(date -r "$file" '+%Y-%m-%d %H:%M')")
    done < <(find "$LOG_DIR" -name "*.log" -type f -print0 2>/dev/null | head -20)
    
    if [[ ${#log_files[@]} -eq 0 ]]; then
        whiptail --msgbox "No log files found in $LOG_DIR" 8 50
        return 0
    fi
    
    local temp_file="$TEMP_DIR/log_choice"
    
    if whiptail --title "Log Viewer" --menu "Select log file:" 20 70 10 "${log_files[@]}" 2> "$temp_file"; then
        local selected_log=$(cat "$temp_file")
        local log_path="$LOG_DIR/$selected_log"
        
        if [[ -r "$log_path" ]]; then
            whiptail --textbox "$log_path" 25 90
        else
            whiptail --msgbox "Cannot read log file: $log_path" 8 50
        fi
    fi
}

# Main menu function
show_main_menu() {
    while true; do
        local temp_file="$TEMP_DIR/main_menu"
        
        if whiptail --title "Manzolo Network & File Monitor v$SCRIPT_VERSION" \
            --menu "Select monitoring option:" 20 75 12 \
            "1" "Port Analysis (lsof) - Detailed network connections" \
            "2" "Network Analysis (ss) - Fast socket statistics" \
            "3" "Process Analysis - Complete process information" \
            "4" "File Lock Analysis - Check file usage and locks" \
            "5" "Process File Search - Find files used by processes" \
            "6" "System Overview - Comprehensive status report" \
            "7" "Log Viewer - View application logs" \
            "8" "Configuration - Manage settings" \
            "9" "Help - Usage information" \
            "10" "Exit - Quit application" 2> "$temp_file"; then
            
            local choice=$(cat "$temp_file")
            
            case $choice in
                1) clear; show_ports_lsof ;;
                2) clear; show_ports_ss ;;
                3) clear; analyze_process ;;
                4) clear; check_file_locks ;;
                5) clear; search_files_by_process ;;
                6) clear; show_system_overview ;;
                7) view_logs ;;
                8) manage_configuration ;;
                9) show_help ;;
                10)
                    log_message "INFO" "User initiated shutdown"
                    print_color "$GREEN" "Thank you for using Manzolo Network & File Monitor!"
                    exit 0
                    ;;
                *)
                    whiptail --msgbox "Invalid option selected!" 8 40
                    ;;
            esac
        else
            # User pressed Cancel or ESC
            log_message "INFO" "User cancelled - shutting down"
            exit 0
        fi
    done
}

# Main execution
main() {
    # Initialize environment
    init_environment
    
    # Check dependencies
    check_dependencies
    
    # Show startup message
    print_color "$GREEN" "Manzolo Network & File Monitor v$SCRIPT_VERSION"
    print_color "$CYAN" "Initializing system monitoring capabilities..."
    
    # Brief pause for visual effect
    sleep 2
    
    # Clear screen and start main menu
    clear
    show_main_menu
}

# Run main function
main "$@"