#!/bin/bash

# Docker Manager - Docker management script with Whiptail interface
# For Ubuntu - Requires whiptail and docker to be installed

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to check if Docker is installed and running
check_docker() {
    if ! command -v docker &> /dev/null; then
        whiptail --title "Error" --msgbox "Docker is not installed on the system!" 8 50
        exit 1
    fi
    
    if ! sudo systemctl is-active --quiet docker; then
        whiptail --title "Docker not active" --yesno "Docker is not running. Do you want to start it?" 8 50
        if [ $? -eq 0 ]; then
            sudo systemctl start docker
            whiptail --title "Info" --msgbox "Docker started successfully!" 8 50
        else
            exit 1
        fi
    fi
}

# Main menu
main_menu() {
    while true; do
        CHOICE=$(whiptail --title "Docker Manager" --menu "Choose an option:" 20 70 12 \
            "1" "Manage Containers" \
            "2" "Manage Images" \
            "3" "Manage Volumes" \
            "4" "Manage Networks" \
            "5" "Clean up Docker System" \
            "6" "Docker Stats" \
            "7" "Backup/Export" \
            "8" "Real-time Monitoring" \
            "9" "Docker Compose" \
            "10" "Docker Settings" \
            "0" "Exit" 3>&1 1>&2 2>&3)
        
        case $CHOICE in
            1) manage_containers ;;
            2) manage_images ;;
            3) manage_volumes ;;
            4) manage_networks ;;
            5) cleanup_menu ;;
            6) show_stats ;;
            7) backup_menu ;;
            8) monitor_realtime ;;
            9) docker_compose_menu ;;
            10) docker_settings ;;
            0) exit 0 ;;
            *) whiptail --title "Error" --msgbox "Invalid option!" 8 50 ;;
        esac
    done
}

# Container Management
manage_containers() {
    while true; do
        CHOICE=$(whiptail --title "Container Management" --menu "Choose an option:" 16 70 8 \
            "1" "List all containers" \
            "2" "Start a container" \
            "3" "Stop a container" \
            "4" "Remove a container" \
            "5" "Remove ALL containers (FORCE)" \
            "6" "View container logs" \
            "7" "Access a container (bash)" \
            "0" "Back to main menu" 3>&1 1>&2 2>&3)
        
        case $CHOICE in
            1) list_containers ;;
            2) start_container ;;
            3) stop_container ;;
            4) remove_container ;;
            5) force_remove_all_containers ;;
            6) show_container_logs ;;
            7) exec_container ;;
            0) break ;;
        esac
    done
}

# List containers
list_containers() {
    CONTAINERS=$(sudo docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}")
    whiptail --title "Existing Containers" --msgbox "$CONTAINERS" 20 100
}

# Start container
start_container() {
    CONTAINERS=$(sudo docker ps -a --filter "status=exited" --format "{{.Names}}")
    if [ -z "$CONTAINERS" ]; then
        whiptail --title "Info" --msgbox "No stopped containers found!" 8 50
        return
    fi
    
    OPTIONS=""
    for container in $CONTAINERS; do
        OPTIONS="$OPTIONS $container $container"
    done
    
    SELECTED=$(whiptail --title "Start Container" --menu "Choose a container to start:" 15 70 8 $OPTIONS 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ]; then
        sudo docker start $SELECTED
        whiptail --title "Success" --msgbox "Container $SELECTED started!" 8 50
    fi
}

# Stop container
stop_container() {
    CONTAINERS=$(sudo docker ps --format "{{.Names}}")
    if [ -z "$CONTAINERS" ]; then
        whiptail --title "Info" --msgbox "No running containers found!" 8 50
        return
    fi
    
    OPTIONS=""
    for container in $CONTAINERS; do
        OPTIONS="$OPTIONS $container $container"
    done
    
    SELECTED=$(whiptail --title "Stop Container" --menu "Choose a container to stop:" 15 70 8 $OPTIONS 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ]; then
        sudo docker stop $SELECTED
        whiptail --title "Success" --msgbox "Container $SELECTED stopped!" 8 50
    fi
}

