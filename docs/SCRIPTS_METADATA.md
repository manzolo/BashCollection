# Scripts Metadata Summary

This document lists all the metadata that has been added or should be added to scripts.

## ✅ Completed

### 1. disk-usage (utils/disk-usage/disk-usage.sh)
- Version: 2.1.0
- Section: utils
- Depends: bash (>= 4.0), coreutils (>= 8.0)
- Recommends: ncdu
- Description: Advanced disk usage analyzer with visual progress bars

### 2. server-monitor (utils/server-monitor/server-monitor.sh)
- Version: 3.0.0
- Section: admin
- Depends: bash (>= 4.0), coreutils, procps, sysstat
- Recommends: docker.io, lm-sensors
- Description: Comprehensive server monitoring dashboard with real-time stats

### 3. docker-manager (docker/docker-manager.sh)
- Version: 2.5.0
- Section: admin
- Depends: bash (>= 4.0), whiptail, docker.io | docker-ce
- Recommends: docker-compose
- Description: Interactive Docker management tool with TUI interface

### 4. systemd-manager (utils/systemd/systemd-manager.sh)
- Version: 1.5.0
- Section: admin
- Depends: bash (>= 4.0), systemd, whiptail
- Description: Interactive systemd service management tool with TUI

### 5. ssh-manager (utils/ssh-manager/ssh-manager.sh)
- Version: 2.2.0
- Section: admin
- Depends: bash (>= 4.0), openssh-client
- Recommends: sshpass
- Description: Enhanced SSH connection manager with profiles and automation

## 📝 To Be Added

### VM Management Scripts

#### vm-disk-manager (vm/vm-disk-manager.sh)
```bash
# PKG_NAME: vm-disk-manager
# PKG_VERSION: 4.0.0
# PKG_SECTION: admin
# PKG_DEPENDS: bash (>= 4.0), qemu-utils, whiptail
# PKG_RECOMMENDS: qemu-system-x86, gparted
# PKG_DESCRIPTION: Comprehensive virtual disk management tool with TUI
# PKG_LONG_DESCRIPTION: Advanced tool for managing QEMU/KVM virtual disk images
#  with interactive text-based interface.
#  .
#  Features:
#  - Create, resize, and convert virtual disk images
#  - NBD mounting for direct filesystem access
#  - Partition management with GParted integration
#  - Snapshot management
#  - Format conversion (qcow2, raw, vdi, vmdk)
#  - Disk image optimization and compression
#  - Interactive file browser for image contents
```

#### vm-create-disk (vm/vm-create-disk.sh)
```bash
# PKG_NAME: vm-create-disk
# PKG_VERSION: 2.0.0
# PKG_SECTION: admin
# PKG_DEPENDS: bash (>= 4.0), qemu-utils
# PKG_DESCRIPTION: Interactive virtual disk creation wizard
# PKG_LONG_DESCRIPTION: User-friendly tool for creating QEMU virtual disk images
#  with guided configuration for size, format, and options.
```

#### vm-clone (vm/vm-clone.sh)
```bash
# PKG_NAME: vm-clone
# PKG_VERSION: 1.5.0
# PKG_SECTION: admin
# PKG_DEPENDS: bash (>= 4.0), qemu-system-x86
# PKG_DESCRIPTION: Clone and test QEMU virtual machines
# PKG_LONG_DESCRIPTION: Tool for cloning virtual machines and testing with
#  different boot media in QEMU with UEFI/BIOS support.
```

### Backup Scripts

#### backup-qemu-vms (backup/backup-qemu-vms.sh)
```bash
# PKG_NAME: backup-qemu-vms
# PKG_VERSION: 2.0.0
# PKG_SECTION: admin
# PKG_DEPENDS: bash (>= 4.0), qemu-utils, virsh
# PKG_RECOMMENDS: pv
# PKG_DESCRIPTION: Backup QEMU/KVM virtual machines with verification
# PKG_LONG_DESCRIPTION: Automated backup tool for QEMU virtual machines
#  including XML configs, disk images, and MD5 verification.
#  .
#  Features:
#  - Automatic VM shutdown before backup
#  - XML configuration backup
#  - Disk image backup with progress
#  - MD5 checksum verification
#  - Automatic VM restart after backup
```

