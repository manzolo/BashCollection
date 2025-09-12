#!/bin/bash

# UFW Manager - Advanced Interactive Firewall Management
# Author: Manzolo
# Version: 1.0
# License: MIT
# Compatible: Ubuntu 18.04+, Debian 10+

set -euo pipefail
LANG=C
LC_ALL=C
# =================== CONFIGURATION ===================
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_NAME="Manzolo UFW Manager"
readonly LOG_FILE="/var/log/ufw-manager.log"
readonly CONFIG_FILE="/etc/ufw-manager/config.conf"
readonly BACKUP_DIR="/etc/ufw-manager/backups"

# Color definitions with better organization
declare -A COLORS=(
    [RED]='\033[0;31m'
    [GREEN]='\033[0;32m'
    [YELLOW]='\033[1;33m'
    [BLUE]='\033[0;34m'
    [PURPLE]='\033[0;35m'
    [CYAN]='\033[0;36m'
    [WHITE]='\033[1;37m'
    [BOLD]='\033[1m'
    [DIM]='\033[2m'
    [NC]='\033[0m'
)

# Icon definitions for better UX
declare -A ICONS=(
    [SUCCESS]="✓"    # Simple check mark
    [ERROR]="✗"      # Simple cross mark
    [WARNING]="⚠"    # Warning sign (without emoji variation)
    [INFO]="ℹ"       # Information source (without emoji variation)
    [ARROW]="→"      # Simple right arrow
    [BULLET]="•"     # Simple bullet point
    [SHIELD]="🛡"     # Shield (without emoji variation)
    [QUESTION]="?"    # Simple question mark
    [CHECK]="✔"      # Heavy check mark (without emoji variation)
    [FIRE]="🔥"    # Subdued fire representation (text-based)
    [LOCK]="🔓"      # Open lock (less intense than closed lock)
)

# =================== UTILITY FUNCTIONS ===================

# Enhanced logging function
log_action() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user=$(whoami)
    
    echo "[$timestamp] [$level] [$user] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Print with color and icon support
print_message() {
    local type="$1"
    local message="$2"
    local color=""
    local icon=""
    
    case $type in
        "success") color="${COLORS[GREEN]}" icon="${ICONS[SUCCESS]}" ;;
        "error") color="${COLORS[RED]}" icon="${ICONS[ERROR]}" ;;
        "warning") color="${COLORS[YELLOW]}" icon="${ICONS[WARNING]}" ;;
        "info") color="${COLORS[CYAN]}" icon="${ICONS[INFO]}" ;;
        "header") color="${COLORS[BLUE]}" ;;
        *) color="${COLORS[NC]}" ;;
    esac
    
    echo -e "${color}${icon} $message${COLORS[NC]}"
    log_action "INFO" "$message"
}

# Enhanced header with system info
print_header() {
    clear
    local ufw_status=""
    local system_info=""
    
    # Get UFW status safely
    if command -v ufw &> /dev/null; then
        ufw_status=$(sudo ufw status | head -1 | awk '{print $2}' 2>/dev/null || echo "unknown")
    else
        ufw_status="not installed"
    fi
    
    system_info=$(lsb_release -d 2>/dev/null | cut -f2 || echo "$(uname -s) $(uname -r)")
    
    echo -e "${COLORS[BLUE]}${COLORS[BOLD]}"
    echo " ══════════════════════════════════════════════════════════"
    echo "                  ${ICONS[SHIELD]} MANZOLO UFW MANAGER ${ICONS[SHIELD]}                "
    echo "                         Version $SCRIPT_VERSION                        "
    echo " ══════════════════════════════════════════════════════════"
    echo -e "  System: ${COLORS[WHITE]}$(printf "%-44s" "$system_info")${COLORS[BLUE]} "
    echo -e "  UFW Status: ${COLORS[WHITE]}$(printf "%-40s" "$ufw_status")${COLORS[BLUE]} "
    echo -e "  Date: ${COLORS[WHITE]}$(printf "%-46s" "$(date '+%Y-%m-%d %H:%M:%S')")${COLORS[BLUE]} "
    echo " ══════════════════════════════════════════════════════════"
    echo -e "${COLORS[NC]}"
}

# Progress bar function
show_progress() {
    local duration="$1"
    local description="$2"
    local progress=0
    
    echo -ne "${COLORS[CYAN]}$description "
    while [ $progress -le 100 ]; do
        echo -ne "▓"
        sleep $(echo "scale=2; $duration/100" | bc -l 2>/dev/null || echo "0.01")
        ((progress += 10))
    done
    echo -e " ${ICONS[SUCCESS]}${COLORS[NC]}"
}

# Enhanced confirmation with timeout
confirm_action() {
    local message="$1"
    local timeout="${2:-30}"
    local default="${3:-n}"
    
    print_message "warning" "$message"
    echo -e "${COLORS[YELLOW]}Timeout in ${timeout}s (default: $default)${COLORS[NC]}"
    
    if read -t "$timeout" -p "Proceed? (y/n): " -n 1 -r; then
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
    else
        echo -e "\n${COLORS[YELLOW]}Timeout reached, using default: $default${COLORS[NC]}"
        [[ $default =~ ^[Yy]$ ]]
    fi
}

# System requirements check
check_system_requirements() {
    local requirements_met=true
    
    echo -e "${COLORS[CYAN]}${ICONS[INFO]} Checking system requirements...${COLORS[NC]}"
    
    # Check OS
    if ! grep -qi "ubuntu\|debian" /etc/os-release; then
        print_message "warning" "This script is optimized for Ubuntu/Debian systems"
    fi
    
    # Check UFW installation
    if ! command -v ufw &> /dev/null; then
        print_message "error" "UFW is not installed!"
        echo -e "${COLORS[YELLOW]}Install with: sudo apt update && sudo apt install ufw${COLORS[NC]}"
        requirements_met=false
    fi
    
    # Check sudo privileges
    if ! sudo -n true 2>/dev/null; then
        print_message "warning" "Sudo privileges required for most operations"
    fi
    
    # Check required tools
    local tools=("awk" "grep" "sed" "bc")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            print_message "error" "Required tool missing: $tool"
            requirements_met=false
        fi
    done
    
    if [ "$requirements_met" = false ]; then
        exit 1
    fi
    
    print_message "success" "System requirements check passed"
    sleep 1
}

