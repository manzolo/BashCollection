#!/bin/bash

# Ubuntu Repository Docker Manager
# Wrapper script for easy repository management

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check if .env exists
check_env() {
    if [ ! -f .env ]; then
        echo -e "${YELLOW}No .env file found. Creating from .env.example...${NC}"
        if [ -f .env.example ]; then
            cp .env.example .env
            echo -e "${GREEN}✓ .env file created${NC}"
            echo -e "${CYAN}Please edit .env file with your configuration before starting${NC}"
            return 1
        else
            echo -e "${RED}✗ .env.example not found${NC}"
            return 1
        fi
    fi
    return 0
}

# Show banner
show_banner() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║          Ubuntu Repository Manager - Docker               ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Start repository
start() {
    echo -e "${CYAN}Starting Ubuntu repository...${NC}"

    # Create packages directory if it doesn't exist
    mkdir -p packages logs

    docker-compose up -d

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Repository started${NC}"
        echo
        show_status
    else
        echo -e "${RED}✗ Failed to start repository${NC}"
        return 1
    fi
}

# Stop repository
stop() {
    echo -e "${CYAN}Stopping Ubuntu repository...${NC}"
    docker-compose stop

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Repository stopped${NC}"
    else
        echo -e "${RED}✗ Failed to stop repository${NC}"
    fi
}

# Restart repository
restart() {
    echo -e "${CYAN}Restarting Ubuntu repository...${NC}"
    docker-compose restart

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Repository restarted${NC}"
    fi
}

# Show status
show_status() {
    echo -e "${CYAN}Container Status:${NC}"
    docker-compose ps
    echo

    # Get the HTTP port from .env or default
    source .env 2>/dev/null
    HTTP_PORT=${HTTP_PORT:-8080}
    SERVER_NAME=${SERVER_NAME:-localhost}

    echo -e "${CYAN}Repository URL:${NC} ${GREEN}http://${SERVER_NAME}:${HTTP_PORT}${NC}"
    echo -e "${CYAN}GPG Key URL:${NC} ${GREEN}http://${SERVER_NAME}:${HTTP_PORT}/KEY.gpg${NC}"
}

# Show logs
show_logs() {
    local follow="${1:-}"

    if [ "$follow" = "-f" ] || [ "$follow" = "--follow" ]; then
        docker-compose logs -f
    else
        docker-compose logs --tail=50
    fi
}

# Add package
add_package() {
    local package="$1"

    if [ -z "$package" ]; then
        echo -e "${RED}✗ Package path required${NC}"
        echo -e "${CYAN}Usage: $0 add <path-to-package.deb>${NC}"
        return 1
    fi

    if [ ! -f "$package" ]; then
        echo -e "${RED}✗ Package file not found: $package${NC}"
        return 1
    fi

    # Copy package to packages directory
    local package_name=$(basename "$package")
    echo -e "${CYAN}Copying package to container...${NC}"
    cp "$package" packages/

    # Add package using repo-manager inside container
    echo -e "${CYAN}Adding package to repository...${NC}"
    docker-compose exec ubuntu-repo /scripts/repo-manager.sh add "/packages/$package_name"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Package added successfully${NC}"
    else
        echo -e "${RED}✗ Failed to add package${NC}"
    fi
}

# Remove package
remove_package() {
    local package_name="$1"

    if [ -z "$package_name" ]; then
        echo -e "${RED}✗ Package name required${NC}"
        echo -e "${CYAN}Usage: $0 remove <package-name>${NC}"
        return 1
    fi

    docker-compose exec ubuntu-repo /scripts/repo-manager.sh remove "$package_name"
}

# List packages
list_packages() {
    docker-compose exec ubuntu-repo /scripts/repo-manager.sh list
}

# Search packages
search_packages() {
    local query="$1"

    if [ -z "$query" ]; then
        echo -e "${RED}✗ Search query required${NC}"
        echo -e "${CYAN}Usage: $0 search <query>${NC}"
        return 1
    fi

    docker-compose exec ubuntu-repo /scripts/repo-manager.sh search "$query"
}

# Import all packages from packages directory
import_packages() {
    echo -e "${CYAN}Importing all packages from ./packages directory...${NC}"
    docker-compose exec ubuntu-repo /scripts/repo-manager.sh import /packages
}

# Show repository info
show_info() {
    docker-compose exec ubuntu-repo /scripts/repo-manager.sh info
}

# Shell access to container
shell() {
    echo -e "${CYAN}Opening shell in container...${NC}"
    docker-compose exec ubuntu-repo /bin/bash
}

