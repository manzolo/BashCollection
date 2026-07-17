# Manzolo Scripts Collection

A curated collection of Bash scripts for system administration, backups, cleaning, Docker management, and utilities. These scripts are designed for Linux environments (primarily Ubuntu/Debian) and include tools for tasks like VM backups, system monitoring, Docker maintenance, and more. The main management script (`menage_scripts.sh`) handles installation/uninstallation by creating symlinks in `/usr/local/bin` for easy access.

## Table of Contents

- [Installation](#installation)
- [Script Categories](#script-categories)
  - [vm/](vm/) - Virtual machines, emulation, chroot, Ventoy
  - [disk/](disk/) - Disk cloning, LUKS, USB, disk usage
  - [system/](system/) - Host administration (cleaner, systemd, firewall, NVIDIA, monitoring)
  - [network/](network/) - Networking, SSH, shares, DNS
  - [containers/](containers/) - Docker and Compose tools
  - [backup/](backup/) - VM and system backups
  - [dev-tools/](dev-tools/) - Developer/user tooling (email, Firefox, git, ollama)
- [Requirements](#requirements)
- [Contributing](#contributing)
- [License](#license)

## Features
- **Modular Structure**: Scripts organized by problem domain — `vm/`, `disk/`, `system/`, `network/`, `containers/`, `backup/`, `dev-tools/` (no catch-all `utils/` bucket).
- **Easy Installation**: Symlinks make scripts executable as global commands (without `.sh` extension).
- **Dependencies**: Most scripts require common tools like `bash`, `whiptail` (for TUI), `docker` (for Docker-related scripts), and `sudo`. Install missing deps via `apt` (e.g., `sudo apt install whiptail`).
- **Logging and Safety**: Many scripts include logging, confirmations, and safety checks.

## Installation

### Method 1: Install from PPA Repository (Recommended)

You can now install these utilities directly from the Manzolo PPA repository for easier installation and automatic updates.

**📦 [Install from Manzolo PPA](https://www.manzolo.it/2025/11/manzolo-ppa-my-own-ubuntu-repository/)**

This method provides:
- Easy installation via `apt install`
- Automatic dependency resolution
- Automatic updates with system updates
- No manual symlink management

### Method 2: Manual Installation from Source

1. **Clone the Repository**:
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

Scripts are grouped by problem domain. There is no catch-all `utils/` bucket —
each tool lives under one of seven domain directories.

### [vm/](vm/) — Virtual machines & emulation
- **vm-disk-manager**: Interactive VM disk operations (resize, partition, NBD mounting, QEMU testing)
- **vm-create-disk**, **vm-clone**, **vm-iso-manager**, **compress-qemu-hd**
- **manzolo-chroot (mchroot)** [`vm/chroot/`]: Chroot into physical/virtual disks with NBD, LUKS, LVM
- **usb-boot-test (ventoy-usb-test)** [`vm/ventoy/`]: Test bootable USB/disks in QEMU (UEFI/BIOS)

### [disk/](disk/) — Disk & storage operations
- **manzolo-disk-clone** [`disk/disk-cloner/`]: Clone disks with UUID preservation, LUKS, dry-run
- **disk-usage**: Disk usage analysis
- **luks-manager** [`disk/crypt/`]: LUKS encryption management
- **check-disks**, **usb-inspector**, **ubuntu-usb-installer**

### [system/](system/) — Host administration
- **manzolo-cleaner (mcleaner)**: System cleaning tool with TUI
- **systemd-manager**, **server-monitor**, **mprocmon** (process monitoring)
- **mfirewall** (UFW), **nvidia-manager**, **gnome-backup**
- **manzolo-app**: Interactive catalog/launcher for all scripts

### [network/](network/) — Networking & services
- **network-viewer**, **dns-info**, **ssh-manager**
- **share-manager**: CIFS/NFS/SSHFS share management (dialog TUI, per-share descriptions)
- **wp-management**: WordPress management

### [containers/](containers/) — Docker & Compose
- **docker-manager**: TUI for container/image/volume/network management
- **compose-stack-manager**, **update-docker-compose**

### [backup/](backup/) — Backups
- **backup-qemu-vms**: Backup QEMU/KVM virtual machines
- **manzolo-backup-home (mbackup)**: rsync-based incremental backup solution

### [dev-tools/](dev-tools/) — Developer/user tooling
- **dmarc-report**, **email-domain-check** [`dev-tools/email/`]
- **firefox-session-recover**: Restore Firefox sessions from sessionstore-backups
- **ollama-claude / ollama-codex / openrouter-claude** [`dev-tools/ollama-tools/`]
- **git-info**, **code2one/one2code** (merge/extract files), **pi-emulate** (Raspberry Pi)

## Requirements
- Bash 4+
- Ubuntu/Debian-based system (for APT-related features)
- Optional: Docker, QEMU, whiptail, dialog
- Root access for installation and some operations

## Contributing
Feel free to fork, add scripts, or submit PRs. Ensure scripts are well-commented and safe.

Every PR runs through a GitHub Actions matrix that builds, installs and smoke-tests each mapped command independently (`pkg (<name>)` checks). New scripts are expected to:
- carry a complete `PKG_*` header (see existing scripts as a template),
- be listed in `.manzolomap` and (optionally) `.github/smoke-tests.yaml`,
- support `-h` / `--help` and exit `0` — the CI smoke step invokes it.

Developer-facing notes (CI layout, functional test fixtures under `tests/<pkg>/`, ShellCheck baseline, the `build` sub-command, etc.) live in [CLAUDE.md](CLAUDE.md).

## License
MIT License - Free to use/modify/distribute. No warranty provided.
