cleanup_and_exit() {
    # Write to log only if it exists
    if [ -w "$LOG_FILE" ]; then
        log INFO "QEMU RPi Manager terminated"
    fi
    echo "Thank you for using QEMU Raspberry Pi Manager!"
    exit 0
}