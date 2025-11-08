# Publishing Scripts to Ubuntu Repository

This guide shows you how to build .deb packages from your BashCollection scripts and publish them to your Ubuntu repository.

## Prerequisites

1. **Ubuntu Repository Setup** - Make sure you have the repository running:
   ```bash
   cd utils/ubuntu_repo
   cp .env.example .env
   # Edit .env with your configuration
   ./repo.sh start
   ```

2. **dpkg-deb tool** - Should be pre-installed on Ubuntu/Debian

## Quick Start

### Option 1: Interactive Menu

```bash
./menage_scripts.sh
# Select: 5) 📦 Build & Publish to Repository
```

### Option 2: Command Line

```bash
./menage_scripts.sh publish
```

## How It Works

The publish feature automatically:

1. **Scans** all your executable scripts (respecting `.manzoloignore`)
2. **Builds** .deb packages for each script
3. **Publishes** them to your Ubuntu repository
4. **Imports** them into the repository (if Docker container is running)

## Publishing Modes

### 1. Publish All Scripts

Builds and publishes ALL executable scripts in BashCollection.

```bash
./menage_scripts.sh publish
# Select option 1
```

**What gets packaged:**
- All .sh files in subdirectories
- Only executable files
- Respects `.manzoloignore` exclusions
- Uses custom names from `.manzolomap`

### 2. Publish Selected Scripts

Choose specific scripts to publish.

```bash
./menage_scripts.sh publish
# Select option 2
# Enter numbers: 1 3 5 7
```

## Package Details

Each script is packaged as:

**Package name**: `script-name` (underscores converted to dashes)
**Version**: 1.0.0
**Installed to**: `/usr/local/bin/script-name`
**Section**: utils
**Dependencies**: bash >= 4.0

## Example Workflow

### 1. Setup Repository (One Time)

```bash
# Start Ubuntu repository
cd utils/ubuntu_repo
cp .env.example .env
nano .env  # Edit configuration
./repo.sh start
```

### 2. Publish Scripts

```bash
# Go back to BashCollection root
cd ../..

# Publish all scripts
./menage_scripts.sh publish
# Select: 1) Publish all scripts
```

### 3. Verify Packages

```bash
cd utils/ubuntu_repo
./repo.sh list
```

### 4. Install on Client

On any Ubuntu machine:

```bash
# Add repository
wget -qO - http://YOUR_SERVER:8080/KEY.gpg | sudo apt-key add -
echo "deb http://YOUR_SERVER:8080 focal main" | sudo tee /etc/apt/sources.list.d/bashcollection.list

# Update and install
sudo apt update
sudo apt install disk-usage docker-manager mfirewall
```

## Package Structure

Each package includes:

```
package-name_1.0.0/
├── DEBIAN/
│   ├── control          # Package metadata
│   └── postinst         # Post-installation script
├── usr/local/bin/
│   └── script-name      # Your script
└── usr/share/doc/package-name/
    ├── copyright        # License info
    └── changelog.gz     # Version history
```

## Workflow Scenarios

### Scenario 1: First Time Publishing

```bash
# 1. Make sure repository is running
cd utils/ubuntu_repo && ./repo.sh status

# 2. If not running, start it
./repo.sh start

# 3. Go back and publish
cd ../.. && ./menage_scripts.sh publish
```

### Scenario 2: Update Existing Packages

```bash
# 1. Make changes to your scripts
nano utils/disk_usage/disk_usage.sh

# 2. Publish updated version
./menage_scripts.sh publish
# Select specific script or all

# 3. On clients, update packages
sudo apt update && sudo apt upgrade
```

### Scenario 3: Add New Script

```bash
# 1. Create new script
mkdir utils/mynew-tool
nano utils/mynew-tool/mynew-tool.sh
chmod +x utils/mynew-tool/mynew-tool.sh

# 2. Test it
./utils/mynew-tool/mynew-tool.sh

# 3. Publish to repository
./menage_scripts.sh publish
# Select the new script

# 4. Install on clients
sudo apt update
sudo apt install mynew-tool
```

## Automation

### Auto-Publish After Git Push

Add to `.git/hooks/post-commit`:

```bash
#!/bin/bash
echo "Building and publishing packages..."
./menage_scripts.sh publish <<< "1"  # Auto-select "publish all"
```

### Scheduled Publishing

Add to crontab:

```bash
# Publish all scripts daily at 2 AM
0 2 * * * cd /path/to/BashCollection && ./menage_scripts.sh publish <<< "1" >> /var/log/bashcollection-publish.log 2>&1
```

## Troubleshooting

### Repository Not Found

```
✖ Ubuntu repository not found at utils/ubuntu_repo
```

**Solution**: Setup the repository first:
```bash
cd utils/ubuntu_repo
./repo.sh start
```

### Container Not Running

```
! Repository container is not running
Packages copied to utils/ubuntu_repo/packages/
```

**Solution**: Start the repository container:
```bash
cd utils/ubuntu_repo
./repo.sh start
./repo.sh import
```

### Package Build Failed

```
✖ Failed to build package
```

**Solution**: Check if dpkg-deb is installed:
```bash
sudo apt install dpkg-dev
```

### No Scripts Found

```
No executable scripts found.
```

**Solution**: Make sure scripts are executable:
```bash
chmod +x utils/*/**.sh
```

## Advanced Configuration

### Custom Package Version

Edit `menage_scripts.sh`, find `build_script_package()` function:

```bash
local version="1.0.0"  # Change this
```

### Custom Maintainer Info

Edit `menage_scripts.sh`, find `build_script_package()` function:

```bash
Maintainer: Your Name <your@email.com>
```

### Custom Dependencies

Add dependencies in the control file generation:

```bash
Depends: bash (>= 4.0), whiptail, dialog
```

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Publish to Repository

on:
  push:
    branches: [ main ]

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2

      - name: Build packages
        run: ./menage_scripts.sh publish <<< "1"

      - name: Upload to repository
        run: |
          cd utils/ubuntu_repo
          ./repo.sh import
```

## Tips

1. **Test locally first** - Use `sudo dpkg -i package.deb` to test before publishing
2. **Version management** - Update version numbers for significant changes
3. **Changelog** - Document changes in package changelogs
4. **Dependencies** - List all required packages in control file
5. **Repository organization** - Group related tools in same component

## See Also

- [Ubuntu Repository Docker Guide](utils/ubuntu_repo/README_DOCKER.md)
- [Package Building Guide](utils/ubuntu_repo/README.md)
- [menage_scripts.sh Documentation](README.md)

---

**Happy Publishing! 📦**
