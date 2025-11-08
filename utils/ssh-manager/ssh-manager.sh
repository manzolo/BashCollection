#!/bin/bash
# PKG_NAME: ssh-manager
# PKG_VERSION: 2.2.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), openssh-client
# PKG_RECOMMENDS: sshpass
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Enhanced SSH connection manager with profiles and automation
# PKG_LONG_DESCRIPTION: Comprehensive SSH management tool for managing
#  multiple SSH connections, profiles, and automation tasks.
#  .
#  Features:
#  - Save and manage SSH connection profiles
#  - Quick connect to saved hosts
#  - SSH key management and generation
#  - Port forwarding configuration
#  - Connection logging and history
#  - Batch operations across multiple hosts
#  - YAML-based configuration
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Enhanced SSH Manager
# Version: 2.2 - Named server identification

# Configuration
CONFIG_DIR="$HOME/.config/manzolo-ssh-manager"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
LOG_FILE="$CONFIG_DIR/ssh-manager.log"

# Colors for output
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
RESET='\e[0m'

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    rotate_log
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$LOG_FILE"
}

# Log rotation
rotate_log() {
    local max_size=$((1024*1024)) # 1MB
    if [[ -f "$LOG_FILE" ]]; then
        local file_size
        file_size=$(wc -c < "$LOG_FILE" 2>/dev/null)
        if [[ -n "$file_size" && "$file_size" =~ ^[0-9]+$ && "$file_size" -gt "$max_size" ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.1"
            touch "$LOG_FILE"
            log_message "INFO" "Log file rotated"
        fi
    fi
}

# Function to print colored messages
print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${RESET}"
}

# Configuration initialization
init_config() {
    mkdir -p "$CONFIG_DIR"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << EOF
servers:
  - name: "Example Server"
    host: "example.com"
    user: "root"
    port: 22
    description: "Example server"
EOF
        print_message "$GREEN" "✅ Configuration file created: $CONFIG_FILE"
        log_message "INFO" "Initial configuration file created"
    fi
}

# Backup configuration
backup_config() {
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-$(date +%Y%m%d%H%M%S)"
    log_message "INFO" "Configuration backed up"
}

# Install prerequisites
install_prerequisites() {
    print_message "$BLUE" "🔧 Installing prerequisites..."
    
    if command -v dialog &> /dev/null && command -v yq &> /dev/null; then
        print_message "$GREEN" "✅ Prerequisites already installed"
        return 0
    fi
    
    local pkg_manager=""
    if command -v apt >/dev/null 2>&1; then
        pkg_manager="apt"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_manager="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        pkg_manager="pacman"
    else
        print_message "$RED" "❌ No supported package manager found (apt/yum/dnf/pacman)"
        return 1
    fi
    
    case "$pkg_manager" in
        "apt")
            sudo apt update -qq && sudo apt install -qqy dialog wget
            ;;
        "yum")
            sudo yum install -y dialog wget
            ;;
        "dnf")
            sudo dnf install -y dialog wget
            ;;
        "pacman")
            sudo pacman -Syu --noconfirm dialog wget
            ;;
    esac || {
        print_message "$RED" "❌ Error installing dialog and wget"
        return 1
    }
    
    if ! command -v yq &> /dev/null; then
        local arch
        arch=$(uname -m)
        local yq_url
        case "$arch" in
            x86_64) yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" ;;
            aarch64) yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64" ;;
            *) print_message "$RED" "❌ Unsupported architecture: $arch"; return 1 ;;
        esac
        sudo wget -q "$yq_url" -O /usr/local/bin/yq || {
            print_message "$RED" "❌ Error downloading yq"
            return 1
        }
        sudo chmod +x /usr/local/bin/yq
    fi
    
    print_message "$GREEN" "✅ Prerequisites installed successfully"
    log_message "INFO" "Prerequisites installed"
}

