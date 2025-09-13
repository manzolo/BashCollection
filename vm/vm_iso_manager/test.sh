test_iso_with_qemu() {
    local iso_file="$1"
    local mode="$2"
    
    case "$mode" in
        "bios")
            echo "[INFO] Starting QEMU in BIOS mode..."
            qemu-system-x86_64 -m 2G -cdrom "$iso_file" -boot d -enable-kvm 2>/dev/null || \
            qemu-system-x86_64 -m 2G -cdrom "$iso_file" -boot d
            ;;
        "uefi")
            echo "[INFO] Starting QEMU in UEFI mode..."
            local ovmf_code=""
            
            # Find OVMF files
            for ovmf_dir in "/usr/share/OVMF" "/usr/share/ovmf" "/usr/share/qemu" "/usr/share/edk2-ovmf"; do
                if [[ -f "$ovmf_dir/OVMF_CODE.fd" ]]; then
                    ovmf_code="$ovmf_dir/OVMF_CODE.fd"
                    break
                elif [[ -f "$ovmf_dir/OVMF.fd" ]]; then
                    ovmf_code="$ovmf_dir/OVMF.fd"
                    break
                fi
            done
            
            [[ -z "$ovmf_code" ]] && error "OVMF firmware not found. Install with: sudo apt-get install ovmf"
            
            qemu-system-x86_64 -m 2G -cdrom "$iso_file" -boot d \
                -drive if=pflash,format=raw,readonly,file="$ovmf_code" \
                -enable-kvm 2>/dev/null || \
            qemu-system-x86_64 -m 2G -cdrom "$iso_file" -boot d \
                -drive if=pflash,format=raw,readonly,file="$ovmf_code"
            ;;
    esac
}