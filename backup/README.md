# Backup Scripts

This directory contains backup utilities for system directories and QEMU virtual machines.

## Available Scripts

### backup-qemu-vms

Backs up QEMU/KVM virtual machines including XML configurations and disk images.

**Features:**
- Gracefully shuts down running VMs before backup
- Backs up VM XML configuration files
- Copies VM disk images
- MD5 checksum verification
- Automated backup organization (xml/ and hd/ subdirectories)

**Usage:**
```bash
sudo backup-qemu-vms <backup_directory>
```

**Example:**
```bash
sudo backup-qemu-vms /media/backup/qemu
```

**Requirements:**
- Root privileges
- libvirt/virsh installed
- Sufficient disk space for VM images

**Directory Structure:**
```
backup_directory/
├── xml/          # VM configuration files
└── hd/           # VM disk images
```

---

### manzolo-backup-home (mbackup)

Professional backup solution with incremental backups using rsync. Supports multiple directories with exclusions and detailed reporting.

**Features:**
- Incremental backup support
- Multiple source directories (/home, /etc, /var)
- Exclusion patterns (caches, temp files, etc.)
- Sudo support for root-owned files
- Progress reporting with statistics
- Dry-run mode for testing
- Verbose logging
- Beautiful colored output

**Usage:**
```bash
sudo manzolo-backup-home <destination_disk> [username] [options]
# Or using the mapped alias:
sudo mbackup <destination_disk> [username] [options]
```

**Options:**
- `--dry-run`: Test run without actual copying
- `--verbose`: Detailed output
- `--help`: Show help message

**Example:**
```bash
# Backup current user's home
sudo mbackup /media/backup myusername

# Dry run to see what would be backed up
sudo mbackup /media/backup myusername --dry-run

# Verbose output
sudo mbackup /media/backup myusername --verbose
```

**Requirements:**
- Root privileges
- rsync installed
- Sufficient disk space on destination

**Backed Up Directories:**
- `/home/<username>`
- `/etc` (system configuration)
- `/var` (application data, logs)

**Exclusions:**
- Browser caches (.cache/google-chrome, .cache/mozilla, etc.)
- Node.js modules (node_modules)
- Python caches (__pycache__)
- Temporary files
- Thumbnails
- Trash folders

**Configuration:**
Default configuration can be customized via `backup.conf` file in the script directory.

**Logs:**
Backup logs are stored in `/var/log/backup/`