# Create necessary directories
setup_directories() {
    local dirs=("/etc/ufw-manager" "$BACKUP_DIR")
    
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            sudo mkdir -p "$dir" 2>/dev/null || true
        fi
    done
    
    # Create log file with proper permissions
    sudo touch "$LOG_FILE" 2>/dev/null || true
    sudo chmod 644 "$LOG_FILE" 2>/dev/null || true
}

# Enhanced command execution with rollback capability
execute_command() {
    local cmd="$1"
    local description="$2"
    local backup_before="${3:-false}"
    local rollback_cmd="${4:-}"
    
    echo
    echo -e "${COLORS[BOLD]}${ICONS[INFO]} Command Execution${COLORS[NC]}"
    echo -e "${COLORS[CYAN]}Command:${COLORS[NC]} $cmd"
    echo -e "${COLORS[PURPLE]}Description:${COLORS[NC]} $description"
    
    if [ "$backup_before" = "true" ]; then
        echo -e "${COLORS[YELLOW]}${ICONS[WARNING]} This operation will create a backup first${COLORS[NC]}"
    fi
    
    if confirm_action "Execute this command?" 15 "n"; then
        # Create backup if requested
        if [ "$backup_before" = "true" ]; then
            backup_configuration
        fi
        
        print_message "info" "Executing: $description"
        show_progress 1 "Processing"
        
        if eval "$cmd" 2>&1 | tee -a "$LOG_FILE"; then
            print_message "success" "Command executed successfully"
            log_action "SUCCESS" "Executed: $cmd"
        else
            print_message "error" "Command failed"
            log_action "ERROR" "Failed: $cmd"
            
            if [ -n "$rollback_cmd" ] && confirm_action "Execute rollback command?" 10 "y"; then
                eval "$rollback_cmd"
                print_message "info" "Rollback executed"
            fi
        fi
    else
        print_message "warning" "Command cancelled by user"
        log_action "CANCELLED" "User cancelled: $cmd"
    fi
    
    echo
    read -p "Press ENTER to continue..."
}

# =================== BACKUP AND RESTORE ===================

backup_configuration() {
    local backup_file="$BACKUP_DIR/ufw_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    print_message "info" "Creating UFW configuration backup..."
    
    if sudo tar -czf "$backup_file" /etc/ufw/ /lib/ufw/ 2>/dev/null; then
        print_message "success" "Backup created: $backup_file"
        log_action "BACKUP" "Created backup: $backup_file"
    else
        print_message "error" "Failed to create backup"
    fi
}

