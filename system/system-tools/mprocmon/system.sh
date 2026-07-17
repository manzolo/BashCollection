# mprocmon module: system overview
# Sourced by mprocmon.sh — do not execute directly.
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
