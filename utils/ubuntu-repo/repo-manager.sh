#!/bin/bash

# Repository Manager (runs inside container)
# Used to manage packages in the repository

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load configuration from environment
REPO_NAME="${REPO_NAME:-myrepo}"
REPO_DISTRIBUTION="${REPO_DISTRIBUTION:-focal}"

# Add package to repository
add_package() {
    local deb_file="$1"

    if [ ! -f "$deb_file" ]; then
        echo -e "${RED}✗ File not found: $deb_file${NC}"
        return 1
    fi

    echo -e "${CYAN}Adding package: $(basename $deb_file)${NC}"
    aptly repo add "$REPO_NAME" "$deb_file"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Package added${NC}"
        publish_repository
    else
        echo -e "${RED}✗ Failed to add package${NC}"
        return 1
    fi
}

# Remove package from repository
remove_package() {
    local package_name="$1"

    if [ -z "$package_name" ]; then
        echo -e "${RED}✗ Package name required${NC}"
        return 1
    fi

    echo -e "${CYAN}Removing package: $package_name${NC}"
    aptly repo remove "$REPO_NAME" "$package_name"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Package removed${NC}"
        publish_repository
    else
        echo -e "${RED}✗ Failed to remove package${NC}"
        return 1
    fi
}

# List packages in repository
list_packages() {
    echo -e "${CYAN}Packages in repository '$REPO_NAME':${NC}"
    echo "────────────────────────────────────────────"
    aptly repo show -with-packages "$REPO_NAME"
}

# Publish repository
publish_repository() {
    echo -e "${CYAN}Publishing repository...${NC}"

    # Get GPG key ID for signing
    GPG_KEY_EMAIL="${GPG_KEY_EMAIL:-repo@example.com}"
    GPG_KEY_ID=$(gpg --list-keys --with-colons "$GPG_KEY_EMAIL" | grep ^pub | cut -d':' -f5)

    if [ -z "$GPG_KEY_ID" ]; then
        echo -e "${RED}✗ GPG key not found${NC}"
        return 1
    fi

    # Try to publish, if already published, update it
    aptly publish repo -batch -gpg-key="$GPG_KEY_ID" -distribution="$REPO_DISTRIBUTION" "$REPO_NAME" filesystem:public: 2>/dev/null || \
    aptly publish update -batch -gpg-key="$GPG_KEY_ID" "$REPO_DISTRIBUTION" filesystem:public:

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Repository published and signed${NC}"
    else
        echo -e "${RED}✗ Failed to publish repository${NC}"
        return 1
    fi

    # Export GPG public key
    gpg --armor --export "$GPG_KEY_ID" > /var/www/manzolo-ubuntu-repo/public/KEY.gpg
}

# Search packages
search_packages() {
    local query="$1"

    if [ -z "$query" ]; then
        echo -e "${RED}✗ Search query required${NC}"
        return 1
    fi

    echo -e "${CYAN}Searching for: $query${NC}"
    aptly repo search "$REPO_NAME" "$query"
}

# Show repository info
show_info() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Repository Information${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Name:${NC} $REPO_NAME"
    echo -e "${CYAN}Distribution:${NC} $REPO_DISTRIBUTION"

    echo
    aptly repo show "$REPO_NAME"

    echo
    echo -e "${CYAN}Published at:${NC}"
    aptly publish list
}

# Import packages from directory
import_directory() {
    local dir="$1"

    if [ ! -d "$dir" ]; then
        echo -e "${RED}✗ Directory not found: $dir${NC}"
        return 1
    fi

    echo -e "${CYAN}Importing packages from: $dir${NC}"

    local count=0
    for deb in "$dir"/*.deb; do
        if [ -f "$deb" ]; then
            echo -e "${YELLOW}Adding: $(basename $deb)${NC}"
            aptly repo add "$REPO_NAME" "$deb"
            ((count++))
        fi
    done

    echo -e "${GREEN}✓ Imported $count packages${NC}"
    publish_repository
}

# Show usage
show_usage() {
    cat << EOF
${CYAN}Repository Manager${NC}

${YELLOW}Usage:${NC}
  repo-manager.sh <command> [arguments]

${YELLOW}Commands:${NC}
  add <file.deb>           Add a package to the repository
  remove <package-name>    Remove a package from the repository
  list                     List all packages in the repository
  search <query>           Search for packages
  import <directory>       Import all .deb files from a directory
  publish                  Publish/update the repository
  info                     Show repository information
  help                     Show this help message

${YELLOW}Examples:${NC}
  repo-manager.sh add /packages/myapp_1.0.deb
  repo-manager.sh remove myapp
  repo-manager.sh list
  repo-manager.sh import /packages
  repo-manager.sh search "name (~ my.*)"

EOF
}

# Main execution
case "${1:-}" in
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
        import_directory "$2"
        ;;
    publish)
        publish_repository
        ;;
    info)
        show_info
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
