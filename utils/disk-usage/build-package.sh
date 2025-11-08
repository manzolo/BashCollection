#!/bin/bash

# Build .deb package for disk-usage
# This creates a Debian package that can be distributed via apt repository

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Package information
PACKAGE_NAME="disk-usage"
VERSION="1.0.0"
MAINTAINER="BashCollection <manzolo@example.com>"
DESCRIPTION="Disk usage analyzer with graphical visualization"
ARCHITECTURE="all"

echo -e "${CYAN}Building .deb package for disk-usage...${NC}"

# Package directory
PKG_DIR="${PACKAGE_NAME}_${VERSION}"

# Clean up previous builds
rm -rf "$PKG_DIR" "${PKG_DIR}.deb"

# Create package structure
echo -e "${CYAN}Creating package structure...${NC}"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/local/bin"
mkdir -p "$PKG_DIR/usr/share/doc/$PACKAGE_NAME"
mkdir -p "$PKG_DIR/usr/share/man/man1"

# Create DEBIAN/control file
cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: $PACKAGE_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCHITECTURE
Depends: bc, coreutils, findutils
Maintainer: $MAINTAINER
Description: $DESCRIPTION
 Analyze folder sizes and visualize them with colored progress bars.
 Shows directory sizes, top largest files, and provides multiple
 output options for easy disk space analysis.
 .
 Features:
  - Graphical progress bars with color coding
  - Customizable depth and bar width
  - Top N largest files display
  - Human-readable size formatting
  - Hidden file support
Homepage: https://github.com/yourusername/BashCollection
EOF

# Create postinst script (run after installation)
cat > "$PKG_DIR/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e

# Make sure the script is executable
chmod +x /usr/local/bin/disk-usage

echo "disk-usage installed successfully!"
echo "Run 'disk-usage --help' for usage information"

exit 0
EOF
chmod 755 "$PKG_DIR/DEBIAN/postinst"

# Create prerm script (run before removal)
cat > "$PKG_DIR/DEBIAN/prerm" << 'EOF'
#!/bin/bash
set -e

echo "Removing disk-usage..."

exit 0
EOF
chmod 755 "$PKG_DIR/DEBIAN/prerm"

# Copy the main script
echo -e "${CYAN}Copying disk-usage.sh...${NC}"
cp disk-usage.sh "$PKG_DIR/usr/local/bin/disk-usage"
chmod 755 "$PKG_DIR/usr/local/bin/disk-usage"

# Create man page
echo -e "${CYAN}Creating man page...${NC}"
cat > "$PKG_DIR/usr/share/man/man1/disk-usage.1" << 'EOF'
.TH DISK-USAGE 1 "2024" "disk-usage 1.0.0" "User Commands"
.SH NAME
disk-usage \- analyze and visualize folder sizes
.SH SYNOPSIS
.B disk-usage
[\fIOPTIONS\fR] [\fIDIRECTORY\fR]
.SH DESCRIPTION
Analyze folder sizes in the specified directory (or current directory) and display them with graphical progress bars.
.SH OPTIONS
.TP
.BR \-d ", " \-\-depth " " \fIDEPTH\fR
Maximum depth for folder analysis (default: 1)
.TP
.BR \-w ", " \-\-width " " \fIWIDTH\fR
Width of progress bar (default: 20)
.TP
.BR \-a ", " \-\-all
Include hidden folders
.TP
.BR \-f ", " \-\-files " " [\fIN\fR]
Show top N largest files (default: 10)
.TP
.BR \-h ", " \-\-help
Show help message
.SH EXAMPLES
.TP
.B disk-usage
Analyze current directory
.TP
.B disk-usage /var/log
Analyze /var/log directory
.TP
.B disk-usage -d 2 -a
Show 2 levels deep, include hidden folders
.TP
.B disk-usage -f 20 /home
Show top 20 largest files in /home
.SH AUTHOR
BashCollection
.SH SEE ALSO
.BR du (1),
.BR df (1)
EOF

# Compress man page
gzip -9 "$PKG_DIR/usr/share/man/man1/disk-usage.1"

# Create copyright file
cat > "$PKG_DIR/usr/share/doc/$PACKAGE_NAME/copyright" << 'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: disk-usage
Source: https://github.com/yourusername/BashCollection

Files: *
Copyright: 2024 BashCollection
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
EOF

# Create changelog
cat > "$PKG_DIR/usr/share/doc/$PACKAGE_NAME/changelog" << EOF
disk-usage ($VERSION) stable; urgency=medium

  * Initial release
  * Folder size visualization with progress bars
  * Top N largest files display
  * Support for hidden files and custom depth
  * Human-readable size formatting
  * Color-coded output based on usage percentage

 -- $MAINTAINER  $(date -R)
EOF

# Compress changelog
gzip -9 "$PKG_DIR/usr/share/doc/$PACKAGE_NAME/changelog"

# Create README
cat > "$PKG_DIR/usr/share/doc/$PACKAGE_NAME/README" << 'EOF'
Disk Usage Analyzer
===================

A tool to analyze and visualize folder sizes with graphical progress bars.

Usage:
------
    disk-usage [OPTIONS] [DIRECTORY]

Examples:
---------
    disk-usage                    # Analyze current directory
    disk-usage /var/log           # Analyze /var/log
    disk-usage -d 2 -a            # 2 levels deep, include hidden
    disk-usage -f 20 /home        # Show top 20 largest files

For more information, see: man disk-usage
EOF

# Set correct permissions
echo -e "${CYAN}Setting permissions...${NC}"
find "$PKG_DIR" -type d -exec chmod 755 {} \;
find "$PKG_DIR" -type f -exec chmod 644 {} \;
chmod 755 "$PKG_DIR/usr/local/bin/disk-usage"
chmod 755 "$PKG_DIR/DEBIAN/postinst"
chmod 755 "$PKG_DIR/DEBIAN/prerm"

# Build the package
echo -e "${CYAN}Building .deb package...${NC}"
dpkg-deb --build "$PKG_DIR"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Package built successfully: ${PKG_DIR}.deb${NC}"

    # Show package info
    echo
    echo -e "${CYAN}Package Information:${NC}"
    dpkg-deb --info "${PKG_DIR}.deb"

    echo
    echo -e "${CYAN}Package Contents:${NC}"
    dpkg-deb --contents "${PKG_DIR}.deb"

    echo
    echo -e "${GREEN}Next steps:${NC}"
    echo -e "${YELLOW}1. Test locally:${NC}"
    echo -e "   sudo dpkg -i ${PKG_DIR}.deb"
    echo
    echo -e "${YELLOW}2. Add to repository:${NC}"
    echo -e "   cd ../ubuntu-repo"
    echo -e "   ./repo.sh add ../disk-usage/${PKG_DIR}.deb"
    echo
    echo -e "${YELLOW}3. Or if using Docker repo:${NC}"
    echo -e "   cd ../ubuntu-repo"
    echo -e "   ./repo.sh add ../disk-usage/${PKG_DIR}.deb"

    # Clean up build directory
    rm -rf "$PKG_DIR"

else
    echo -e "${RED}✗ Failed to build package${NC}"
    exit 1
fi
