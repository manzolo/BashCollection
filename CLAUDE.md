# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

BashCollection is a collection of system administration and VM management Bash scripts for Linux (Ubuntu/Debian). Scripts are organized in a modular structure with a central installer (`menage_scripts.sh`) that creates symlinks in `/usr/local/bin` for easy access.

## Installation and Management

### Installing Scripts

```bash
# Install all scripts as system commands
sudo ./menage_scripts.sh install

# Install with debug output
sudo ./menage_scripts.sh install --debug

# Interactive menu
sudo ./menage_scripts.sh
```

### Script Selection System

The installer uses two configuration files in the repository root:

- **.manzoloignore**: Excludes scripts from installation (similar to .gitignore syntax)
- **.manzolomap**: Maps script filenames to custom command names using `path#name` format

Example mapping: `chroot/manzolo-chroot.sh#mchroot` creates both `mchroot` and `manzolo-chroot` commands.

### Other Management Commands

```bash
# List all available scripts
./menage_scripts.sh list

# Uninstall all scripts
sudo ./menage_scripts.sh uninstall

# Update from git and reinstall
sudo ./menage_scripts.sh update

# Build .deb for one package without publishing/deploying (used by CI)
./menage_scripts.sh build <pkg-name>          # prints .deb path on stdout

# Build + upload to remote APT repo
./menage_scripts.sh publish <pkg-name>
```

**Heads-up on `publish`**: its lookup includes a substring fallback
(`*$name*`), so any directory whose path contains the package name can be
matched accidentally (e.g. `tests/dmarc-report/test.sh` would shadow
`utils/email/dmarc-report.sh`). When adding directories that mirror a
package name, list them in `.manzoloignore`.

## Code Architecture

### Modular Structure Pattern

Most major scripts follow a modular architecture where the main script sources helper modules from a subdirectory:

```bash
# Main script: vm/vm_disk_manager.sh
# Helper modules: vm/vm_disk_manager/*.sh

for script in "$SCRIPT_DIR/vm_disk_manager/"**/*.sh; do
    source "$script"
done
```

This pattern is used by:
- `chroot/manzolo-chroot.sh` → sources from `chroot/manzolo-chroot/`
- `disk-cloner/manzolo-disk-clone.sh` → sources from `disk-cloner/manzolo-disk-clone/`
- `vm/vm_disk_manager.sh` → sources from `vm/vm_disk_manager/`
- `utils/ventoy/ventoy-usb-test.sh` → sources from `utils/ventoy/ventoy-usb-test/`

When modifying these scripts, always check the subdirectory for the actual implementation logic.

### Main Script Categories

**VM Management** (`vm/`):
- `vm_disk_manager.sh`: Interactive VM disk operations (resize, partition, NBD-based mounting, QEMU testing)
- `vm_create_disk.sh`: Create new VM disk images with partitions and filesystems
- `vm_clone.sh`: Clone VM images

**Chroot Tools** (`chroot/`):
- `manzolo-chroot.sh`: Advanced chroot into physical/virtual disks with NBD, LUKS, and LVM support
- Supports both block devices and virtual disk images

**Disk Operations** (`disk-cloner/`):
- `manzolo-disk-clone.sh`: Clone between physical/virtual disks with UUID preservation, LUKS support, and dry-run mode
- Uses `partclone` for smart cloning (only used space)

**Docker Management** (`docker/`):
- `docker-manager.sh`: TUI for container/image/volume/network management
- `update-docker-compose.sh`: Update and restart Docker Compose projects

**Backup** (`backup/`):
- `backup-qemu-vms.sh`: Backup QEMU VMs (shutdown, copy, MD5 verification)
- `manzolo-backup-home.sh`: Incremental rsync-based backups with exclusions

**Utilities** (`utils/`):
- `systemd/systemd-manager.sh`: Manage systemd services via TUI
- `server-monitor/server-monitor.sh`: System dashboard with Docker stats
- `ventoy/ventoy-usb-test.sh`: Test Ventoy USB in QEMU (UEFI/BIOS modes)
- `firefox/firefox-session-recover.sh`: Restore Firefox sessions from sessionstore-backups (Snap/APT/Flatpak)
- `code2one/`: Merge/extract files to/from single files

### Common Patterns

**NBD (Network Block Device) Usage**: Scripts that work with virtual disk images (qcow2, vdi, vmdk) use NBD to map them as block devices:

```bash
qemu-nbd --connect=/dev/nbd0 image.qcow2
# Work with /dev/nbd0 as a block device
qemu-nbd --disconnect /dev/nbd0
```

**Whiptail/Dialog TUIs**: Interactive scripts use `whiptail` or `dialog` for text-based UIs. Check dependencies at script start.

**Cleanup Traps**: Most scripts use `trap cleanup EXIT INT TERM` to ensure proper cleanup of mounted filesystems, NBD devices, and temporary files.

**Logging**: Many scripts write to `/tmp/<scriptname>_log_$$.txt` for debugging.

**Root Privileges**: Most scripts require root and check with `[ "$EUID" -ne 0 ]` or `[ "$(id -u)" -ne 0 ]`.