# Remove container
remove_container() {
    CONTAINERS=$(sudo docker ps -a --format "{{.Names}}")
    if [ -z "$CONTAINERS" ]; then
        whiptail --title "Info" --msgbox "No containers found!" 8 50
        return
    fi
    
    OPTIONS=""
    for container in $CONTAINERS; do
        STATUS=$(sudo docker ps -a --filter "name=$container" --format "{{.Status}}")
        OPTIONS="$OPTIONS $container \"$STATUS\""
    done
    
    SELECTED=$(whiptail --title "Remove Container" --menu "Choose a container to remove:" 15 70 8 $OPTIONS 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ]; then
        if whiptail --title "Confirmation" --yesno "Are you sure you want to remove $SELECTED?" 8 50; then
            sudo docker rm -f $SELECTED
            whiptail --title "Success" --msgbox "Container $SELECTED removed!" 8 50
        fi
    fi
}

# Force remove all containers
force_remove_all_containers() {
    if whiptail --title "WARNING!" --yesno "This will FORCE-remove all containers!\nAre you ABSOLUTELY sure?" 10 60; then
        if whiptail --title "LAST CONFIRMATION" --yesno "LAST CHANCE!\nRemove ALL containers?" 8 50; then
            sudo docker rm -f $(sudo docker ps -aq) 2>/dev/null
            whiptail --title "Completed" --msgbox "All containers have been removed!" 8 50
        fi
    fi
}

# Image Management
manage_images() {
    while true; do
        CHOICE=$(whiptail --title "Image Management" --menu "Choose an option:" 14 70 6 \
            "1" "List all images" \
            "2" "Remove a specific image" \
            "3" "Remove ALL images (FORCE)" \
            "4" "Remove dangling images" \
            "5" "Pull a new image" \
            "0" "Back to main menu" 3>&1 1>&2 2>&3)
        
        case $CHOICE in
            1) list_images ;;
            2) remove_image ;;
            3) force_remove_all_images ;;
            4) remove_dangling_images ;;
            5) pull_image ;;
            0) break ;;
        esac
    done
}

# List images
list_images() {
    IMAGES=$(sudo docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}")
    whiptail --title "Docker Images" --msgbox "$IMAGES" 20 120
}

# Remove image
remove_image() {
    # Create an array with images
    IMAGES=$(sudo docker images --format "{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}")
    if [ -z "$IMAGES" ]; then
        whiptail --title "Info" --msgbox "No images found!" 8 50
        return
    fi
    
    # Build whiptail options
    OPTIONS=()
    counter=1
    
    # Save mapping to a temporary file
    TEMP_MAP=$(mktemp)
    
    while read -r line; do
        if [ -n "$line" ]; then
            # Extract name, ID, and size
            IMAGE_NAME=$(echo "$line" | awk '{print $1}')
            IMAGE_ID=$(echo "$line" | awk '{print $2}')
            IMAGE_SIZE=$(echo "$line" | awk '{print $3}')
            
            # Add to options array
            OPTIONS+=("$counter" "$IMAGE_NAME ($IMAGE_SIZE)")
            
            # Save mapping
            echo "$counter|$IMAGE_ID|$IMAGE_NAME" >> "$TEMP_MAP"
            
            counter=$((counter + 1))
        fi
    done <<< "$IMAGES"
    
    # Show menu
    SELECTED=$(whiptail --title "Remove Image" --menu "Choose image to remove:" 20 90 10 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$SELECTED" ]; then
        # Retrieve selected image info
        IMAGE_LINE=$(grep "^$SELECTED|" "$TEMP_MAP")
        if [ -n "$IMAGE_LINE" ]; then
            IMAGE_ID=$(echo "$IMAGE_LINE" | cut -d'|' -f2)
            IMAGE_NAME=$(echo "$IMAGE_LINE" | cut -d'|' -f3)
            
            if whiptail --title "Confirmation" --yesno "Remove image:\n$IMAGE_NAME\n(ID: ${IMAGE_ID:0:12}...)?" 10 70; then
                # Use ID for certainty
                if sudo docker rmi -f "$IMAGE_ID" 2>/dev/null; then
                    whiptail --title "Success" --msgbox "Image $IMAGE_NAME removed successfully!" 8 60
                else
                    whiptail --title "Error" --msgbox "Error removing image!\nIt might be in use by a container." 8 70
                fi
            fi
        fi
    fi
    
    # Clean up temporary file
    rm -f "$TEMP_MAP"
}

# Remove ALL images
force_remove_all_images() {
    if whiptail --title "DANGER!" --yesno "This will remove ALL images!\nThis operation is IRREVERSIBLE!\nContinue?" 10 60; then
        if whiptail --title "FINAL CONFIRMATION" --yesno "LAST CHANCE!\nRemove ALL images?" 8 50; then
            sudo docker rmi -f $(sudo docker images -q) 2>/dev/null
            whiptail --title "Completed" --msgbox "All images have been removed!" 8 50
        fi
    fi
}

# Docker system cleanup
cleanup_menu() {
    while true; do
        CHOICE=$(whiptail --title "Docker System Cleanup" --menu "Choose cleanup type:" 16 70 8 \
            "1" "Light cleanup (dangling)" \
            "2" "Full cleanup" \
            "3" "Prune EVERYTHING (system prune -a)" \
            "4" "Remove unused volumes" \
            "5" "Clean up BUILD CACHE" \
            "6" "Total cleanup + Builder" \
            "7" "Reclaimable space stats" \
            "0" "Go back" 3>&1 1>&2 2>&3)
        
        case $CHOICE in
            1) 
                sudo docker system prune -f
                whiptail --title "Completed" --msgbox "Light cleanup completed!" 8 50
                ;;
            2) 
                sudo docker system prune --volumes -f
                whiptail --title "Completed" --msgbox "Full cleanup completed!" 8 50
                ;;
            3) 
                if whiptail --title "WARNING" --yesno "This will remove EVERYTHING unused!\nContinue?" 8 60; then
                    sudo docker system prune -a --volumes -f
                    whiptail --title "Completed" --msgbox "Total cleanup completed!" 8 50
                fi
                ;;
            4) 
                sudo docker volume prune -f
                whiptail --title "Completed" --msgbox "Unused volumes removed!" 8 50
                ;;
            5)
                cleanup_build_cache
                ;;
            6)
                cleanup_everything_plus_builder
                ;;
            7) 
                show_cleanup_stats
                ;;
            0) break ;;
        esac
    done
}