restore_configuration() {
    print_header
    echo -e "${COLORS[CYAN]}=== RESTORE UFW CONFIGURATION ===${COLORS[NC]}"
    echo
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        print_message "error" "No backups found in $BACKUP_DIR"
        read -p "Press ENTER to continue..."
        return
    fi
    
    echo -e "${COLORS[CYAN]}Available backups:${COLORS[NC]}"
    local i=1
    local -a backups=()
    
    while IFS= read -r -d '' backup; do
        backups+=("$backup")
        echo "$i. $(basename "$backup")"
        ((i++))
    done < <(find "$BACKUP_DIR" -name "*.tar.gz" -print0 | sort -z)
    
    echo
    read -p "Select backup to restore (1-$((i-1))): " choice
    
    if [[ $choice =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt $i ]; then
        local backup_file="${backups[$((choice-1))]}"
        
        if confirm_action "Restore from $(basename "$backup_file")?"; then
            sudo ufw --force reset
            sudo tar -xzf "$backup_file" -C / 2>/dev/null
            sudo ufw reload
            print_message "success" "Configuration restored successfully"
        fi
    else
        print_message "error" "Invalid selection"
    fi
    
    read -p "Press ENTER to continue..."
}

# =================== ENHANCED STATUS AND MONITORING ===================

show_detailed_status() {
    print_header
    echo -e "${COLORS[CYAN]}=== DETAILED UFW STATUS ===${COLORS[NC]}"
    echo
    
    # Basic status
    echo -e "${COLORS[BOLD]}${ICONS[SHIELD]} Firewall Status:${COLORS[NC]}"
    sudo ufw status verbose
    echo
    
    # Numbered rules
    echo -e "${COLORS[BOLD]}${ICONS[BULLET]} Numbered Rules:${COLORS[NC]}"
    sudo ufw status numbered
    echo
    
    # Application profiles
    echo -e "${COLORS[BOLD]}${ICONS[BULLET]} Available Application Profiles:${COLORS[NC]}"
    sudo ufw app list 2>/dev/null || echo "No application profiles found"
    echo
    
    # Network interfaces
    echo -e "${COLORS[BOLD]}${ICONS[BULLET]} Network Interfaces:${COLORS[NC]}"
    ip -brief addr show | head -5
    echo
    
    # Active connections
    echo -e "${COLORS[BOLD]}${ICONS[BULLET]} Active Network Connections:${COLORS[NC]}"
    ss -tuln | head -10
    echo
    
    # Recent log entries
    echo -e "${COLORS[BOLD]}${ICONS[BULLET]} Recent UFW Log Entries (last 5):${COLORS[NC]}"
    sudo tail -5 /var/log/ufw.log 2>/dev/null | grep -v "^$" || echo "No recent log entries"
    
    echo
    read -p "Press ENTER to continue..."
}

# Real-time monitoring
real_time_monitoring() {
    print_header
    echo -e "${COLORS[CYAN]}=== REAL-TIME UFW MONITORING ===${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}Press Ctrl+C to exit${COLORS[NC]}"
    echo
    
    trap 'echo -e "\n${COLORS[YELLOW]}Monitoring stopped${COLORS[NC]}"; return' INT
    
    while true; do
        clear
        print_header
        echo -e "${COLORS[CYAN]}=== REAL-TIME UFW MONITORING ===${COLORS[NC]}"
        echo -e "${COLORS[DIM]}Updated: $(date)${COLORS[NC]}"
        echo
        
        echo -e "${COLORS[BOLD]}Recent UFW Events:${COLORS[NC]}"
        sudo tail -10 /var/log/ufw.log 2>/dev/null | grep -v "^$" || echo "No recent events"
        
        echo
        echo -e "${COLORS[BOLD]}Active Connections:${COLORS[NC]}"
        ss -tuln | head -10
        
        sleep 5
    done
}

# =================== ADVANCED RULE MANAGEMENT ===================

advanced_rule() {
    print_header
    echo -e "${COLORS[CYAN]}=== UFW COMMAND EXAMPLES ===${COLORS[NC]}"
    echo
    echo "Here are some common and advanced UFW rules. These are for reference only and are NOT executed."
    echo
    
    # 1. Allow incoming SSH traffic (port 22) from anywhere
    echo -e "${COLORS[CYAN]}1. Allow incoming SSH (from any IP):${COLORS[NC]}"
    echo -e "   ${COLORS[GREEN]}sudo ufw allow ssh${COLORS[NC]}"
    echo -e "   ${COLORS[DIM]}# Shorthand for: sudo ufw allow 22/tcp${COLORS[NC]}"
    echo
    
    # 2. Deny a specific port
    echo -e "${COLORS[CYAN]}2. Deny a specific port (e.g., FTP):${COLORS[NC]}"
    echo -e "   ${COLORS[RED]}sudo ufw deny 21/tcp${COLORS[NC]}"
    echo -e "   ${COLORS[DIM]}# Blocks all incoming TCP traffic on port 21${COLORS[NC]}"
    echo
    
    # 3. Limit connections to a port
    echo -e "${COLORS[CYAN]}3. Limit incoming connections on port 22:${COLORS[NC]}"
    echo -e "   ${COLORS[YELLOW]}sudo ufw limit 22/tcp${COLORS[NC]}"
    echo -e "   ${COLORS[DIM]}# Limits connections to protect against brute-force attacks${COLORS[NC]}"
    echo
    
    # 4. Allow traffic on a specific interface
    echo -e "${COLORS[CYAN]}4. Allow traffic on a specific interface:${COLORS[NC]}"
    echo -e "   ${COLORS[GREEN]}sudo ufw allow in on eth0 to any port 80${COLORS[NC]}"
    echo -e "   ${COLORS[DIM]}# Allows incoming HTTP traffic on 'eth0'${COLORS[NC]}"
    echo
    
    # 5. Allow traffic from a specific IP
    echo -e "${COLORS[CYAN]}5. Allow traffic from a specific IP to a destination port:${COLORS[NC]}"
    echo -e "   ${COLORS[GREEN]}sudo ufw allow proto tcp from 192.168.1.100 to any port 3306${COLORS[NC]}"
    echo -e "   ${COLORS[DIM]}# Allows TCP traffic from 192.168.1.100 to port 3306 (MySQL)${COLORS[NC]}"
    echo
    
    # 6. Reject outgoing traffic
    echo -e "${COLORS[CYAN]}6. Reject outgoing traffic to a specific IP:${COLORS[NC]}"
    echo -e "   ${COLORS[RED]}sudo ufw reject out to 10.0.0.50${COLORS[NC]}"
    echo -e "   ${COLORS[DIM]}# Blocks and sends an ICMP 'port unreachable' message${COLORS[NC]}"
    echo
    
    # 7. Allow a range of ports
    echo -e "${COLORS[CYAN]}7. Allow a range of UDP ports:${COLORS[NC]}"
    echo -e "   ${COLORS[GREEN]}sudo ufw allow 60000:61000/udp${COLORS[NC]}"
    echo -e "   ${COLORS[DIM]}# Allows all incoming UDP traffic on ports 60000 through 61000${COLORS[NC]}"
    echo
    
    # 8. Insert a rule at a specific position
    echo -e "${COLORS[CYAN]}8. Insert a rule at a specific position:${COLORS[NC]}"
    echo -e "   ${COLORS[WHITE]}sudo ufw insert 1 deny from 203.0.113.1${COLORS[NC]}"
    echo -e "   ${COLORS[DIM]}# Inserts a new rule as the first one, denying traffic from IP 203.0.113.1${COLORS[NC]}"
    echo

    read -p "Press ENTER to continue..."
}

# Bulk rule management
bulk_rule_management() {
    print_header
    echo -e "${COLORS[CYAN]}=== BULK RULE MANAGEMENT ===${COLORS[NC]}"
    echo
    echo "1. Import rules from file"
    echo "2. Export current rules to file"
    echo "3. Apply predefined rule set"
    echo "4. Return to main menu"
    echo
    read -p "Choose option (1-4): " choice
    
    case $choice in
        1)
            read -p "Enter file path: " file_path
            if [ -f "$file_path" ]; then
                while IFS= read -r line; do
                    if [[ $line =~ ^[[:space:]]*# ]] || [[ -z $line ]]; then
                        continue
                    fi
                    echo "Executing: sudo ufw $line"
                    sudo ufw $line
                done < "$file_path"
                print_message "success" "Rules imported successfully"
            else
                print_message "error" "File not found"
            fi
            ;;
        2)
            local export_file="/tmp/ufw_rules_$(date +%Y%m%d_%H%M%S).txt"
            sudo ufw status numbered > "$export_file"
            print_message "success" "Rules exported to: $export_file"
            ;;
        3)
            apply_predefined_rules
            ;;
        4)
            return
            ;;
    esac
    
    read -p "Press ENTER to continue..."
}

# =================== PREDEFINED CONFIGURATIONS ===================

apply_predefined_rules() {
    echo -e "${COLORS[CYAN]}=== PREDEFINED RULE SETS ===${COLORS[NC]}"
    echo
    echo "1. Web Server (HTTP/HTTPS + SSH)"
    echo "2. Database Server (MySQL/PostgreSQL + SSH)"
    echo "3. Mail Server (SMTP/POP3/IMAP + SSH)"
    echo "4. Development Server (Common dev ports + SSH)"
    echo "5. Secure Desktop (Minimal access)"
    echo "6. Gaming Server (Steam/Minecraft/Custom)"
    echo
    read -p "Choose configuration (1-6): " config_choice
    
    case $config_choice in
        1)
            if confirm_action "Apply web server configuration?"; then
                sudo ufw allow ssh
                sudo ufw allow http
                sudo ufw allow https
                sudo ufw allow 8080/tcp comment 'Alternative HTTP'
                print_message "success" "Web server configuration applied"
            fi
            ;;
        2)
            if confirm_action "Apply database server configuration?"; then
                sudo ufw allow ssh
                sudo ufw allow 3306/tcp comment 'MySQL'
                sudo ufw allow 5432/tcp comment 'PostgreSQL'
                print_message "success" "Database server configuration applied"
            fi
            ;;
        3)
            if confirm_action "Apply mail server configuration?"; then
                sudo ufw allow ssh
                sudo ufw allow 25/tcp comment 'SMTP'
                sudo ufw allow 110/tcp comment 'POP3'
                sudo ufw allow 995/tcp comment 'POP3S'
                sudo ufw allow 143/tcp comment 'IMAP'
                sudo ufw allow 993/tcp comment 'IMAPS'
                print_message "success" "Mail server configuration applied"
            fi
            ;;
        4)
            if confirm_action "Apply development server configuration?"; then
                sudo ufw allow ssh
                sudo ufw allow 3000/tcp comment 'Node.js dev'
                sudo ufw allow 8000/tcp comment 'Django dev'
                sudo ufw allow 4200/tcp comment 'Angular dev'
                sudo ufw allow 3001/tcp comment 'React dev'
                print_message "success" "Development server configuration applied"
            fi
            ;;
        5)
            if confirm_action "Apply secure desktop configuration?"; then
                sudo ufw --force reset
                sudo ufw default deny incoming
                sudo ufw default allow outgoing
                sudo ufw allow out 53 comment 'DNS'
                sudo ufw allow out 80 comment 'HTTP'
                sudo ufw allow out 443 comment 'HTTPS'
                sudo ufw enable
                print_message "success" "Secure desktop configuration applied"
            fi
            ;;
        6)
            apply_gaming_rules
            ;;
    esac
}

