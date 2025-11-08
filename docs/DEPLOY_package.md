# Deploy to Repository - Quick Guide

Automated deployment pipeline for BashCollection packages to Ubuntu repository.

## Quick Start

```bash
# Deploy a specific package
./deploy-to-repo.sh manzolo-chroot

# Deploy all packages
./deploy-to-repo.sh --all

# Test without making changes
./deploy-to-repo.sh manzolo-disk-clone --dry-run
```

## What It Does

The script automates these manual steps:

1. **Publish** - Builds .deb package using `./menage_scripts.sh publish [package]`
2. **Copy** - Transfers .deb to remote server via `scp`
3. **Import** - Runs `./repo.sh import` on remote server

## Setup

### 1. Configure SSH Key Authentication

```bash
# Generate SSH key if needed
ssh-keygen -t ed25519 -C "deploy@bashcollection"

# Copy to remote server
ssh-copy-id root@home-server.lan

# Test connection
ssh root@home-server.lan "echo 'Connected!'"
```

### 2. Create Custom Configuration (Optional)

```bash
# Copy example config
cp .deploy-config.example .deploy-config

# Edit configuration
nano .deploy-config
```

Configuration options:
```bash
REMOTE_SERVER="root@home-server.lan"
REMOTE_REPO_PATH="/root/ubuntu-repo"
REMOTE_PACKAGES_DIR="$REMOTE_REPO_PATH/packages"
LOCAL_PACKAGES_DIR="utils/ubuntu-repo/packages"
```

## Usage Examples

### Deploy Single Package
```bash
./deploy-to-repo.sh manzolo-chroot
./deploy-to-repo.sh luks-manager
./deploy-to-repo.sh pi-boot
```

### Deploy All Packages
```bash
./deploy-to-repo.sh --all
```

### Dry Run (Test Mode)
```bash
# Test single package deployment
./deploy-to-repo.sh manzolo-cleaner --dry-run

# Test full deployment
./deploy-to-repo.sh --all --dry-run
```

### Copy Only (Skip Import)
```bash
# Copy packages but don't run import
./deploy-to-repo.sh manzolo-disk-clone --no-import
```

### Use Different Server
```bash
# Override server configuration
./deploy-to-repo.sh manzolo-chroot --server root@192.168.1.100
./deploy-to-repo.sh --all --server root@192.168.1.100 --path /srv/ubuntu-repo
```

## Command Options

```
./deploy-to-repo.sh [PACKAGE_NAME] [OPTIONS]

Arguments:
  PACKAGE_NAME        Package to deploy (e.g., manzolo-chroot)

Options:
  -a, --all           Deploy all packages
  -d, --dry-run       Simulate deployment
  -s, --server HOST   Remote server
  -p, --path PATH     Remote repository path
  -n, --no-import     Skip import step
  -h, --help          Show help
```

## Available Packages

Packages with metadata (ready to deploy):
- `manzolo-cleaner` - System cleaning tool
- `manzolo-disk-clone` - Disk cloning utility
- `manzolo-chroot` - Chroot manager
- `luks-manager` - LUKS container manager
- `pi-boot` - Raspberry Pi image boot tool
- `pi-emulate` - Raspberry Pi emulation manager
- `wp-management` - WordPress backup/dockerization
- `deploy-to-repo` - This deployment script
- `docker-manager` - Docker TUI manager
- `nvidia-manager` - NVIDIA driver manager
- `vm-try` - QEMU VM launcher
- `vm-create-disk` - Virtual disk creator
- `vm-iso-manager` - ISO image editor
- `vm-clone` - VM cloning tool
- `server-monitor` - System monitoring dashboard

## Installed Command

After running `sudo ./menage_scripts.sh install`, you can use:

```bash
# Short command
mdeploy manzolo-chroot
mdeploy --all

# Full command
deploy-to-repo manzolo-disk-clone
deploy-to-repo --all --dry-run
```

## Troubleshooting

### Connection Issues

```bash
# Test SSH connection
ssh root@home-server.lan "echo 'OK'"

# Check SSH key
ssh-add -l

# Verbose SSH output
ssh -v root@home-server.lan
```

### Package Not Found

```bash
# Check if package was built
ls -la utils/ubuntu-repo/packages/

# Rebuild package
sudo ./menage_scripts.sh publish manzolo-chroot
```

### Remote Repository Issues

```bash
# Check remote repository
ssh root@home-server.lan "ls -la /root/ubuntu-repo"

# Check repo.sh exists
ssh root@home-server.lan "test -f /root/ubuntu-repo/repo.sh && echo 'Found' || echo 'Not found'"

# Run import manually
ssh root@home-server.lan
cd /root/ubuntu-repo
./repo.sh import
```

## Workflow Integration

### Deploy After Development

```bash
# 1. Make changes to script
vim chroot/manzolo-chroot.sh

# 2. Test locally
sudo ./chroot/manzolo-chroot.sh

# 3. Update version in metadata (PKG_VERSION)
# 4. Deploy
./deploy-to-repo.sh manzolo-chroot
```

### CI/CD Integration

```bash
# In your CI/CD pipeline
./deploy-to-repo.sh --all --dry-run  # Test first
./deploy-to-repo.sh --all             # Deploy if tests pass
```

## Tips

1. **Use dry-run first** - Always test with `--dry-run` before actual deployment
2. **Deploy specific packages** - Faster than `--all` when working on one script
3. **Check logs** - Script shows detailed progress for debugging
4. **SSH keys** - Set up key authentication for passwordless deployment
5. **Config file** - Use `.deploy-config` for persistent custom settings

## Security Notes

- `.deploy-config` is in `.gitignore` to prevent committing sensitive data
- Use SSH keys instead of passwords
- Consider using a dedicated deploy user instead of root
- Review packages with `--dry-run` before deployment

## See Also

- `./menage_scripts.sh --help` - Package manager help
- `CLAUDE.md` - Repository documentation
- `.manzolomap` - Command name mappings
- `.manzoloignore` - Package exclusions
