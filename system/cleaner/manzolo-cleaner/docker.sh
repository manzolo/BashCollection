# manzolo-cleaner module: Docker cleanup menu
# Sourced by manzolo-cleaner.sh — do not execute directly.
check_docker() {
    if ! command -v docker &> /dev/null; then
        dialog --msgbox "Docker is not installed on the system." 8 50
        return 1
    fi
    
    if ! docker info &> /dev/null; then
        dialog --msgbox "Docker is not running or you do not have the necessary permissions." 10 60
        return 1
    fi
    
    return 0
}

# Improved Docker menu (added space calculation for prunes)
docker_menu() {
    if ! check_docker; then
        return
    fi
    
    while true; do
        choice=$(dialog --clear --backtitle "$SCRIPT_NAME - Docker Menu" --title "Docker Cleanup" \
        --menu "Choose an option:" 18 60 8 \
        1 "Docker System Prune (full)" \
        2 "Docker Builder Prune" \
        3 "Remove stopped containers" \
        4 "Remove unused images" \
        5 "Remove unused volumes" \
        6 "Remove unused networks" \
        7 "Show Docker stats" \
        8 "Back to main menu" \
        2>&1 >/dev/tty)

        case $choice in
            1)
                dialog --defaultno --title "Confirmation" --yesno "This will remove:\n- All stopped containers\n- All unused networks\n- All unused images\n- All build cache\n\nContinue?" 12 60
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Docker System Prune" "docker system prune -a -f" "true" "true"
                fi
                ;;
            2)
                dialog --defaultno --title "Confirmation" --yesno "Remove all Docker build cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Docker Builder Prune" "docker builder prune -a -f" "true" "true"
                fi
                ;;
            3)
                dialog --title "Confirmation" --yesno "Remove all stopped containers?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Stopped Containers" "docker container prune -f" "true" "true"
                fi
                ;;
            4)
                choice_img=$(dialog --title "Choose type" --menu "What type of images to remove?" 12 50 2 \
                1 "Only dangling images" \
                2 "All unused images" \
                2>&1 >/dev/tty)
                if [ $? -eq 0 ]; then
                    if [ "$choice_img" = "1" ]; then
                        dialog --title "Confirmation" --yesno "Remove dangling images?" 8 50
                        if [ $? -eq 0 ]; then
                            run_command_in_terminal "Remove Dangling Images" "docker image prune -f" "true" "true"
                        fi
                    else
                        dialog --defaultno --title "Confirmation" --yesno "Remove all unused images?" 8 50
                        if [ $? -eq 0 ]; then
                            run_command_in_terminal "Remove All Unused Images" "docker image prune -a -f" "true" "true"
                        fi
                    fi
                fi
                ;;
            5)
                dialog --defaultno --title "Confirmation" --yesno "Remove unused volumes?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Unused Volumes" "docker volume prune -f" "true" "true"
                fi
                ;;
            6)
                dialog --title "Confirmation" --yesno "Remove unused networks?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Unused Networks" "docker network prune -f" "true" "true"
                fi
                ;;
            7)
                run_command_in_terminal "Docker Statistics" "docker system df && docker images && docker ps -a" "true" "false"
                ;;
            8|*)
                break
                ;;
        esac
    done
}

# Improved Ubuntu menu (fixed kernel removal)