apply_gaming_rules() {
    echo -e "${COLORS[CYAN]}Gaming Server Rules:${COLORS[NC]}"
    echo "1. Steam Server"
    echo "2. Minecraft Server"
    echo "3. Custom Gaming Ports"
    echo
    read -p "Choose gaming type (1-3): " game_choice
    
    case $game_choice in
        1)
            sudo ufw allow 27015/tcp comment 'Steam Server'
            sudo ufw allow 27015/udp comment 'Steam Server'
            ;;
        2)
            sudo ufw allow 25565/tcp comment 'Minecraft Server'
            ;;
        3)
            read -p "Enter custom port range (e.g., 7777:7784): " port_range
            sudo ufw allow $port_range comment 'Custom Gaming'
            ;;
    esac
}

# =================== ENHANCED MAIN MENU ===================

main_menu() {
    while true; do
        print_header
        echo -e "${COLORS[CYAN]}=== MAIN MENU ===${COLORS[NC]}"
        echo
        echo -e "${COLORS[BOLD]}${ICONS[SHIELD]} Firewall Management:${COLORS[NC]}"
        echo "  1.  ${ICONS[INFO]} Detailed UFW Status"
        echo "  2.  ${ICONS[FIRE]} Basic UFW Control"
        echo "  3.  ${ICONS[ARROW]} Add Rules"
        echo "  4.  ${ICONS[ARROW]} Remove Rules"
        echo "  5.  ${ICONS[BULLET]} Advanced Rule"
        echo "  6.  ${ICONS[BULLET]} Bulk Rule Management"
        echo
        echo -e "${COLORS[BOLD]}${ICONS[LOCK]} Security & Monitoring:${COLORS[NC]}"
        echo "  7.  ${ICONS[INFO]} Real-time Monitoring"
        echo "  8.  ${ICONS[BULLET]} View Logs & Analytics"
        echo "  9.  ${ICONS[SHIELD]} Predefined Configurations"
        echo "  10. ${ICONS[WARNING]} Security Audit"
        echo
        echo -e "${COLORS[BOLD]}${ICONS[INFO]} Backup & Maintenance:${COLORS[NC]}"
        echo "  11. ${ICONS[SUCCESS]} Backup Configuration"
        echo "  12. ${ICONS[WARNING]} Restore Configuration"
        echo "  13. ${ICONS[INFO]} System Information"
        echo
        echo "  14. ${ICONS[ERROR]} Exit"
        echo
        read -p "Choose option (1-14): " choice
        
        case $choice in
            1) show_detailed_status ;;
            2) manage_ufw_basic ;;
            3) add_rules ;;
            4) remove_rules ;;
            5) advanced_rule ;;
            6) bulk_rule_management ;;
            7) real_time_monitoring ;;
            8) enhanced_log_management ;;
            9) apply_predefined_rules; read -p "Press ENTER to continue..." ;;
            10) security_audit ;;
            11) backup_configuration; read -p "Press ENTER to continue..." ;;
            12) restore_configuration ;;
            13) show_system_info ;;
            14) 
                print_message "success" "Thank you for using UFW Manager Professional!"
                log_action "EXIT" "UFW Manager Professional session ended"
                exit 0
                ;;
            *) 
                print_message "error" "Invalid option selected"
                sleep 1
                ;;
        esac
    done
}

# =================== ADDITIONAL FEATURES ===================

security_audit() {
    print_header
    echo -e "${COLORS[CYAN]}=== SECURITY AUDIT ===${COLORS[NC]}"
    echo
    
    print_message "info" "Running comprehensive security audit..."
    show_progress 3 "Analyzing"
    
    echo -e "${COLORS[BOLD]}Audit Results:${COLORS[NC]}"
    echo
    
    # Check if UFW is enabled
    if sudo ufw status | grep -q "Status: active"; then
        print_message "success" "UFW is active"
    else
        print_message "error" "UFW is not active"
    fi
    
    # Check default policies
    local default_in=$(sudo ufw status verbose | grep "Default:" | awk '{print $2}')
    local default_out=$(sudo ufw status verbose | grep "Default:" | awk '{print $4}')
    
    if [ "$default_in" = "deny" ]; then
        print_message "success" "Default incoming policy is secure (deny)"
    else
        print_message "warning" "Default incoming policy: $default_in"
    fi
    
    # Check for common security issues
    echo
    echo -e "${COLORS[BOLD]}Security Recommendations:${COLORS[NC]}"
    
    if sudo ufw status | grep -q "22/tcp.*ALLOW.*Anywhere"; then
        print_message "warning" "SSH is open to everywhere - consider restricting to specific IPs"
    fi
    
    if sudo ufw status | grep -q "80/tcp.*ALLOW.*Anywhere"; then
        print_message "info" "HTTP port is open (standard for web servers)"
    fi
    
    read -p "Press ENTER to continue..."
}

