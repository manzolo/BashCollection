#!/bin/bash
# User Interface for SSH Manager
# Provides: main menu and UI functions

# Main menu
main_menu() {
    while true; do
        local choice
        choice=$(dialog --clear --title "🔧 SSH Manager v$VERSION" --menu \
            "Select an option:\n(ESC to exit)" \
            22 64 13 \
            "1" "🚀 Connect via SSH" \
            "2" "🔑 Copy SSH key" \
            "3" "📁 Connect via SFTP" \
            "4" "🗂️  Browse with MC (SSHFS)" \
            "5" "🔀 Port Forwarding (Tunnels)" \
            "6" "➕ Add server" \
            "7" "✏️  Edit server" \
            "8" "🗑️  Remove server" \
            "9" "ℹ️  Server information" \
            "A" "🧰 Profile Toolkit" \
            "P" "🔧 Install prerequisites" \
            "0" "🚪 Exit" 2>&1 >/dev/tty)

        if should_return_to_main_menu; then
            clear
            clear_interrupt_state
            clear_main_menu_request
            continue
        fi

        case "$choice" in
            ""  ) clear; exit 0 ;;
            "1" ) handle_ssh_action "ssh" ;;
            "2" ) handle_ssh_action "ssh-copy-id" ;;
            "3" ) handle_ssh_action "sftp" ;;
            "4" ) handle_ssh_action "sshfs-mc" ;;
            "5" ) portforward_menu ;;
            "6" ) add_server ;;
            "7" ) edit_server ;;
            "8" ) remove_server ;;
            "9" ) show_server_info ;;
            "A" ) profile_toolkit_menu ;;
            "P" ) install_prerequisites ;;
            "0" ) clear; exit 0 ;;
        esac
    done
}
