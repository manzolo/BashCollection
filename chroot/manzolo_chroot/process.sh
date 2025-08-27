# Find processes using a mount point
find_processes_using_mount() {
    local mount_point="$1"
    local processes=()
    
    debug "Finding processes using $mount_point"
    
    if command -v fuser &> /dev/null; then
        local pids
        pids=$(fuser -m "$mount_point" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' || true)
        
        if [[ -n "$pids" ]]; then
            while IFS= read -r pid; do
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    local cmd
                    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                    processes+=("$pid:$cmd")
                    debug "Found process using $mount_point: PID $pid ($cmd)"
                fi
            done <<< "$pids"
        fi
    fi
    
    if command -v lsof &> /dev/null; then
        local lsof_pids
        lsof_pids=$(lsof +D "$mount_point" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)
        
        if [[ -n "$lsof_pids" ]]; then
            while IFS= read -r pid; do
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    local cmd
                    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                    if [[ ! " ${processes[*]} " =~ " $pid:$cmd " ]]; then
                        processes+=("$pid:$cmd")
                        debug "Found additional process using $mount_point: PID $pid ($cmd)"
                    fi
                fi
            done <<< "$lsof_pids"
        fi
    fi
    
    printf '%s\n' "${processes[@]}"
}

# Terminate processes gracefully
terminate_processes_gracefully() {
    local mount_point="$1"
    local processes
    local success=true
    
    processes=($(find_processes_using_mount "$mount_point"))
    
    if [[ ${#processes[@]} -eq 0 ]]; then
        debug "No processes found using $mount_point"
        return 0
    fi
    
    log "Found ${#processes[@]} processes using $mount_point"
    
    for process in "${processes[@]}"; do
        local pid="${process%%:*}"
        local cmd="${process#*:}"
        
        if kill -0 "$pid" 2>/dev/null; then
            log "Sending SIGTERM to process $pid ($cmd)"
            if ! kill -TERM "$pid" 2>/dev/null; then
                warning "Failed to send SIGTERM to process $pid"
                success=false
            fi
        fi
    done
    
    sleep 3
    
    for process in "${processes[@]}"; do
        local pid="${process%%:*}"
        local cmd="${process#*:}"
        
        if kill -0 "$pid" 2>/dev/null; then
            warning "Process $pid ($cmd) still running, sending SIGKILL"
            if ! kill -KILL "$pid" 2>/dev/null; then
                error "Failed to kill process $pid"
                success=false
            else
                log "Successfully killed process $pid ($cmd)"
            fi
        else
            debug "Process $pid ($cmd) terminated gracefully"
        fi
    done
    
    sleep 1
    
    if [[ "$success" == true ]]; then
        log "All processes using $mount_point have been terminated"
        return 0
    else
        error "Some processes could not be terminated"
        return 1
    fi
}

# Find all processes chrooted to ROOT_MOUNT
find_chroot_processes() {
    local chroot_path
    chroot_path=$(realpath "$ROOT_MOUNT" 2>/dev/null || echo "$ROOT_MOUNT")
    local processes=()
    
    debug "Finding processes chrooted to $chroot_path"
    
    for proc in /proc/[0-9]*; do
        if [[ -d "$proc" ]]; then
            local root_link="$proc/root"
            if [[ -L "$root_link" ]]; then
                local proc_root
                proc_root=$(readlink "$root_link" 2>/dev/null || continue)
                if [[ "$proc_root" == "$chroot_path" ]] || [[ "$proc_root" == "$chroot_path/"* ]]; then
                    local pid="${proc##/proc/}"
                    local cmd
                    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                    processes+=("$pid:$cmd")
                    debug "Found chroot process: PID $pid ($cmd)"
                fi
            fi
        fi
    done
    
    printf '%s\n' "${processes[@]}"
}

# Terminate all chroot processes gracefully
terminate_chroot_processes() {
    local processes
    processes=($(find_chroot_processes))
    
    if [[ ${#processes[@]} -eq 0 ]]; then
        debug "No chroot processes found"
        return 0
    fi
    
    log "Found ${#processes[@]} chroot processes to terminate"
    local success=true
    
    for process in "${processes[@]}"; do
        local pid="${process%%:*}"
        local cmd="${process#*:}"
        if kill -0 "$pid" 2>/dev/null; then
            log "Sending SIGTERM to chroot process $pid ($cmd)"
            kill -TERM "$pid" 2>/dev/null || { warning "Failed to send SIGTERM to $pid"; success=false; }
        fi
    done
    
    sleep 3
    
    for process in "${processes[@]}"; do
        local pid="${process%%:*}"
        local cmd="${process#*:}"
        if kill -0 "$pid" 2>/dev/null; then
            warning "Chroot process $pid ($cmd) still running, sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || { error "Failed to kill $pid"; success=false; }
        else
            debug "Chroot process $pid ($cmd) terminated gracefully"
        fi
    done
    
    sleep 1
    
    if [[ "$success" == true ]]; then
        log "All chroot processes terminated"
        return 0
    else
        error "Some chroot processes could not be terminated"
        return 1
    fi
}