# Specific build cache cleanup
cleanup_build_cache() {
    CHOICE=$(whiptail --title "Build Cache Cleanup" --menu "Choose cleanup level:" 14 70 6 \
        "1" "Unused cache (prune)" \
        "2" "Cache older than X days" \
        "3" "ALL cache (--all)" \
        "4" "Builder cache info" \
        "5" "Full builder reset" \
        "0" "Cancel" 3>&1 1>&2 2>&3)
    
    case $CHOICE in
        1)
            # Show how much space will be reclaimed
            CACHE_INFO=$(sudo docker builder prune --filter until=1h --dry-run 2>/dev/null | grep "Total:" || echo "Calculating space...")
            if whiptail --title "Confirmation" --yesno "Cleanup unused cache.\n\n$CACHE_INFO\n\nContinue?" 10 70; then
                sudo docker builder prune -f
                whiptail --title "Success" --msgbox "Builder cache cleaned!" 8 50
            fi
            ;;
        2)
            DAYS=$(whiptail --title "Days" --inputbox "Remove cache older than how many days?" 8 50 "7" 3>&1 1>&2 2>&3)
            if [ $? -eq 0 ] && [ -n "$DAYS" ] && [ "$DAYS" -gt 0 ] 2>/dev/null; then
                sudo docker builder prune --filter until=${DAYS}d -f
                whiptail --title "Success" --msgbox "Cache older than $DAYS days removed!" 8 60
            fi
            ;;
        3)
            if whiptail --title "WARNING" --yesno "This will remove ALL build cache!\nYour next build will be much slower.\nContinue?" 10 60; then
                sudo docker builder prune --all -f
                whiptail --title "Completed" --msgbox "All build cache has been removed!" 8 60
            fi
            ;;
        4)
            show_builder_info
            ;;
        5)
            if whiptail --title "DANGER" --yesno "This will COMPLETELY reset the builder!\nAll caches and configurations will be lost.\nContinue?" 10 70; then
                # Reset default builder
                sudo docker buildx prune --all -f 2>/dev/null
                sudo docker builder prune --all -f
                whiptail --title "Completed" --msgbox "Builder completely reset!" 8 50
            fi
            ;;
    esac
}

