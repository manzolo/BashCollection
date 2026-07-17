# manzolo-cleaner module: Ubuntu system cleanup menu
# Sourced by manzolo-cleaner.sh — do not execute directly.
ubuntu_menu() {
    while true; do
        choice=$(dialog --clear --backtitle "$SCRIPT_NAME - Ubuntu Menu" --title "Ubuntu Cleanup" \
        --menu "Choose an option:" 20 70 10 \
        1 "Update package cache" \
        2 "Remove unnecessary packages" \
        3 "Clean APT cache" \
        4 "Clear old kernels" \
        5 "Clean system logs" \
        6 "Empty trash bin" \
        7 "Clean thumbnail cache" \
        8 "Full Ubuntu cleanup" \
        9 "Show disk space" \
        10 "Back to main menu" \
        2>&1 >/dev/tty)

        case $choice in
            1)
                run_command_in_terminal "Update Cache" "sudo apt update" "true" "false"
                ;;
            2)
                dialog --title "Confirmation" --yesno "Remove unnecessary packages?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Unnecessary Packages" "sudo apt autoremove -y && sudo apt autoclean" "true" "true"
                fi
                ;;
            3)
                dialog --title "Confirmation" --yesno "Clean the APT cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean APT Cache" "sudo apt clean" "true" "true"
                fi
                ;;
            4)
                dialog --defaultno --title "Confirmation" --yesno "Remove old kernels?\nWARNING: Always keep at least 2 kernels for safety." 10 60
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clear Old Kernels" "
                    {
                        echo 'Installed Kernels:'
                        dpkg --list | grep '^ii' | grep linux-image | awk '{print \$2}' | sort -V
                        echo ''
                        echo 'Current Kernel: $(uname -r)'
                        echo ''
                        # List kernels to remove (all except current and the 2 most recent)
                        kernels_to_remove=\$(dpkg --list | grep '^ii' | grep linux-image | awk '{print \$2}' | grep -v \"\$(uname -r)\" | sort -V | head -n -2)
                        if [ -z \"\$kernels_to_remove\" ]; then
                            echo 'No old kernels to remove (keeping at least 2).'
                        else
                            echo 'Kernels to remove:'
                            echo \"\$kernels_to_remove\"
                            echo ''
                            echo 'Removing old kernels...'
                            sudo apt-get purge -y \$kernels_to_remove 2>/dev/null || true
                            sudo apt-get autoremove -y
                            echo 'Old kernels removed successfully.'
                        fi
                    }" "true" "true"
                fi
                ;;
            5)
                dialog --title "Confirmation" --yesno "Clean system logs?\nOnly the last 7 days will be kept." 10 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean Logs" "sudo journalctl --vacuum-time=7d && sudo find /var/log -name '*.log' -type f -mtime +30 -delete || true" "true" "true"
                fi
                ;;
            6)
                dialog --title "Confirmation" --yesno "Empty the trash bin?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Empty Trash Bin" "rm -rf ~/.local/share/Trash/* || true" "true" "true"
                fi
                ;;
            7)
                dialog --title "Confirmation" --yesno "Clean the thumbnail cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean Thumbnails" "rm -rf ~/.cache/thumbnails/* || true" "true" "true"
                fi
                ;;
            8)
                dialog --defaultno --title "Confirmation" --yesno "Perform full Ubuntu cleanup?\nThis will include all cleanup options." 10 60
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Full Ubuntu Cleanup" "
                    {
                        echo 'Starting full cleanup...'
                        sudo apt update
                        sudo apt autoremove -y
                        sudo apt clean
                        sudo apt autoclean
                        sudo journalctl --vacuum-time=7d
                        rm -rf ~/.local/share/Trash/* || true
                        rm -rf ~/.cache/thumbnails/* || true
                        rm -rf ~/.cache/* 2>/dev/null || true
                        echo 'Cleanup completed!'
                    }" "true" "true"
                fi
                ;;
            9)
                run_command_in_terminal "Disk Space" "df -h | awk 'NR==1 || /^\/dev\//' && du -sh ~/.* 2>/dev/null | sort -hr | head -10" "true" "false"
                ;;
            10|*)
                break
                ;;
        esac
    done
}

# Settings menu (unchanged, minor fixes)