# Validate YAML configuration
validate_config() {
    if ! yq eval '.servers' "$CONFIG_FILE" &> /dev/null; then
        print_message "$RED" "❌ Invalid YAML in configuration file"
        return 1
    fi
    
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")
    
    if [[ "$server_count" == "0" || "$server_count" == "null" ]]; then
        print_message "$YELLOW" "⚠️ No servers configured"
        return 1
    fi
    
    for ((i=0; i<server_count; i++)); do
        local name host user port
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
        
        [[ -z "$name" || "$name" == "null" ]] && { print_message "$RED" "❌ Server $i: Missing name"; return 1; }
        [[ -z "$host" || "$host" == "null" ]] && { print_message "$RED" "❌ Server $i: Missing host"; return 1; }
        [[ -z "$user" || "$user" == "null" ]] && { print_message "$RED" "❌ Server $i: Missing user"; return 1; }
        if [[ "$port" != "null" && ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
            print_message "$RED" "❌ Server $i: Invalid port '$port'"
            return 1
        fi
    done
    
    return 0
}

# Get server index by name
get_server_index_by_name() {
    local server_name="$1"
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")
    
    for ((i=0; i<server_count; i++)); do
        local name
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        if [[ "$name" == "$server_name" ]]; then
            echo "$i"
            return 0
        fi
    done
    
    return 1
}

# Check for SSH key existence
check_ssh_key() {
    if [[ ! -f "$HOME/.ssh/id_rsa.pub" ]]; then
        print_message "$RED" "❌ No SSH public key found. Generate one with 'ssh-keygen'."
        return 1
    fi
    return 0
}

# Test SSH connectivity
test_ssh_connection() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"
    
    print_message "$BLUE" "🔍 Testing connectivity to $user@$host:$port..."
    
    if timeout 5 ssh -o ConnectTimeout=3 -p "$port" "$user@$host" exit 2> ssh_error.log; then
        print_message "$GREEN" "✅ Connection successful"
        rm -f ssh_error.log
        return 0
    else
        print_message "$RED" "❌ Connection failed: $(cat ssh_error.log)"
        log_message "ERROR" "Connection test failed for $user@$host:$port - $(cat ssh_error.log)"
        rm -f ssh_error.log
        return 1
    fi
}

# Generic function to handle SSH actions
handle_ssh_action() {
    local action="$1"
    
    if ! validate_config; then
        dialog --title "Error" --msgbox "Invalid or empty configuration file" 8 50
        return 1
    fi
    
    while true; do
        local menu_items=()
        local server_count
        server_count=$(yq eval '.servers | length' "$CONFIG_FILE")
        
        for ((i=0; i<server_count; i++)); do
            local name host user port description
            name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
            host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
            user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
            port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
            description=$(yq eval ".servers[$i].description // \"\"" "$CONFIG_FILE")
            
            local display_text="$name ($user@$host:$port)"
            [[ -n "$description" && "$description" != "null" ]] && display_text="$display_text - $description"
            
            # Usa il nome del server come identificatore invece dell'indice
            menu_items+=("$name" "$display_text")
        done
        
        menu_items+=("T" "🔍 Test connectivity")
        menu_items+=("Q" "← Back to main menu")
        
        local choice
        choice=$(dialog --clear --title "SSH Manager - $action" --menu \
            "Select a server:\n(Use arrow keys and press Enter, or type to search)" \
            20 80 10 "${menu_items[@]}" 2>&1 >/dev/tty)
        
        case "$choice" in
            ""|"Q") clear; return ;;
            "T") test_connectivity_menu; continue ;;
            *)
                # Trova l'indice del server dal nome
                local server_index
                server_index=$(get_server_index_by_name "$choice")
                if [[ $? -eq 0 ]]; then
                    execute_ssh_action "$action" "$server_index"
                fi
                ;;
        esac
    done
}

# Check for required packages
check_sshfs_mc() {
    local missing_packages=()
    
    if ! command -v sshfs &> /dev/null; then
        missing_packages+=("sshfs")
    fi
    
    if ! command -v mc &> /dev/null; then
        missing_packages+=("mc")
    fi
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        local packages_list=$(printf ", %s" "${missing_packages[@]}")
        packages_list=${packages_list:2}  # Remove leading ", "
        
        dialog --title "Missing Packages" --yesno \
            "The following packages are required for SSHFS+MC functionality:\n\n$packages_list\n\nWould you like to install them now?" \
            12 60
        
        if [[ $? -eq 0 ]]; then
            install_sshfs_mc_packages "${missing_packages[@]}"
            return $?
        else
            return 1
        fi
    fi
    
    return 0
}

