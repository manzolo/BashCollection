detect_iso_type() {
    local workdir="$1"
    
    # GParted Detection
    if [[ -f "$workdir/GParted-Live-Version" ]] || [[ -d "$workdir/syslinux" && -d "$workdir/utils" ]]; then
        echo "gparted"
        return 0
    fi
    
    # Windows Detection
    if find "$workdir" -type f -name "bootmgr*" -o -name "winload.exe" | grep -q . || [[ -d "$workdir/sources" ]]; then
        echo "windows"
        return 0
    fi
    
    # Ubuntu Detection (modern Ubuntu uses GRUB2, not isolinux)
    if [[ -d "$workdir/casper" ]] || [[ -f "$workdir/ubuntu" ]] || [[ -d "$workdir/.disk" ]]; then
        echo "ubuntu"
        return 0
    fi
    
    # CentOS/RHEL/Rocky/Alma Detection
    if [[ -f "$workdir/.discinfo" ]] || [[ -f "$workdir/.treeinfo" ]] || [[ -d "$workdir/BaseOS" ]]; then
        echo "redhat"
        return 0
    fi
    
    # Generic Linux Detection
    if [[ -d "$workdir/isolinux" ]] || [[ -d "$workdir/syslinux" ]] || [[ -d "$workdir/live" ]]; then
        echo "linux"
        return 0
    fi
    
    # UEFI Detection
    if [[ -d "$workdir/EFI" ]]; then
        echo "uefi"
        return 0
    fi
    
    echo "unknown"
}