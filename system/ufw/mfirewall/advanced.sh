# mfirewall module: examples, bulk management, predefined configs
# Sourced by mfirewall.sh — do not execute directly.
# =================== ADVANCED FEATURES ===================

show_advanced_examples() {
    local examples_text="ADVANCED UFW COMMAND EXAMPLES\n\n"
    
    examples_text+="=== BASICS AND MANAGEMENT ===\n"
    examples_text+="1. Enable/disable UFW:\n"
    examples_text+="    sudo ufw enable\n    sudo ufw disable\n\n"
    
    examples_text+="2. Check status:\n"
    examples_text+="    sudo ufw status verbose\n    sudo ufw status numbered\n\n"
    
    examples_text+="=== BASIC RULES ===\n"
    examples_text+="3. Allow SSH from anywhere:\n"
    examples_text+="    sudo ufw allow ssh\n\n"
    
    examples_text+="4. Deny FTP traffic:\n"
    examples_text+="    sudo ufw deny 21/tcp\n\n"
    
    examples_text+="5. Limit SSH connections (anti-brute force):\n"
    examples_text+="    sudo ufw limit 22/tcp\n\n"
    
    examples_text+="=== SUBNETS AND CIDR ===\n"
    examples_text+="6. Allow entire subnet (CIDR notation):\n"
    examples_text+="    sudo ufw allow from 192.168.1.0/24\n\n"
    
    examples_text+="7. Allow subnet to specific port:\n"
    examples_text+="    sudo ufw allow from 10.0.0.0/8 to any port 22\n\n"
    
    examples_text+="8. Deny range of IPs:\n"
    examples_text+="    sudo ufw deny from 203.0.113.0/24\n\n"
    
    examples_text+="9. Allow specific IP range to web server:\n"
    examples_text+="    sudo ufw allow proto tcp from 172.16.0.0/12 to any port 80,443\n\n"
    
    examples_text+="=== INTERFACES AND DIRECTION ===\n"
    examples_text+="10. Allow on specific interface:\n"
    examples_text+="     sudo ufw allow in on eth0 to any port 80\n\n"
    
    examples_text+="11. Block outgoing traffic to IP:\n"
    examples_text+="     sudo ufw reject out to 10.0.0.50\n\n"
    
    examples_text+="12. Allow from specific interface and IP range:\n"
    examples_text+="     sudo ufw allow in on eth1 from 192.168.2.0/24\n\n"
    
    examples_text+="=== PORTS AND PROTOCOLS ===\n"
    examples_text+="13. Allow port range:\n"
    examples_text+="     sudo ufw allow 60000:61000/udp\n\n"
    
    examples_text+="14. Allow multiple ports:\n"
    examples_text+="     sudo ufw allow 80,443/tcp\n\n"
    
    examples_text+="15. Allow specific protocol:\n"
    examples_text+="     sudo ufw allow proto udp to any port 53\n\n"
    
    examples_text+="=== MANAGING RULES ===\n"
    examples_text+="16. Insert rule at specific position:\n"
    examples_text+="     sudo ufw insert 1 deny from 203.0.113.1\n\n"
    
    examples_text+="17. Delete rule by number:\n"
    examples_text+="     sudo ufw delete 3\n\n"
    
    examples_text+="18. Delete specific rule:\n"
    examples_text+="     sudo ufw delete allow 80/tcp\n\n"
    
    examples_text+="=== COMPLEX EXAMPLES ===\n"
    examples_text+="19. Allow LAN access but restrict specific IP:\n"
    examples_text+="     sudo ufw allow from 192.168.1.0/24\n"
    examples_text+="     sudo ufw deny from 192.168.1.100\n\n"
    
    examples_text+="20. Complex rule with multiple parameters:\n"
    examples_text+="     sudo ufw allow proto tcp from 192.168.1.0/24 to any port 22,80,443\n"
    
    whiptail --title "Advanced UFW Examples" --scrolltext --msgbox "$examples_text" 30 100 || true
}

bulk_rule_management() {
    local choice
    choice=$(whiptail --title "Bulk Rule Management" --menu "Choose bulk operation:" $WT_HEIGHT $WT_WIDTH 4 \
    "1" "Import rules from file" \
    "2" "Export current rules to file" \
    "3" "Apply predefined rule set" \
    "4" "Return to main menu" 3>&1 1>&2 2>&3) || true
    
    case $choice in
        1)
            local file_path
            file_path=$(whiptail --title "Import Rules" --inputbox "Enter file path containing UFW rules:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
            if [ -n "$file_path" ] && [ -f "$file_path" ]; then
                if confirm_action "Import rules from $file_path?"; then
                    local count=0
                    while IFS= read -r line; do
                        if [[ $line =~ ^[[:space:]]*# ]] || [[ -z $line ]]; then
                            continue
                        fi
                        sudo ufw $line 2>/dev/null && ((count++))
                    done < "$file_path"
                    show_message "Import Complete" "$count rules imported successfully" "success"
                fi
            else
                show_message "File Error" "File not found or invalid path" "error"
            fi
            ;;
        2)
            local export_file
            export_file="/tmp/ufw_rules_$(date +%Y%m%d_%H%M%S).txt"
            sudo ufw status numbered | tee "$export_file" >/dev/null
            show_message "Export Complete" "Rules exported to:\n$export_file" "success"
            ;;
        3)
            predefined_configurations
            ;;
    esac
}