## Common Development Tasks

### Adding a New Script

1. Create the script in the appropriate category directory (e.g., `utils/mynewscript/mynewscript.sh`)
2. Add the standard `PKG_NAME` / `PKG_VERSION` / `PKG_DESCRIPTION` / `PKG_DEPENDS` header (required — CI's `pkg-headers` job rejects mapped scripts without them)
3. Make it executable: `chmod +x utils/mynewscript/mynewscript.sh`
4. If it has helper modules, create a subdirectory: `utils/mynewscript/mynewscript/`
5. Ensure the script supports `-h` / `--help` and exits 0 (CI smoke matrix invokes `--help` on every installed wrapper — see "Continuous Integration" below)
6. Optionally add to `.manzoloignore` to exclude or `.manzolomap` to rename
7. Add the package entry to `.github/smoke-tests.yaml` (default `cmd: ["--help"]` is fine for most scripts; use `skip: "<reason>"` only for things that genuinely can't be smoke-tested)
8. Test with `sudo ./menage_scripts.sh install --debug`

### Testing Scripts Without Installation

```bash
# Run directly
sudo ./path/to/script.sh

# Or use the manager's run command
./menage_scripts.sh run scriptname
```

## Continuous Integration

CI lives in `.github/workflows/ci.yml`. Six job classes run on every push to `main` and every PR:

- **`bash-syntax`** — `bash -n` on every `*.sh`
- **`shellcheck`** — `-S warning` on every script in `.manzolomap` (failing floor; all currently warning-clean)
- **`pkg-headers`** — validates required `PKG_*` fields
- **`discover`** — emits the matrix list from `.manzolomap` as JSON
- **`pkg` (matrix, `fail-fast: false`)** — one job per mapped command. Each runs: build .deb → `sudo apt install ./<deb>` (resolves deps) → smoke test (cmd from `.github/smoke-tests.yaml`) → optional functional test
- **`ollama-backend-tests`** — Docker-based mock backend for the ollama-tools trio

Failures surface as discrete GitHub checks (`pkg (git-info)`, `pkg (mfirewall)`, ...) so you can see at a glance which package broke.

### Smoke-test configuration

`.github/smoke-tests.yaml` is the source of truth for per-package smoke behaviour:

```yaml
git-info:
  cmd: ["--help"]                  # default if omitted

share-manager:
  cmd: ["info"]                    # non-default invocation

dmarc-report:
  cmd: ["--help"]
  apt_deps: [libxml2-utils]        # extras not declared in PKG_DEPENDS
  script: tests/dmarc-report/test.sh   # functional test (see below)

some-pkg:
  skip: "reason — shows as ⊘ in the job summary"
```

### Functional tests

Live under `tests/<pkg>/`:

```
tests/
  <pkg>/
    test.sh              # executable; receives PKG_BIN = path to installed wrapper
    fixtures/            # synthetic inputs (XML samples, fake dirs, etc.)
```

The test script is invoked by `.github/scripts/smoke-test-pkg.sh` after the basic `cmd` succeeds. It receives `$PKG_BIN` pointing at the installed wrapper (usually `/usr/local/bin/<pkg>`) and must exit 0 on success. **`tests/*` is intentionally in `.manzoloignore`** — these are CI fixtures, not publishable scripts.

### CI helper scripts

Under `.github/scripts/`:

- `discover-packages.sh` — emits the JSON matrix list; runnable locally for debug
- `build-pkg.sh` — wraps `./menage_scripts.sh build <name>`; reserves stdout for the .deb path, log goes to stderr (the workflow captures stdout into `$GITHUB_OUTPUT`)
- `smoke-test-pkg.sh` — runs the YAML-configured smoke for a single package

### Common Dependencies

Most scripts require:
- `bash` 4+
- `sudo` for privilege escalation
- `whiptail` or `dialog` for TUI scripts
- `qemu-utils` for NBD and disk image tools
- `parted`, `fdisk`, `lsblk` for disk operations
- `rsync` for backups
- `docker` for Docker-related scripts

Check script headers for specific dependencies. Installation scripts often call `check_dependencies()` functions.

## Key Technical Details

### Virtual Disk Format Support

Scripts support multiple formats via `qemu-img`:
- qcow2 (QEMU Copy-On-Write)
- vdi (VirtualBox)
- vmdk (VMware)
- raw/img

### LUKS/LVM Support

Several scripts handle encrypted partitions (LUKS) and logical volumes:
- `cryptsetup` for LUKS operations
- LVM volume group activation/deactivation
- Proper cleanup in reverse order: unmount → vgchange -an → cryptsetup close → NBD disconnect

### Global Variables Tracking

Scripts maintain global arrays for cleanup:
```bash
MOUNTED_PATHS=()    # Mounted filesystems
LUKS_MAPPED=()      # Opened LUKS mappings
LVM_ACTIVE=()       # Activated volume groups
NBD_DEVICE=""       # Connected NBD device
```

Cleanup functions iterate in reverse order to properly tear down the stack.
