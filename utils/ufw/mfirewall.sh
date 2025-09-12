#!/bin/bash

# UFW Manager - Interactive script to manage UFW on Ubuntu
# Author: Assistant
# Version: 1.0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print header
print_header() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           UFW MANAGER v1.0             ║${NC}"
    echo -e "${BLUE}║       Ubuntu Firewall Management       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo
}

# Function to check if UFW is installed
check_ufw() {
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}❌ UFW is not installed on the system!${NC}"
        echo -e "${YELLOW}Install it with: sudo apt update && sudo apt install ufw${NC}"
        exit 1
    fi
}

# Function to ask for confirmation
confirm_action() {
    local message="$1"
    echo -e "${YELLOW}$message${NC}"
    read -p "Proceed? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[SsYy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to execute a command with confirmation
execute_command() {
    local cmd="$1"
    local description="$2"
    
    echo -e "${CYAN}Command to be executed:${NC} $cmd"
    echo -e "${PURPLE}Description:${NC} $description"
    
    if confirm_action "Execute this command?"; then
        echo -e "${GREEN}Executing...${NC}"
        eval "$cmd"
        echo -e "${GREEN}✓ Command executed!${NC}"
    else
        echo -e "${YELLOW}⚠️  Command cancelled${NC}"
    fi
    echo
    read -p "Press ENTER to continue..."
}

# Function to show UFW status
show_status() {
    print_header
    echo -e "${CYAN}=== CURRENT UFW STATUS ===${NC}"
    echo
    sudo ufw status verbose
    echo
    echo -e "${CYAN}=== NUMBERED RULES ===${NC}"
    echo
    sudo ufw status numbered
    echo
    read -p "Press ENTER to continue..."
}

# Function for basic UFW management
manage_ufw_basic() {
    while true; do
        print_header
        echo -e "${CYAN}=== BASIC UFW MANAGEMENT ===${NC}"
        echo "1. Enable UFW"
        echo "2. Disable UFW"
        echo "3. Reset UFW (removes all rules)"
        echo "4. Reload UFW"
        echo "5. Return to main menu"
        echo
        read -p "Choose an option (1-5): " choice
        
        case $choice in
            1)
                execute_command "sudo ufw enable" "Enables the UFW firewall"
                ;;
            2)
                execute_command "sudo ufw disable" "Disables the UFW firewall"
                ;;
            3)
                execute_command "sudo ufw --force reset" "Complete reset of UFW (removes all rules)"
                ;;
            4)
                execute_command "sudo ufw reload" "Reloads the UFW configuration"
                ;;
            5)
                break
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 2
                ;;
        esac
    done
}

# Function to add rules
add_rules() {
    while true; do
        print_header
        echo -e "${CYAN}=== ADD RULES ===${NC}"
        echo "1. Allow a specific port (ALLOW)"
        echo "2. Block a specific port (DENY)"
        echo "3. Allow a service"
        echo "4. Allow from a specific IP"
        echo "5. Allow from a subnet"
        echo "6. Custom rule"
        echo "7. Return to main menu"
        echo
        read -p "Choose an option (1-7): " choice
        
        case $choice in
            1)
                echo -e "${YELLOW}Examples: 22, 80, 443, 8080${NC}"
                read -p "Enter the port to allow: " port
                if [[ $port =~ ^[0-9]+$ ]]; then
                    execute_command "sudo ufw allow $port" "Allow traffic on port $port"
                else
                    echo -e "${RED}Invalid port!${NC}"
                    sleep 2
                fi
                ;;
            2)
                echo -e "${YELLOW}Examples: 22, 80, 443, 8080${NC}"
                read -p "Enter the port to block: " port
                if [[ $port =~ ^[0-9]+$ ]]; then
                    execute_command "sudo ufw deny $port" "Block traffic on port $port"
                else
                    echo -e "${RED}Invalid port!${NC}"
                    sleep 2
                fi
                ;;
            3)
                echo -e "${YELLOW}Examples: ssh, http, https, ftp${NC}"
                read -p "Enter the service name: " service
                execute_command "sudo ufw allow $service" "Allow service $service"
                ;;
            4)
                echo -e "${YELLOW}Example: 192.168.1.100${NC}"
                read -p "Enter the IP: " ip
                execute_command "sudo ufw allow from $ip" "Allow all traffic from $ip"
                ;;
            5)
                echo -e "${YELLOW}Example: 192.168.1.0/24${NC}"
                read -p "Enter the subnet: " subnet
                execute_command "sudo ufw allow from $subnet" "Allow all traffic from the subnet $subnet"
                ;;
            6)
                echo -e "${YELLOW}Examples:${NC}"
                echo -e "${YELLOW}  sudo ufw allow from 192.168.1.100 to any port 22${NC}"
                echo -e "${YELLOW}  sudo ufw deny out 53${NC}"
                echo -e "${YELLOW}  sudo ufw allow in on eth0 to any port 80${NC}"
                echo
                read -p "Enter the full UFW command (without 'sudo ufw'): " custom_rule
                execute_command "sudo ufw $custom_rule" "Execute custom rule: $custom_rule"
                ;;
            7)
                break
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 2
                ;;
        esac
    done
}

