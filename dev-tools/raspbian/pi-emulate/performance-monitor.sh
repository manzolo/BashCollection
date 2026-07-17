# ==============================================================================
# PERFORMANCE MONITORING
# ==============================================================================

performance_monitor() {
    local instance_pids=$(pgrep -f qemu-system-arm)
    
    if [ -z "$instance_pids" ]; then
        dialog --msgbox "No running instances found!" 8 40
        return
    fi
    
    local perf_data=""
    perf_data+="QEMU Performance Monitor\n"
    perf_data+="========================\n\n"
    
    for pid in $instance_pids; do
        if [ -d "/proc/$pid" ]; then
            local cmdline=$(cat /proc/$pid/cmdline | tr '\0' ' ')
            local instance_name="Unknown"
            
            if [[ "$cmdline" =~ images/([^.]+)\.img ]]; then
                instance_name="${BASH_REMATCH[1]}"
            fi
            
            local cpu_usage=$(ps -p $pid -o %cpu= | tr -d ' ')
            local mem_usage=$(ps -p $pid -o %mem= | tr -d ' ')
            local virt_mem=$(ps -p $pid -o vsz= | awk '{print $1/1024 "MB"}')
            local res_mem=$(ps -p $pid -o rss= | awk '{print $1/1024 "MB"}')
            
            perf_data+="Instance: $instance_name (PID: $pid)\n"
            perf_data+="  CPU Usage: ${cpu_usage}%\n"
            perf_data+="  Memory Usage: ${mem_usage}%\n"
            perf_data+="  Virtual Memory: $virt_mem\n"
            perf_data+="  Resident Memory: $res_mem\n"
            perf_data+="  Status: Running\n\n"
        fi
    done
    
    perf_data+="System Resources:\n"
    perf_data+="  CPU Load: $(uptime | awk -F'load average:' '{print $2}')\n"
    perf_data+="  Memory: $(free -h | grep Mem | awk '{print "Used: " $3 " / Total: " $2}')\n"
    
    dialog --title "Performance Monitor" --msgbox "$perf_data" 20 70
}