# Total cleanup including builder
cleanup_everything_plus_builder() {
    if whiptail --title "TOTAL CLEANUP" --yesno "This operation will remove:\n\n• All stopped containers\n• All unused images\n• All unused volumes\n• All unused networks\n• ALL build cache\n\nTHIS OPERATION IS IRREVERSIBLE!\nContinue?" 16 70; then
        
        if whiptail --title "FINAL CONFIRMATION" --yesno "ARE YOU ABSOLUTELY SURE?\n\nThis is your last chance to cancel!" 10 60; then
            # Show progress
            {
                echo "10" ; sleep 1
                sudo docker system prune -a --volumes -f >/dev/null 2>&1
                echo "50" ; sleep 1
                sudo docker builder prune --all -f >/dev/null 2>&1
                echo "80" ; sleep 1
                sudo docker buildx prune --all -f >/dev/null 2>&1
                echo "100" ; sleep 1
            } | whiptail --title "Cleanup in progress..." --gauge "Removing everything..." 8 60 0
            
            whiptail --title "COMPLETED" --msgbox "Total cleanup completed!\n\nAll possible space has been reclaimed." 10 60
        fi
    fi
}

# Show detailed builder info
show_builder_info() {
    BUILDER_INFO=$(cat << EOF
=== BUILDER INFORMATION ===

$(sudo docker builder ls 2>/dev/null || echo "No custom builder found")

=== BUILD CACHE DISK USAGE ===
$(sudo docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Size}}\t{{.Reclaimable}}" | grep -i build || sudo docker builder df 2>/dev/null || echo "Cache info not available")

=== DETAILED BUILD CACHE ===
$(sudo docker builder du 2>/dev/null | head -10 || echo "Detailed cache not available")
EOF
)
    whiptail --title "Builder Information" --msgbox "$BUILDER_INFO" 20 100
}

# Detailed cleanup stats
show_cleanup_stats() {
    CLEANUP_STATS=$(cat << EOF
=== DOCKER DISK USAGE ===

$(sudo docker system df)

=== RECLAIMABLE SPACE ===

$(sudo docker system df --format "table {{.Type}}\t{{.Size}}\t{{.Reclaimable}}")

=== BUILD CACHE ===
$(sudo docker builder du 2>/dev/null | head -5 || echo "Build cache: $(sudo docker system df | grep 'Build Cache' || echo 'N/A')")

=== CLEANUP PREVIEW (dry-run) ===
Containers: $(sudo docker container prune --dry-run 2>/dev/null | grep "Total reclaimed space" || echo "No containers to remove")
Images: $(sudo docker image prune --dry-run 2>/dev/null | grep "Total reclaimed space" || echo "No images to remove")
Volumes: $(sudo docker volume prune --dry-run 2>/dev/null | grep "Total reclaimed space" || echo "No volumes to remove")
Build Cache: $(sudo docker builder prune --dry-run 2>/dev/null | grep "Total:" || echo "Cache info not available")
EOF
)
    whiptail --title "Docker Cleanup Stats" --msgbox "$CLEANUP_STATS" 25 100
}

# Docker Stats
show_stats() {
    STATS=$(cat << EOF
=== DOCKER STATS ===

$(sudo docker system df)

=== ACTIVE CONTAINERS ===
$(sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}")

=== RESOURCE USAGE ===
$(sudo docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}")
EOF
)
    whiptail --title "Docker Stats" --msgbox "$STATS" 25 100
}

# Show container logs
show_container_logs() {
    CONTAINERS=$(sudo docker ps -a --format "{{.Names}}")
    if [ -z "$CONTAINERS" ]; then
        whiptail --title "Info" --msgbox "No containers found!" 8 50
        return
    fi
    
    OPTIONS=""
    for container in $CONTAINERS; do
        OPTIONS="$OPTIONS $container $container"
    done
    
    SELECTED=$(whiptail --title "Container Logs" --menu "Choose container:" 15 70 8 $OPTIONS 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ]; then
        LOGS=$(sudo docker logs --tail 50 $SELECTED 2>&1)
        whiptail --title "Logs of $SELECTED" --msgbox "$LOGS" 25 100
    fi
}

# Access container
exec_container() {
    CONTAINERS=$(sudo docker ps --format "{{.Names}}")
    if [ -z "$CONTAINERS" ]; then
        whiptail --title "Info" --msgbox "No running containers!" 8 50
        return
    fi
    
    OPTIONS=""
    for container in $CONTAINERS; do
        OPTIONS="$OPTIONS $container $container"
    done
    
    SELECTED=$(whiptail --title "Access Container" --menu "Choose a container:" 15 70 8 $OPTIONS 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ]; then
        whiptail --title "Info" --msgbox "Opening a shell in container $SELECTED\nUse 'exit' to quit." 8 60
        sudo docker exec -it $SELECTED /bin/bash || sudo docker exec -it $SELECTED /bin/sh
    fi
}