show_system_info() {
    print_header
    echo -e "${COLORS[CYAN]}=== SYSTEM INFORMATION ===${COLORS[NC]}"
    echo
    
    echo -e "${COLORS[BOLD]}System Details:${COLORS[NC]}"
    echo "OS: $(lsb_release -d 2>/dev/null | cut -f2 || uname -a)"
    echo "Kernel: $(uname -r)"
    echo "Uptime: $(uptime -p 2>/dev/null || uptime)"
    echo
    
    echo -e "${COLORS[BOLD]}UFW Information:${COLORS[NC]}"
    echo "Version: $(ufw --version 2>/dev/null || echo 'Unknown')"
    echo "Rules count: $(sudo ufw status numbered | grep -c "^\[" || echo '0')"
    echo
    
    echo -e "${COLORS[BOLD]}Network Interfaces:${COLORS[NC]}"
    ip -brief addr show
    echo
    
    read -p "Press ENTER to continue..."
}

enhanced_log_management() {
    while true; do
        print_header
        echo -e "${COLORS[CYAN]}=== ENHANCED LOG MANAGEMENT ===${COLORS[NC]}"
        echo
        echo "1. View recent UFW logs"
        echo "2. Search logs by IP"
        echo "3. Search logs by port"
        echo "4. Log statistics"
        echo "5. Export logs"
        echo "6. Configure logging"
        echo "7. Return to main menu"
        echo
        read -p "Choose option (1-7): " choice
        
        case $choice in
            1)
                echo -e "${COLORS[CYAN]}Recent UFW logs (last 20 entries):${COLORS[NC]}"
                sudo tail -20 /var/log/ufw.log 2>/dev/null || echo "No logs found"
                ;;
            2)
                read -p "Enter IP to search for: " search_ip
                grep "$search_ip" /var/log/ufw.log 2>/dev/null | tail -10 || echo "No matches found"
                ;;
            3)
                read -p "Enter port to search for: " search_port
                grep "DPT=$search_port" /var/log/ufw.log 2>/dev/null | tail -10 || echo "No matches found"
                ;;
            4)
                echo -e "${COLORS[CYAN]}Log Statistics:${COLORS[NC]}"
                echo "Total log entries: $(wc -l /var/log/ufw.log 2>/dev/null | cut -d' ' -f1 || echo '0')"
                echo "Most blocked IPs:"
                grep "BLOCK" /var/log/ufw.log 2>/dev/null | awk '{print $13}' | cut -d'=' -f2 | sort | uniq -c | sort -nr | head -5 || echo "No data"
                ;;
            5)
                local export_file="/tmp/ufw_logs_$(date +%Y%m%d_%H%M%S).txt"
                sudo cp /var/log/ufw.log "$export_file" 2>/dev/null
                print_message "success" "Logs exported to: $export_file"
                ;;
            6)
                configure_logging
                ;;
            7)
                break
                ;;
        esac
        echo
        read -p "Press ENTER to continue..."
    done
}

configure_logging() {
    echo -e "${COLORS[CYAN]}Current logging configuration:${COLORS[NC]}"
    sudo ufw status verbose | grep "Logging:"
    echo
    echo "1. Enable logging"
    echo "2. Disable logging"
    echo "3. Set logging level"
    echo
    read -p "Choose option (1-3): " log_choice
    
    case $log_choice in
        1) execute_command "sudo ufw logging on" "Enable UFW logging" ;;
        2) execute_command "sudo ufw logging off" "Disable UFW logging" ;;
        3)
            echo "Available levels: off, low, medium, high, full"
            read -p "Enter logging level: " level
            execute_command "sudo ufw logging $level" "Set logging level to $level"
            ;;
    esac
}

# =================== LEGACY FUNCTIONS (ENHANCED) ===================

manage_ufw_basic() {
    while true; do
        print_header
        echo -e "${COLORS[CYAN]}=== BASIC UFW MANAGEMENT ===${COLORS[NC]}"
        echo
        echo "1. ${ICONS[SUCCESS]} Enable UFW"
        echo "2. ${ICONS[ERROR]} Disable UFW"
        echo "3. ${ICONS[WARNING]} Reset UFW (removes all rules)"
        echo "4. ${ICONS[ARROW]} Reload UFW"
        echo "5. ${ICONS[INFO]} Show UFW version"
        echo "6. ${ICONS[SHIELD]} Set default policies"
        echo "7. ${ICONS[ARROW]} Return to main menu"
        echo
        read -p "Choose option (1-7): " choice
        
        case $choice in
            1)
                execute_command "sudo ufw enable" "Enable UFW firewall" true
                ;;
            2)
                execute_command "sudo ufw disable" "Disable UFW firewall"
                ;;
            3)
                execute_command "sudo ufw --force reset" "Complete UFW reset (removes all rules)" true
                ;;
            4)
                execute_command "sudo ufw reload" "Reload UFW configuration"
                ;;
            5)
                echo -e "${COLORS[CYAN]}UFW Version Information:${COLORS[NC]}"
                ufw --version
                echo
                read -p "Press ENTER to continue..."
                ;;
            6)
                set_default_policies
                ;;
            7)
                break
                ;;
            *)
                print_message "error" "Invalid option"
                sleep 1
                ;;
        esac
    done
}

set_default_policies() {
    echo -e "${COLORS[CYAN]}=== SET DEFAULT POLICIES ===${COLORS[NC]}"
    echo
    echo "Current default policies:"
    sudo ufw status verbose | grep "Default:"
    echo
    
    echo "1. Secure (deny incoming, allow outgoing)"
    echo "2. Restrictive (deny incoming, deny outgoing)"
    echo "3. Permissive (allow incoming, allow outgoing)"
    echo "4. Custom configuration"
    echo
    read -p "Choose policy set (1-4): " policy_choice
    
    case $policy_choice in
        1)
            if confirm_action "Apply secure default policies?"; then
                sudo ufw default deny incoming
                sudo ufw default allow outgoing
                print_message "success" "Secure policies applied"
            fi
            ;;
        2)
            if confirm_action "Apply restrictive policies? (WARNING: May block internet)"; then
                sudo ufw default deny incoming
                sudo ufw default deny outgoing
                print_message "warning" "Restrictive policies applied"
            fi
            ;;
        3)
            if confirm_action "Apply permissive policies? (WARNING: Less secure)"; then
                sudo ufw default allow incoming
                sudo ufw default allow outgoing
                print_message "warning" "Permissive policies applied"
            fi
            ;;
        4)
            custom_default_policies
            ;;
    esac
    
    read -p "Press ENTER to continue..."
}

custom_default_policies() {
    echo -e "${COLORS[CYAN]}Custom Default Policies:${COLORS[NC]}"
    echo
    
    echo "Incoming policy:"
    select incoming in "allow" "deny" "reject"; do
        if [ -n "$incoming" ]; then break; fi
    done
    
    echo "Outgoing policy:"
    select outgoing in "allow" "deny" "reject"; do
        if [ -n "$outgoing" ]; then break; fi
    done
    
    if confirm_action "Apply custom policies (incoming: $incoming, outgoing: $outgoing)?"; then
        sudo ufw default $incoming incoming
        sudo ufw default $outgoing outgoing
        print_message "success" "Custom policies applied"
    fi
}

