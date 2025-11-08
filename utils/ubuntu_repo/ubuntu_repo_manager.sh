#!/bin/bash

# Ubuntu Repository Manager
# Create and manage your own Ubuntu/Debian package repository (PPA-like)
# Uses aptly for repository management

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default configuration
REPO_BASE_DIR="/var/www/ubuntu-repo"
APTLY_CONFIG="/etc/aptly.conf"
REPO_NAME="myrepo"
REPO_DISTRIBUTION="focal"
REPO_COMPONENT="main"
REPO_ARCHITECTURE="amd64"
GPG_KEY_NAME="Ubuntu Repo Signing Key"
GPG_KEY_EMAIL="repo@example.com"

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}This script must be run as root (use sudo)${NC}"
        exit 1
    fi
}

# Show banner
show_banner() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║          Ubuntu Repository Manager (PPA-like)             ║"
    echo "║          Create and manage your package repository        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command -v aptly &> /dev/null; then
        missing+=("aptly")
    fi

    if ! command -v gpg &> /dev/null; then
        missing+=("gnupg")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}Missing dependencies: ${missing[*]}${NC}"
        echo -e "${CYAN}Do you want to install them now? (y/n)${NC}"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            install_dependencies
        else
            echo -e "${RED}Cannot proceed without dependencies${NC}"
            exit 1
        fi
    fi
}

