connect_vnc() {
    local port=$1
    
    if [ "$port" = "0" ] || [ -z "$port" ]; then
        dialog --msgbox "VNC not enabled for this instance!" 8 40
        return
    fi
    
    if ! command -v vncviewer &> /dev/null; then
        dialog --msgbox "VNC viewer not installed!\n\nInstall with:\nsudo apt-get install tigervnc-viewer" 10 50
        return
    fi
    
    dialog --msgbox "Connecting to VNC on port $port...\n\nPress OK to continue" 10 50
    vncviewer localhost:$((port - 5900))
}