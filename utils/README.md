# Utility Scripts

Collection of various utility scripts for system administration, monitoring, and specialized tasks.

## Directory Structure

The utils directory contains subdirectories organized by functionality:

- **[code2one](#code2one)**: Merge and extract code files
- **[crypt](#crypt-luks)**: LUKS encryption management
- **[disk-usage](#disk-usage)**: Disk usage analysis
- **[dns](#dns)**: DNS information tools
- **[gnome](#gnome)**: GNOME desktop backup
- **[raspbian](#raspbian-raspberry-pi)**: Raspberry Pi tools
- **[server-monitor](#server-monitor)**: System monitoring dashboard
- **[ssh-manager](#ssh-manager)**: SSH connection manager
- **[systemd](#systemd)**: Systemd service management
- **[system-tools](#system-tools)**: System utilities
- **[ubuntu-usb-installer](#ubuntu-usb-installer)**: Ubuntu USB creation
- **[ufw](#ufw-firewall)**: Firewall management
- **[usb](#usb)**: USB device inspection
- **[usb-boot-test](#usb-boot-test)**: USB boot testing
- **[wordpress](#wordpress)**: WordPress management

---

## Available Scripts

### code2one

Merge multiple code files into a single file or extract them back.

**Scripts:**
- **code2one**: Merge code files into single file
- **one2code**: Extract files from merged file

**Usage:**
```bash
# Merge files
code2one <directory> <output_file>

# Extract files
one2code <merged_file>
```

**Use Cases:**
- Code sharing and documentation
- Archive multiple source files
- Backup code structure
- Share code in single file (e.g., for LLM input)

---

### crypt (LUKS)

**Script:** luks-manager

LUKS encryption management tool for creating, opening, and managing encrypted volumes.

**Features:**
- Create LUKS-encrypted volumes
- Open/close encrypted volumes
- Change passphrases
- Backup/restore LUKS headers
- Format encrypted volumes

**Usage:**
```bash
sudo luks-manager
```

---

### disk-usage

**Script:** disk-usage

Analyze disk usage with interactive reports and visualizations.

**Features:**
- Directory size analysis
- Largest files finder
- Disk usage reports
- Colorful output

**Usage:**
```bash
disk-usage [directory]
```

---

### dns

**Script:** dns-info

DNS information and diagnostics tool.

**Features:**
- Query DNS records (A, AAAA, MX, NS, TXT, etc.)
- Reverse DNS lookups
- DNS server information
- WHOIS lookups

**Usage:**
```bash
dns-info <domain>
```

---

### gnome

**Script:** gnome-backup

Backup and restore GNOME desktop settings and extensions.

**Features:**
- Backup dconf settings
- Backup GNOME extensions
- Backup keybindings
- Restore configurations

**Usage:**
```bash
# Backup
gnome-backup backup <output_directory>

# Restore
gnome-backup restore <backup_directory>
```

---

### raspbian (Raspberry Pi)

Tools for Raspberry Pi image management and emulation.

**Scripts:**
- **pi-boot**: Boot Raspberry Pi images in chroot
- **pi-emulate**: Emulate Raspberry Pi with QEMU

**Features:**
- Mount and chroot into Raspberry Pi images
- QEMU emulation of ARM systems
- Support for various Pi models

**Usage:**
```bash
# Chroot into Pi image
sudo pi-boot <image_file>

# Emulate Pi
sudo pi-emulate <image_file>
```

---

### server-monitor

**Script:** server-monitor

Real-time system monitoring dashboard with beautiful colored output.

**Features:**
- CPU/Memory/Disk usage
- Process monitoring
- Docker container stats
- Network information
- Uptime and load average
- Service status
- Colorful TUI dashboard

**Usage:**
```bash
# One-time report
server-monitor

# Continuous monitoring (refresh every 5 seconds)
server-monitor --watch 5
```

---

### ssh-manager

**Script:** ssh-manager

Interactive SSH connection manager with saved profiles.

**Features:**
- Save SSH connection profiles
- Quick connect to saved hosts
- Manage SSH keys
- Port forwarding helpers
- Connection history

**Usage:**
```bash
ssh-manager
```

---

### systemd

**Script:** systemd-manager

Interactive systemd service management with TUI.

**Features:**
- List all services
- View service status and logs
- Start/stop/restart services
- Enable/disable services
- Edit service files
- Create new services
- Delete services

**Usage:**
```bash
sudo systemd-manager
```

**Main Menu:**
- List services (running/all)
- Service details
- Start/stop/restart
- Enable/disable autostart
- View logs (journalctl)
- Edit unit files
- Reload systemd daemon

---

### system-tools

**Script:** mprocmon

Process monitoring tool with enhanced features.

**Features:**
- Real-time process monitoring
- CPU and memory usage tracking
- Process search and filter
- Kill processes
- Process tree view

**Usage:**
```bash
mprocmon
```

---

### ubuntu-usb-installer

**Script:** ubuntu-usb-installer

Create bootable Ubuntu USB drives.

**Features:**
- Download Ubuntu ISOs
- Create bootable USB drives
- Verify ISO integrity
- Support for multiple Ubuntu flavors

**Usage:**
```bash
sudo ubuntu-usb-installer
```

---

### ufw (Firewall)

**Script:** mfirewall

UFW (Uncomplicated Firewall) management tool.

**Features:**
- Enable/disable firewall
- Add/remove rules
- Port management
- Application profiles
- Rule listing
- Status display

**Usage:**
```bash
sudo mfirewall
```

---

### usb

**Script:** usb-inspector

USB device inspection and information tool.

**Features:**
- List connected USB devices
- Device details (vendor, product, speed)
- USB tree visualization
- Device power information

**Usage:**
```bash
usb-inspector
```

---

### usb-boot-test

**Script:** usb-boot-test (formerly ventoy-usb-test)

Test bootable USB drives and disk images in QEMU without rebooting. Works with Ventoy, Ubuntu ISOs, Windows installers, and any bootable media.

**📖 [Full Documentation](ventoy/README.md)**

**Features:**
- Test physical USB devices and disk images
- UEFI and BIOS/Legacy boot modes
- Dual mode testing (test both UEFI+BIOS sequentially)
- Interactive TUI configuration
- RAM, CPU, VGA, USB configuration
- Format auto-detection
- OVMF firmware management
- Configuration profiles
- Diagnostic tools

**Usage:**
```bash
# Interactive mode
sudo usb-boot-test

# Legacy command (still works)
sudo ventoy-usb-test
```

**Supported Media:**
- Ventoy USB drives
- Ubuntu/Debian ISOs
- Windows installers
- Rescue disks (SystemRescue, GParted, etc.)
- Any bootable USB or disk image

**Boot Modes:**
- UEFI mode (modern systems)
- Legacy BIOS/MBR mode (older systems)
- Auto-detection from partition table
- Dual testing (both modes)

**Requirements:**
- QEMU (qemu-system-x86)
- OVMF (for UEFI support)
- whiptail (TUI interface)

---

### wordpress

**Script:** wp-management

WordPress site management tool.

**Features:**
- Backup WordPress sites
- Update WordPress core
- Manage plugins
- Manage themes
- Database operations
- Restore backups

**Usage:**
```bash
wp-management <wordpress_directory>
```

---

## General Requirements

Most utility scripts require:
- Bash 4+
- Root privileges (for system operations)
- whiptail or dialog (for TUI scripts)
- Specific dependencies listed in each script

## Installation

Install via the main management script:
```bash
sudo ./menage_scripts.sh install
```

Or run utilities directly:
```bash
sudo ./utils/<category>/<script>.sh
```

## Tips

- Most TUI scripts can be navigated with arrow keys and Enter
- Use Tab key for field navigation in dialog boxes
- Press Esc or select Cancel/Exit to quit
- Check script help with `--help` flag when available
- Review script source for advanced options
