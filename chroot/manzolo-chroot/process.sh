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

terminate_chroot_processes() {
    local chroot_path
    chroot_path=$(realpath "$ROOT_MOUNT" 2>/dev/null || echo "$ROOT_MOUNT")

    debug "Scanning for processes inside chroot: $chroot_path"

    local processes_found=0
    for pid_dir in /proc/[0-9]*; do
        pid=${pid_dir#/proc/}
        
        # Check if chroot process
        local proc_root
        proc_root=$(readlink "$pid_dir/root" 2>/dev/null || true)
        
        if [[ "$proc_root" == "$chroot_path" ]] || [[ "$proc_root" == $chroot_path/* ]]; then
            local cmd
            cmd=$(ps -o comm= -p "$pid" 2>/dev/null || echo "unknown")
            log "Killing chroot process (TERM): $pid ($cmd)"
            
            # Send kill term
            if kill -TERM "$pid" 2>/dev/null; then
                processes_found=1
            fi
        fi
    done

    if [[ $processes_found -eq 1 ]]; then
        sleep 1
        for pid_dir in /proc/[0-9]*; do
            pid=${pid_dir#/proc/}
            
            local proc_root
            proc_root=$(readlink "$pid_dir/root" 2>/dev/null || true)

            if [[ "$proc_root" == "$chroot_path" ]] || [[ "$proc_root" == $chroot_path/* ]]; then
                if kill -0 "$pid" 2>/dev/null; then
                    local cmd
                    cmd=$(ps -o comm= -p "$pid" 2>/dev/null || echo "unknown")
                    warning "Force killing stubborn chroot process (KILL): $pid ($cmd)"
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            fi
        done
    fi

    return 0
}