# Install SSHFS and MC packages
install_sshfs_mc_packages() {
    local packages=("$@")
    
    print_message "$BLUE" "🔧 Installing packages: ${packages[*]}..."
    
    local pkg_manager=""
    if command -v apt >/dev/null 2>&1; then
        pkg_manager="apt"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_manager="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        pkg_manager="pacman"
    else
        print_message "$RED" "❌ No supported package manager found"
        return 1
    fi
    
    case "$pkg_manager" in
        "apt")
            sudo apt update -qq && sudo apt install -qqy "${packages[@]}"
            ;;
        "yum")
            sudo yum install -y "${packages[@]}"
            ;;
        "dnf")
            sudo dnf install -y "${packages[@]}"
            ;;
        "pacman")
            sudo pacman -Syu --noconfirm "${packages[@]}"
            ;;
    esac || {
        print_message "$RED" "❌ Error installing packages: ${packages[*]}"
        return 1
    }
    
    print_message "$GREEN" "✅ Packages installed successfully"
    return 0
}

# Execute specific SSH action
execute_ssh_action() {
    local action="$1"
    local index="$2"
    
    local name host user port ssh_options
    name=$(yq eval ".servers[$index].name" "$CONFIG_FILE")
    host=$(yq eval ".servers[$index].host" "$CONFIG_FILE")
    user=$(yq eval ".servers[$index].user" "$CONFIG_FILE")
    port=$(yq eval ".servers[$index].port // 22" "$CONFIG_FILE")
    ssh_options=$(yq eval ".servers[$index].ssh_options // \"\"" "$CONFIG_FILE")
    
    clear
    
    case "$action" in
        "ssh")
            print_message "$BLUE" "🚀 Connecting to: $user@$host:$port ($name)..."
            log_message "INFO" "SSH connection to $user@$host:$port"
            ssh $ssh_options -p "$port" -t "$user@$host" 2> ssh_error.log
            local status=$?
            ;;
        "ssh-copy-id")
            if ! check_ssh_key; then
                dialog --title "Error" --msgbox "No SSH public key found" 8 50
                return 1
            fi
            print_message "$BLUE" "🔑 Copying SSH key to: $user@$host:$port ($name)..."
            log_message "INFO" "Copying SSH key to $user@$host:$port"
            ssh-copy-id $ssh_options -p "$port" "$user@$host" 2> ssh_error.log
            local status=$?
            ;;
        "sftp")
            print_message "$BLUE" "📁 Starting SFTP with: $user@$host:$port ($name)..."
            log_message "INFO" "SFTP connection to $user@$host:$port"
            sftp $ssh_options -P "$port" "$user@$host" 2> ssh_error.log
            local status=$?
            ;;
        "sshfs-mc")
            if ! check_sshfs_mc; then
                print_message "$RED" "❌ Required packages not available"
                print_message "$YELLOW" "\nPress ENTER to continue..."
                read -r
                return 1
            fi
            
            execute_sshfs_mc "$name" "$host" "$user" "$port" "$ssh_options"
            local status=$?
            ;;
    esac
    
    if [[ $status -ne 0 ]]; then
        print_message "$RED" "❌ Error during $action: $(cat ssh_error.log 2>/dev/null || echo 'Unknown error')"
        log_message "ERROR" "$action failed on $user@$host:$port - $(cat ssh_error.log 2>/dev/null || echo 'Unknown error')"
        rm -f ssh_error.log
    else
        case "$action" in
            "ssh") print_message "$GREEN" "✅ SSH connection terminated successfully" ;;
            "ssh-copy-id") print_message "$GREEN" "✅ SSH key copied successfully" ;;
            "sftp") print_message "$GREEN" "✅ SFTP session terminated" ;;
            "sshfs-mc") print_message "$GREEN" "✅ SSHFS+MC session completed" ;;
        esac
        log_message "INFO" "Operation $action completed successfully on $user@$host:$port"
    fi
    
    if [[ "$action" != "sshfs-mc" ]]; then
        print_message "$YELLOW" "\nPress ENTER to continue..."
        read -r
    fi
}

