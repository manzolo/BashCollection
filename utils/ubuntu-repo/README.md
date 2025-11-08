# Ubuntu Repository Manager

Create and manage your own Ubuntu/Debian package repository (PPA-like) on your server.

## Features

- 🚀 Easy setup wizard
- 📦 Add/remove packages with simple commands
- 🔐 Automatic GPG key generation and signing
- 🌐 Nginx web server configuration
- 📊 Package listing and management
- 🔄 Support for multiple distributions
- 🎯 Both public and internal network support

## Requirements

- Ubuntu/Debian server with root access
- Internet connection (for initial setup)
- At least 1GB free disk space (more depending on packages)

## Quick Start

### 1. Run the setup wizard

```bash
sudo ./ubuntu-repo_manager.sh setup
```

This will guide you through:
- Installing dependencies (aptly, gnupg, nginx)
- Generating GPG signing key
- Creating repository structure
- Configuring web server
- Showing client configuration

### 2. Add your first package

```bash
# Add a .deb package
sudo ./ubuntu-repo_manager.sh add /path/to/package.deb

# Or use interactive mode
sudo ./ubuntu-repo_manager.sh
# Then select option 2
```

### 3. Configure clients to use your repository

On client machines:

```bash
# Add GPG key (modern method)
wget -qO - http://your-server.com/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/myrepo.gpg

# Add repository with signed-by
echo "deb [signed-by=/etc/apt/trusted.gpg.d/myrepo.gpg] http://your-server.com focal main" | sudo tee /etc/apt/sources.list.d/myrepo.list

# Update and install
sudo apt update
sudo apt install your-package
```

## Usage

### Interactive Menu

```bash
sudo ./ubuntu-repo_manager.sh
```

Provides a menu with all operations.

### Command Line

```bash
# Setup new repository
sudo ./ubuntu-repo_manager.sh setup

# Add package
sudo ./ubuntu-repo_manager.sh add /path/to/package.deb

# Remove package
sudo ./ubuntu-repo_manager.sh remove package-name

# List all packages
sudo ./ubuntu-repo_manager.sh list

# Publish changes
sudo ./ubuntu-repo_manager.sh publish

# Show client configuration
sudo ./ubuntu-repo_manager.sh client-config
```

## Architecture Overview

```
/var/www/ubuntu-repo/
├── aptly/              # Aptly database and package pool
│   ├── db/
│   └── pool/
└── public/             # Published repository (served by nginx)
    ├── dists/
    │   └── focal/
    │       └── main/
    ├── pool/
    └── KEY.gpg         # Public GPG key for verification
```

## Configuration

Default configuration can be customized in the setup wizard:

- **Repository Name**: Default `myrepo`
- **Distribution**: Default `focal` (Ubuntu 20.04)
  - Other options: `jammy` (22.04), `noble` (24.04), `bionic` (18.04)
- **Component**: Default `main`
- **Architecture**: Default `amd64`
- **Base Directory**: Default `/var/www/ubuntu-repo`

## Creating Packages for Your Repository

### Option 1: Use existing .deb files

Download or build .deb packages and add them directly:

```bash
sudo ./ubuntu-repo_manager.sh add mypackage.deb
```

### Option 2: Build from source

Create a simple package:

```bash
# Create package structure
mkdir -p mypackage_1.0/DEBIAN
mkdir -p mypackage_1.0/usr/local/bin

# Create control file
cat > mypackage_1.0/DEBIAN/control << EOF
Package: mypackage
Version: 1.0
Section: utils
Priority: optional
Architecture: all
Maintainer: Your Name <you@example.com>
Description: My custom package
 Longer description of my package
EOF

# Add your files
cp myscript.sh mypackage_1.0/usr/local/bin/

# Build package
dpkg-deb --build mypackage_1.0

# Add to repository
sudo ./ubuntu-repo_manager.sh add mypackage_1.0.deb
```

## Advanced Usage

### Supporting Multiple Distributions

To support multiple Ubuntu versions, run setup wizard multiple times with different distributions:

