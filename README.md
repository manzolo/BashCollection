# Manzolo Scripts Collection

A curated collection of Bash scripts for system administration, backups, cleaning, Docker management, and utilities. These scripts are designed for Linux environments (primarily Ubuntu/Debian) and include tools for tasks like VM backups, system monitoring, Docker maintenance, and more. The main management script (`menage_scripts.sh`) handles installation/uninstallation by creating symlinks in `/usr/local/bin` for easy access.

## Table of Contents

- [Installation](#installation)
- [Script Categories](#script-categories)
  - [Backup Scripts](backup/) - VM and system backups
  - [VM Management](vm/) - Virtual machine operations
  - [Chroot Tools](chroot/) - Advanced chroot utilities
  - [Disk Operations](disk-cloner/) - Disk cloning tools
  - [Docker Management](docker/) - Docker and Compose tools
  - [System Cleaner](cleaner/) - System maintenance
  - [QEMU Utilities](qemu/) - QEMU image tools
  - [Utilities](utils/) - Various admin tools
- [Requirements](#requirements)
- [Contributing](#contributing)
- [License](#license)

## Features
- **Modular Structure**: Scripts organized into directories like `backup/`, `cleaner/`, `docker/`, `utils/`.
- **Easy Installation**: Symlinks make scripts executable as global commands (without `.sh` extension).
- **Dependencies**: Most scripts require common tools like `bash`, `whiptail` (for TUI), `docker` (for Docker-related scripts), and `sudo`. Install missing deps via `apt` (e.g., `sudo apt install whiptail`).
- **Logging and Safety**: Many scripts include logging, confirmations, and safety checks.

## Installation

1. **Clone the Repository** (assuming it's hosted on GitHub or similar):
   ```bash
   git clone https://github.com/manzolo/BashCollection.git
   cd BashCollection
   ```

2. **Install Scripts**:
   Run the management script to create symlinks in `/usr/local/bin`:
   ```bash
   sudo ./menage_scripts.sh install
   ```
   - This makes all scripts available as commands (e.g., `backup-qemu-vms` instead of `./backup/backup-qemu-vms.sh`).
   - You may need to restart your shell or run `source ~/.bashrc` for PATH changes to take effect.

3. **Verify Installation**:
   ```bash
   sudo ./menage_scripts.sh list
   ```
   This lists all installed commands.

## Uninstallation

Remove all symlinks:
```bash
sudo ./menage_scripts.sh uninstall
```

## Usage

After installation, run scripts directly from the terminal (e.g., `docker-manager`). Most scripts include help messages or TUIs (text-based UIs via `whiptail`).

## Script Categories

All scripts are organized into categories. Click on each category to see detailed documentation:

### [Backup Scripts](backup/)
Tools for backing up QEMU VMs and system directories.
- **backup-qemu-vms**: Backup QEMU/KVM virtual machines
- **manzolo-backup-home (mbackup)**: Professional rsync-based backup solution

### [VM Management](vm/)
Virtual machine disk operations and management.
- **vm-disk-manager**: Interactive VM disk operations (resize, partition, NBD mounting, QEMU testing)
- **vm-create-disk**: Create new VM disk images
- **vm-clone**: Clone VM images
- **vm-iso-manager**: ISO management for VMs
- **vm-helper**: VM utility functions

### [Chroot Tools](chroot/)
Advanced chroot utilities for physical and virtual disks.
- **manzolo-chroot (mchroot)**: Chroot into disks with NBD, LUKS, and LVM support

### [Disk Operations](disk-cloner/)
Advanced disk cloning between physical and virtual formats.
- **manzolo-disk-clone**: Clone disks with UUID preservation, LUKS support, and multiple format options

### [Docker Management](docker/)
Docker container and compose management tools.
- **docker-manager**: TUI for container/image/volume/network management
- **update-docker-compose**: Update and restart Docker Compose projects

### [System Cleaner](cleaner/)
System cleaning and maintenance utilities.
- **manzolo-cleaner (mcleaner)**: Advanced system cleaning tool with TUI

### [QEMU Utilities](qemu/)
QEMU disk image utilities.
- **compress-qemu-hd-folder**: Batch compress QEMU disk images

### [Utilities](utils/)
Various system administration and specialized tools.
- **code2one/one2code**: Merge and extract code files
- **luks-manager**: LUKS encryption management
- **disk-usage**: Disk usage analysis
- **dns-info**: DNS information tool
- **gnome-backup**: GNOME settings backup
- **pi-boot/pi-emulate**: Raspberry Pi tools
- **server-monitor**: System monitoring dashboard
- **ssh-manager**: SSH connection manager
- **systemd-manager**: Systemd service management TUI
- **mprocmon**: Process monitoring
- **ubuntu-usb-installer**: Create Ubuntu USB drives
- **mfirewall**: UFW firewall management
- **usb-inspector**: USB device inspection
- **ventoy-usb-test**: Test Ventoy USB in QEMU
- **wp-management**: WordPress management

### NVIDIA Tools
- **nvidia-manager**: NVIDIA GPU and driver management

For detailed usage of each category, click on the category links above or check the README in each subdirectory.

## Requirements
- Bash 4+
- Ubuntu/Debian-based system (for APT-related features)
- Optional: Docker, QEMU, whiptail, dialog
- Root access for installation and some operations

## Contributing
Feel free to fork, add scripts, or submit PRs. Ensure scripts are well-commented and safe.

## License
MIT License - Free to use/modify/distribute. No warranty provided.