# Execute SSHFS + MC
execute_sshfs_mc() {
    local name="$1"
    local host="$2"
    local user="$3"
    local port="$4"
    local ssh_options="$5"
    
    # Create mount point
    local mount_point="/tmp/sshfs-${name// /_}-$"
    mkdir -p "$mount_point" || {
        print_message "$RED" "❌ Cannot create mount point: $mount_point"
        return 1
    }
    
    print_message "$BLUE" "🔗 Mounting remote filesystem: $user@$host:$port ($name)..."
    print_message "$BLUE" "📂 Mount point: $mount_point"
    
    # SSHFS mount options
    local sshfs_options="-p $port"
    if [[ -n "$ssh_options" && "$ssh_options" != "null" ]]; then
        sshfs_options="$sshfs_options -o ssh_command='ssh $ssh_options'"
    fi
    
    # Add common SSHFS options for better experience
    sshfs_options="$sshfs_options -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3"
    
    # Mount the remote filesystem
    if sshfs $sshfs_options "$user@$host:/" "$mount_point" 2> sshfs_error.log; then
        print_message "$GREEN" "✅ Remote filesystem mounted successfully"
        log_message "INFO" "SSHFS mount successful: $user@$host:/ -> $mount_point"
        
        print_message "$BLUE" "🗂️  Starting Midnight Commander..."
        print_message "$YELLOW" "💡 When you exit MC, the remote filesystem will be automatically unmounted"
        
        # Wait a moment to let user read the message
        sleep 2
        
        # Start Midnight Commander
        mc "$mount_point" 2> mc_error.log
        local mc_status=$?
        
        # Unmount the filesystem
        print_message "$BLUE" "🔌 Unmounting remote filesystem..."
        if fusermount -u "$mount_point" 2> unmount_error.log; then
            print_message "$GREEN" "✅ Remote filesystem unmounted successfully"
            log_message "INFO" "SSHFS unmount successful: $mount_point"
        else
            print_message "$YELLOW" "⚠️  Warning during unmount: $(cat unmount_error.log)"
            log_message "WARNING" "SSHFS unmount warning: $(cat unmount_error.log)"
            # Try force unmount
            if fusermount -uz "$mount_point" 2>/dev/null; then
                print_message "$GREEN" "✅ Force unmount successful"
            fi
        fi
        
        # Clean up mount point
        rmdir "$mount_point" 2>/dev/null
        
        # Clean up error logs
        rm -f sshfs_error.log mc_error.log unmount_error.log
        
        if [[ $mc_status -eq 0 ]]; then
            return 0
        else
            print_message "$YELLOW" "⚠️  MC exited with status: $mc_status"
            return 0  # Non è necessariamente un errore
        fi
        
    else
        print_message "$RED" "❌ Failed to mount remote filesystem: $(cat sshfs_error.log)"
        log_message "ERROR" "SSHFS mount failed: $user@$host:/ -> $mount_point - $(cat sshfs_error.log)"
        
        # Clean up
        rmdir "$mount_point" 2>/dev/null
        rm -f sshfs_error.log
        
        print_message "$YELLOW" "\nPress ENTER to continue..."
        read -r
        return 1
    fi
}

# Connectivity test menu
test_connectivity_menu() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "Invalid configuration file" 8 50
        return
    fi
    
    local menu_items=()
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")
    
    for ((i=0; i<server_count; i++)); do
        local name host user
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        menu_items+=("$name" "$name ($user@$host)")
    done
    
    local choice
    choice=$(dialog --clear --title "Connectivity Test" --menu \
        "Select server to test:" \
        15 60 8 "${menu_items[@]}" 2>&1 >/dev/tty)
    
    if [[ -n "$choice" ]]; then
        local server_index
        server_index=$(get_server_index_by_name "$choice")
        if [[ $? -eq 0 ]]; then
            local user host port
            user=$(yq eval ".servers[$server_index].user" "$CONFIG_FILE")
            host=$(yq eval ".servers[$server_index].host" "$CONFIG_FILE")
            port=$(yq eval ".servers[$server_index].port // 22" "$CONFIG_FILE")
            
            clear
            test_ssh_connection "$user" "$host" "$port"
            print_message "$YELLOW" "\nPress ENTER to continue..."
            read -r
        fi
    fi
}