# Pull image
pull_image() {
    IMAGE=$(whiptail --title "Pull Image" --inputbox "Enter the image name (e.g., nginx:latest):" 8 60 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ] && [ -n "$IMAGE" ]; then
        sudo docker pull $IMAGE
        whiptail --title "Success" --msgbox "Image $IMAGE downloaded!" 8 50
    fi
}

# Remove dangling images
remove_dangling_images() {
    sudo docker image prune -f
    whiptail --title "Completed" --msgbox "Dangling images removed!" 8 50
}

# Volume management
manage_volumes() {
    while true; do
        CHOICE=$(whiptail --title "Volume Management" --menu "Choose an option:" 12 70 4 \
            "1" "List volumes" \
            "2" "Remove a volume" \
            "3" "Remove unused volumes" \
            "0" "Go back" 3>&1 1>&2 2>&3)
        
        case $CHOICE in
            1) 
                VOLUMES=$(sudo docker volume ls)
                whiptail --title "Docker Volumes" --msgbox "$VOLUMES" 20 80
                ;;
            2)
                VOLUMES=$(sudo docker volume ls --format "{{.Name}}")
                if [ -n "$VOLUMES" ]; then
                    OPTIONS=""
                    for vol in $VOLUMES; do
                        OPTIONS="$OPTIONS $vol $vol"
                    done
                    SELECTED=$(whiptail --title "Remove Volume" --menu "Choose volume:" 15 70 8 $OPTIONS 3>&1 1>&2 2>&3)
                    if [ $? -eq 0 ]; then
                        sudo docker volume rm $SELECTED
                        whiptail --title "Success" --msgbox "Volume $SELECTED removed!" 8 50
                    fi
                else
                    whiptail --title "Info" --msgbox "No volumes found!" 8 50
                fi
                ;;
            3) 
                sudo docker volume prune -f
                whiptail --title "Completed" --msgbox "Unused volumes removed!" 8 50
                ;;
            0) break ;;
        esac
    done
}

# Network management
manage_networks() {
    while true; do
        CHOICE=$(whiptail --title "Network Management" --menu "Choose an option:" 12 70 4 \
            "1" "List networks" \
            "2" "Remove a network" \
            "3" "Remove unused networks" \
            "0" "Go back" 3>&1 1>&2 2>&3)
        
        case $CHOICE in
            1)
                NETWORKS=$(sudo docker network ls)
                whiptail --title "Docker Networks" --msgbox "$NETWORKS" 20 80
                ;;
            2)
                NETWORKS=$(sudo docker network ls --format "{{.Name}}" | grep -v "bridge\|host\|none")
                if [ -n "$NETWORKS" ]; then
                    OPTIONS=""
                    for net in $NETWORKS; do
                        OPTIONS="$OPTIONS $net $net"
                    done
                    SELECTED=$(whiptail --title "Remove Network" --menu "Choose network:" 15 70 8 $OPTIONS 3>&1 1>&2 2>&3)
                    if [ $? -eq 0 ]; then
                        sudo docker network rm $SELECTED
                        whiptail --title "Success" --msgbox "Network $SELECTED removed!" 8 50
                    fi
                else
                    whiptail --title "Info" --msgbox "No custom networks found!" 8 50
                fi
                ;;
            3)
                sudo docker network prune -f
                whiptail --title "Completed" --msgbox "Unused networks removed!" 8 50
                ;;
            0) break ;;
        esac
    done
}

# Backup menu
backup_menu() {
    while true; do
        CHOICE=$(whiptail --title "Backup/Export" --menu "Choose an option:" 12 70 4 \
            "1" "Export container" \
            "2" "Export image" \
            "3" "Backup volume" \
            "0" "Go back" 3>&1 1>&2 2>&3)
        
        case $CHOICE in
            1) export_container ;;
            2) export_image ;;
            3) backup_volume ;;
            0) break ;;
        esac
    done
}

# Export container
export_container() {
    CONTAINERS=$(sudo docker ps -a --format "{{.Names}}")
    if [ -z "$CONTAINERS" ]; then
        whiptail --title "Info" --msgbox "No containers found!" 8 50
        return
    fi
    
    OPTIONS=""
    for container in $CONTAINERS; do
        OPTIONS="$OPTIONS $container $container"
    done
    
    SELECTED=$(whiptail --title "Export Container" --menu "Choose a container:" 15 70 8 $OPTIONS 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ]; then
        FILENAME="/tmp/${SELECTED}_$(date +%Y%m%d_%H%M%S).tar"
        sudo docker export $SELECTED > $FILENAME
        whiptail --title "Success" --msgbox "Container exported to:\n$FILENAME" 8 60
    fi
}

