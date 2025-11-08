#!/bin/bash

# Quick Package Builder
# Creates a simple example .deb package

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Get package details
echo -e "${CYAN}Package Name:${NC}"
read -r pkg_name

echo -e "${CYAN}Version (e.g., 1.0):${NC}"
read -r version

echo -e "${CYAN}Short Description:${NC}"
read -r description

echo -e "${CYAN}Your Name:${NC}"
read -r maintainer_name

echo -e "${CYAN}Your Email:${NC}"
read -r maintainer_email

# Create package directory
PKG_DIR="${pkg_name}_${version}"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/local/bin"

# Create control file
cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: $pkg_name
Version: $version
Section: utils
Priority: optional
Architecture: all
Maintainer: $maintainer_name <$maintainer_email>
Description: $description
EOF

# Create example script
cat > "$PKG_DIR/usr/local/bin/$pkg_name" << EOF
#!/bin/bash
echo "Hello from $pkg_name version $version!"
echo "This is an example package created with ubuntu_repo_manager"
EOF

chmod +x "$PKG_DIR/usr/local/bin/$pkg_name"

# Build package
echo -e "${YELLOW}Building package...${NC}"
dpkg-deb --build "$PKG_DIR"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Package created: ${PKG_DIR}.deb${NC}"
    echo -e "${CYAN}Add to repository with:${NC}"
    echo -e "${YELLOW}  sudo ./ubuntu_repo_manager.sh add ${PKG_DIR}.deb${NC}"

    # Cleanup source directory
    rm -rf "$PKG_DIR"
else
    echo -e "${RED}✗ Failed to build package${NC}"
    exit 1
fi
