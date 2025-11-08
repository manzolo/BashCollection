#!/bin/bash
# PKG_NAME: wp-management
# PKG_VERSION: 1.5.0
# PKG_SECTION: web
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), tar, gzip
# PKG_RECOMMENDS: docker.io | docker-ce, docker-compose | docker-compose-plugin, mysql-client | mariadb-client
# PKG_SUGGESTS: rsync
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: WordPress site backup and dockerization tool
# PKG_LONG_DESCRIPTION: Manage WordPress backups and convert sites to Docker containers.
#  .
#  Features:
#  - Backup WordPress sites with files and database
#  - Convert existing WordPress to Docker Compose
#  - Automatic database export and import
#  - Docker network creation and configuration
#  - Support for both MySQL and MariaDB
#  - Preserve file permissions and ownership
#  - Interactive site selection and configuration
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
# wp-management - Enhanced script to manage backups and dockerization of WordPress sites
# Usage:
# ./wp-management backup <site_name>
# ./wp-management dockerize <site_name>

set -e # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to pause and wait for user input
pause_for_user() {
    local message="$1"
    echo
    print_message $YELLOW "$message"
    read -p "Press ENTER to continue..." dummy
    echo
}

# Function to check and create Docker networks
check_docker_networks() {
    print_message $BLUE "=== CHECKING DOCKER NETWORKS ==="
    local networks_needed=("wp-net" "nginx-net")
    local networks_missing=()
    
    for network in "${networks_needed[@]}"; do
        if ! docker network ls | grep -q "$network"; then
            networks_missing+=("$network")
        else
            print_message $GREEN "✓ Network '$network' exists"
        fi
    done
    
    if [ ${#networks_missing[@]} -gt 0 ]; then
        print_message $YELLOW "Missing networks detected. Creating them now..."
        for network in "${networks_missing[@]}"; do
            print_message $YELLOW "Creating network: $network"
            docker network create "$network"
            print_message $GREEN "✓ Network '$network' created"
        done
    else
        print_message $GREEN "All required networks are available"
    fi
    echo
}

# Function to extract values from wp-config.php (backward compatible)
get_wp_config_value() {
    local config_file="$1"
    local key="$2"
    
    local line
    line=$(grep -i "define.*['\"]${key}['\"]" "$config_file" | head -n1)
    
    if [ -z "$line" ]; then
        echo ""
        return
    fi
    
    echo "$line" | sed -e 's/.*define[[:space:]]*([[:space:]]*['\''"][^'\'']*['\''"][[:space:]]*,[[:space:]]*['\''"]//i' -e 's/['\''"][[:space:]]*)[[:space:]]*;.*$//' | head -c 200
}

# Function to set proper permissions for wp-content
set_wp_content_permissions() {
    local docker_dir="$1"
    local site_name="$2"
    
    print_message $BLUE "=== SETTING WP-CONTENT PERMISSIONS ==="
    
    local wp_content_path="$docker_dir/wp-data/wp-content"
    
    if [ ! -d "$wp_content_path" ]; then
        print_message $YELLOW "⚠ wp-content directory not found, skipping permissions"
        return
    fi
    
    if id -u www-data >/dev/null 2>&1; then
        print_message $GREEN "✓ www-data user found on host system"
        
        local WWW_DATA_UID=$(id -u www-data)
        local WWW_DATA_GID=$(id -g www-data)
        
        print_message $YELLOW "Setting ownership to www-data (UID: $WWW_DATA_UID, GID: $WWW_DATA_GID)..."
        
        if sudo chown -R www-data:www-data "$wp_content_path" 2>/dev/null; then
            print_message $GREEN "✓ Ownership set to www-data:www-data"
        else
            print_message $YELLOW "⚠ Could not set ownership (may need sudo privileges)"
            print_message $YELLOW "You can manually run: sudo chown -R www-data:www-data $wp_content_path"
        fi
        
        print_message $YELLOW "Setting permissions (755 for directories, 644 for files)..."
        if sudo find "$wp_content_path" -type d -exec chmod 755 {} \; 2>/dev/null && \
           sudo find "$wp_content_path" -type f -exec chmod 644 {} \; 2>/dev/null; then
            print_message $GREEN "✓ Permissions set correctly"
        else
            print_message $YELLOW "⚠ Could not set permissions (may need sudo privileges)"
        fi
        
        local uploads_dir="$wp_content_path/uploads"
        if [ -d "$uploads_dir" ]; then
            print_message $YELLOW "Setting writable permissions for uploads directory..."
            if sudo chmod -R 775 "$uploads_dir" 2>/dev/null; then
                print_message $GREEN "✓ Uploads directory is now writable"
            else
                print_message $YELLOW "⚠ Could not set uploads permissions"
            fi
        fi
        
    else
        print_message $YELLOW "⚠ www-data user not found on host system"
        print_message $YELLOW "Setting generic permissions (will be handled by Docker container)..."
        
        chmod -R 755 "$wp_content_path" 2>/dev/null || true
        find "$wp_content_path" -type f -exec chmod 644 {} \; 2>/dev/null || true
        
        print_message $GREEN "✓ Generic permissions set (Docker will handle user mapping)"
    fi
    
    echo
}

