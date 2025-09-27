#!/bin/bash

# wp-management - Script to manage backups and dockerization of WordPress sites
# Usage: 
#   ./wp-management backup <site_name>
#   ./wp-management dockerize <site_name>

set -e  # Exit on error

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
    # Uses POSIX bracket expressions [[:space:]] which are widely supported.
    # Handles both single and double quotes, with or without spaces.
    # Note: If your shell lacks proper [[:space:]] support, this might still be the weak point.
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
    
    # Create the database dump (compatible with older mysql clients)
    local db_backup_file="$site_backup_dir/database_${timestamp}.sql"
    
    # More robust method for database backup (Test connection first)
    print_message $YELLOW "Attempting to connect to the database..."
    
    # Test connection using 'mysql' client before running 'mysqldump'
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

# Function for dockerization
dockerize_site() {
    local site_name=$1
    local site_path="./$site_name"
    local docker_dir="./docker-$site_name"
    
    print_message $BLUE "=== DOCKERIZING WORDPRESS SITE: $site_name ==="
    
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
    
    # Use default values if not found
    DB_NAME=${DB_NAME:-"wordpress_db"}
    DB_USER=${DB_USER:-"wordpress_user"}
    DB_PASSWORD=${DB_PASSWORD:-"wordpress_password"}
    
    print_message $GREEN "Configuration extracted for Docker:"
    print_message $GREEN "  Database: $DB_NAME"
    print_message $GREEN "  User: $DB_USER"
    
    # Create the Docker folder
    mkdir -p "$docker_dir"
    
    # Generate random root password if not specified (compatible with older bash/systems)
    if command_exists openssl; then
        MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)
    else
        # Fallback for systems without openssl (less secure, but functional)
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
EOF
    
    # Create the docker-compose.yml
    print_message $YELLOW "Creating docker-compose.yml..."
    cat > "$docker_dir/docker-compose.yml" << EOF
version: '3.8'

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
      - \${WP_NETWORK}
      - \${NGINX_NETWORK}
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
      - \${WP_NETWORK}
      - \${NGINX_NETWORK}
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
      - \${WP_NETWORK}
      - \${NGINX_NETWORK}

networks:
  \${WP_NETWORK}:
    driver: bridge
    external: true
  \${NGINX_NETWORK}:
    driver: bridge
    external: true
EOF
    
    # Create a utility script
    print_message $YELLOW "Creating utility script..."
    cat > "$docker_dir/manage.sh" << 'EOF'
#!/bin/bash

# Management script for the WordPress container
# Usage: ./manage.sh [start|stop|restart|logs|shell|backup]

case "$1" in
    start)
        echo "Starting containers..."
        docker-compose up -d
        ;;
    stop)
        echo "Stopping containers..."
        docker-compose down
        ;;
    restart)
        echo "Restarting containers..."
        docker-compose restart
        ;;
    logs)
        echo "Viewing logs..."
        docker-compose logs -f
        ;;
    shell)
        echo "Accessing WordPress container shell..."
        docker-compose exec wordpress bash
        ;;
    backup)
        echo "Backing up database..."
        docker-compose exec db_* mysqldump -u root -p wordpress_db > backup_$(date +%Y%m%d_%H%M%S).sql
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|logs|shell|backup}"
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
docker-compose up -d
\`\`\`

### Management with script:
\`\`\`bash
./manage.sh start    # Start containers
./manage.sh stop     # Stop containers
./manage.sh restart  # Restart containers
./manage.sh logs     # View logs
./manage.sh shell    # Access the WordPress container
./manage.sh backup   # Backup the database
\`\`\`

### Access:
- **WordPress**: http://localhost (if ports uncommented)
- **phpMyAdmin**: http://localhost:8081 (if ports uncommented)

### Directories:
- \`wp-data/\` - WordPress files
- \`mysql-data/\` - Database data

## Notes:
- The networks \`wp-net\` and \`nginx-net\` must exist
- Create them with: \`docker network create wp-net\` and \`docker network create nginx-net\`
- Ports are commented out for use with a reverse proxy
EOF
    
    print_message $GREEN "=== DOCKERIZATION COMPLETED ==="
    print_message $GREEN "Docker folder: $docker_dir"
    print_message $GREEN "Files created:"
    ls -la "$docker_dir"
    print_message $YELLOW "To start: cd $docker_dir && docker-compose up -d"
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