# Real-time monitoring
monitor_realtime() {
    whiptail --title "Monitoring" --msgbox "Opening real-time Docker monitoring.\nPress Ctrl+C to exit." 8 60
    sudo docker stats
}

# Docker Compose menu
docker_compose_menu() {
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        whiptail --title "Error" --msgbox "Docker Compose not found!\nInstall with: sudo apt-get install docker-compose" 8 60
        return
    fi
    
    while true; do
        CHOICE=$(whiptail --title "Docker Compose" --menu "Choose an option:" 16 70 8 \
            "1" "Select directory and UP" \
            "2" "Select directory and DOWN" \
            "3" "View project logs" \
            "4" "List active services" \
            "5" "Restart services" \
            "6" "Compose projects status" \
            "7" "Pull project images" \
            "0" "Go back" 3>&1 1>&2 2>&3)
        
        case $CHOICE in
            1) compose_up ;;
            2) compose_down ;;
            3) compose_logs ;;
            4) compose_ps ;;
            5) compose_restart ;;
            6) compose_status ;;
            7) compose_pull ;;
            0) break ;;
        esac
    done
}

# Docker Compose UP
compose_up() {
    # Ask for project directory
    PROJECT_DIR=$(whiptail --title "Docker Compose UP" --inputbox "Enter the full path to the directory containing docker-compose.yml:\n\n(e.g., /home/user/myproject)" 12 80 $(pwd) 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$PROJECT_DIR" ]; then
        return
    fi
    
    # Check if directory exists
    if [ ! -d "$PROJECT_DIR" ]; then
        whiptail --title "Error" --msgbox "Directory not found: $PROJECT_DIR" 8 60
        return
    fi
    
    # Check if docker-compose.yml exists
    if [ ! -f "$PROJECT_DIR/docker-compose.yml" ] && [ ! -f "$PROJECT_DIR/docker-compose.yaml" ]; then
        whiptail --title "Error" --msgbox "docker-compose.yml file not found in:\n$PROJECT_DIR" 8 70
        return
    fi
    
    # Options for the up command
    if whiptail --title "UP Options" --yesno "Do you want to run in detached mode (-d)?\n\nYES = In background\nNO = In foreground (you'll see the logs)" 10 60; then
        DETACHED="-d"
        cd "$PROJECT_DIR"
        if docker compose up $DETACHED 2>/dev/null || docker-compose up $DETACHED; then
            whiptail --title "Success" --msgbox "Project started successfully in:\n$PROJECT_DIR" 8 60
        else
            whiptail --title "Error" --msgbox "Error starting the project!" 8 50
        fi
    else
        whiptail --title "Info" --msgbox "The project will start in the foreground.\nPress Ctrl+C to stop it.\n\nPressing OK will open the terminal..." 10 60
        cd "$PROJECT_DIR"
        docker compose up 2>/dev/null || docker-compose up
    fi
}

# Docker Compose DOWN
compose_down() {
    PROJECT_DIR=$(whiptail --title "Docker Compose DOWN" --inputbox "Enter the path to the project directory:" 10 80 $(pwd) 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$PROJECT_DIR" ]; then
        return
    fi
    
    if [ ! -d "$PROJECT_DIR" ]; then
        whiptail --title "Error" --msgbox "Directory not found: $PROJECT_DIR" 8 60
        return
    fi
    
    cd "$PROJECT_DIR"
    
    # Options for down
    CHOICE=$(whiptail --title "DOWN Options" --menu "How do you want to stop the project?" 12 70 4 \
        "1" "Normal stop (keeps volumes)" \
        "2" "Stop and remove volumes (-v)" \
        "3" "Stop with full cleanup (--rmi all)" \
        "0" "Cancel" 3>&1 1>&2 2>&3)
    
    case $CHOICE in
        1) 
            if docker compose down 2>/dev/null || docker-compose down; then
                whiptail --title "Success" --msgbox "Project stopped!" 8 50
            fi
            ;;
        2)
            if whiptail --title "Confirmation" --yesno "WARNING: This will also remove volumes!\nContinue?" 8 60; then
                docker compose down -v 2>/dev/null || docker-compose down -v
                whiptail --title "Success" --msgbox "Project stopped and volumes removed!" 8 60
            fi
            ;;
        3)
            if whiptail --title "Confirmation" --yesno "WARNING: This will remove everything (volumes and images)!\nContinue?" 8 70; then
                docker compose down -v --rmi all 2>/dev/null || docker-compose down -v --rmi all
                whiptail --title "Success" --msgbox "Full cleanup performed!" 8 50
            fi
            ;;
    esac
}

