#!/bin/bash
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
    
    # Robust method that handles various wp-config.php formats
    # Search for lines containing define with our key
    local line
    # Use -i for case-insensitive search (DB_NAME or db_name)
    line=$(grep -i "define.*['\"]${key}['\"]" "$config_file" | head -n1)
    
    if [ -z "$line" ]; then
        echo ""
        return
    fi
    
    # Extract the value using sed in a more compatible way
    echo "$line" | sed -e 's/.*define[[:space:]]*([[:space:]]*['\''"][^'\'']*['\''"][[:space:]]*,[[:space:]]*['\''"]//i' -e 's/['\''"][[:space:]]*)[[:space:]]*;.*$//' | head -c 200
}

# Function for backup
backup_site() {
    local site_name=$1
    local site_path="./$site_name"
    local backup_dir="./backup"
    local site_backup_dir="$backup_dir/$site_name"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    
    print_message $BLUE "=== BACKUP WORDPRESS SITE: $site_name ==="
    
    # Check if the site folder exists
    if [ ! -d "$site_path" ]; then
        print_message $RED "Error: The folder $site_path does not exist!"
        exit 1
    fi
    
    # Check if wp-config.php exists
    local wp_config="$site_path/wp-config.php"
    if [ ! -f "$wp_config" ]; then
        print_message $RED "Error: wp-config.php file not found in $site_path!"
        exit 1
    fi
    
    print_message $YELLOW "Reading configuration from wp-config.php..."
    
    # Extract configuration data
    DB_NAME=$(get_wp_config_value "$wp_config" "DB_NAME")
    DB_USER=$(get_wp_config_value "$wp_config" "DB_USER")
    DB_PASSWORD=$(get_wp_config_value "$wp_config" "DB_PASSWORD")
    DB_HOST=$(get_wp_config_value "$wp_config" "DB_HOST")
    
    # Debug: show what was extracted
    print_message $YELLOW "Debug - Extracted values (Method 1):"
    print_message $YELLOW "  DB_NAME: '$DB_NAME'"
    print_message $YELLOW "  DB_USER: '$DB_USER'"
    print_message $YELLOW "  DB_HOST: '$DB_HOST'"
    
    # Check if data was successfully extracted
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        print_message $RED "Error: Unable to extract database data from wp-config.php using Method 1!"
        print_message $YELLOW "Attempting alternative method..."
        
        # --- Alternative, simpler method using cut ---
        # Tries double quotes first (most common WordPress default)
        DB_NAME=$(grep -i "DB_NAME" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_USER=$(grep -i "DB_USER" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_PASSWORD=$(grep -i "DB_PASSWORD" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_HOST=$(grep -i "DB_HOST" "$wp_config" | cut -d'"' -f4 | head -n1)
        
        # If still unsuccessful, try with single quotes
        if [ -z "$DB_NAME" ]; then
            DB_NAME=$(grep -i "DB_NAME" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_USER=$(grep -i "DB_USER" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_PASSWORD=$(grep -i "DB_PASSWORD" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_HOST=$(grep -i "DB_HOST" "$wp_config" | cut -d"'" -f4 | head -n1)
        fi
        
        print_message $YELLOW "Alternative Method - Extracted values:"
        print_message $YELLOW "  DB_NAME: '$DB_NAME'"
        print_message $YELLOW "  DB_USER: '$DB_USER'"
        print_message $YELLOW "  DB_HOST: '$DB_HOST'"
        
        if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
            print_message $RED "Error: Still unable to extract data!"
            print_message $RED "Extracted values: DB_NAME='$DB_NAME', DB_USER='$DB_USER', DB_PASSWORD='***'"
            print_message $YELLOW "Please check the format of your wp-config.php"
            exit 1
        fi
    fi
    
    print_message $GREEN "Database configuration found:"
    print_message $GREEN "  Database: $DB_NAME"
    print_message $GREEN "  User: $DB_USER"
    print_message $GREEN "  Host: $DB_HOST"
    
    # Create the backup folder
    mkdir -p "$site_backup_dir"
    
    # Backup wp-content
    print_message $YELLOW "Creating wp-content backup..."
    if [ -d "$site_path/wp-content" ]; then
        tar -czf "$site_backup_dir/wp-content_${timestamp}.tar.gz" -C "$site_path" wp-content
        print_message $GREEN "✓ wp-content backup completed"
    else
        print_message $YELLOW "⚠ wp-content folder not found, skipping..."
    fi
    
    # Backup wp-config.php
    print_message $YELLOW "Backing up wp-config.php..."
    cp "$wp_config" "$site_backup_dir/wp-config_${timestamp}.php"
    print_message $GREEN "✓ wp-config.php backup completed"
    
    # Backup database
    print_message $YELLOW "Creating database backup..."
    
    # Check if mysqldump is available
    if ! command_exists mysqldump; then
        print_message $RED "Error: mysqldump not found! Please install mysql-client."
        exit 1
    fi
    
    # Create the database dump
    local db_backup_file="$site_backup_dir/database_${timestamp}.sql"
    
    # Test connection using 'mysql' client before running 'mysqldump'
    print_message $YELLOW "Attempting to connect to the database..."
    if command_exists mysql && mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -e "USE $DB_NAME; SELECT 1;" >/dev/null 2>&1; then
        print_message $GREEN "✓ Database connection successful"
        
        # Perform the dump
        if mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" > "$db_backup_file" 2>/dev/null; then
            print_message $GREEN "✓ Database backup completed"
        else
            print_message $RED "Error during database dump!"
            print_message $YELLOW "Dump command failed despite successful connection test."
            rm -f "$db_backup_file"
            exit 1
        fi
    else
        print_message $RED "Database connection error!"
        print_message $YELLOW "Verify that:"
        print_message $YELLOW "  - The MySQL server is running"
        print_message $YELLOW "  - Credentials are correct"
        print_message $YELLOW "  - Database '$DB_NAME' exists"
        print_message $YELLOW "  - Host '$DB_HOST' is reachable (especially if not localhost)"
        exit 1
    fi
    
    # Create an info file
    cat > "$site_backup_dir/backup_info_${timestamp}.txt" << EOF
BACKUP WORDPRESS SITE: $site_name
Backup date: $(date)
Timestamp: $timestamp

DATABASE CONFIGURATION:
Host: $DB_HOST
Database: $DB_NAME
User: $DB_USER

INCLUDED FILES:
- wp-content_${timestamp}.tar.gz (site contents)
- database_${timestamp}.sql (database dump)
- wp-config_${timestamp}.php (configuration file)
- backup_info_${timestamp}.txt (this file)
EOF
    
    print_message $GREEN "=== BACKUP COMPLETED ==="
    print_message $GREEN "Backup folder: $site_backup_dir"
    print_message $GREEN "Files created:"
    ls -la "$site_backup_dir"/*${timestamp}*
}

# Function to restore wp-content from backup
restore_wp_content() {
    local docker_dir="$1"
    local backup_dir="$2"
    local site_name="$3"
    
    print_message $BLUE "=== RESTORING WP-CONTENT ==="
    
    # Find the most recent wp-content backup
    local wp_content_backup=$(find "$backup_dir" -name "wp-content_*.tar.gz" 2>/dev/null | sort -r | head -n1)
    
    if [ -z "$wp_content_backup" ]; then
        print_message $YELLOW "⚠ No wp-content backup found. WordPress will start with default content."
        return
    fi
    
    print_message $GREEN "Found wp-content backup: $(basename "$wp_content_backup")"
    
    # Create wp-data directory if it doesn't exist
    mkdir -p "$docker_dir/wp-data"
    
    # Extract wp-content to the correct location within wp-data
    print_message $YELLOW "Extracting wp-content backup..."
    if tar -xzf "$wp_content_backup" -C "$docker_dir/wp-data"; then
        print_message $GREEN "✓ wp-content restored successfully"
        print_message $YELLOW "Note: WordPress core files will be installed automatically on first startup"
        print_message $YELLOW "Your wp-content (themes, plugins, uploads) will be preserved"
    else
        print_message $RED "✗ Error extracting wp-content backup"
        print_message $YELLOW "WordPress will start with default content"
    fi
}

# Function to restore database
restore_database() {
    local docker_dir="$1"
    local backup_dir="$2"
    local site_name="$3"
    
    print_message $BLUE "=== RESTORING DATABASE ==="
    
    # Find the most recent database backup
    local db_backup=$(find "$backup_dir" -name "database_*.sql" 2>/dev/null | sort -r | head -n1)
    
    if [ -z "$db_backup" ]; then
        print_message $YELLOW "⚠ No database backup found. WordPress will start with a fresh database."
        return
    fi
    
    print_message $GREEN "Found database backup: $(basename "$db_backup")"
    
    # Copy the database backup to the docker directory for easy access
    cp "$db_backup" "$docker_dir/restore_database.sql"
    print_message $YELLOW "Database backup copied to docker directory as 'restore_database.sql'"
    
    print_message $YELLOW "Starting containers to restore database..."
    # Start only the database container first
    cd "$docker_dir"
    docker compose up -d db_${site_name}
    
    pause_for_user "Database container is starting. Please wait for it to be fully ready, then continue to restore the database."
    
    # Wait a bit more for the database to be ready
    print_message $YELLOW "Waiting for database to be ready..."
    sleep 10
    
    # Check if database container is healthy
    local container_name="wordpress_${site_name}_db"
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Try multiple methods to check if MariaDB is ready
        if docker exec "$container_name" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
            print_message $GREEN "✓ Database is ready"
            break
        elif docker exec "$container_name" mariadb-admin ping -h localhost --silent >/dev/null 2>&1; then
            print_message $GREEN "✓ Database is ready"
            break
        elif docker exec "$container_name" mysqladmin ping -h localhost --silent >/dev/null 2>&1; then
            print_message $GREEN "✓ Database is ready (legacy command)"
            break
        fi
        
        print_message $YELLOW "Waiting for database... (attempt $attempt/$max_attempts)"
        sleep 3
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        print_message $RED "✗ Database failed to become ready in time"
        print_message $YELLOW "You can manually restore later using:"
        print_message $YELLOW "docker compose exec db_${site_name} mariadb -u root -p\${MYSQL_ROOT_PASSWORD} \${MYSQL_DATABASE} < restore_database.sql"
        return
    fi
    
    # Get environment variables
    source .env
    
    # Restore the database
    print_message $YELLOW "Restoring database content..."
    if docker exec -i "$container_name" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < restore_database.sql; then
        print_message $GREEN "✓ Database restored successfully"
        # Clean up the copied sql file
        rm -f restore_database.sql
    elif docker exec -i "$container_name" mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < restore_database.sql; then
        print_message $GREEN "✓ Database restored successfully (legacy command)"
        # Clean up the copied sql file
        rm -f restore_database.sql
    else
        print_message $RED "✗ Error restoring database"
        print_message $YELLOW "The SQL file is available at: $docker_dir/restore_database.sql"
        print_message $YELLOW "You can restore manually later using:"
        print_message $YELLOW "docker compose exec db_${site_name} mariadb -u root -p\${MYSQL_ROOT_PASSWORD} \${MYSQL_DATABASE} < restore_database.sql"
        print_message $YELLOW "or try:"
        print_message $YELLOW "docker compose exec db_${site_name} mysql -u root -p\${MYSQL_ROOT_PASSWORD} \${MYSQL_DATABASE} < restore_database.sql"
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
    
    # Check if Docker is available
    if ! command_exists docker; then
        print_message $RED "Error: Docker is not installed or not in PATH!"
        print_message $YELLOW "Please install Docker and try again."
        exit 1
    fi
    
    # Check and create Docker networks
    check_docker_networks
    
    # First, try to find wp-config.php in the original site folder
    if [ -d "$site_path" ] && [ -f "$site_path/wp-config.php" ]; then
        wp_config="$site_path/wp-config.php"
        print_message $GREEN "Found wp-config.php in original site folder"
    else
        # Look for backed-up wp-config.php files
        if [ -d "$backup_dir" ]; then
            print_message $YELLOW "Original site folder not found or missing wp-config.php"
            print_message $YELLOW "Looking for backed-up wp-config.php files..."
            
            # Find all wp-config backup files
            local config_files=($(find "$backup_dir" -name "wp-config_*.php" 2>/dev/null | sort -r))
            
            if [ ${#config_files[@]} -eq 0 ]; then
                print_message $RED "Error: No wp-config.php files found in $site_path or $backup_dir!"
                exit 1
            elif [ ${#config_files[@]} -eq 1 ]; then
                # Only one backup file found, use it
                wp_config="${config_files[0]}"
                print_message $GREEN "Found single backup: $(basename "$wp_config")"
            else
                # Multiple backup files found, let user choose or show error
                print_message $YELLOW "Multiple wp-config.php backup files found:"
                for i in "${!config_files[@]}"; do
                    local filename=$(basename "${config_files[$i]}")
                    local timestamp=$(echo "$filename" | sed 's/wp-config_\(.*\)\.php/\1/')
                    print_message $YELLOW "  [$((i+1))] $filename (timestamp: $timestamp)"
                done
                print_message $RED "Error: Multiple backup files found. Please specify which one to use or remove older backups."
                print_message $YELLOW "You can manually copy the desired wp-config backup to $site_path/wp-config.php and run again."
                exit 1
            fi
        else
            print_message $RED "Error: Neither original site folder nor backup folder found!"
            print_message $RED "Expected paths: $site_path or $backup_dir"
            exit 1
        fi
    fi
    
    print_message $YELLOW "Reading configuration from: $wp_config"
    
    # Extract configuration data
    DB_NAME=$(get_wp_config_value "$wp_config" "DB_NAME")
    DB_USER=$(get_wp_config_value "$wp_config" "DB_USER")
    DB_PASSWORD=$(get_wp_config_value "$wp_config" "DB_PASSWORD")
    
    # Check if data was successfully extracted
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        print_message $RED "Error: Unable to extract database data from wp-config.php using Method 1!"
        print_message $YELLOW "Attempting alternative method..."
        
        # --- Alternative, simpler method using cut ---
        # Tries double quotes first (most common WordPress default)
        DB_NAME=$(grep -i "DB_NAME" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_USER=$(grep -i "DB_USER" "$wp_config" | cut -d'"' -f4 | head -n1)
        DB_PASSWORD=$(grep -i "DB_PASSWORD" "$wp_config" | cut -d'"' -f4 | head -n1)
        
        # If still unsuccessful, try with single quotes
        if [ -z "$DB_NAME" ]; then
            DB_NAME=$(grep -i "DB_NAME" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_USER=$(grep -i "DB_USER" "$wp_config" | cut -d"'" -f4 | head -n1)
            DB_PASSWORD=$(grep -i "DB_PASSWORD" "$wp_config" | cut -d"'" -f4 | head -n1)
        fi
        
        print_message $YELLOW "Alternative Method - Extracted values:"
        print_message $YELLOW "  DB_NAME: '$DB_NAME'"
        print_message $YELLOW "  DB_USER: '$DB_USER'"
        
        if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
            print_message $RED "Error: Still unable to extract data!"
            print_message $RED "Extracted values: DB_NAME='$DB_NAME', DB_USER='$DB_USER', DB_PASSWORD='***'"
            print_message $YELLOW "Please check the format of your wp-config.php"
            exit 1
        fi
    fi
    
    # Use default values if not found
    DB_NAME=${DB_NAME:-"wordpress_db"}
    DB_USER=${DB_USER:-"wordpress_user"}
    DB_PASSWORD=${DB_PASSWORD:-"wordpress_password"}
    
    print_message $GREEN "Configuration extracted for Docker:"
    print_message $GREEN "  Database: $DB_NAME"
    print_message $GREEN "  User: $DB_USER"
    
    # Create the Docker folder
    mkdir -p "$docker_dir"
    
    # Generate random root password if not specified
    if command_exists openssl; then
        MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)
    else
        # Fallback for systems without openssl
        MYSQL_ROOT_PASSWORD="mysql_root_$(date +%s | tail -c 10)"
    fi
    
    # Create the .env file
    print_message $YELLOW "Creating .env file..."
    cat > "$docker_dir/.env" << EOF
# WordPress Docker Environment
# Automatically generated for: $site_name

# Database Configuration
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_DATABASE=$DB_NAME
MYSQL_USER=$DB_USER
MYSQL_PASSWORD=$DB_PASSWORD

# WordPress Configuration
WORDPRESS_DB_HOST=db_${site_name}
WORDPRESS_DB_NAME=$DB_NAME
WORDPRESS_DB_USER=$DB_USER
WORDPRESS_DB_PASSWORD=$DB_PASSWORD

# Container Names
DB_CONTAINER_NAME=wordpress_${site_name}_db
WP_CONTAINER_NAME=wordpress_${site_name}_webserver
PMA_CONTAINER_NAME=wordpress_${site_name}_phpmyadmin

# Network Names
WP_NETWORK=wp-net
NGINX_NETWORK=nginx-net

# Site Name (for scripts)
SITE_NAME=$site_name
EOF
    
    # Create the docker-compose.yml
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

  wordpress:
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
    #  - "8080:80"  # Uncomment if necessary

  phpmyadmin:
    depends_on:
      db_${site_name}:
        condition: service_healthy
    image: phpmyadmin:latest
    container_name: \${PMA_CONTAINER_NAME}
    restart: unless-stopped
    #ports:
    #  - "8081:80"  # Uncomment if necessary
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
    
    # Create a utility script
    print_message $YELLOW "Creating utility script..."
    cat > "$docker_dir/manage.sh" << 'EOF'
#!/bin/bash
# Management script for the WordPress container
# Usage: ./manage.sh [start|stop|restart|logs|shell|backup|restore-db|status]

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

# Load environment variables
if [ -f .env ]; then
    source .env
else
    print_message $RED "Error: .env file not found"
    exit 1
fi

# Function to check if container is running
check_container() {
    local container_name=$1
    if docker ps --format "table {{.Names}}" | grep -q "^${container_name}$"; then
        return 0
    else
        return 1
    fi
}

# Function to wait for database to be ready
wait_for_database() {
    local container_name=$1
    local max_attempts=30
    local attempt=1
    
    print_message $YELLOW "Waiting for database to be ready..."
    
    while [ $attempt -le $max_attempts ]; do
        # Try multiple methods to check if MariaDB is ready
        if docker exec "$container_name" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
            print_message $GREEN "✓ Database is ready"
            return 0
        elif docker exec "$container_name" mariadb-admin ping -h localhost --silent >/dev/null 2>&1; then
            print_message $GREEN "✓ Database is ready"
            return 0
        elif docker exec "$container_name" mysqladmin ping -h localhost --silent >/dev/null 2>&1; then
            print_message $GREEN "✓ Database is ready (legacy command)"
            return 0
        fi
        
        print_message $YELLOW "Waiting for database... (attempt $attempt/$max_attempts)"
        sleep 3
        ((attempt++))
    done
    
    print_message $RED "✗ Database failed to become ready in time"
    return 1
}

case "$1" in
    start)
        print_message $BLUE "Starting containers..."
        docker compose up -d
        
        # Wait for database to be ready
        if check_container "$DB_CONTAINER_NAME"; then
            wait_for_database "$DB_CONTAINER_NAME"
        fi
        
        print_message $GREEN "✓ All containers started"
        ;;
        
    stop)
        print_message $BLUE "Stopping containers..."
        docker compose down
        print_message $GREEN "✓ All containers stopped"
        ;;
        
    restart)
        print_message $BLUE "Restarting containers..."
        docker compose restart
        
        # Wait for database to be ready after restart
        if check_container "$DB_CONTAINER_NAME"; then
            wait_for_database "$DB_CONTAINER_NAME"
        fi
        
        print_message $GREEN "✓ All containers restarted"
        ;;
        
    logs)
        print_message $BLUE "Viewing logs..."
        docker compose logs -f
        ;;
        
    shell)
        if check_container "$WP_CONTAINER_NAME"; then
            print_message $BLUE "Accessing WordPress container shell..."
            docker compose exec wordpress bash
        else
            print_message $RED "WordPress container is not running. Start it first with: ./manage.sh start"
        fi
        ;;
        
    status)
        print_message $BLUE "Container Status:"
        echo
        print_message $YELLOW "Database Container ($DB_CONTAINER_NAME):"
        if check_container "$DB_CONTAINER_NAME"; then
            print_message $GREEN "  ✓ Running"
            if wait_for_database "$DB_CONTAINER_NAME" >/dev/null 2>&1; then
                print_message $GREEN "  ✓ Database is responsive"
            else
                print_message $YELLOW "  ⚠ Database is starting up"
            fi
        else
            print_message $RED "  ✗ Not running"
        fi
        
        print_message $YELLOW "WordPress Container ($WP_CONTAINER_NAME):"
        if check_container "$WP_CONTAINER_NAME"; then
            print_message $GREEN "  ✓ Running"
        else
            print_message $RED "  ✗ Not running"
        fi
        
        print_message $YELLOW "phpMyAdmin Container ($PMA_CONTAINER_NAME):"
        if check_container "$PMA_CONTAINER_NAME"; then
            print_message $GREEN "  ✓ Running"
        else
            print_message $RED "  ✗ Not running"
        fi
        ;;
        
    backup)
        if ! check_container "$DB_CONTAINER_NAME"; then
            print_message $RED "Database container is not running. Start it first with: ./manage.sh start"
            exit 1
        fi
        
        print_message $BLUE "Backing up database..."
        
        # Check if database is ready
        if ! wait_for_database "$DB_CONTAINER_NAME" >/dev/null 2>&1; then
            print_message $RED "Database is not ready. Please wait and try again."
            exit 1
        fi
        
        backup_file="backup_$(date +%Y%m%d_%H%M%S).sql"
        
        # Try mariadb-dump first, then mysqldump as fallback
        if docker exec "$DB_CONTAINER_NAME" mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" > "$backup_file" 2>/dev/null; then
            print_message $GREEN "✓ Database backup completed using mariadb-dump"
        elif docker exec "$DB_CONTAINER_NAME" mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" > "$backup_file" 2>/dev/null; then
            print_message $GREEN "✓ Database backup completed using mysqldump"
        else
            print_message $RED "✗ Backup failed with both mariadb-dump and mysqldump"
            print_message $YELLOW "Try checking if the database container is healthy:"
            print_message $YELLOW "  ./manage.sh status"
            rm -f "$backup_file"
            exit 1
        fi
        
        # Check if backup file was created and has content
        if [ -s "$backup_file" ]; then
            file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "unknown")
            print_message $GREEN "Backup saved as: $backup_file"
            print_message $GREEN "File size: $file_size bytes"
        else
            print_message $RED "✗ Backup file is empty or was not created"
            rm -f "$backup_file"
            exit 1
        fi
        ;;
        
    restore-db)
        if [ ! -f "restore_database.sql" ]; then
            print_message $RED "Error: restore_database.sql file not found"
            print_message $YELLOW "Place your SQL backup file as 'restore_database.sql' and try again"
            exit 1
        fi
        
        if ! check_container "$DB_CONTAINER_NAME"; then
            print_message $RED "Database container is not running. Start it first with: ./manage.sh start"
            exit 1
        fi
        
        # Check if database is ready
        if ! wait_for_database "$DB_CONTAINER_NAME" >/dev/null 2>&1; then
            print_message $RED "Database is not ready. Please wait and try again."
            exit 1
        fi
        
        print_message $BLUE "Restoring database from restore_database.sql..."
        
        # Try mariadb first, then mysql as fallback
        if docker exec -i "$DB_CONTAINER_NAME" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < restore_database.sql 2>/dev/null; then
            print_message $GREEN "✓ Database restore completed using mariadb"
        elif docker exec -i "$DB_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < restore_database.sql 2>/dev/null; then
            print_message $GREEN "✓ Database restore completed using mysql"
        else
            print_message $RED "✗ Database restore failed with both mariadb and mysql"
            print_message $YELLOW "Check if:"
            print_message $YELLOW "  - The restore_database.sql file is valid"
            print_message $YELLOW "  - The database container is healthy: ./manage.sh status"
            exit 1
        fi
        ;;
        
    *)
        print_message $RED "Usage: $0 {start|stop|restart|logs|shell|backup|restore-db|status}"
        print_message $YELLOW ""
        print_message $YELLOW "Commands:"
        print_message $YELLOW "  start      - Start all containers"
        print_message $YELLOW "  stop       - Stop all containers"
        print_message $YELLOW "  restart    - Restart all containers"
        print_message $YELLOW "  logs       - View container logs"
        print_message $YELLOW "  shell      - Access WordPress container shell"
        print_message $YELLOW "  backup     - Backup the database"
        print_message $YELLOW "  restore-db - Restore database from restore_database.sql"
        print_message $YELLOW "  status     - Show container status"
        exit 1
        ;;
esac
EOF
    chmod +x "$docker_dir/manage.sh"
    
    # Create README
    cat > "$docker_dir/README.md" << EOF
# WordPress Docker Setup - $site_name

Docker configuration for the WordPress site: **$site_name**

## Generated Files:
- \`.env\` - Environment variables
- \`docker-compose.yml\` - Docker configuration
- \`manage.sh\` - Management script
- \`README.md\` - This documentation

## Usage:

### First run:
\`\`\`bash
cd docker-$site_name
docker compose up -d
\`\`\`

### Management with script:
\`\`\`bash
./manage.sh start      # Start containers
./manage.sh stop       # Stop containers
./manage.sh restart    # Restart containers
./manage.sh logs       # View logs
./manage.sh shell      # Access the WordPress container
./manage.sh backup     # Backup the database
./manage.sh restore-db # Restore database from restore_database.sql
./manage.sh status     # Show container status
\`\`\`

### Access:
- **WordPress**: http://localhost (if ports uncommented)
- **phpMyAdmin**: http://localhost:8081 (if ports uncommented)

### Directories:
- \`wp-data/\` - WordPress files
- \`mysql-data/\` - Database data

## Notes:
- The networks \`wp-net\` and \`nginx-net\` are automatically created if missing
- Ports are commented out for use with a reverse proxy
- If you have backup files, they will be automatically restored during setup

## Configuration Source:
- Configuration read from: $wp_config

## Backup Restoration:
- **wp-content**: Automatically restored from backup if available
- **Database**: Automatically restored from backup if available
- Manual database restore: Place SQL file as \`restore_database.sql\` and run \`./manage.sh restore-db\`
EOF
    
    # Restore wp-content if backup exists
    if [ -d "$backup_dir" ]; then
        restore_wp_content "$docker_dir" "$backup_dir" "$site_name"
        pause_for_user "wp-content restoration completed. Ready to start containers and restore database?"
        
        # Restore database
        restore_database "$docker_dir" "$backup_dir" "$site_name"
        print_message $GREEN "All containers are now running with restored content!"
    else
        print_message $YELLOW "No backup directory found. Creating empty Docker setup."
    fi
    
    print_message $GREEN "=== DOCKERIZATION COMPLETED ==="
    print_message $GREEN "Docker folder: $docker_dir"
    print_message $GREEN "Files created:"
    if [ -d "$docker_dir" ]; then
        ls -la "$docker_dir"
    else
        print_message $RED "Error: Docker directory was not created successfully"
    fi
    
    print_message $BLUE "=== NEXT STEPS ==="
    print_message $YELLOW "1. Navigate to the docker directory: cd $docker_dir"
    print_message $YELLOW "2. Start all services: docker compose up -d"
    print_message $YELLOW "3. Check logs: docker compose logs -f"
    print_message $YELLOW "4. Access WordPress at the configured domain/port"
    
    print_message $BLUE "=== IMPORTANT NOTES ==="
    print_message $GREEN "✓ Docker networks 'wp-net' and 'nginx-net' are ready"
    print_message $GREEN "✓ Database and wp-content have been restored from backups (if available)"
    print_message $YELLOW "⚠ Ports are commented out in docker-compose.yml for reverse proxy usage"
    print_message $YELLOW "⚠ Uncomment port mappings if you want direct access"
}

# Main function
main() {
    if [ $# -lt 2 ]; then
        print_message $RED "Usage: $0 {backup|dockerize} <site_name>"
        print_message $YELLOW "Examples:"
        print_message $YELLOW "  $0 backup site1"
        print_message $YELLOW "  $0 dockerize site1"
        exit 1
    fi
    
    local command=$1
    local site_name=$2
    
    case "$command" in
        backup)
            backup_site "$site_name"
            ;;
        dockerize)
            dockerize_site "$site_name"
            ;;
        *)
            print_message $RED "Unrecognized command: $command"
            print_message $YELLOW "Available commands: backup, dockerize"
            exit 1
            ;;
    esac
}

# Execute the main function with all arguments
main "$@"