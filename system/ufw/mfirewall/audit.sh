# mfirewall module: security audit and system info
# Sourced by mfirewall.sh — do not execute directly.
security_audit() {
    show_progress "Running security audit..." 5
    
    local audit_results="SECURITY AUDIT RESULTS\n\n"
    
    # Check if UFW is enabled
    if sudo ufw status | grep -q "Status: active"; then
        audit_results+="[OK] UFW is active\n"
    else
        audit_results+="[WARNING] UFW is not active\n"
    fi
    
    # Check default policies
    local default_in
    default_in=$(sudo ufw status verbose | grep "Default:" | awk '{print $2}')
    local default_out
    # shellcheck disable=SC2034
    default_out=$(sudo ufw status verbose | grep "Default:" | awk '{print $4}')
    if [ "$default_in" = "deny" ]; then
        audit_results+="[OK] Default incoming policy is secure (deny)\n"
    else
        audit_results+="[WARNING] Default incoming policy: $default_in\n"
    fi
    
    audit_results+="\nSECURITY RECOMMENDATIONS:\n\n"
    
    if sudo ufw status | grep -q "22/tcp.*ALLOW.*Anywhere"; then
        audit_results+="[WARNING] SSH is open to everywhere - consider restricting to specific IPs\n"
    fi
    
    if sudo ufw status | grep -q "80/tcp.*ALLOW.*Anywhere"; then
        audit_results+="[INFO] HTTP port is open (standard for web servers)\n"
    fi
    
    audit_results+="\nRule count: $(sudo ufw status numbered | grep -c '^\[' || echo '0')\n"
    
    whiptail --title "Security Audit Results" --scrolltext --msgbox "$audit_results" 25 $WT_WIDTH || true
}

show_system_info() {
    local system_info="SYSTEM INFORMATION\n\n"
    system_info+="OS: $(lsb_release -d 2>/dev/null | cut -f2 || uname -a)\n"
    system_info+="Kernel: $(uname -r)\n"
    system_info+="Uptime: $(uptime -p 2>/dev/null || uptime)\n\n"
    system_info+="UFW INFORMATION:\n"
    system_info+="Version: $(ufw --version 2>/dev/null || echo 'Unknown')\n"
    system_info+="Rules count: $(sudo ufw status numbered | grep -c '^\[' || echo '0')\n\n"
    system_info+="NETWORK INTERFACES:\n"
    system_info+="$(ip -brief addr show)\n"
    
    whiptail --title "System Information" --scrolltext --msgbox "$system_info" 25 90 || true
}

