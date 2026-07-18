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
                        # Only numbered kernel images: meta-packages such as
                        # linux-image-generic(-hwe) must never be candidates —
                        # they sort after numbered kernels in sort -V, so the
                        # old 'grep linux-image' filter kept the metas and
                        # purged the real fallback kernels instead.
                        echo 'Installed kernel images:'
                        dpkg --list | awk '/^ii[[:space:]]+linux-image-[0-9]/{print \$2}' | sort -V
                        echo ''
                        echo 'Current kernel: $(uname -r)'
                        echo ''
                        kernels_to_remove=\$(dpkg --list | awk '/^ii[[:space:]]+linux-image-[0-9]/{print \$2}' | grep -v -F \"\$(uname -r)\" | sort -V | head -n -2)
                        if [ -z \"\$kernels_to_remove\" ]; then
                            echo 'No old kernels to remove (keeping current + 2 most recent).'
                        else
                            echo 'Kernels to remove:'
                            echo \"\$kernels_to_remove\"
                            echo ''
                            echo 'Removing old kernels...'
                            if sudo apt-get purge -y \$kernels_to_remove; then
                                sudo apt-get autoremove -y
                                echo 'Old kernels removed successfully.'
                            else
                                echo 'ERROR: kernel removal failed. Nothing else was touched.'
                                false
                            fi
                        fi
                    }" "true" "true"
                fi
                ;;
            5)
                dialog --title "Confirmation" --yesno "Clean system logs?\n\n- systemd journal: keep last 7 days\n- /var/log/*.log not touched in 30+ days: deleted" 11 60
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean Logs" "sudo journalctl --vacuum-time=7d && sudo find /var/log -name '*.log' -type f -mtime +30 -delete || true" "true" "true"
                fi
                ;;
            6)
                dialog --title "Confirmation" --yesno "Empty the trash bin?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Empty Trash Bin" "rm -rf ~/.local/share/Trash/files ~/.local/share/Trash/info || true" "true" "true"
                fi
                ;;
            7)
                dialog --title "Confirmation" --yesno "Clean the thumbnail cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean Thumbnails" "rm -rf ~/.cache/thumbnails/* || true" "true" "true"
                fi
                ;;
            8)
                dialog --defaultno --title "Confirmation" --yesno "Perform full Ubuntu cleanup?\n\nIncludes: apt update/autoremove/clean, journal vacuum (7d),\ntrash bin, thumbnail cache.\nOld kernels are NOT removed (use the dedicated entry)." 12 65
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Full Ubuntu Cleanup" "
                    {
                        echo 'Starting full cleanup...'
                        sudo apt update
                        sudo apt autoremove -y
                        sudo apt clean
                        sudo apt autoclean
                        sudo journalctl --vacuum-time=7d
                        rm -rf ~/.local/share/Trash/files ~/.local/share/Trash/info || true
                        rm -rf ~/.cache/thumbnails/* || true
                        echo 'Cleanup completed!'
                    }" "true" "true"
                fi
                ;;
            9)
                run_command_in_terminal "Disk Space" "df -h | awk 'NR==1 || /^\/dev\//' && du -sh ~/.[!.]* 2>/dev/null | sort -hr | head -10" "true" "false"
                ;;
            10|*)
                break
                ;;
        esac
    done
}

# Settings menu (unchanged, minor fixes)
