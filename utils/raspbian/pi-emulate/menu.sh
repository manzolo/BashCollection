show_main_menu() {
    dialog --clear --backtitle "QEMU Raspberry Pi Manager v${VERSION} - Enhanced with Audio & Modern Kernels" \
        --title "[ Main Menu ]" \
        --menu "Select an option:" 20 70 13 \
        "1" "Quick Start (Auto-detect best config)" \
        "2" "Create New Instance" \
        "3" "Manage Instances" \
        "4" "Download OS Images" \
        "5" "Kernel Management" \
        "6" "Audio Configuration" \
        "7" "System Diagnostics" \
        "8" "Performance Monitor" \
        "9" "View Logs" \
        "10" "Performance Tips" \
        "11" "Clean Workspace" \
        "0" "Exit" \
        2>&1 >/dev/tty
}