# Install dependencies
install_dependencies() {
    echo -e "${CYAN}Installing dependencies...${NC}"

    # Add aptly repository if not present
    if ! grep -q "aptly" /etc/apt/sources.list.d/* 2>/dev/null; then
        echo -e "${CYAN}Adding aptly repository...${NC}"
        wget -qO - https://www.aptly.info/pubkey.txt | gpg --dearmor -o /usr/share/keyrings/aptly-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/aptly-archive-keyring.gpg] http://repo.aptly.info/ squeeze main" > /etc/apt/sources.list.d/aptly.list
        apt-get update
    fi

    apt-get install -y aptly gnupg nginx

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Dependencies installed successfully${NC}"
    else
        echo -e "${RED}✗ Failed to install dependencies${NC}"
        exit 1
    fi
}

# Generate GPG key for signing packages
generate_gpg_key() {
    echo -e "${CYAN}Generating GPG key for package signing...${NC}"

    # Check if key already exists
    if gpg --list-keys | grep -q "$GPG_KEY_EMAIL"; then
        echo -e "${YELLOW}GPG key already exists for $GPG_KEY_EMAIL${NC}"
        return
    fi

    # Generate key
    cat > /tmp/gpg-key-config << EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: $GPG_KEY_NAME
Name-Email: $GPG_KEY_EMAIL
Expire-Date: 0
EOF

    gpg --batch --gen-key /tmp/gpg-key-config
    rm -f /tmp/gpg-key-config

    # Export public key
    GPG_KEY_ID=$(gpg --list-keys --with-colons "$GPG_KEY_EMAIL" | grep ^pub | cut -d':' -f5)

    echo -e "${GREEN}✓ GPG key generated: $GPG_KEY_ID${NC}"
    echo -e "${CYAN}Exporting public key to $REPO_BASE_DIR/KEY.gpg${NC}"
}

# Initialize repository
init_repository() {
    echo -e "${CYAN}Initializing repository...${NC}"

    # Create base directory
    mkdir -p "$REPO_BASE_DIR"

    # Create aptly configuration
    cat > "$APTLY_CONFIG" << EOF
{
  "rootDir": "$REPO_BASE_DIR/aptly",
  "downloadConcurrency": 4,
  "downloadSpeedLimit": 0,
  "architectures": ["$REPO_ARCHITECTURE", "all"],
  "dependencyFollowSuggests": false,
  "dependencyFollowRecommends": false,
  "dependencyFollowAllVariants": false,
  "dependencyFollowSource": false,
  "dependencyVerboseResolve": false,
  "gpgDisableSign": false,
  "gpgDisableVerify": false,
  "gpgProvider": "gpg",
  "downloadSourcePackages": false,
  "skipLegacyPool": true,
  "ppaDistributorID": "ubuntu",
  "ppaCodename": "",
  "skipContentsPublishing": false,
  "FileSystemPublishEndpoints": {
    "public": {
      "rootDir": "$REPO_BASE_DIR/public",
      "linkMethod": "copy"
    }
  }
}
EOF

    # Create repository with aptly
    aptly repo create -distribution="$REPO_DISTRIBUTION" -component="$REPO_COMPONENT" "$REPO_NAME"

    echo -e "${GREEN}✓ Repository initialized${NC}"
}

# Publish repository
publish_repository() {
    echo -e "${CYAN}Publishing repository...${NC}"

    # Publish the repository
    aptly publish repo -skip-signing="$REPO_NAME" filesystem:public:$REPO_DISTRIBUTION || \
    aptly publish update -skip-signing "$REPO_DISTRIBUTION" filesystem:public

    # Export GPG public key
    GPG_KEY_ID=$(gpg --list-keys --with-colons "$GPG_KEY_EMAIL" | grep ^pub | cut -d':' -f5)
    if [ -n "$GPG_KEY_ID" ]; then
        gpg --armor --export "$GPG_KEY_ID" > "$REPO_BASE_DIR/public/KEY.gpg"
        echo -e "${GREEN}✓ Public key exported to KEY.gpg${NC}"
    fi

    echo -e "${GREEN}✓ Repository published${NC}"
}

# Configure nginx
configure_nginx() {
    echo -e "${CYAN}Configuring nginx...${NC}"

    local server_name
    echo -e "${CYAN}Enter server name (domain or IP, e.g., repo.example.com or 192.168.1.10):${NC}"
    read -r server_name

    if [ -z "$server_name" ]; then
        server_name="localhost"
    fi

    cat > /etc/nginx/sites-available/ubuntu-repo << EOF
server {
    listen 80;
    server_name $server_name;

    root $REPO_BASE_DIR/public;
    autoindex on;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Enable directory listing
    location /dists/ {
        autoindex on;
    }

    location /pool/ {
        autoindex on;
    }

    # Serve the GPG key
    location /KEY.gpg {
        default_type application/pgp-keys;
    }

    access_log /var/log/nginx/ubuntu-repo-access.log;
    error_log /var/log/nginx/ubuntu-repo-error.log;
}
EOF

    # Enable site
    ln -sf /etc/nginx/sites-available/ubuntu-repo /etc/nginx/sites-enabled/

    # Test configuration
    nginx -t

    if [ $? -eq 0 ]; then
        systemctl reload nginx
        echo -e "${GREEN}✓ Nginx configured and reloaded${NC}"
        echo -e "${CYAN}Repository URL: http://$server_name${NC}"
    else
        echo -e "${RED}✗ Nginx configuration error${NC}"
    fi
}

# Add package to repository
add_package() {
    local deb_file="$1"

    if [ -z "$deb_file" ]; then
        echo -e "${CYAN}Enter path to .deb file:${NC}"
        read -r deb_file
    fi

    if [ ! -f "$deb_file" ]; then
        echo -e "${RED}✗ File not found: $deb_file${NC}"
        return 1
    fi

    echo -e "${CYAN}Adding package: $deb_file${NC}"

    aptly repo add "$REPO_NAME" "$deb_file"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Package added successfully${NC}"
        echo -e "${YELLOW}Don't forget to publish the repository!${NC}"
    else
        echo -e "${RED}✗ Failed to add package${NC}"
    fi
}

# Remove package from repository
remove_package() {
    local package_name="$1"

    if [ -z "$package_name" ]; then
        echo -e "${CYAN}Enter package name to remove:${NC}"
        read -r package_name
    fi

    echo -e "${CYAN}Removing package: $package_name${NC}"

    aptly repo remove "$REPO_NAME" "$package_name"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Package removed successfully${NC}"
        echo -e "${YELLOW}Don't forget to publish the repository!${NC}"
    else
        echo -e "${RED}✗ Failed to remove package${NC}"
    fi
}

# List packages in repository
list_packages() {
    echo -e "${CYAN}Packages in repository:${NC}"
    echo "────────────────────────────────────────────"
    aptly repo show -with-packages "$REPO_NAME"
}

# Show client configuration
show_client_config() {
    local server_name
    echo -e "${CYAN}Enter your server address (domain or IP):${NC}"
    read -r server_name

    if [ -z "$server_name" ]; then
        server_name="repo.example.com"
    fi

    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Client Configuration Instructions (Modern Method)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${CYAN}1. Download and install GPG key:${NC}"
    echo -e "${YELLOW}   wget -qO - http://$server_name/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/$REPO_NAME.gpg${NC}"
    echo
    echo -e "${CYAN}2. Add repository with signed-by:${NC}"
    echo -e "${YELLOW}   echo \"deb [signed-by=/etc/apt/trusted.gpg.d/$REPO_NAME.gpg] http://$server_name $REPO_DISTRIBUTION $REPO_COMPONENT\" | sudo tee /etc/apt/sources.list.d/$REPO_NAME.list${NC}"
    echo
    echo -e "${CYAN}3. Update package lists:${NC}"
    echo -e "${YELLOW}   sudo apt update${NC}"
    echo
    echo -e "${CYAN}4. Install packages:${NC}"
    echo -e "${YELLOW}   sudo apt install <package-name>${NC}"
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}Note: apt-key is deprecated. The above method is compatible with Ubuntu 20.04+ and Debian 11+${NC}"
}

# Setup wizard
setup_wizard() {
    echo -e "${CYAN}Starting repository setup wizard...${NC}"
    echo

    # Get repository name
    echo -e "${CYAN}Repository name (default: myrepo):${NC}"
    read -r input
    if [ -n "$input" ]; then
        REPO_NAME="$input"
    fi

    # Get distribution
    echo -e "${CYAN}Ubuntu distribution (focal/jammy/noble, default: focal):${NC}"
    read -r input
    if [ -n "$input" ]; then
        REPO_DISTRIBUTION="$input"
    fi

    # Get email for GPG key
    echo -e "${CYAN}Email for GPG key (default: repo@example.com):${NC}"
    read -r input
    if [ -n "$input" ]; then
        GPG_KEY_EMAIL="$input"
    fi

    # Get repository base directory
    echo -e "${CYAN}Repository directory (default: /var/www/ubuntu-repo):${NC}"
    read -r input
    if [ -n "$input" ]; then
        REPO_BASE_DIR="$input"
    fi

    echo
    echo -e "${GREEN}Configuration:${NC}"
    echo -e "  Repository name: ${YELLOW}$REPO_NAME${NC}"
    echo -e "  Distribution: ${YELLOW}$REPO_DISTRIBUTION${NC}"
    echo -e "  Component: ${YELLOW}$REPO_COMPONENT${NC}"
    echo -e "  Architecture: ${YELLOW}$REPO_ARCHITECTURE${NC}"
    echo -e "  GPG Email: ${YELLOW}$GPG_KEY_EMAIL${NC}"
    echo -e "  Base directory: ${YELLOW}$REPO_BASE_DIR${NC}"
    echo

    echo -e "${CYAN}Proceed with setup? (y/n):${NC}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Setup cancelled${NC}"
        exit 0
    fi

    # Run setup
    check_dependencies
    generate_gpg_key
    init_repository
    publish_repository
    configure_nginx

    echo
    echo -e "${GREEN}✓ Repository setup complete!${NC}"
    echo
    show_client_config
}

# Main menu
main_menu() {
    while true; do
        echo
        echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}Ubuntu Repository Manager${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}1)${NC} Setup new repository (wizard)"
        echo -e "${GREEN}2)${NC} Add package to repository"
        echo -e "${GREEN}3)${NC} Remove package from repository"
        echo -e "${GREEN}4)${NC} List packages"
        echo -e "${GREEN}5)${NC} Publish repository"
        echo -e "${GREEN}6)${NC} Show client configuration"
        echo -e "${GREEN}7)${NC} Configure nginx"
        echo -e "${GREEN}0)${NC} Exit"
        echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
        echo -ne "${CYAN}Select option: ${NC}"
        read -r choice

        case $choice in
            1) setup_wizard ;;
            2) add_package ;;
            3) remove_package ;;
            4) list_packages ;;
            5) publish_repository ;;
            6) show_client_config ;;
            7) configure_nginx ;;
            0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac
    done
}

# Main execution
check_root
show_banner

# Check if arguments provided
if [ $# -gt 0 ]; then
    case $1 in
        add)
            add_package "$2"
            publish_repository
            ;;
        remove)
            remove_package "$2"
            publish_repository
            ;;
        list)
            list_packages
            ;;
        publish)
            publish_repository
            ;;
        client-config)
            show_client_config
            ;;
        setup)
            setup_wizard
            ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"
            echo "Usage: $0 {setup|add|remove|list|publish|client-config}"
            exit 1
            ;;
    esac
else
    main_menu
fi
