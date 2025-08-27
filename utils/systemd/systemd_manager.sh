#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if whiptail is installed
if ! command_exists whiptail; then
    echo "whiptail is not installed. Install it with: sudo apt install whiptail"
    exit 1
fi

# Check if the user has root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script requires root privileges. Run with sudo."
    exit 1
fi

# Function to decode service names (e.g., \x2d -> -)
decode_service_name() {
    local name="$1"
    # Replaces \x2d with - and other encoded characters if needed
    echo "$name" | sed 's/\\x2d/-/g'
}

# Function to get the list of systemd services (UNIT only)
get_services() {
    # Use systemctl to get only the service names
    systemctl list-units --type=service --all --no-pager --no-legend | grep '\.service' | grep -v 'dev-disk-by' | sed 's/^[● ]*//' | awk '{print $1}' | while read -r UNIT; do
        # Decode the service name
        DECODED_UNIT=$(decode_service_name "$UNIT")
        # Format the output for radiolist: tag (original UNIT) and description (decoded UNIT)
        printf "%s \"%s\" OFF\n" "$UNIT" "$DECODED_UNIT"
    done
}

# Main menu function
main_menu() {
    while true; do
        CHOICE=$(whiptail --title "Systemd Service Management" --menu "Choose an option" 20 100 10 \
            "1" "List and select services" \
            "2" "View service details" \
            "3" "Start service" \
            "4" "Stop service" \
            "5" "Restart service" \
            "6" "Enable service" \
            "7" "Disable service" \
            "8" "Delete service file" \
            "9" "Reload service list" \
            "10" "Exit" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) select_and_view_service ;;
            2) view_service ;;
            3) start_service ;;
            4) stop_service ;;
            5) restart_service ;;
            6) enable_service ;;
            7) disable_service ;;
            8) delete_service ;;
            9) reload_daemon ;;
            10) exit 0 ;;
            *) whiptail --msgbox "Invalid option!" 8 40 ;;
        esac
    done
}

# Function to list services and select one to view its file
select_and_view_service() {
    # Get the list of services
    SERVICES=$(get_services)
    if [[ -z "$SERVICES" ]]; then
        whiptail --title "Systemd Service List" --msgbox "No services found!" 8 40
    else
        # Use radiolist to allow selecting a service
        SELECTED=$(whiptail --title "Systemd Service List" --radiolist \
            "Select a service to view its configuration file" 20 100 10 \
            $SERVICES 3>&1 1>&2 2>&3)
        if [[ -n "$SELECTED" ]]; then
            # Check if the service file exists
            SERVICE_FILE=$(systemctl cat "$SELECTED" --no-pager 2>/dev/null)
            if [[ $? -eq 0 && -n "$SERVICE_FILE" ]]; then
                whiptail --title "Content of $SELECTED" --scrolltext --msgbox "$SERVICE_FILE" 20 78
            else
                whiptail --msgbox "Could not view file for $SELECTED: file not found or not readable!" 8 40
            fi
        fi
    fi
}

# Function to view service details
view_service() {
    SERVICE=$(whiptail --inputbox "Enter the service name (e.g., sshd.service):" 8 78 --title "View Service" 3>&1 1>&2 2>&3)
    if [[ -n "$SERVICE" ]]; then
        if systemctl status "$SERVICE" >/dev/null 2>&1; then
            STATUS=$(systemctl status "$SERVICE" --no-pager)
            whiptail --title "Service Details: $SERVICE" --scrolltext --msgbox "$STATUS" 20 78
        else
            whiptail --msgbox "Service $SERVICE not found!" 8 40
        fi
    fi
}

# Function to start a service
start_service() {
    SERVICE=$(whiptail --inputbox "Enter the service name to start:" 8 78 --title "Start Service" 3>&1 1>&2 2>&3)
    if [[ -n "$SERVICE" ]]; then
        if systemctl start "$SERVICE" 2>/dev/null; then
            whiptail --msgbox "Service $SERVICE started successfully!" 8 40
        else
            whiptail --msgbox "Error starting service $SERVICE!" 8 40
        fi
    fi
}

# Function to stop a service
stop_service() {
    SERVICE=$(whiptail --inputbox "Enter the service name to stop:" 8 78 --title "Stop Service" 3>&1 1>&2 2>&3)
    if [[ -n "$SERVICE" ]]; then
        if systemctl stop "$SERVICE" 2>/dev/null; then
            whiptail --msgbox "Service $SERVICE stopped successfully!" 8 40
        else
            whiptail --msgbox "Error stopping service $SERVICE!" 8 40
        fi
    fi
}

# Function to restart a service
restart_service() {
    SERVICE=$(whiptail --inputbox "Enter the service name to restart:" 8 78 --title "Restart Service" 3>&1 1>&2 2>&3)
    if [[ -n "$SERVICE" ]]; then
        if systemctl restart "$SERVICE" 2>/dev/null; then
            whiptail --msgbox "Service $SERVICE restarted successfully!" 8 40
        else
            whiptail --msgbox "Error restarting service $SERVICE!" 8 40
        fi
    fi
}

# Function to enable a service
enable_service() {
    SERVICE=$(whiptail --inputbox "Enter the service name to enable:" 8 78 --title "Enable Service" 3>&1 1>&2 2>&3)
    if [[ -n "$SERVICE" ]]; then
        if systemctl enable "$SERVICE" 2>/dev/null; then
            whiptail --msgbox "Service $SERVICE enabled successfully!" 8 40
        else
            whiptail --msgbox "Error enabling service $SERVICE!" 8 40
        fi
    fi
}

# Function to disable a service
disable_service() {
    SERVICE=$(whiptail --inputbox "Enter the service name to disable:" 8 78 --title "Disable Service" 3>&1 1>&2 2>&3)
    if [[ -n "$SERVICE" ]]; then
        if systemctl disable "$SERVICE" 2>/dev/null; then
            whiptail --msgbox "Service $SERVICE disabled successfully!" 8 40
        else
            whiptail --msgbox "Error disabling service $SERVICE!" 8 40
        fi
    fi
}

# Function to delete a service file
delete_service() {
    SERVICE=$(whiptail --inputbox "Enter the service name to delete:" 8 78 --title "Delete Service" 3>&1 1>&2 2>&3)
    if [[ -n "$SERVICE" ]]; then
        if whiptail --yesno "Are you sure you want to delete service $SERVICE?" 8 40; then
            systemctl stop "$SERVICE" 2>/dev/null
            systemctl disable "$SERVICE" 2>/dev/null
            rm -f "/etc/systemd/system/$SERVICE" "/lib/systemd/system/$SERVICE" 2>/dev/null
            systemctl daemon-reload
            systemctl reset-failed
            whiptail --msgbox "Service $SERVICE deleted successfully!" 8 40
        fi
    fi
}

# Function to reload the service list
reload_daemon() {
    systemctl daemon-reload
    whiptail --msgbox "Service list reloaded!" 8 40
}

# Start the main menu
main_menu
