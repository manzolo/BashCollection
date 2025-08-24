# Manzolo Scripts Collection

A curated collection of Bash scripts for system administration, backups, cleaning, Docker management, and utilities. These scripts are designed for Linux environments (primarily Ubuntu/Debian) and include tools for tasks like VM backups, system monitoring, Docker maintenance, and more. The main management script (`menage_scripts.sh`) handles installation/uninstallation by creating symlinks in `/usr/local/bin` for easy access.

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
   - This makes all scripts available as commands (e.g., `backup_qemu_vms` instead of `./backup/backup_qemu_vms.sh`).
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

After installation, run scripts directly from the terminal (e.g., `docker_manager`). Most scripts include help messages or TUIs (text-based UIs via `whiptail`).

### Brief Overview of Commands

- **backup_qemu_vms**: Backs up QEMU virtual machines, including XML configs and disk images. Usage: `backup_qemu_vms <backup_dir>`. Includes shutdown, copy, and MD5 verification.
  
- **manzolo_backup_home**: Backs up multiple directories (e.g., `/home`, `/etc`) using `rsync` with incremental support, exclusions, and sudo for root files. Usage: `manzolo_backup_home <dest_disk> [username] [options]`. Options: `--dry-run`, `--verbose`.

- **update_docker_compose**: Scans subdirectories for Docker Compose files, pulls updates, and optionally restarts projects. Interactive prompts for confirmation.

- **docker_manager**: TUI-based Docker management: containers, images, volumes, networks, cleanup, stats, backups, and Compose integration. Requires `whiptail`.

- **one2code**: Extracts and restores individual files from a merged code file (e.g., `code_merged.txt`). Usage: `one2code <cumulative_file>`.

- **server_monitor**: Displays a colorful system dashboard with CPU/memory/disk usage, processes, Docker stats, and more. Run without arguments for a one-time report.

- **systemd_manager**: TUI for managing systemd services: list, view, start/stop/restart, enable/disable, delete. Requires `whiptail`.

- **manzolo_cleaner**: Advanced cleaner with TUI for Docker/Ubuntu: prune resources, remove packages/logs/caches, show stats. Run without arguments to start the menu.

- **ventoy_tester**: (From utils) Tests Ventoy USB boot in QEMU with UEFI/BIOS modes, diagnostics, and configs. Requires QEMU and related deps.

- **vm_image_manager**: An interactive shell script for advanced VM disk image operations. Use it to resize disks, manage partitions, and extend filesystems directly via the NBD protocol. It also includes an option to test the image with QEMU and a dedicated GParted Live boot feature for manual resizing.

- **menage_scripts**: The installer itself (symlinked as `menage_scripts`). Use for install/uninstall/list.

For detailed usage, run each script with `--help` (if supported) or check the source code. Scripts may require sudo for privileged operations.

## Requirements
- Bash 4+
- Ubuntu/Debian-based system (for APT-related features)
- Optional: Docker, QEMU, whiptail, dialog
- Root access for installation and some operations

## Contributing
Feel free to fork, add scripts, or submit PRs. Ensure scripts are well-commented and safe.

## License
MIT License - Free to use/modify/distribute. No warranty provided.
