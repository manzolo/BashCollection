get_virtual_disk_info() {
    local file="$1"
    
    local info
    info=$(qemu-img info "$file" 2> >(tee -a "$LOGFILE" >&4))
    if [ $? -eq 0 ]; then
        echo "$info"
        return 0
    fi
    
    info=$(qemu-img info --format=vpc "$file" 2> >(tee -a "$LOGFILE" >&4))
    if [ $? -eq 0 ]; then
        echo "$info"
        return 0
    fi
    
    info=$(qemu-img info --format=vhdx "$file" 2> >(tee -a "$LOGFILE" >&4))
    if [ $? -eq 0 ]; then
        echo "$info"
        return 0
    fi
    
    return 1
}