# Docker Compose LOGS
compose_logs() {
    PROJECT_DIR=$(whiptail --title "Docker Compose LOGS" --inputbox "Enter the path to the project directory:" 10 80 $(pwd) 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$PROJECT_DIR" ]; then
        return
    fi
    
    if [ ! -d "$PROJECT_DIR" ]; then
        whiptail --title "Error" --msgbox "Directory not found!" 8 50
        return
    fi
    
    cd "$PROJECT_DIR"
    
    # List available services
    SERVICES=$(docker compose config --services 2>/dev/null || docker-compose config --services 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        whiptail --title "Error" --msgbox "No services found or invalid docker-compose.yml!" 8 70
        return
    fi
    
    # Build whiptail options
    OPTIONS=("all" "All services")
    for service in $SERVICES; do
        OPTIONS+=("$service" "Service: $service")
    done
    
    SELECTED=$(whiptail --title "Choose Service" --menu "Which service's logs do you want to see?" 15 60 8 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ]; then
        if [ "$SELECTED" = "all" ]; then
            whiptail --title "Info" --msgbox "Showing logs for all services.\nPress Ctrl+C to exit." 8 50
            docker compose logs -f 2>/dev/null || docker-compose logs -f
        else
            whiptail --title "Info" --msgbox "Showing logs for service: $SELECTED\nPress Ctrl+C to exit." 8 60
            docker compose logs -f "$SELECTED" 2>/dev/null || docker-compose logs -f "$SELECTED"
        fi
    fi
}

# Docker Compose PS
compose_ps() {
    PROJECT_DIR=$(whiptail --title "List Services" --inputbox "Project directory (or leave blank for all):" 10 80 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        return
    fi
    
    if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
        cd "$PROJECT_DIR"
        SERVICES=$(docker compose ps 2>/dev/null || docker-compose ps 2>/dev/null)
    else
        # Show all compose containers
        SERVICES=$(docker ps -a --filter "label=com.docker.compose.project" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}")
    fi
    
    if [ -n "$SERVICES" ]; then
        whiptail --title "Docker Compose Services" --msgbox "$SERVICES" 20 120
    else
        whiptail --title "Info" --msgbox "No Docker Compose services are running!" 8 60
    fi
}

# Docker Compose RESTART
compose_restart() {
    PROJECT_DIR=$(whiptail --title "Restart Services" --inputbox "Project directory:" 10 80 $(pwd) 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
        return
    fi
    
    cd "$PROJECT_DIR"
    
    if docker compose restart 2>/dev/null || docker-compose restart; then
        whiptail --title "Success" --msgbox "Services restarted!" 8 50
    else
        whiptail --title "Error" --msgbox "Error during restart!" 8 50
    fi
}

# Compose projects status
compose_status() {
    STATUS=$(cat << EOF
=== ACTIVE DOCKER COMPOSE PROJECTS ===

$(docker ps --filter "label=com.docker.compose.project" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}")

=== COMPOSE NETWORKS ===
$(docker network ls --filter "label=com.docker.compose.network" --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}")

=== COMPOSE VOLUMES ===
$(docker volume ls --filter "label=com.docker.compose.volume" --format "table {{.Name}}\t{{.Driver}}")
EOF
)
    whiptail --title "Docker Compose Status" --msgbox "$STATUS" 25 120
}

# Pull project images
compose_pull() {
    PROJECT_DIR=$(whiptail --title "Pull Images" --inputbox "Project directory:" 10 80 $(pwd) 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
        return
    fi
    
    cd "$PROJECT_DIR"
    
    whiptail --title "Info" --msgbox "Pulling the latest images...\nThis may take some time." 8 60
    
    if docker compose pull 2>/dev/null || docker-compose pull; then
        whiptail --title "Success" --msgbox "Images updated successfully!" 8 50
    else
        whiptail --title "Error" --msgbox "Error pulling images!" 8 50
    fi
}

# Docker settings
docker_settings() {
    INFO=$(sudo docker info 2>/dev/null | head -20)
    whiptail --title "Docker Information" --msgbox "$INFO" 20 80
}

# Export image
export_image() {
    # Create an array with images
    IMAGES=$(sudo docker images --format "{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}")
    if [ -z "$IMAGES" ]; then
        whiptail --title "Info" --msgbox "No images found!" 8 50
        return
    fi
    
    # Build whiptail options
    OPTIONS=()
    counter=1
    
    # Save mapping to a temporary file
    TEMP_MAP=$(mktemp)
    
    while read -r line; do
        if [ -n "$line" ]; then
            # Extract name, ID, and size
            IMAGE_NAME=$(echo "$line" | awk '{print $1}')
            IMAGE_ID=$(echo "$line" | awk '{print $2}')
            IMAGE_SIZE=$(echo "$line" | awk '{print $3}')
            
            # Add to options array
            OPTIONS+=("$counter" "$IMAGE_NAME ($IMAGE_SIZE)")
            
            # Save mapping
            echo "$counter|$IMAGE_ID|$IMAGE_NAME" >> "$TEMP_MAP"
            
            counter=$((counter + 1))
        fi
    done <<< "$IMAGES"
    
    # Show menu
    SELECTED=$(whiptail --title "Export Image" --menu "Choose image to export:" 20 90 10 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$SELECTED" ]; then
        # Retrieve selected image info
        IMAGE_LINE=$(grep "^$SELECTED|" "$TEMP_MAP")
        if [ -n "$IMAGE_LINE" ]; then
            IMAGE_ID=$(echo "$IMAGE_LINE" | cut -d'|' -f2)
            IMAGE_NAME=$(echo "$IMAGE_LINE" | cut -d'|' -f3)
            
            # Create a safe file name
            SAFE_NAME=$(echo "$IMAGE_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g')
            FILENAME="/tmp/${SAFE_NAME}_$(date +%Y%m%d_%H%M%S).tar"
            
            whiptail --title "Info" --msgbox "Export in progress...\nThis may take a few minutes." 8 60
            
            if sudo docker save "$IMAGE_ID" > "$FILENAME" 2>/dev/null; then
                FILE_SIZE=$(ls -lh "$FILENAME" | awk '{print $5}')
                whiptail --title "Success" --msgbox "Image $IMAGE_NAME exported!\n\nFile: $FILENAME\nSize: $FILE_SIZE" 10 80
            else
                whiptail --title "Error" --msgbox "Error during export!" 8 50
            fi
        fi
    fi
    
    # Clean up temporary file
    rm -f "$TEMP_MAP"
}

# Backup volume
backup_volume() {
    VOLUMES=$(sudo docker volume ls --format "{{.Name}}")
    if [ -z "$VOLUMES" ]; then
        whiptail --title "Info" --msgbox "No volumes found!" 8 50
        return
    fi
    
    OPTIONS=""
    for vol in $VOLUMES; do
        OPTIONS="$OPTIONS $vol $vol"
    done
    
    SELECTED=$(whiptail --title "Backup Volume" --menu "Choose volume:" 15 70 8 $OPTIONS 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ]; then
        BACKUP_PATH="/tmp/volume_${SELECTED}_$(date +%Y%m%d_%H%M%S).tar.gz"
        sudo docker run --rm -v $SELECTED:/volume -v /tmp:/backup alpine tar czf /backup/volume_${SELECTED}_$(date +%Y%m%d_%H%M%S).tar.gz -C /volume .
        whiptail --title "Success" --msgbox "Volume backed up to:\n$BACKUP_PATH" 8 80
    fi
}

# Startup banner
show_banner() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                               DOCKER MANAGER                                 ║"
    echo "║                            Docker Management Script                         ║"
    echo "║                                   v1.0                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo
}

# Check dependencies
check_dependencies() {
    if ! command -v whiptail &> /dev/null; then
        echo -e "${RED}Error: whiptail not found!${NC}"
        echo "Install with: sudo apt-get install whiptail"
        exit 1
    fi
}

# MAIN EXECUTION
show_banner
check_dependencies
check_docker

# Welcome message
whiptail --title "Welcome to Docker Manager" --msgbox "Easily manage Docker containers, images, volumes, and networks!\n\nWARNING: This script requires sudo privileges to function." 12 70

# Start main menu
main_menu
