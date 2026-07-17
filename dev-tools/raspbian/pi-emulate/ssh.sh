connect_ssh() {
    local port=$1
    dialog --msgbox "Connecting to SSH on port $port...\n\nPress OK to continue" 10 50
    clear
    echo "Attempting SSH connection..."
    echo "Default credentials: pi / raspberry"
    echo ""
    ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null pi@localhost
    read -p "Press ENTER to return to menu..."
}