# Function for backup
backup_site() {
    local site_name=$1
    local site_path="./$site_name"
    local backup_dir="./backup"
    local site_backup_dir="$backup_dir/$site_name"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    
    print_message $BLUE "=== BACKUP WORDPRESS SITE: $site_name ==="
    
    if [ ! -d "$site_path" ]; then
        print_message $RED "Error: The folder $site_path does not exist!"
        exit 1
    fi
    
    local wp_config="$site_path/wp-config.php"
    if [ ! -f "$wp_config" ]; then
        print_message $RED "Error: wp-config.php file not found in $site_path!"
        exit 1
    fi
    
    print_message $YELLOW "Reading configuration from wp-config.php..."
    
    DB_NAME=$(get_wp_config_value "$wp_config" "DB_NAME")
    DB_USER=$(get_wp_config_value "$wp_config" "DB_USER")
    DB_PASSWORD=$(get_wp_config_value "$wp_config" "DB_PASSWORD")
    DB_HOST=$(get_wp_config_value "$wp_config" "DB_HOST")
    
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        DB_NAME=$(grep -i "DB_NAME" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_USER=$(grep -i "DB_USER" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_PASSWORD=$(grep -i "DB_PASSWORD" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_HOST=$(grep -i "DB_HOST" "$wp_config" | cut -d'"' -f4 | head -n1)
        
        if [ -z "$DB_NAME" ]; then
            DB_NAME=$(grep -i "DB_NAME" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_USER=$(grep -i "DB_USER" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_PASSWORD=$(grep -i "DB_PASSWORD" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_HOST=$(grep -i "DB_HOST" "$wp_config" | cut -d"'" -f4 | head -n1)
        fi
        
        if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
            print_message $RED "Error: Unable to extract database data!"
            exit 1
        fi
    fi
    
    print_message $GREEN "Database configuration found:"
    print_message $GREEN "  Database: $DB_NAME"
    print_message $GREEN "  User: $DB_USER"
    print_message $GREEN "  Host: $DB_HOST"
    
    mkdir -p "$site_backup_dir"
    
    print_message $YELLOW "Creating wp-content backup..."
    if [ -d "$site_path/wp-content" ]; then
        tar -czf "$site_backup_dir/wp-content_${timestamp}.tar.gz" -C "$site_path" wp-content
        print_message $GREEN "✓ wp-content backup completed"
    else
        print_message $YELLOW "⚠ wp-content folder not found, skipping..."
    fi
    
    print_message $YELLOW "Backing up wp-config.php..."
    cp "$wp_config" "$site_backup_dir/wp-config_${timestamp}.php"
    print_message $GREEN "✓ wp-config.php backup completed"
    
    print_message $YELLOW "Creating database backup..."
    
    if ! command_exists mysqldump; then
        print_message $RED "Error: mysqldump not found! Please install mysql-client."
        exit 1
    fi
    
    local db_backup_file="$site_backup_dir/database_${timestamp}.sql"
    
    print_message $YELLOW "Attempting to connect to the database..."
    if command_exists mysql && mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -e "USE $DB_NAME; SELECT 1;" >/dev/null 2>&1; then
        print_message $GREEN "✓ Database connection successful"
        
        if mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" > "$db_backup_file" 2>/dev/null; then
            print_message $GREEN "✓ Database backup completed"
        else
            print_message $RED "Error during database dump!"
            rm -f "$db_backup_file"
            exit 1
        fi
    else
        print_message $RED "Database connection error!"
        exit 1
    fi
    
    cat > "$site_backup_dir/backup_info_${timestamp}.txt" << EOF
BACKUP WORDPRESS SITE: $site_name
Backup date: $(date)
Timestamp: $timestamp

DATABASE CONFIGURATION:
Host: $DB_HOST
Database: $DB_NAME
User: $DB_USER

INCLUDED FILES:
- wp-content_${timestamp}.tar.gz
- database_${timestamp}.sql
- wp-config_${timestamp}.php
- backup_info_${timestamp}.txt
EOF
    
    print_message $GREEN "=== BACKUP COMPLETED ==="
    print_message $GREEN "Backup folder: $site_backup_dir"
}

# Function to restore wp-content from backup
restore_wp_content() {
    local docker_dir="$1"
    local backup_dir="$2"
    local site_name="$3"
    
    print_message $BLUE "=== RESTORING WP-CONTENT ==="
    
    local wp_content_backup=$(find "$backup_dir" -name "wp-content_*.tar.gz" 2>/dev/null | sort -r | head -n1)
    
    if [ -z "$wp_content_backup" ]; then
        print_message $YELLOW "⚠ No wp-content backup found."
        return
    fi
    
    print_message $GREEN "Found wp-content backup: $(basename "$wp_content_backup")"
    
    mkdir -p "$docker_dir/wp-data"
    
    print_message $YELLOW "Extracting wp-content backup..."
    if tar -xzf "$wp_content_backup" -C "$docker_dir/wp-data"; then
        print_message $GREEN "✓ wp-content restored successfully"
        set_wp_content_permissions "$docker_dir" "$site_name"
    else
        print_message $RED "✗ Error extracting wp-content backup"
    fi
}

# Function to restore database
restore_database() {
    local docker_dir="$1"
    local backup_dir="$2"
    local site_name="$3"
    
    print_message $BLUE "=== RESTORING DATABASE ==="
    
    local db_backup=$(find "$backup_dir" -name "database_*.sql" 2>/dev/null | sort -r | head -n1)
    
    if [ -z "$db_backup" ]; then
        print_message $YELLOW "⚠ No database backup found."
        return
    fi
    
    print_message $GREEN "Found database backup: $(basename "$db_backup")"
    
    cp "$db_backup" "$docker_dir/restore_database.sql"
    print_message $YELLOW "Database backup copied to docker directory"
    
    print_message $YELLOW "Starting containers to restore database..."
    cd "$docker_dir"
    docker compose up -d db_${site_name}
    
    pause_for_user "Database container is starting. Press ENTER when ready to restore..."
    
    print_message $YELLOW "Waiting for database to be ready..."
    sleep 10
    
    local container_name="db_${site_name}"
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if docker exec "$container_name" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
            print_message $GREEN "✓ Database is ready"
            break
        fi
        
        print_message $YELLOW "Waiting... (attempt $attempt/$max_attempts)"
        sleep 3
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        print_message $RED "✗ Database failed to become ready"
        return
    fi
    
    source .env
    
    print_message $YELLOW "Restoring database content..."
    if docker exec -i "$container_name" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < restore_database.sql; then
        print_message $GREEN "✓ Database restored successfully"
        rm -f restore_database.sql
    else
        print_message $RED "✗ Error restoring database"
    fi
}

# Function for dockerization
dockerize_site() {
    local site_name=$1
    local site_path="./$site_name"
    local backup_dir="./backup/$site_name"
    local docker_dir="./docker-$site_name"
    local wp_config=""
    
    print_message $BLUE "=== DOCKERIZING WORDPRESS SITE: $site_name ==="
    
    if ! command_exists docker; then
        print_message $RED "Error: Docker is not installed!"
        exit 1
    fi
    
    check_docker_networks
    
    if [ -d "$site_path" ] && [ -f "$site_path/wp-config.php" ]; then
        wp_config="$site_path/wp-config.php"
        print_message $GREEN "Found wp-config.php in original site folder"
    else
        if [ -d "$backup_dir" ]; then
            print_message $YELLOW "Looking for backed-up wp-config.php files..."
            
            local config_files=($(find "$backup_dir" -name "wp-config_*.php" 2>/dev/null | sort -r))
            
            if [ ${#config_files[@]} -eq 0 ]; then
                print_message $RED "Error: No wp-config.php files found!"
                exit 1
            elif [ ${#config_files[@]} -eq 1 ]; then
                wp_config="${config_files[0]}"
                print_message $GREEN "Found backup: $(basename "$wp_config")"
            else
                print_message $RED "Error: Multiple backup files found."
                exit 1
            fi
        else
            print_message $RED "Error: Neither original site nor backup folder found!"
            exit 1
        fi
    fi
    
    print_message $YELLOW "Reading configuration from: $wp_config"
    
    DB_NAME=$(get_wp_config_value "$wp_config" "DB_NAME")
    DB_USER=$(get_wp_config_value "$wp_config" "DB_USER")
    DB_PASSWORD=$(get_wp_config_value "$wp_config" "DB_PASSWORD")
    
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        DB_NAME=$(grep -i "DB_NAME" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_USER=$(grep -i "DB_USER" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_PASSWORD=$(grep -i "DB_PASSWORD" "$wp_config" | cut -d'"' -f4 | head -n1)
        
        if [ -z "$DB_NAME" ]; then
            DB_NAME=$(grep -i "DB_NAME" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_USER=$(grep -i "DB_USER" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_PASSWORD=$(grep -i "DB_PASSWORD" "$wp_config" | cut -d"'" -f4 | head -n1)
        fi
        
        if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
            print_message $RED "Error: Unable to extract database data!"
            exit 1
        fi
    fi
    
    DB_NAME=${DB_NAME:-"wordpress_db"}
    DB_USER=${DB_USER:-"wordpress_user"}
    DB_PASSWORD=${DB_PASSWORD:-"wordpress_password"}
    
    print_message $GREEN "Configuration extracted for Docker:"
    print_message $GREEN "  Database: $DB_NAME"
    print_message $GREEN "  User: $DB_USER"
    
    mkdir -p "$docker_dir"
    
    if command_exists openssl; then
        MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)
    else
        MYSQL_ROOT_PASSWORD="mysql_root_$(date +%s | tail -c 10)"
    fi
    
    print_message $YELLOW "Creating .env file..."
    # Write .env file with proper escaping
    cat > "$docker_dir/.env" << EOF
# WordPress Docker Environment
# Automatically generated for: ${site_name}

MYSQL_ROOT_PASSWORD='${MYSQL_ROOT_PASSWORD}'
MYSQL_DATABASE='${DB_NAME}'
MYSQL_USER='${DB_USER}'
MYSQL_PASSWORD='${DB_PASSWORD}'

WORDPRESS_DB_HOST=db_${site_name}
WORDPRESS_DB_NAME='${DB_NAME}'
WORDPRESS_DB_USER='${DB_USER}'
WORDPRESS_DB_PASSWORD='${DB_PASSWORD}'

DB_CONTAINER_NAME=db_${site_name}
WP_CONTAINER_NAME=wp_${site_name}
PMA_CONTAINER_NAME=phpmyadmin_${site_name}

WP_NETWORK=wp-net
NGINX_NETWORK=nginx-net

SITE_NAME=${site_name}
EOF
    
    print_message $YELLOW "Creating docker-compose.yml..."
    cat > "$docker_dir/docker-compose.yml" << EOF
services:
  db_${site_name}:
    image: mariadb:latest
    container_name: \${DB_CONTAINER_NAME}
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    networks:
      - wp-net
      - nginx-net
    volumes:
      - ./mysql-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3

  wp_${site_name}:
    depends_on:
      db_${site_name}:
        condition: service_healthy
    image: wordpress:6.8.1
    container_name: \${WP_CONTAINER_NAME}
    restart: always
    environment:
      WORDPRESS_DB_HOST: \${WORDPRESS_DB_HOST}
      WORDPRESS_DB_NAME: \${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER: \${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WORDPRESS_DB_PASSWORD}
    networks:
      - wp-net
      - nginx-net
    volumes:
      - ./wp-data:/var/www/html
    #ports:
    #  - "8080:80"

  phpmyadmin_${site_name}:
    depends_on:
      db_${site_name}:
        condition: service_healthy
    image: phpmyadmin:latest
    container_name: \${PMA_CONTAINER_NAME}
    restart: unless-stopped
    #ports:
    #  - "8081:80"
    environment:
      PMA_HOST: \${WORDPRESS_DB_HOST}
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
    networks:
      - wp-net
      - nginx-net

networks:
  wp-net:
    driver: bridge
    external: true
  nginx-net:
    driver: bridge
    external: true
EOF
    
    print_message $YELLOW "Creating utility script..."
    cat > "$docker_dir/manage.sh" << 'MANAGE_EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_message() {
    echo -e "${1}${2}${NC}"
}

if [ -f .env ]; then
    source .env
else
    print_message $RED "Error: .env file not found"
    exit 1
fi

check_container() {
    docker ps --format "table {{.Names}}" | grep -q "^${1}$"
}

wait_for_database() {
    local max_attempts=30
    local attempt=1
    
    print_message $YELLOW "Waiting for database..."
    
    while [ $attempt -le $max_attempts ]; do
        if docker exec "$1" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
            print_message $GREEN "✓ Database is ready"
            return 0
        fi
        
        sleep 3
        ((attempt++))
    done
    
    print_message $RED "✗ Database timeout"
    return 1
}

case "$1" in
    start)
        print_message $BLUE "Starting containers..."
        docker compose up -d
        if check_container "$DB_CONTAINER_NAME"; then
            wait_for_database "$DB_CONTAINER_NAME"
        fi
        print_message $GREEN "✓ Containers started"
        ;;
        
    stop)
        print_message $BLUE "Stopping containers..."
        docker compose down
        print_message $GREEN "✓ Containers stopped"
        ;;
        
    restart)
        print_message $BLUE "Restarting containers..."
        docker compose restart
        if check_container "$DB_CONTAINER_NAME"; then
            wait_for_database "$DB_CONTAINER_NAME"
        fi
        print_message $GREEN "✓ Containers restarted"
        ;;
        
    logs)
        docker compose logs -f
        ;;
        
    shell)
        if check_container "$WP_CONTAINER_NAME"; then
            docker compose exec wp_${SITE_NAME} bash
        else
            print_message $RED "WordPress container not running"
        fi
        ;;
        
    status)
        print_message $BLUE "Container Status:"
        echo
        
        print_message $YELLOW "Database ($DB_CONTAINER_NAME):"
        if check_container "$DB_CONTAINER_NAME"; then
            print_message $GREEN "  ✓ Running"
        else
            print_message $RED "  ✗ Not running"
        fi
        
        print_message $YELLOW "WordPress ($WP_CONTAINER_NAME):"
        if check_container "$WP_CONTAINER_NAME"; then
            print_message $GREEN "  ✓ Running"
        else
            print_message $RED "  ✗ Not running"
        fi
        
        print_message $YELLOW "phpMyAdmin ($PMA_CONTAINER_NAME):"
        if check_container "$PMA_CONTAINER_NAME"; then
            print_message $GREEN "  ✓ Running"
        else
            print_message $RED "  ✗ Not running"
        fi
        ;;
        
    backup)
        if ! check_container "$DB_CONTAINER_NAME"; then
            print_message $RED "Database not running"
            exit 1
        fi
        
        if ! wait_for_database "$DB_CONTAINER_NAME" >/dev/null 2>&1; then
            print_message $RED "Database not ready"
            exit 1
        fi
        
        backup_file="backup_$(date +%Y%m%d_%H%M%S).sql"
        
        if docker exec "$DB_CONTAINER_NAME" mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" > "$backup_file" 2>/dev/null; then
            print_message $GREEN "✓ Backup completed: $backup_file"
        else
            print_message $RED "✗ Backup failed"
            rm -f "$backup_file"
            exit 1
        fi
        ;;
        
    restore-db)
        if [ ! -f "restore_database.sql" ]; then
            print_message $RED "Error: restore_database.sql not found"
            exit 1
        fi
        
        if ! check_container "$DB_CONTAINER_NAME"; then
            print_message $RED "Database not running"
            exit 1
        fi
        
        if ! wait_for_database "$DB_CONTAINER_NAME" >/dev/null 2>&1; then
            print_message $RED "Database not ready"
            exit 1
        fi
        
        if docker exec -i "$DB_CONTAINER_NAME" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < restore_database.sql 2>/dev/null; then
            print_message $GREEN "✓ Database restored"
        else
            print_message $RED "✗ Restore failed"
            exit 1
        fi
        ;;
        
    *)
        print_message $RED "Usage: $0 {start|stop|restart|logs|shell|backup|restore-db|status}"
        exit 1
        ;;
esac
MANAGE_EOF
    chmod +x "$docker_dir/manage.sh"
    
    cat > "$docker_dir/README.md" << EOF
# WordPress Docker Setup - $site_name

## Service Names:
- \`db_${site_name}\` - MariaDB database
- \`wp_${site_name}\` - WordPress application
- \`phpmyadmin_${site_name}\` - phpMyAdmin interface

## Usage:
\`\`\`bash
cd docker-$site_name
docker compose up -d
\`\`\`

## Management:
\`\`\`bash
./manage.sh start      # Start containers
./manage.sh stop       # Stop containers
./manage.sh restart    # Restart containers
./manage.sh logs       # View logs
./manage.sh shell      # Access WordPress shell
./manage.sh backup     # Backup database
./manage.sh restore-db # Restore database
./manage.sh status     # Show status
\`\`\`

## Directories:
- \`wp-data/\` - WordPress files (www-data ownership)
- \`mysql-data/\` - Database data

## Notes:
- Networks \`wp-net\` and \`nginx-net\` are external
- Ports commented for reverse proxy usage
- wp-content permissions set for www-data if available
EOF
    
    if [ -d "$backup_dir" ]; then
        restore_wp_content "$docker_dir" "$backup_dir" "$site_name"
        pause_for_user "wp-content restored. Ready to restore database?"
        restore_database "$docker_dir" "$backup_dir" "$site_name"
        print_message $GREEN "All containers running with restored content!"
    else
        print_message $YELLOW "No backup directory found."
    fi
    
    print_message $GREEN "=== DOCKERIZATION COMPLETED ==="
    print_message $GREEN "Docker folder: $docker_dir"
    
    print_message $BLUE "=== NEXT STEPS ==="
    print_message $YELLOW "1. cd $docker_dir"
    print_message $YELLOW "2. docker compose up -d"
    print_message $YELLOW "3. Check logs: docker compose logs -f"
    
    print_message $BLUE "=== NOTES ==="
    print_message $GREEN "✓ Networks ready"
    print_message $GREEN "✓ Content restored (if available)"
    print_message $GREEN "✓ Permissions set for www-data"
}

main() {
    if [ $# -lt 2 ]; then
        print_message $RED "Usage: $0 {backup|dockerize} <site_name>"
        exit 1
    fi
    
    case "$1" in
        backup)
            backup_site "$2"
            ;;
        dockerize)
            dockerize_site "$2"
            ;;
        *)
            print_message $RED "Unknown command: $1"
            exit 1
            ;;
    esac
}

main "$@"