#### manzolo-backup-home (backup/manzolo-backup-home.sh)
```bash
# PKG_NAME: manzolo-backup-home
# PKG_VERSION: 3.0.0
# PKG_SECTION: admin
# PKG_DEPENDS: bash (>= 4.0), rsync (>= 3.0)
# PKG_DESCRIPTION: Incremental backup tool for home directories
# PKG_LONG_DESCRIPTION: Advanced rsync-based backup tool for home directories
#  with incremental support, exclusions, and detailed logging.
#  .
#  Features:
#  - Incremental backups with hardlinks
#  - Customizable exclusion patterns
#  - Dry-run mode for testing
#  - Detailed statistics and logging
#  - Support for multiple backup destinations
#  - Root file backup with sudo
```

### Docker Tools

#### update-docker-compose (docker/update-docker-compose.sh)
```bash
# PKG_NAME: update-docker-compose
# PKG_VERSION: 1.3.0
# PKG_SECTION: admin
# PKG_DEPENDS: bash (>= 4.0), docker-compose | docker-compose-plugin
# PKG_DESCRIPTION: Update and restart Docker Compose projects
# PKG_LONG_DESCRIPTION: Scans directories for Docker Compose files,
#  pulls latest images, and optionally restarts services.
#  .
#  Features:
#  - Recursive scanning for docker-compose.yml files
#  - Pull latest images for all services
#  - Interactive restart prompts
#  - Status reporting for each project
```

### Utility Scripts

#### usb-inspector (utils/usb/usb-inspector.sh)
```bash
# PKG_NAME: usb-inspector
# PKG_VERSION: 5.0.0
# PKG_SECTION: utils
# PKG_DEPENDS: bash (>= 4.0), usbutils, lsblk
# PKG_DESCRIPTION: Comprehensive USB device inspector with performance testing
# PKG_LONG_DESCRIPTION: Advanced tool for inspecting USB devices with
#  detailed information, performance testing, and HTML report generation.
#  .
#  Features:
#  - USB device identification and details
#  - Performance benchmarking
#  - Connection speed detection
#  - HTML report generation
#  - Beautiful colored terminal output
```

#### luks-manager (utils/crypt/luks-manager.sh)
```bash
# PKG_NAME: luks-manager
# PKG_VERSION: 1.0.0
# PKG_SECTION: admin
# PKG_DEPENDS: bash (>= 4.0), cryptsetup
# PKG_DESCRIPTION: LUKS encrypted volume management tool
# PKG_LONG_DESCRIPTION: Interactive tool for managing LUKS encrypted
#  volumes, including creation, opening, closing, and key management.
```

#### manzolo-disk-clone (disk-cloner/manzolo-disk-clone.sh)
```bash
# PKG_NAME: manzolo-disk-clone
# PKG_VERSION: 3.0.0
# PKG_SECTION: admin
# PKG_DEPENDS: bash (>= 4.0), partclone, whiptail
# PKG_RECOMMENDS: qemu-utils, cryptsetup
# PKG_DESCRIPTION: Advanced disk cloning tool with UUID preservation
# PKG_LONG_DESCRIPTION: Comprehensive disk cloning tool supporting both
#  physical and virtual disks with UUID preservation and LUKS support.
#  .
#  Features:
#  - Clone physical to physical disks
#  - Clone virtual disk images
#  - UUID preservation for partitions
#  - LUKS encrypted partition support
#  - Dry-run mode for testing
#  - Uses partclone for efficient copying
```

### Other Tools

#### ventoy-usb-test (utils/ventoy/ventoy-usb-test.sh)
```bash
# PKG_NAME: ventoy-usb-test
# PKG_VERSION: 2.0.0
# PKG_SECTION: utils
# PKG_DEPENDS: bash (>= 4.0), qemu-system-x86
# PKG_DESCRIPTION: Test Ventoy USB drives in QEMU
# PKG_LONG_DESCRIPTION: Tool for testing Ventoy USB boot drives in QEMU
#  virtual machine with UEFI/BIOS mode support.
```

#### code2one / one2code (utils/code2one/)
```bash
# PKG_NAME: code2one
# PKG_VERSION: 1.0.0
# PKG_SECTION: devel
# PKG_DEPENDS: bash (>= 4.0)
# PKG_DESCRIPTION: Merge multiple code files into single file
# PKG_LONG_DESCRIPTION: Tools for merging multiple code files into a single
#  file and extracting them back, useful for code sharing and backups.
```

## Quick Add Commands

To add metadata to a script, use this template at the top (after shebang):

```bash
#!/bin/bash
# PKG_NAME: script-name
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils|admin|devel
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), dependency1, dependency2
# PKG_RECOMMENDS: optional-package
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: One-line description
# PKG_LONG_DESCRIPTION: Detailed description
#  that can span multiple lines
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
```

## Testing

Test package build with:
```bash
./menage_scripts.sh publish script-name
```

View package info:
```bash
dpkg -I package_name.deb
```