# Check for duplicate server
check_duplicate_server() {
    local host="$1"
    local user="$2"
    local exclude_name="$3"  # Nome da escludere durante l'edit
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")
    
    for ((i=0; i<server_count; i++)); do
        local existing_host existing_user existing_name
        existing_host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        existing_user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        existing_name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        
        # Skip se è il server che stiamo modificando
        if [[ -n "$exclude_name" && "$existing_name" == "$exclude_name" ]]; then
            continue
        fi
        
        if [[ "$existing_host" == "$host" && "$existing_user" == "$user" ]]; then
            dialog --title "Error" --msgbox "Server with host '$host' and user '$user' already exists!" 8 50
            return 1
        fi
    done
    return 0
}

# Check for duplicate server name
check_duplicate_name() {
    local name="$1"
    local exclude_name="$2"  # Nome da escludere durante l'edit
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")
    
    for ((i=0; i<server_count; i++)); do
        local existing_name
        existing_name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        
        # Skip se è il server che stiamo modificando
        if [[ -n "$exclude_name" && "$existing_name" == "$exclude_name" ]]; then
            continue
        fi
        
        if [[ "$existing_name" == "$name" ]]; then
            dialog --title "Error" --msgbox "Server name '$name' already exists!" 8 50
            return 1
        fi
    done
    return 0
}