# Show client configuration
client_config() {
    source .env 2>/dev/null
    HTTP_PORT=${HTTP_PORT:-8080}
    SERVER_NAME=${SERVER_NAME:-localhost}
    REPO_NAME=${REPO_NAME:-myrepo}
    REPO_DISTRIBUTION=${REPO_DISTRIBUTION:-focal}
    REPO_COMPONENT=${REPO_COMPONENT:-main}

    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Client Configuration (Modern Method)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${CYAN}1. Download and install GPG key:${NC}"
    echo -e "${YELLOW}   wget -qO - http://${SERVER_NAME}:${HTTP_PORT}/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/${REPO_NAME}.gpg${NC}"
    echo
    echo -e "${CYAN}2. Add repository with signed-by:${NC}"
    echo -e "${YELLOW}   echo \"deb [signed-by=/etc/apt/trusted.gpg.d/${REPO_NAME}.gpg] http://${SERVER_NAME}:${HTTP_PORT} ${REPO_DISTRIBUTION} ${REPO_COMPONENT}\" | sudo tee /etc/apt/sources.list.d/${REPO_NAME}.list${NC}"
    echo
    echo -e "${CYAN}3. Update package lists:${NC}"
    echo -e "${YELLOW}   sudo apt update${NC}"
    echo
    echo -e "${CYAN}4. Install packages:${NC}"
    echo -e "${YELLOW}   sudo apt install <package-name>${NC}"
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}Note: Legacy method using 'apt-key' is deprecated.${NC}"
    echo -e "${YELLOW}The above method is compatible with Ubuntu 20.04+ and Debian 11+${NC}"
    echo
}

# Build image
build() {
    echo -e "${CYAN}Building Docker image...${NC}"
    docker-compose build

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Image built successfully${NC}"
    fi
}

# Clean up
cleanup() {
    echo -e "${YELLOW}This will remove all containers, volumes, and data!${NC}"
    echo -e "${CYAN}Are you sure? (yes/no):${NC}"
    read -r response

    if [ "$response" = "yes" ]; then
        docker-compose down -v
        rm -rf packages/* logs/*
        echo -e "${GREEN}✓ Cleanup complete${NC}"
    else
        echo -e "${YELLOW}Cleanup cancelled${NC}"
    fi
}

# Backup repository
backup() {
    local backup_file="ubuntu-repo-backup-$(date +%Y%m%d_%H%M%S).tar.gz"

    echo -e "${CYAN}Creating backup...${NC}"

    # Export volumes
    docker run --rm \
        -v ubuntu-repo_repo-data:/data \
        -v ubuntu-repo_gpg-keys:/keys \
        -v $(pwd):/backup \
        ubuntu:22.04 \
        tar czf /backup/"$backup_file" /data /keys

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Backup created: $backup_file${NC}"
    else
        echo -e "${RED}✗ Backup failed${NC}"
    fi
}

# Show usage
show_usage() {
    cat << EOF
${CYAN}Ubuntu Repository Manager - Docker${NC}

${YELLOW}Usage:${NC}
  $0 <command> [arguments]

${YELLOW}Container Management:${NC}
  start              Start the repository container
  stop               Stop the repository container
  restart            Restart the repository container
  status             Show container status
  logs [-f]          Show container logs (-f to follow)
  shell              Open shell in container
  build              Build/rebuild Docker image

${YELLOW}Repository Management:${NC}
  add <file>         Add a .deb package to the repository
  remove <name>      Remove a package from the repository
  list               List all packages in repository
  search <query>     Search for packages
  import             Import all .deb files from ./packages directory
  info               Show repository information

${YELLOW}Client Configuration:${NC}
  client-config      Show how to configure clients

${YELLOW}Maintenance:${NC}
  backup             Create a backup of the repository
  cleanup            Remove all containers and data

${YELLOW}Examples:${NC}
  $0 start                          # Start repository
  $0 add mypackage.deb              # Add a package
  $0 list                           # List all packages
  $0 logs -f                        # Follow logs
  $0 client-config                  # Show client setup

${YELLOW}Package Directory:${NC}
  Place .deb files in ./packages directory and use 'import' command
  to add them all at once.

EOF
}

# Main execution
show_banner

case "${1:-}" in
    start)
        check_env && start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs "$2"
        ;;
    add)
        add_package "$2"
        ;;
    remove)
        remove_package "$2"
        ;;
    list)
        list_packages
        ;;
    search)
        search_packages "$2"
        ;;
    import)
        import_packages
        ;;
    info)
        show_info
        ;;
    shell)
        shell
        ;;
    client-config)
        client_config
        ;;
    build)
        build
        ;;
    backup)
        backup
        ;;
    cleanup)
        cleanup
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo -e "${RED}Unknown command: ${1:-}${NC}"
        echo
        show_usage
        exit 1
        ;;
esac
