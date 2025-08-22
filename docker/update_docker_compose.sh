#!/bin/bash

# Define the colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Define the possible docker-compose filenames
DOCKER_COMPOSE_FILES=("docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml")

echo -e "${GREEN}Docker Compose Update Script${NC}"
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
    
    # Check if any images were actually updated
    if echo "$PULL_OUTPUT" | grep -q "Pulling"; then
        echo -e "${GREEN}Updates found for this compose project:${NC}"
        echo "$PULL_OUTPUT"
        
        # Ask the user for confirmation, defaulting to 'N'
        read -p "Do you want to update and restart this project? (y/N) " choice
        choice=${choice:-N}  # Default to 'N' if input is empty
        
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            echo "Starting update process..."
            
            # Stop, remove, and restart the containers
            docker compose down
            docker compose rm -f
            docker compose up -d
            
            # Optionally, clean up unused images
            docker image prune -f
            
            echo -e "${GREEN}Update complete for $dir${NC}"
        else
            echo -e "${RED}Skipping update for $dir.${NC}"
        fi
    else
        echo -e "${RED}No updates found for this compose project.${NC}"
    fi
    
    # Go back to the original directory
    cd - > /dev/null
    echo "---------------------------------"
done

echo -e "${GREEN}Script finished.${NC}"