add_rules() {
    while true; do
        print_header
        echo -e "${COLORS[CYAN]}=== ADD FIREWALL RULES ===${COLORS[NC]}"
        echo
        echo "1. ${ICONS[SUCCESS]} Allow specific port"
        echo "2. ${ICONS[ERROR]} Block specific port"
        echo "3. ${ICONS[SHIELD]} Limit connections (rate limiting)"
        echo "4. ${ICONS[BULLET]} Allow service by name"
        echo "5. ${ICONS[BULLET]} Allow from specific IP"
        echo "6. ${ICONS[BULLET]} Allow from subnet/range"
        echo "7. ${ICONS[ARROW]} Port range rules"
        echo "8. ${ICONS[INFO]} Application profile rules"
        echo "9. ${ICONS[FIRE]} Custom rule builder"
        echo "10. ${ICONS[ARROW]} Return to main menu"
        echo
        read -p "Choose option (1-10): " choice
        
        case $choice in
            1)
                add_port_rule "allow"
                ;;
            2)
                add_port_rule "deny"
                ;;
            3)
                add_port_rule "limit"
                ;;
            4)
                add_service_rule
                ;;
            5)
                add_ip_rule
                ;;
            6)
                add_subnet_rule
                ;;
            7)
                add_port_range_rule
                ;;
            8)
                add_app_profile_rule
                ;;
            9)
                custom_rule_builder
                ;;
            10)
                break
                ;;
            *)
                print_message "error" "Invalid option"
                sleep 1
                ;;
        esac
    done
}

add_port_rule() {
    local action="$1"
    echo -e "${COLORS[YELLOW]}Examples: 22, 80, 443, 8080${COLORS[NC]}"
    read -p "Enter port number: " port
    
    if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        echo "Protocol selection:"
        select protocol in "tcp" "udp" "both"; do
            if [ -n "$protocol" ]; then break; fi
        done
        
        local cmd=""
        case $protocol in
            "tcp")
                cmd="sudo ufw $action $port/tcp"
                ;;
            "udp")
                cmd="sudo ufw $action $port/udp"
                ;;
            "both")
                cmd="sudo ufw $action $port"
                ;;
        esac
        
        read -p "Add comment (optional): " comment
        if [ -n "$comment" ]; then
            cmd+=" comment '$comment'"
        fi
        
        execute_command "$cmd" "$action port $port ($protocol)" false
    else
        print_message "error" "Invalid port number (1-65535)"
        sleep 2
    fi
}

add_service_rule() {
    echo -e "${COLORS[YELLOW]}Common services: ssh, http, https, ftp, smtp, pop3, imap${COLORS[NC]}"
    echo -e "${COLORS[INFO]}Available services on system:${COLORS[NC]}"
    grep -E '^[a-zA-Z]' /etc/services | head -10 | awk '{print $1}' | tr '\n' ' '
    echo
    echo
    read -p "Enter service name: " service
    
    if [ -n "$service" ]; then
        execute_command "sudo ufw allow $service" "Allow service: $service"
    else
        print_message "error" "Service name cannot be empty"
        sleep 2
    fi
}

add_ip_rule() {
    echo -e "${COLORS[YELLOW]}${ICONS[QUESTION]} Enter IP address (e.g., 192.168.1.100):${COLORS[NC]}"
    read -p "IP address: " ip
    
    # Validate IP address
    if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        # Check if each octet is between 0 and 255
        if (( ${BASH_REMATCH[1]} <= 255 && ${BASH_REMATCH[2]} <= 255 && ${BASH_REMATCH[3]} <= 255 && ${BASH_REMATCH[4]} <= 255 )); then
            echo -e "${COLORS[CYAN]}${ICONS[SHIELD]} Rule type:${COLORS[NC]}"
            echo "${ICONS[BULLET]} 1. Allow all traffic from this IP"
            echo "${ICONS[BULLET]} 2. Allow specific port from this IP"
            echo "${ICONS[BULLET]} 3. Block all traffic from this IP"
            read -p "Choose (1-3): " ip_choice
            
            case $ip_choice in
                1)
                    execute_command "sudo ufw allow from $ip" "Allow all traffic from $ip"
                    ;;
                2)
                    read -p "Enter port: " port
                    if [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
                        read -p "Protocol (tcp/udp, press Enter for tcp): " proto
                        proto=${proto:-tcp}  # Default to tcp if empty
                        if [[ "$proto" == "tcp" || "$proto" == "udp" ]]; then
                            execute_command "sudo ufw allow from $ip to any port $port proto $proto" "Allow $ip to access port $port/$proto"
                        else
                            print_message "error" "Invalid protocol: must be tcp or udp"
                        fi
                    else
                        print_message "error" "Invalid port: must be a number between 1 and 65535"
                    fi
                    ;;
                3)
                    execute_command "sudo ufw deny from $ip" "Block all traffic from $ip"
                    ;;
                *)
                    print_message "error" "Invalid choice: must be 1, 2, or 3"
                    ;;
            esac
        else
            print_message "error" "Invalid IP address: each octet must be between 0 and 255"
        fi
    else
        print_message "error" "Invalid IP address format: use xxx.xxx.xxx.xxx"
    fi
    
    read -p "Press ENTER to continue..."
}