```bash
# Setup for Ubuntu 20.04
sudo ./ubuntu-repo_manager.sh setup
# Choose: focal

# Setup for Ubuntu 22.04
sudo ./ubuntu-repo_manager.sh setup
# Choose: jammy
```

### HTTPS Support

For production environments, use HTTPS:

1. Install certbot:
```bash
sudo apt install certbot python3-certbot-nginx
```

2. Get certificate:
```bash
sudo certbot --nginx -d repo.example.com
```

3. Certbot will automatically configure nginx for HTTPS

### Firewall Configuration

Allow HTTP/HTTPS traffic:

```bash
sudo ufw allow 'Nginx Full'
sudo ufw enable
```

### Internal Network Only

If you want the repository only accessible internally:

1. In nginx configuration, bind only to internal IP:
```nginx
listen 192.168.1.100:80;
```

2. Or use firewall rules to restrict access:
```bash
sudo ufw allow from 192.168.1.0/24 to any port 80
```

## Troubleshooting

### Packages not showing up

After adding packages, always publish:
```bash
sudo ./ubuntu-repo_manager.sh publish
```

### GPG signature errors on clients

Re-add the GPG key (modern method):
```bash
wget -qO - http://your-server.com/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/myrepo.gpg
```

**Note**: The old `apt-key` method is deprecated. Always use the `signed-by` method shown above.

### Nginx 404 errors

Check that the repository is published:
```bash
ls -la /var/www/ubuntu-repo/public/dists/
```

Should contain your distribution folders.

### Permission errors

Ensure correct ownership:
```bash
sudo chown -R www-data:www-data /var/www/ubuntu-repo/public/
```

## Maintenance

### Backup your repository

```bash
# Backup aptly database and packages
sudo tar -czf ubuntu-repo-backup.tar.gz /var/www/ubuntu-repo/aptly/

# Backup GPG keys
gpg --export-secret-keys > gpg-secret-keys.asc
```

### Remove old package versions

```bash
# List packages
sudo ./ubuntu-repo_manager.sh list

# Remove old version
sudo ./ubuntu-repo_manager.sh remove package-name_old-version

# Publish changes
sudo ./ubuntu-repo_manager.sh publish
```

### Monitor repository size

```bash
du -sh /var/www/ubuntu-repo/
```

## Example: Complete Workflow

```bash
# 1. Setup repository
sudo ./ubuntu-repo_manager.sh setup

# 2. Create a simple package
mkdir -p hello_1.0/DEBIAN hello_1.0/usr/local/bin

cat > hello_1.0/DEBIAN/control << EOF
Package: hello
Version: 1.0
Architecture: all
Maintainer: Me <me@example.com>
Description: Hello world script
EOF

echo '#!/bin/bash' > hello_1.0/usr/local/bin/hello
echo 'echo "Hello from my repo!"' >> hello_1.0/usr/local/bin/hello
chmod +x hello_1.0/usr/local/bin/hello

dpkg-deb --build hello_1.0

# 3. Add to repository
sudo ./ubuntu-repo_manager.sh add hello_1.0.deb

# 4. On client machine
wget -qO - http://my-server.com/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/myrepo.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/myrepo.gpg] http://my-server.com focal main" | sudo tee /etc/apt/sources.list.d/myrepo.list
sudo apt update
sudo apt install hello

# 5. Test
hello
# Output: Hello from my repo!
```

## Security Considerations

1. **Always use GPG signing**: Enabled by default in this tool
2. **Use HTTPS in production**: Especially for public repositories
3. **Regular security updates**: Keep aptly and nginx updated
4. **Access control**: Use firewall rules or nginx auth for sensitive repos
5. **Backup GPG keys**: Store securely, losing them means rebuilding trust

## Resources

- [Aptly Documentation](https://www.aptly.info/doc/overview/)
- [Debian Package Guide](https://www.debian.org/doc/manuals/maint-guide/)
- [Ubuntu Packaging Guide](https://packaging.ubuntu.com/html/)
- [Creating .deb Packages](https://wiki.debian.org/BuildingTutorial)

## License

This tool is part of BashCollection and follows the same license.
