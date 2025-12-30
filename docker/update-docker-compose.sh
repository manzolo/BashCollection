#!/bin/bash
# PKG_NAME: update-docker-compose
# PKG_VERSION: 1.0.4
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), docker-ce
# PKG_RECOMMENDS: docker-compose-plugin
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Interactive Docker Compose updater for multiple projects
# PKG_LONG_DESCRIPTION: Scans subdirectories for Docker Compose projects and interactively
#  updates them by pulling new images and optionally restarting containers.
#  .
#  Features:
#  - Automatic discovery of docker-compose files in subdirectories
#  - Support for multiple compose file names (docker-compose.yml, compose.yml, etc.)
#  - Interactive prompts for updating/restarting containers
#  - Smart detection of new image downloads
#  - Automatic cleanup of unused images
#  - Colored output for better readability
#  - Permission error handling
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Define the colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default mode: non-interactive (auto-execute)
INTERACTIVE_MODE=false
FORCE_RESTART=false

# Parse command line arguments
show_help() {
    echo -e "${BLUE}Docker Compose Update Script${NC}"
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -i, --interactive      Interactive mode (prompt for confirmation)"
    echo "  -f, --force-restart    Force restart all containers even without updates"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Default behavior: Automatically update all Docker Compose projects without prompts"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interactive)
            INTERACTIVE_MODE=true
            shift
            ;;
        -f|--force-restart)
            FORCE_RESTART=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            ;;
    esac
done

# Define the possible docker-compose filenames
DOCKER_COMPOSE_FILES=("docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml")

echo -e "${GREEN}Docker Compose Update Script${NC}"
if [ "$INTERACTIVE_MODE" = true ]; then
    echo -e "${YELLOW}Mode: Interactive${NC}"
else
    echo -e "${YELLOW}Mode: Automatic (use --interactive for prompts)${NC}"
fi
echo "---------------------------------"

# Find all first-level subdirectories
for dir in */; do
    # Skip if it's not a directory
    [ -d "$dir" ] || continue
    
    # Check if a docker-compose file exists in the subdirectory
    found_file=""
    for file in "${DOCKER_COMPOSE_FILES[@]}"; do
        if [ -f "$dir/$file" ]; then
            found_file="$dir/$file"
            break
        fi
    done
    
    # If no docker-compose file is found, continue to the next directory
    if [ -z "$found_file" ]; then
        echo -e "${RED}Skipping directory $dir: No docker-compose file found.${NC}"
        echo "---------------------------------"
        continue
    fi
    
    echo -e "${YELLOW}Checking directory: $dir${NC}"
    
    # Change into the directory, suppressing permission errors
    if ! cd "$dir" 2>/dev/null; then
        echo -e "${RED}Skipping directory $dir: Permission denied.${NC}"
        echo "---------------------------------"
        continue
    fi
    
    # Capture image IDs before pulling
    IMAGES_BEFORE=$(docker compose images -q 2>/dev/null | sort)
    
    # Execute docker compose pull and capture the output
    PULL_OUTPUT=$(docker compose pull 2>&1)
    PULL_EXIT_CODE=$?

    # Check if the pull command was successful
    if [ $PULL_EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Error during docker compose pull in $dir:${NC}"
        echo "$PULL_OUTPUT"
        cd - > /dev/null
        echo "---------------------------------"
        continue
    fi

    # Capture image IDs after pulling
    IMAGES_AFTER=$(docker compose images -q 2>/dev/null | sort)
    
    # Check if any images were actually downloaded (updated)
    # Method 1: Compare image IDs before and after
    IMAGES_UPDATED=false
    if [ "$IMAGES_BEFORE" != "$IMAGES_AFTER" ]; then
        IMAGES_UPDATED=true
    fi
    
    # Method 2: Look for signs of actual download activity in the output
    # This catches cases where new layers were downloaded even if image ID didn't change
    if echo "$PULL_OUTPUT" | grep -qE "(Downloaded newer image|Downloading|Download complete|Pull complete|\[=+\>])"; then
        IMAGES_UPDATED=true
    fi
    
    # Method 3: Check for "Pulled" status with hexadecimal IDs (layer downloads)
    # Pattern: lines with hex IDs (like "014e56e61396") indicate layers were processed
    if echo "$PULL_OUTPUT" | grep -qE "Pulled" && echo "$PULL_OUTPUT" | grep -qE "^[[:space:]]*[0-9a-f]{12}"; then
        # Additional check: make sure it's not just "already exists"
        if ! echo "$PULL_OUTPUT" | grep -q "Already exists"; then
            IMAGES_UPDATED=true
        fi
    fi

    # Check if there was any pulling activity
    if echo "$PULL_OUTPUT" | grep -q "Pulling"; then
        echo "$PULL_OUTPUT"
        echo ""

        if [ "$IMAGES_UPDATED" = true ]; then
            echo -e "${GREEN}✔ New images downloaded for this compose project!${NC}"

            # In interactive mode, ask for confirmation; otherwise auto-execute
            if [ "$INTERACTIVE_MODE" = true ]; then
                read -p "Do you want to update and restart this project? (Y/n) " choice
                choice=${choice:-Y}  # Default to 'Y' if input is empty
            else
                choice="Y"
                echo -e "${BLUE}→ Automatically updating and restarting...${NC}"
            fi

            if [[ "$choice" =~ ^[Yy]$ ]]; then
                echo "Starting update process..."

                # Stop, remove, and restart the containers
                docker compose down
                docker compose rm -f
                docker compose up -d

                # Optionally, clean up unused images
                docker image prune -f

                echo -e "${GREEN}✔ Update complete for $dir${NC}"
            else
                echo -e "${YELLOW}⚠ Skipping update for $dir.${NC}"
            fi
        else
            echo -e "${YELLOW}ℹ No new images - all images are up to date.${NC}"

            # Check if force restart is enabled
            if [ "$FORCE_RESTART" = true ]; then
                choice="Y"
                echo -e "${BLUE}→ Force restart enabled - restarting anyway...${NC}"
            # In interactive mode, ask for confirmation; otherwise skip
            elif [ "$INTERACTIVE_MODE" = true ]; then
                read -p "Do you want to restart this project anyway? (y/N) " choice
                choice=${choice:-N}  # Default to 'N' if input is empty
            else
                choice="N"
                echo -e "${BLUE}→ Skipping (no updates found)${NC}"
            fi

            if [[ "$choice" =~ ^[Yy]$ ]]; then
                echo "Restarting containers..."

                docker compose down
                docker compose rm -f
                docker compose up -d

                echo -e "${GREEN}✔ Restart complete for $dir${NC}"
            else
                echo -e "${YELLOW}⚠ Skipping $dir.${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}ℹ No updates found for this compose project.${NC}"
    fi
    
    # Go back to the original directory
    cd - > /dev/null
    echo "---------------------------------"
done

echo -e "${GREEN}Script finished.${NC}"