add_subnet_rule() {
    echo -e "${COLORS[YELLOW]}Examples: 192.168.1.0/24, 10.0.0.0/8${COLORS[NC]}"
    read -p "Enter subnet (CIDR notation): " subnet
    
    if [[ $subnet =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        execute_command "sudo ufw allow from $subnet" "Allow traffic from subnet $subnet"
    else
        print_message "error" "Invalid subnet format (use CIDR notation)"
        sleep 2
    fi
}

add_port_range_rule() {
    echo -e "${COLORS[YELLOW]}Example: 8000:8010${COLORS[NC]}"
    read -p "Enter port range (start:end): " port_range
    
    if [[ $port_range =~ ^[0-9]+:[0-9]+$ ]]; then
        echo "Protocol:"
        select protocol in "tcp" "udp"; do
            if [ -n "$protocol" ]; then break; fi
        done
        
        execute_command "sudo ufw allow $port_range/$protocol" "Allow port range $port_range ($protocol)"
    else
        print_message "error" "Invalid port range format (use start:end)"
        sleep 2
    fi
}

add_app_profile_rule() {
    echo -e "${COLORS[CYAN]}Available application profiles:${COLORS[NC]}"
    sudo ufw app list 2>/dev/null || {
        print_message "error" "No application profiles available"
        sleep 2
        return
    }
    echo
    read -p "Enter application profile name: " app_name
    
    if sudo ufw app info "$app_name" >/dev/null 2>&1; then
        execute_command "sudo ufw allow '$app_name'" "Allow application profile: $app_name"
    else
        print_message "error" "Application profile not found"
        sleep 2
    fi
}

custom_rule_builder() {
    echo -e "${COLORS[CYAN]}${ICONS[SHIELD]} === CUSTOM RULE BUILDER ===${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}Build your custom UFW rule step by step${COLORS[NC]}"
    echo
    
    local rule_parts=()
    
    # Action
    echo "${ICONS[QUESTION]} 1. Select action:"
    select action in "allow" "deny" "reject" "limit"; do
        if [ -n "$action" ]; then
            rule_parts+=("$action")
            break
        fi
    done
    
    # Direction (optional)
    echo -e "\n${ICONS[QUESTION]} 2. Direction (optional):"
    select direction in "in" "out" "skip"; do
        case $direction in
            "in"|"out") rule_parts+=("$direction"); break ;;
            "skip") break ;;
        esac
    done
    
    # Interface (optional)
    read -p "\n${ICONS[QUESTION]} 3. Interface (optional, press Enter to skip): " interface
    if [ -n "$interface" ]; then
        rule_parts+=("on" "$interface")
    fi
    
    # Protocol (optional) - Moved here to match UFW syntax order
    echo -e "\n${ICONS[QUESTION]} 4. Protocol (optional):"
    select proto in "tcp" "udp" "icmp" "esp" "ah" "skip"; do
        case $proto in
            "tcp"|"udp"|"icmp"|"esp"|"ah") rule_parts+=("proto" "$proto"); break ;;
            "skip") break ;;
        esac
    done
    
    # From specification
    read -p "\n${ICONS[QUESTION]} 5. From IP/subnet (optional, press Enter to skip): " from_spec
    if [ -n "$from_spec" ]; then
        # Basic validation for IP/subnet (IPv4 or CIDR)
        if [[ $from_spec =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
            rule_parts+=("from" "$from_spec")
            read -p "${ICONS[QUESTION]} From port (optional, press Enter to skip): " from_port
            if [ -n "$from_port" ]; then
                if [[ $from_port =~ ^[0-9]+$ ]] && (( from_port >= 1 && from_port <= 65535 )); then
                    rule_parts+=("port" "$from_port")
                else
                    print_message "error" "Invalid from port: must be a number between 1 and 65535"
                    return 1
                fi
            fi
        else
            print_message "error" "Invalid from IP/subnet format (use xxx.xxx.xxx.xxx or xxx.xxx.xxx.xxx/xx)"
            return 1
        fi
    fi
    
    # To specification
    read -p "\n${ICONS[QUESTION]} 6. To IP/subnet (optional, press Enter for any): " to_spec
    if [ -n "$to_spec" ]; then
        # Basic validation for IP/subnet (IPv4 or CIDR)
        if [[ $to_spec =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
            rule_parts+=("to" "$to_spec")
        else
            print_message "error" "Invalid to IP/subnet format (use xxx.xxx.xxx.xxx or xxx.xxx.xxx.xxx/xx)"
            return 1
        fi
    else
        rule_parts+=("to" "any")
    fi
    
    read -p "${ICONS[QUESTION]} To port (optional, press Enter to skip): " to_port
    if [ -n "$to_port" ]; then
        if [[ $to_port =~ ^[0-9]+$ ]] && (( to_port >= 1 && to_port <= 65535 )); then
            rule_parts+=("port" "$to_port")
        else
            print_message "error" "Invalid to port: must be a number between 1 and 65535"
            return 1
        fi
    fi
    
    # Comment
    read -p "\n${ICONS[QUESTION]} 7. Comment (optional, press Enter to skip): " comment
    if [ -n "$comment" ]; then
        rule_parts+=("comment" "\"$comment\"")  # Use double quotes for comments with spaces
    fi
    
    # Preview the rule
    echo -e "\n${COLORS[CYAN]}${ICONS[INFO]} Preview of the rule:${COLORS[NC]}"
    echo "sudo ufw ${rule_parts[*]}"
    
    # Confirm before execution
    if confirm_action "Add this custom rule?"; then
        local final_cmd="sudo ufw ${rule_parts[*]}"
        execute_command "$final_cmd" "Custom UFW rule"
    fi
    
    read -p "Press ENTER to continue..."
}

remove_rules() {
    while true; do
        print_header
        echo -e "${COLORS[CYAN]}=== REMOVE FIREWALL RULES ===${COLORS[NC]}"
        echo
        
        # Show current rules with proper formatting
        echo -e "${COLORS[YELLOW]}Current rules:${COLORS[NC]}"
        if ! sudo ufw status numbered | grep -q "^\["; then
            print_message "info" "No numbered rules found"
        else
            sudo ufw status numbered
        fi
        echo
        
        echo "1. ${ICONS[ERROR]} Remove by rule number"
        echo "2. ${ICONS[ERROR]} Remove by port"
        echo "3. ${ICONS[ERROR]} Remove by service name"
        echo "4. ${ICONS[ERROR]} Remove by IP address"
        echo "5. ${ICONS[WARNING]} Remove multiple rules"
        echo "6. ${ICONS[FIRE]} Remove all rules (reset)"
        echo "7. ${ICONS[ARROW]} Return to main menu"
        echo
        read -p "Choose option (1-7): " choice
        
        case $choice in
            1)
                remove_by_number
                ;;
            2)
                remove_by_port
                ;;
            3)
                remove_by_service
                ;;
            4)
                remove_by_ip
                ;;
            5)
                remove_multiple_rules
                ;;
            6)
                if confirm_action "Remove ALL rules? This will reset UFW completely!" 20 "n"; then
                    execute_command "sudo ufw --force reset" "Remove all UFW rules" true
                fi
                ;;
            7)
                break
                ;;
            *)
                print_message "error" "Invalid option"
                sleep 1
                ;;
        esac
    done
}