# Function to remove rules
remove_rules() {
    while true; do
        print_header
        echo -e "${CYAN}=== REMOVE RULES ===${NC}"
        echo
        echo -e "${YELLOW}Current rules:${NC}"
        sudo ufw status numbered
        echo
        echo "1. Remove by number"
        echo "2. Remove by port"
        echo "3. Remove by service"
        echo "4. Remove by IP"
        echo "5. Return to main menu"
        echo
        read -p "Choose an option (1-5): " choice
        
        case $choice in
            1)
                read -p "Enter the number of the rule to remove: " rule_num
                if [[ $rule_num =~ ^[0-9]+$ ]]; then
                    execute_command "sudo ufw delete $rule_num" "Remove rule number $rule_num"
                else
                    echo -e "${RED}Invalid rule number!${NC}"
                    sleep 2
                fi
                ;;
            2)
                read -p "Enter the port: " port
                if [[ $port =~ ^[0-9]+$ ]]; then
                    execute_command "sudo ufw delete allow $port" "Remove ALLOW rule for port $port"
                else
                    echo -e "${RED}Invalid port!${NC}"
                    sleep 2
                fi
                ;;
            3)
                read -p "Enter the service: " service
                execute_command "sudo ufw delete allow $service" "Remove ALLOW rule for service $service"
                ;;
            4)
                read -p "Enter the IP: " ip
                execute_command "sudo ufw delete allow from $ip" "Remove rules for IP $ip"
                ;;
            5)
                break
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 2
                ;;
        esac
    done
}

# Function for common rules
common_rules() {
    while true; do
        print_header
        echo -e "${CYAN}=== COMMON RULES ===${NC}"
        echo "1. Allow SSH (port 22)"
        echo "2. Allow HTTP (port 80)"
        echo "3. Allow HTTPS (port 443)"
        echo "4. Allow FTP (port 21)"
        echo "5. Allow MySQL (port 3306)"
        echo "6. Allow PostgreSQL (port 5432)"
        echo "7. Block all outgoing traffic"
        echo "8. Allow all outgoing traffic"
        echo "9. Basic web server configuration"
        echo "10. Return to main menu"
        echo
        read -p "Choose an option (1-10): " choice
        
        case $choice in
            1)
                execute_command "sudo ufw allow ssh" "Allow SSH (port 22)"
                ;;
            2)
                execute_command "sudo ufw allow http" "Allow HTTP (port 80)"
                ;;
            3)
                execute_command "sudo ufw allow https" "Allow HTTPS (port 443)"
                ;;
            4)
                execute_command "sudo ufw allow ftp" "Allow FTP (port 21)"
                ;;
            5)
                execute_command "sudo ufw allow 3306" "Allow MySQL (port 3306)"
                ;;
            6)
                execute_command "sudo ufw allow 5432" "Allow PostgreSQL (port 5432)"
                ;;
            7)
                execute_command "sudo ufw default deny outgoing" "Block all outgoing traffic"
                ;;
            8)
                execute_command "sudo ufw default allow outgoing" "Allow all outgoing traffic"
                ;;
            9)
                echo -e "${CYAN}Basic web server configuration:${NC}"
                echo "- SSH (22), HTTP (80), HTTPS (443)"
                if confirm_action "Configure basic web server?"; then
                    sudo ufw allow ssh
                    sudo ufw allow http
                    sudo ufw allow https
                    echo -e "${GREEN}✓ Configuration complete!${NC}"
                fi
                read -p "Press ENTER to continue..."
                ;;
            10)
                break
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 2
                ;;
        esac
    done
}

# Function for logs
view_logs() {
    while true; do
        print_header
        echo -e "${CYAN}=== UFW LOGS ===${NC}"
        echo "1. View UFW logs"
        echo "2. Enable logging"
        echo "3. Disable logging"
        echo "4. Set logging level"
        echo "5. Last 20 lines of the log"
        echo "6. Return to main menu"
        echo
        read -p "Choose an option (1-6): " choice
        
        case $choice in
            1)
                echo -e "${CYAN}UFW Log:${NC}"
                sudo tail -50 /var/log/ufw.log 2>/dev/null || echo "Log not found or empty"
                read -p "Press ENTER to continue..."
                ;;
            2)
                execute_command "sudo ufw logging on" "Enable UFW logging"
                ;;
            3)
                execute_command "sudo ufw logging off" "Disable UFW logging"
                ;;
            4)
                echo -e "${YELLOW}Levels: low, medium, high, full${NC}"
                read -p "Enter the level: " level
                execute_command "sudo ufw logging $level" "Set UFW logging to level $level"
                ;;
            5)
                echo -e "${CYAN}Last 20 lines of the UFW log:${NC}"
                sudo tail -20 /var/log/ufw.log 2>/dev/null || echo "Log not found or empty"
                read -p "Press ENTER to continue..."
                ;;
            6)
                break
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 2
                ;;
        esac
    done
}

# Main menu
main_menu() {
    while true; do
        print_header
        echo -e "${CYAN}=== MAIN MENU ===${NC}"
        echo "1. View UFW status"
        echo "2. Basic UFW management (enable/disable/reset)"
        echo "3. Add rules"
        echo "4. Remove rules"
        echo "5. Common rules"
        echo "6. View logs"
        echo "7. Exit"
        echo
        read -p "Choose an option (1-7): " choice
        
        case $choice in
            1)
                show_status
                ;;
            2)
                manage_ufw_basic
                ;;
            3)
                add_rules
                ;;
            4)
                remove_rules
                ;;
            5)
                common_rules
                ;;
            6)
                view_logs
                ;;
            7)
                echo -e "${GREEN}Thank you for using UFW Manager!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 2
                ;;
        esac
    done
}

# Check for root privileges for some operations
check_root() {
    if [[ $EUID -ne 0 ]] && [[ $1 != "status" ]]; then
        echo -e "${YELLOW}⚠️  This script requires sudo privileges for most operations${NC}"
        echo -e "${YELLOW}   Make sure you have sudo access before proceeding${NC}"
        echo
    fi
}

# Main function
main() {
    check_ufw
    check_root
    main_menu
}

# Execute script
main