#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Ubuntu Repository Manager - Docker Container${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

# Load environment variables with defaults
REPO_NAME="${REPO_NAME:-myrepo}"
REPO_DISTRIBUTION="${REPO_DISTRIBUTION:-focal}"
REPO_COMPONENT="${REPO_COMPONENT:-main}"
REPO_ARCHITECTURE="${REPO_ARCHITECTURE:-amd64}"
GPG_KEY_NAME="${GPG_KEY_NAME:-Ubuntu Repo Signing Key}"
GPG_KEY_EMAIL="${GPG_KEY_EMAIL:-repo@example.com}"
SERVER_NAME="${SERVER_NAME:-localhost}"

echo -e "${CYAN}Configuration:${NC}"
echo -e "  Repository: ${YELLOW}$REPO_NAME${NC}"
echo -e "  Distribution: ${YELLOW}$REPO_DISTRIBUTION${NC}"
echo -e "  Component: ${YELLOW}$REPO_COMPONENT${NC}"
echo -e "  Architecture: ${YELLOW}$REPO_ARCHITECTURE${NC}"
echo -e "  Server: ${YELLOW}$SERVER_NAME${NC}"

# Fix GPG directory permissions
echo -e "${CYAN}Fixing GPG permissions...${NC}"
mkdir -p /root/.gnupg
chmod 700 /root/.gnupg
chmod -R 600 /root/.gnupg/* 2>/dev/null || true

# Create aptly configuration
APTLY_CONFIG="/etc/aptly.conf"
if [ ! -f "$APTLY_CONFIG" ]; then
    echo -e "${CYAN}Creating aptly configuration...${NC}"
    cat > "$APTLY_CONFIG" << EOF
{
  "rootDir": "/var/www/manzolo-ubuntu-repo/aptly",
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
      "rootDir": "/var/www/manzolo-ubuntu-repo/public",
      "linkMethod": "copy"
    }
  }
}
EOF
    echo -e "${GREEN}✓ Aptly configuration created${NC}"
fi

# Check if GPG key exists
if ! gpg --list-keys | grep -q "$GPG_KEY_EMAIL"; then
    echo -e "${CYAN}Generating GPG key...${NC}"

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

    echo -e "${GREEN}✓ GPG key generated${NC}"
else
    echo -e "${YELLOW}✓ GPG key already exists${NC}"
fi

# Export GPG public key
GPG_KEY_ID=$(gpg --list-keys --with-colons "$GPG_KEY_EMAIL" | grep ^pub | cut -d':' -f5)
if [ -n "$GPG_KEY_ID" ]; then
    gpg --armor --export "$GPG_KEY_ID" > /var/www/manzolo-ubuntu-repo/public/KEY.gpg
    echo -e "${GREEN}✓ GPG public key exported to /public/KEY.gpg${NC}"
fi

# Check if repository exists
if ! aptly repo show "$REPO_NAME" &>/dev/null; then
    echo -e "${CYAN}Creating repository...${NC}"
    aptly repo create -distribution="$REPO_DISTRIBUTION" -component="$REPO_COMPONENT" "$REPO_NAME"
    echo -e "${GREEN}✓ Repository created${NC}"
else
    echo -e "${YELLOW}✓ Repository already exists${NC}"
fi

# Check if repository is published
if ! aptly publish list | grep -q "$REPO_DISTRIBUTION"; then
    echo -e "${CYAN}Publishing repository...${NC}"

    # Get GPG key ID for signing
    GPG_KEY_ID=$(gpg --list-keys --with-colons "$GPG_KEY_EMAIL" | grep ^pub | cut -d':' -f5)

    if [ -n "$GPG_KEY_ID" ]; then
        aptly publish repo -batch -gpg-key="$GPG_KEY_ID" -distribution="$REPO_DISTRIBUTION" -architectures="$REPO_ARCHITECTURE,all" "$REPO_NAME" filesystem:public: 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Repository published and signed${NC}"
        else
            echo -e "${YELLOW}! Repository published (may be empty, add packages later)${NC}"
        fi
    else
        echo -e "${RED}✗ GPG key not found, cannot sign repository${NC}"
        return 1
    fi
else
    echo -e "${YELLOW}✓ Repository already published${NC}"
fi

# Create nginx configuration
echo -e "${CYAN}Configuring nginx...${NC}"
cat > /etc/nginx/sites-available/ubuntu-repo << EOF
server {
    listen 80 default_server;
    server_name $SERVER_NAME;

    root /var/www/manzolo-ubuntu-repo/public;
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

    # Add CORS headers for public access
    add_header Access-Control-Allow-Origin *;
    add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS";

    access_log /var/log/nginx/ubuntu-repo-access.log;
    error_log /var/log/nginx/ubuntu-repo-error.log;
}
EOF

ln -sf /etc/nginx/sites-available/ubuntu-repo /etc/nginx/sites-enabled/ubuntu-repo

# Test nginx configuration
nginx -t
echo -e "${GREEN}✓ Nginx configured${NC}"

# Show client configuration
echo
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Client Configuration:${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}1. Download and install GPG key:${NC}"
echo -e "${YELLOW}   wget -qO - https://$SERVER_NAME/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/$REPO_NAME.gpg${NC}"
echo
echo -e "${CYAN}2. Add repository with signed-by:${NC}"
echo -e "${YELLOW}   echo \"deb [signed-by=/etc/apt/trusted.gpg.d/$REPO_NAME.gpg] https://$SERVER_NAME $REPO_DISTRIBUTION $REPO_COMPONENT\" | sudo tee /etc/apt/sources.list.d/$REPO_NAME.list${NC}"
echo
echo -e "${CYAN}3. Update package lists:${NC}"
echo -e "${YELLOW}   sudo apt update${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo

# Execute the main command
exec "$@"