remove_by_number() {
    echo -e "${COLORS[CYAN]}Current numbered rules:${COLORS[NC]}"
    sudo ufw status numbered
    echo
    
    read -p "Enter rule number to remove: " rule_num
    
    if [[ $rule_num =~ ^[0-9]+$ ]]; then
        # Show the rule that will be deleted - fixed regex pattern
        echo -e "${COLORS[YELLOW]}Rule to be removed:${COLORS[NC]}"
        local rule_line=$(sudo ufw status numbered | grep "^\[ *$rule_num\]")
        if [ -n "$rule_line" ]; then
            echo "$rule_line"
            echo
            execute_command "sudo ufw delete $rule_num" "Remove rule number $rule_num" true
        else
            print_message "error" "Rule number $rule_num not found"
            sleep 2
            return
        fi
    else
        print_message "error" "Invalid rule number"
        sleep 2
    fi
}

remove_by_port() {
    echo -e "${COLORS[CYAN]}Current rules:${COLORS[NC]}"
    sudo ufw status numbered
    echo
    
    read -p "Enter port number: " port
    
    if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        echo "Select protocol and action:"
        echo "1. Remove TCP allow rule for port $port"
        echo "2. Remove UDP allow rule for port $port"  
        echo "3. Remove both TCP and UDP allow rules for port $port"
        echo "4. Remove TCP deny rule for port $port"
        echo "5. Remove UDP deny rule for port $port"
        echo "6. Remove all rules (allow/deny) for port $port"
        
        read -p "Choose option (1-6): " port_choice
        
        case $port_choice in
            1)
                execute_command "sudo ufw delete allow $port/tcp" "Remove TCP allow rule for port $port" true
                ;;
            2)
                execute_command "sudo ufw delete allow $port/udp" "Remove UDP allow rule for port $port" true
                ;;
            3)
                execute_command "sudo ufw delete allow $port" "Remove allow rules for port $port" true
                ;;
            4)
                execute_command "sudo ufw delete deny $port/tcp" "Remove TCP deny rule for port $port" true
                ;;
            5)
                execute_command "sudo ufw delete deny $port/udp" "Remove UDP deny rule for port $port" true
                ;;
            6)
                if confirm_action "Remove ALL rules for port $port?"; then
                    sudo ufw delete allow $port 2>/dev/null || true
                    sudo ufw delete deny $port 2>/dev/null || true
                    sudo ufw delete reject $port 2>/dev/null || true
                    print_message "success" "All rules for port $port removed"
                fi
                ;;
            *)
                print_message "error" "Invalid choice"
                ;;
        esac
    else
        print_message "error" "Invalid port number (must be 1-65535)"
        sleep 2
    fi
}

remove_by_service() {
    read -p "Enter service name: " service
    
    if [ -n "$service" ]; then
        execute_command "sudo ufw delete allow $service" "Remove rule for service $service"
    else
        print_message "error" "Service name cannot be empty"
        sleep 2
    fi
}

remove_by_ip() {
    read -p "Enter IP address: " ip
    
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        execute_command "sudo ufw delete allow from $ip" "Remove rules for IP $ip"
    else
        print_message "error" "Invalid IP address"
        sleep 2
    fi
}

remove_multiple_rules() {
    echo -e "${COLORS[CYAN]}Current numbered rules:${COLORS[NC]}"
    sudo ufw status numbered
    echo
    
    echo -e "${COLORS[YELLOW]}${ICONS[QUESTION]} Enter rule numbers separated by spaces (e.g., 1 3 5):${COLORS[NC]}"
    read -p "Rule numbers: " rule_numbers
    
    # Validate input
    if [ -z "$rule_numbers" ]; then
        print_message "error" "No rule numbers provided"
        read -p "Press ENTER to continue..."
        return 1
    fi
    
    # Convert to array and sort in descending order (to maintain rule numbers during deletion)
    local -a rules
    read -ra rules <<< "$rule_numbers"
    
    # Sort in descending order
    local IFS=$'\n'
    rules=($(sort -nr <<<"${rules[*]}"))
    unset IFS
    
    # Validate and display rules
    local valid_rules=()
    echo -e "${COLORS[CYAN]}${ICONS[SHIELD]} Rules to be removed:${COLORS[NC]}"
    
    for rule in "${rules[@]}"; do
        # Skip empty values
        if [ -z "$rule" ]; then
            continue
        fi
        
        if [[ ! $rule =~ ^[0-9]+$ ]]; then
            print_message "warning" "Invalid rule number: $rule (must be numeric)"
            continue
        fi
        
        # Fixed pattern matching - look for rule number at start of line
        local rule_line=$(sudo ufw status numbered | grep "^\[ *$rule\]")
        if [ -n "$rule_line" ]; then
            echo "${ICONS[BULLET]} $rule_line"
            valid_rules+=("$rule")
        else
            print_message "warning" "Rule $rule not found"
        fi
    done
    
    # Check if there are valid rules to delete
    if [ ${#valid_rules[@]} -eq 0 ]; then
        print_message "error" "No valid rules to remove"
        read -p "Press ENTER to continue..."
        return 1
    fi
    
    # Confirm and delete rules
    echo
    if confirm_action "Remove ${#valid_rules[@]} rule(s)?"; then
        # Create backup before making changes
        backup_configuration
        
        for rule in "${valid_rules[@]}"; do
            echo "${ICONS[ARROW]} Removing rule $rule..."
            if sudo ufw --force delete "$rule" 2>/dev/null; then
                print_message "success" "Rule $rule removed successfully"
                log_action "DELETE" "Removed UFW rule number $rule"
            else
                print_message "warning" "Failed to remove rule $rule"
                log_action "ERROR" "Failed to remove UFW rule number $rule"
            fi
            
            # Small delay to avoid issues with rapid deletions
            sleep 0.5
        done
        print_message "success" "Multiple rule removal completed"
    else
        print_message "info" "Operation cancelled"
    fi
    
    read -p "Press ENTER to continue..."
}

# =================== INITIALIZATION AND MAIN EXECUTION ===================

# Signal handlers
cleanup_and_exit() {
    echo
    print_message "info" "UFW Manager Professional terminated"
    log_action "EXIT" "Script terminated by signal"
    exit 0
}

# Set up signal handlers
trap cleanup_and_exit SIGINT SIGTERM

# Main initialization function
initialize_script() {
    # Create necessary directories
    setup_directories
    
    # Log script start
    log_action "START" "UFW Manager Professional v${SCRIPT_VERSION:-1.0} started"
    
    # Check system requirements
    check_system_requirements
    
    # Show welcome message
    print_message "success" "UFW Manager Professional v${SCRIPT_VERSION:-1.0} initialized successfully"
    sleep 1
}

# =================== SCRIPT ENTRY POINT ===================

main() {
    # Initialize the script
    initialize_script
    
    # Show main menu
    main_menu
}

# Execute the main function
main "$@"