# Add new server
add_server() {
    local name host user port description
    
    name=$(dialog --inputbox "Server name:" 10 60 2>&1 >/dev/tty) || return
    [[ -z "$name" ]] && return
    
    # Check for duplicate name
    if ! check_duplicate_name "$name"; then
        return 1
    fi
    
    host=$(dialog --inputbox "Server address (host/IP):" 10 60 2>&1 >/dev/tty) || return
    [[ -z "$host" ]] && return
    
    user=$(dialog --inputbox "Username:" 10 60 "root" 2>&1 >/dev/tty) || return
    [[ -z "$user" ]] && return
    
    port=$(dialog --inputbox "SSH port:" 10 60 "22" 2>&1 >/dev/tty) || return
    [[ -z "$port" ]] && port="22"
    
    description=$(dialog --inputbox "Description (optional):" 10 60 2>&1 >/dev/tty)
    
    ssh_options=$(dialog --inputbox "Custom SSH options (optional, e.g., -o ProxyCommand='...'):" 10 60 2>&1 >/dev/tty)
    
    if ! [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
        dialog --title "Error" --msgbox "Port must be a number between 1 and 65535" 8 50
        return 1
    fi
    
    if ! check_duplicate_server "$host" "$user"; then
        return 1
    fi
    
    backup_config
    local new_server_yaml
    new_server_yaml=$(cat << EOF
  - name: "$name"
    host: "$host"
    user: "$user"
    port: $port
EOF
)
    
    if [[ -n "$description" && "$description" != "null" ]]; then
        new_server_yaml+="\n    description: \"$description\""
    fi
    if [[ -n "$ssh_options" && "$ssh_options" != "null" ]]; then
        new_server_yaml+="\n    ssh_options: \"$ssh_options\""
    fi
    
    echo -e "$new_server_yaml" >> "$CONFIG_FILE"
    
    dialog --title "Success" --msgbox "Server '$name' added successfully!" 8 50
    log_message "INFO" "New server added: $name ($user@$host:$port)"
}

# Edit existing server
edit_server() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers to edit" 8 50
        return
    fi
    
    local menu_items=()
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")
    
    for ((i=0; i<server_count; i++)); do
        local name host user
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        menu_items+=("$name" "$name ($user@$host)")
    done
    
    local choice
    choice=$(dialog --clear --title "Edit Server" --menu \
        "Select server to edit:" \
        15 60 8 "${menu_items[@]}" 2>&1 >/dev/tty) || return
    
    local server_index
    server_index=$(get_server_index_by_name "$choice")
    if [[ $? -ne 0 ]]; then
        dialog --title "Error" --msgbox "Server not found!" 8 50
        return 1
    fi
    
    local name host user port description ssh_options
    name=$(yq eval ".servers[$server_index].name" "$CONFIG_FILE")
    host=$(yq eval ".servers[$server_index].host" "$CONFIG_FILE")
    user=$(yq eval ".servers[$server_index].user" "$CONFIG_FILE")
    port=$(yq eval ".servers[$server_index].port // 22" "$CONFIG_FILE")
    description=$(yq eval ".servers[$server_index].description // \"\"" "$CONFIG_FILE")
    ssh_options=$(yq eval ".servers[$server_index].ssh_options // \"\"" "$CONFIG_FILE")
    [[ "$description" == "null" ]] && description=""
    [[ "$ssh_options" == "null" ]] && ssh_options=""
    
    local new_name new_host new_user new_port new_description new_ssh_options
    new_name=$(dialog --inputbox "Server name:" 10 60 "$name" 2>&1 >/dev/tty) || return
    
    # Check for duplicate name only if changed
    if [[ "$new_name" != "$name" ]]; then
        if ! check_duplicate_name "$new_name" "$name"; then
            return 1
        fi
    fi
    
    new_host=$(dialog --inputbox "Server address:" 10 60 "$host" 2>&1 >/dev/tty) || return
    new_user=$(dialog --inputbox "Username:" 10 60 "$user" 2>&1 >/dev/tty) || return
    new_port=$(dialog --inputbox "SSH port:" 10 60 "$port" 2>&1 >/dev/tty) || return
    new_description=$(dialog --inputbox "Description:" 10 60 "$description" 2>&1 >/dev/tty)
    new_ssh_options=$(dialog --inputbox "Custom SSH options:" 10 60 "$ssh_options" 2>&1 >/dev/tty)
    
    if ! [[ "$new_port" =~ ^[0-9]+$ && "$new_port" -ge 1 && "$new_port" -le 65535 ]]; then
        dialog --title "Error" --msgbox "Port must be a number between 1 and 65535" 8 50
        return 1
    fi
    
    if [[ "$new_host" != "$host" || "$new_user" != "$user" ]]; then
        if ! check_duplicate_server "$new_host" "$new_user" "$name"; then
            return 1
        fi
    fi
    
    backup_config
    yq eval ".servers[$server_index].name = \"$new_name\"" -i "$CONFIG_FILE"
    yq eval ".servers[$server_index].host = \"$new_host\"" -i "$CONFIG_FILE"
    yq eval ".servers[$server_index].user = \"$new_user\"" -i "$CONFIG_FILE"
    yq eval ".servers[$server_index].port = $new_port" -i "$CONFIG_FILE"
    
    if [[ -n "$new_description" ]]; then
        yq eval ".servers[$server_index].description = \"$new_description\"" -i "$CONFIG_FILE"
    else
        yq eval "del(.servers[$server_index].description)" -i "$CONFIG_FILE"
    fi
    
    if [[ -n "$new_ssh_options" ]]; then
        yq eval ".servers[$server_index].ssh_options = \"$new_ssh_options\"" -i "$CONFIG_FILE"
    else
        yq eval "del(.servers[$server_index].ssh_options)" -i "$CONFIG_FILE"
    fi
    
    dialog --title "Success" --msgbox "Server edited successfully!" 8 50
    log_message "INFO" "Server edited: $new_name"
}

