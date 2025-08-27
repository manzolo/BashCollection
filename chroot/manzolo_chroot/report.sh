# Function to create a summary report
create_summary_report() {
    local report_file="/tmp/${SCRIPT_NAME%.sh}_summary.log"
    
    {
        echo "=== Chroot Session Summary ==="
        echo "Date: $(date)"
        echo "User: $ORIGINAL_USER"
        echo ""
        echo "Configuration:"
        echo "  ROOT_DEVICE: $ROOT_DEVICE"
        echo "  ROOT_MOUNT: $ROOT_MOUNT"
        echo "  EFI_PART: ${EFI_PART:-none}"
        echo "  BOOT_PART: ${BOOT_PART:-none}"
        echo "  GUI_SUPPORT: $ENABLE_GUI_SUPPORT"
        echo "  CHROOT_USER: ${CHROOT_USER:-root}"
        echo ""
        echo "Mount Points Created:"
        for mount_point in "${MOUNTED_POINTS[@]}"; do
            echo "  $mount_point"
        done
        echo ""
        echo "Additional Mounts:"
        for mount_spec in "${ADDITIONAL_MOUNTS[@]}"; do
            echo "  $mount_spec"
        done
        echo ""
        echo "Log File: $LOG_FILE"
        echo "=== End of Summary ==="
    } > "$report_file"
    
    debug "Summary report created at $report_file"
}