predefined_configurations() {
    local choice
    choice=$(whiptail --title "Predefined Rule Sets" --menu "Choose configuration:" $WT_HEIGHT $WT_WIDTH 6 \
    "1" "Web Server (HTTP/HTTPS + SSH)" \
    "2" "Database Server (MySQL/PostgreSQL + SSH)" \
    "3" "Mail Server (SMTP/POP3/IMAP + SSH)" \
    "4" "Development Server (Common dev ports)" \
    "5" "Secure Desktop (Minimal access)" \
    "6" "Gaming Server configurations" 3>&1 1>&2 2>&3) || true
    
    case $choice in
        1)
            if confirm_action "Apply web server configuration?\n\nThis will allow:\n- SSH (22)\n- HTTP (80)\n- HTTPS (443)\n- Alt HTTP (8080)"; then
                show_progress "Applying web server rules..." 4
                sudo ufw allow ssh
                sudo ufw allow http
                sudo ufw allow https
                sudo ufw allow 8080/tcp comment 'Alternative HTTP'
                show_message "Configuration Applied" "Web server configuration applied successfully" "success"
            fi
            ;;
        2)
            if confirm_action "Apply database server configuration?\n\nThis will allow:\n- SSH (22)\n- MySQL (3306)\n- PostgreSQL (5432)"; then
                show_progress "Applying database server rules..." 3
                sudo ufw allow ssh
                sudo ufw allow 3306/tcp comment 'MySQL'
                sudo ufw allow 5432/tcp comment 'PostgreSQL'
                show_message "Configuration Applied" "Database server configuration applied successfully" "success"
            fi
            ;;
        3)
            if confirm_action "Apply mail server configuration?\n\nThis will allow:\n- SSH, SMTP, POP3, POP3S, IMAP, IMAPS"; then
                show_progress "Applying mail server rules..." 6
                sudo ufw allow ssh
                sudo ufw allow 25/tcp comment 'SMTP'
                sudo ufw allow 110/tcp comment 'POP3'
                sudo ufw allow 995/tcp comment 'POP3S'
                sudo ufw allow 143/tcp comment 'IMAP'
                sudo ufw allow 993/tcp comment 'IMAPS'
                show_message "Configuration Applied" "Mail server configuration applied successfully" "success"
            fi
            ;;
        4)
            if confirm_action "Apply development server configuration?\n\nCommon development ports for Node.js, Django, Angular, React"; then
                show_progress "Applying development server rules..." 5
                sudo ufw allow ssh
                sudo ufw allow 3000/tcp comment 'Node.js dev'
                sudo ufw allow 8000/tcp comment 'Django dev'
                sudo ufw allow 4200/tcp comment 'Angular dev'
                sudo ufw allow 3001/tcp comment 'React dev'
                show_message "Configuration Applied" "Development server configuration applied successfully" "success"
            fi
            ;;
        5)
            if confirm_action "Apply secure desktop configuration?\n\nThis will reset UFW and apply minimal rules"; then
                show_progress "Applying secure desktop rules..." 4
                sudo ufw --force reset
                sudo ufw default deny incoming
                sudo ufw default allow outgoing
                sudo ufw allow out 53 comment 'DNS'
                sudo ufw allow out 80 comment 'HTTP'
                sudo ufw allow out 443 comment 'HTTPS'
                sudo ufw enable
                show_message "Configuration Applied" "Secure desktop configuration applied successfully" "success"
            fi
            ;;
        6)
            gaming_server_config
            ;;
    esac
}

gaming_server_config() {
    local choice
    choice=$(whiptail --title "Gaming Server Configuration" --menu "Choose gaming server type:" $WT_HEIGHT $WT_WIDTH 3 \
    "1" "Steam Server" \
    "2" "Minecraft Server" \
    "3" "Custom Gaming Ports" 3>&1 1>&2 2>&3) || true
    
    case $choice in
        1)
            if confirm_action "Configure Steam server ports?\n(27015 TCP/UDP)"; then
                sudo ufw allow 27015/tcp comment 'Steam Server'
                sudo ufw allow 27015/udp comment 'Steam Server'
                show_message "Steam Config" "Steam server ports configured" "success"
            fi
            ;;
        2)
            if confirm_action "Configure Minecraft server port?\n(25565 TCP)"; then
                sudo ufw allow 25565/tcp comment 'Minecraft Server'
                show_message "Minecraft Config" "Minecraft server port configured" "success"
            fi
            ;;
        3)
            local port_range
            port_range=$(whiptail --title "Custom Gaming Ports" --inputbox "Enter custom port range (e.g., 7777:7784):" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
            if [ -n "$port_range" ]; then
                sudo ufw allow $port_range comment 'Custom Gaming'
                show_message "Custom Gaming" "Custom gaming ports configured" "success"
            fi
            ;;
    esac
}