# Remove server
remove_server() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers to remove" 8 50
        return
    fi
    
    local menu_items=()
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")
    
    for ((i=0; i<server_count; i++)); do
        local name host user port
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
        menu_items+=("$name" "$name ($user@$host:$port)")
    done
    
    local choice
    choice=$(dialog --clear --title "Remove Server" --menu \
        "Select server to remove:" \
        15 70 8 "${menu_items[@]}" 2>&1 >/dev/tty) || return
    
    local server_index
    server_index=$(get_server_index_by_name "$choice")
    if [[ $? -ne 0 ]]; then
        dialog --title "Error" --msgbox "Server not found!" 8 50
        return 1
    fi
    
    local name host user port
    name=$(yq eval ".servers[$server_index].name" "$CONFIG_FILE")
    host=$(yq eval ".servers[$server_index].host" "$CONFIG_FILE")
    user=$(yq eval ".servers[$server_index].user" "$CONFIG_FILE")
    port=$(yq eval ".servers[$server_index].port // 22" "$CONFIG_FILE")
    
    dialog --clear --title "Confirm Removal" --yesno \
        "Are you sure you want to remove this server?\n\nName: $name\nHost: $host\nUser: $user\nPort: $port" \
        12 60 || return
    
    backup_config
    yq eval "del(.servers[$server_index])" -i "$CONFIG_FILE"
    dialog --title "Success" --msgbox "Server removed successfully!" 8 50
    log_message "INFO" "Server removed: $name"
}

# Show server information
show_server_info() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured" 8 50
        return
    fi
    
    local info_text=""
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")
    
    info_text+="Total configured servers: $server_count\n\n"
    
    for ((i=0; i<server_count; i++)); do
        local name host user port description ssh_options
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
        description=$(yq eval ".servers[$i].description // \"\"" "$CONFIG_FILE")
        ssh_options=$(yq eval ".servers[$i].ssh_options // \"\"" "$CONFIG_FILE")
        [[ "$description" == "null" ]] && description=""
        [[ "$ssh_options" == "null" ]] && ssh_options=""
        
        info_text+="[$(($i+1))] $name\n"
        info_text+="    Host: $host\n"
        info_text+="    User: $user\n"
        info_text+="    Port: $port\n"
        [[ -n "$description" ]] && info_text+="    Description: $description\n"
        [[ -n "$ssh_options" ]] && info_text+="    SSH Options: $ssh_options\n"
        info_text+="\n"
    done
    
    dialog --title "Server Information" --msgbox "$info_text" 20 70
}

# Main menu
main_menu() {
    while true; do
        local choice
        choice=$(dialog --clear --title "🔧 SSH Manager v2.2" --menu \
            "Select an option:\n(ESC to exit)" \
            20 60 10 \
            "1" "🚀 Connect via SSH" \
            "2" "🔑 Copy SSH key" \
            "3" "📁 Connect via SFTP" \
            "4" "🗂️  Browse with MC (SSHFS)" \
            "5" "➕ Add server" \
            "6" "✏️  Edit server" \
            "7" "🗑️  Remove server" \
            "8" "ℹ️  Server information" \
            "9" "🔧 Install prerequisites" \
            "0" "🚪 Exit" 2>&1 >/dev/tty)
        
        case "$choice" in
            ""  ) clear; exit 0 ;;
            "1" ) handle_ssh_action "ssh" ;;
            "2" ) handle_ssh_action "ssh-copy-id" ;;
            "3" ) handle_ssh_action "sftp" ;;
            "4" ) handle_ssh_action "sshfs-mc" ;;
            "5" ) add_server ;;
            "6" ) edit_server ;;
            "7" ) remove_server ;;
            "8" ) show_server_info ;;
            "9" ) install_prerequisites ;;
            "0" ) clear; exit 0 ;;
        esac
    done
}

# Main function
main() {
    # Check Bash version
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        print_message "$RED" "❌ Bash version 4 or higher required. Current version: $BASH_VERSION"
        exit 1
    fi
    
    # Check prerequisites
    if ! command -v dialog &> /dev/null; then
        print_message "$RED" "❌ Dialog is not installed. Run option 9 from the menu."
        echo "Do you want to install the prerequisites now? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            install_prerequisites || exit 1
        else
            exit 1
        fi
    fi
    
    if ! command -v yq &> /dev/null; then
        print_message "$RED" "❌ yq is not installed. Run option 9 from the menu."
        echo "Do you want to install the prerequisites now? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            install_prerequisites || exit 1
        else
            exit 1
        fi
    fi
    
    # Initialize configuration
    init_config
    
    # Log startup
    log_message "INFO" "SSH Manager started"
    
    # Start main menu
    main_menu
}

# Run if script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
