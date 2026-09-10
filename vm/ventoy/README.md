# USB Boot Tester (`usb-boot-test`)

Boot a USB stick or a disk image in a QEMU virtual machine, in UEFI or BIOS
mode, without rebooting the host. Interactive whiptail TUI or fully
scriptable CLI. Formerly `ventoy-usb-test`; the old name still works.

```bash
sudo usb-boot-test /dev/sdb                  # boot the stick, auto-detect UEFI/BIOS
usb-boot-test ~/Downloads/ubuntu-24.04.iso   # boot an ISO, no root needed
usb-boot-test --dry-run --bios ventoy.img    # just print the QEMU command line
sudo usb-boot-test --profile windows /dev/sdb # Windows: 8 GiB, integrated mouse
sudo usb-boot-test                           # interactive TUI
```

## What it does

- **Any bootable media**: physical USB devices, and image files in raw/IMG,
  ISO, qcow2, VHD/`.vtoy`, vdi and vmdk format (format auto-detected with
  `qemu-img`).
- **UEFI and BIOS**: UEFI through OVMF (combined `OVMF.fd` or split
  `OVMF_CODE`/`OVMF_VARS` layouts, with a private per-run VARS copy), legacy
  BIOS through SeaBIOS, or both back to back (dual test).
- **Boot-mode auto-detection**: partitioned media are UEFI if they carry an
  EFI System Partition (GPT *or* MBR, so Ventoy sticks are detected
  correctly); plain ISO images are classified from their El Torito boot
  catalog (BIOS-only, UEFI-only or both).
- **ISO images boot as a USB CD-ROM**: a plain ISO 9660 image has no
  partition table, so attached as a USB *disk* nothing would boot. It is
  presented as a USB CD-ROM instead. Hybrid ISOs (isohybrid, most Linux
  installers) keep being tested as a disk, which is what you get after
  `dd`-ing them onto a stick.
- **The target is never modified**: snapshot mode is on by default, so the
  guest writes to a throwaway overlay. Turn it off only to test persistence
  (installers, Ventoy plugins). CD-ROMs are read-only by nature.
- **Refuses to hurt the host**: a device that carries mounted system
  filesystems is rejected; auto-mounted partitions of the target must be
  unmounted first (the TUI offers to, the CLI needs `--unmount`).
- **Reproducible**: `--dry-run` prints the exact QEMU command line, every run
  writes a log, the QEMU monitor listens on a per-run unix socket so several
  instances can coexist.

- **Desktop controls**: integrated USB tablet and fit-to-window scaling by
  default, optional native scaling and fullscreen. Windows and Generic quick
  profiles are available in both the CLI and TUI.
- **Dashboard**: muted blue/grey theme with emoji navigation, visible snapshot
  status, command preview and the last run log. Existing newt themes are honoured.

## Installation

From this repository:

```bash
sudo ./menage_scripts.sh install      # installs usb-boot-test and ventoy-usb-test
```

Dependencies: `qemu-system-x86`, `whiptail`, `jq`, `util-linux`. Recommended:
`ovmf` (UEFI), `qemu-utils` (format detection), `socat` (monitor access).

```bash
# Debian / Ubuntu
sudo apt install qemu-system-x86 ovmf whiptail jq qemu-utils socat
# Fedora
sudo dnf install qemu-system-x86 edk2-ovmf newt jq qemu-img socat
# Arch
sudo pacman -S qemu-full edk2-ovmf libnewt jq socat
```

KVM acceleration is used automatically when `/dev/kvm` is accessible
(`sudo usermod -aG kvm $USER`, then log in again).

## CLI mode

Passing a target (or `--dry-run`) selects the non-interactive mode. Root is
required only for block devices.

```
usb-boot-test [OPTIONS] TARGET
usb-boot-test --dry-run [OPTIONS] TARGET
```

| Option | Meaning | Default |
|--------|---------|---------|
| `--uefi` / `--bios` / `--auto` | boot mode | `auto` |
| `--media auto\|disk\|cdrom` | present TARGET as a USB disk or a USB CD-ROM | `auto` |
| `--profile windows\|generic` | apply hardware defaults; later flags override them | no preset |
| `--mouse tablet\|relative` | integrated pointer or legacy capture | `tablet` |
| `--scale fit\|native` | fit the image to the window or use native size | `fit` |
| `--fullscreen` / `--windowed` | initial window state | windowed |
| `--ram MB` | guest memory | 2048 |
| `--cores N` | guest CPU cores | 4 |
| `--machine q35\|pc\|microvm` | QEMU machine type | `q35` |
| `--usb 1.1\|2.0\|3.0` | USB controller the drive hangs off | `3.0` |
| `--vga virtio\|std\|cirrus\|qxl\|none` | video; `none` is headless with the guest serial console on the terminal | `virtio` |
| `--format FMT` | force the disk format (raw, qcow2, vpc, vdi, vmdk) | detected |
| `--net` / `--sound` | user-mode e1000 network / Intel HDA audio | off |
| `--ovmf PATH` | OVMF firmware (`OVMF.fd` or `OVMF_CODE*.fd`) | auto-detected |
| `--no-snapshot` | let the guest write to TARGET | snapshot on |
| `--unmount` | unmount auto-mounted partitions of TARGET before booting | refuse |
| `-n`, `--dry-run` | print the QEMU command line and exit | |
| `-V`, `--version` / `-h`, `--help` | | |

Exit status: QEMU's when a VM was run, `2` for usage or precondition errors
(target missing, OVMF missing, mounted partitions, ...).

### Desktop profiles

`--profile windows` applies 8192 MB RAM, 4 cores (one thread/core, one
socket), q35, USB 3.0, standard VGA, integrated mouse and fit-to-window.
`--profile generic` applies the same CPU, USB and input defaults with
2048 MB and VirtIO video. They preserve the target, boot mode, snapshot,
network, audio and fullscreen choice.

Options are applied from left to right: `--profile windows --ram 4096`
uses the Windows preset with 4 GiB. The CLI starts from built-in defaults;
the saved configuration is loaded by the interactive TUI.

Scaling enlarges the displayed image; it does not guarantee that the guest
changes its desktop resolution. Adjust resolution inside Windows if needed.
Black bars can remain when the guest and window have different aspect ratios.
The tablet needs a guest USB driver; `--mouse relative` restores legacy input.
Headless mode (`--vga none`) ignores all display and mouse options.

### Examples

```bash
# Ventoy stick, UEFI then BIOS, with network
sudo usb-boot-test --uefi --net /dev/sdb
sudo usb-boot-test --bios --net /dev/sdb

# Windows USB: desktop preset, unmount auto-mounted partitions
sudo usb-boot-test --profile windows --uefi --unmount /dev/sdc

# Windows preset with custom RAM and fullscreen
sudo usb-boot-test --profile windows --ram 4096 --fullscreen /dev/sdc

# Rescue ISO, headless, guest serial console on the terminal (Ctrl+C quits)
usb-boot-test --vga none ~/iso/systemrescue.iso

# Test persistence: the guest really writes to the image
usb-boot-test --no-snapshot ~/vm/ventoy-test.img

# See what would run, e.g. to copy the command into a script
usb-boot-test --dry-run --bios --ram 1024 --usb 2.0 ~/images/freedos.img
```

`--dry-run` output looks like:

```
# target:    /home/me/iso/systemrescue.iso
# format:    raw
# media:     cdrom (auto)
# boot-mode: uefi (auto: ISO 9660, El Torito UEFI+BIOS boot entries)
# snapshot:  n/a (cdrom is read-only)
# firmware:  /usr/share/OVMF/OVMF.fd
# monitor:   socat - UNIX-CONNECT:/tmp/usb-boot-test-me/monitor_12345.sock
qemu-system-x86_64 -name USB\ Boot\ Test -m 2048 -smp cores=4,threads=1,sockets=1 -machine q35 ...
```

## Interactive TUI

```bash
sudo usb-boot-test
```

Root is needed for raw device access; X11 credentials of the invoking user
are inherited so the QEMU window opens on your desktop (the grant is revoked
on exit).

| Menu | What you set |
|------|--------------|
| **Start boot test** | choose a target if needed, then review the configuration and run. |
| **Select USB / image** | removable devices, image browser or a custom path. |
| **Quick profiles** | Windows (8 GiB, standard VGA) or Generic (2 GiB, VirtIO); keeps the selected target and snapshot setting. |
| **Hardware** | RAM, cores, threads, sockets, machine type, disk format and USB version. |
| **Display & mouse** | integrated/relative pointer, fit/native scaling and fullscreen. |
| **Boot mode** | UEFI, BIOS, or detection from the selected target. |
| **Advanced** | VGA, network, audio, snapshot, media type, monitor info and OVMF. |
| **Dual test** | UEFI then BIOS on the same target. |
| **Tools** | preview the QEMU command without booting, read the last run log in this session, diagnostics and help. |
| **Configuration** | save, load or reset; saved automatically before a single test. |

The dashboard shows target, protection status, boot mode, RAM, CPU topology
and KVM availability. It fits an 80×24 terminal and grows up to 100 columns;
the selected menu item is retained when returning from a submenu. For the
new theme, leave `NEWT_COLORS` and `NEWT_COLORS_FILE` unset; set either to
keep your preferred newt palette.

ESC on the main menu asks before quitting; ESC in a sub-dialog just goes back
without changing anything.

### Inside the VM

| Keys | Action |
|------|--------|
| Ctrl+Alt+G | release the mouse |
| Ctrl+Alt+F | toggle fullscreen |
| Ctrl+C in the terminal | terminate QEMU |

## Files

| What | Where |
|------|-------|
| configuration | `~/.config/usb-boot-test/config` (of the invoking user, also under sudo) |
| run logs | `/tmp/usb-boot-test-<user>/logs/run-<timestamp>.log` |
| QEMU monitor | `/tmp/usb-boot-test-<user>/monitor_<pid>.sock` |
| OVMF VARS copy | `/tmp/usb-boot-test-<user>/OVMF_VARS_<pid>.fd` (deleted on exit) |

`<user>` is the user QEMU runs as: your name for unprivileged CLI runs,
`root` for the TUI and for block devices. The paths for the current run are
printed at start-up and in `--help`.

The configuration file is plain `KEY="value"` lines and is parsed, not
sourced. Unknown keys and invalid values are ignored with a warning. A
`~/.ventoy_test_config` from 1.x/2.2 is migrated automatically.

```
MEMORY="2048"
CORES="4"
THREADS="1"
SOCKETS="1"
MACHINE_TYPE="q35"
DISK="/dev/sdb"
FORMAT="raw"
BIOS_MODE="uefi"
VGA_MODE="virtio"
MOUSE_MODE="tablet"
DISPLAY_SCALE="fit"
FULLSCREEN=false
NETWORK=false
SOUND=false
USB_VERSION="3.0"
SNAPSHOT=true
MEDIA_MODE="auto"
```

### QEMU monitor

```bash
socat - UNIX-CONNECT:/tmp/usb-boot-test-root/monitor_<pid>.sock
```

Useful commands: `info status`, `info block`, `info usb`, `system_reset`,
`quit`.

## How detection works

**Format** — `qemu-img info`, with VHD/`.vtoy` files probed as `vpc` first
(their footer is easy to misdetect); extension as a last resort; block
devices are always `raw`.

**Media** (`--media auto`) — a regular file with an ISO 9660 primary volume
descriptor and *no* MBR boot signature (`0x55AA` at offset 510) is a CD-ROM.
Everything else is a disk. Only raw images can be ISOs; qcow2 & co. are
always disks.

**Boot mode** (`--auto`) —

| Target | Result |
|--------|--------|
| partition table with an EFI System Partition (GPT or MBR) | `uefi` |
| GPT without ESP | `uefi` |
| MBR without ESP | `bios` |
| plain ISO with El Torito UEFI entry (with or without a BIOS one) | `uefi` |
| plain ISO with El Torito BIOS entry only | `bios` |
| plain ISO without boot catalog, unpartitioned image | `uefi` (nothing better known) |

The TUI's *Boot → auto* and the CLI's dry-run header both print the reason.

## Troubleshooting

**"OVMF firmware not found"** — `sudo apt install ovmf` (or `edk2-ovmf`), or
pass `--ovmf /path/to/OVMF_CODE.fd`. The TUI can install it from
*Advanced → OVMF Management*.

**"Partitions of /dev/sdX are mounted"** — the desktop auto-mounted the
stick. Pass `--unmount`, or let the TUI unmount it, or `udisksctl unmount -b
/dev/sdX1`.

**"carries mounted system filesystems ... Refusing"** — you picked the disk
the host runs from. There is no override on purpose.

**No bootable device / "Boot failed"** — try the other boot mode; a stick
made for UEFI-only will not boot in BIOS mode and vice versa. Run
`--dry-run` to see what detection concluded. If an ISO was written with a
hybrid MBR but the hybrid part is broken, `--media cdrom` boots it through
El Torito instead.

**Black window** — give it 30 s; try `--vga std`; check the run log for
QEMU warnings. With `--vga none` the guest's serial console is on your
terminal, which is the fastest way to see kernel output.

**GTK "Authorization required" under sudo** — the tool grants root access to
your X server with `xhost`; make sure `xhost` (package `x11-xserver-utils`)
is installed and you run from a terminal inside the graphical session.

**Slow** — check `Diagnostics → KVM Test`; without `/dev/kvm` access QEMU
falls back to TCG emulation.

**`--machine microvm`** has no PCI bus, so the USB controller cannot be
attached; use `q35` or `pc` for USB boot tests.

## Layout

```
vm/ventoy/
├── ventoy-usb-test.sh           # entry point: globals, CLI parsing, main menu
└── usb-boot-test/
    ├── checks.sh                # TUI start-up checks
    ├── config.sh                # KEY="value" config load/save/migrate
    ├── dependencies.sh          # runtime dependency check + install offer
    ├── detect.sh                # USB device list, media type, El Torito, boot mode
    ├── format-detection.sh      # disk image format detection, file browser
    ├── log.sh                   # coloured log helpers
    ├── menu.sh                  # whiptail menus
    ├── ovmf.sh                  # OVMF discovery, pflash/-bios args, install/compile
    ├── qemu.sh                  # QEMU command line, target safety, run
    ├── ui.sh                    # dashboard theme, profiles, command preview and logs
    ├── utils.sh                 # dual test, KVM test
    └── x11.sh                   # X11 access for root under sudo
```

The functional test in `tests/usb-boot-test/test.sh` exercises the CLI in
`--dry-run` mode against synthetic GPT/MBR/hybrid images and ISO 9660 files
(with and without El Torito catalogs); it needs neither root nor QEMU.

```bash
PKG_BIN=./vm/ventoy/ventoy-usb-test.sh tests/usb-boot-test/test.sh
bash tests/usb-boot-test/ui-test.sh
./menage_scripts.sh build usb-boot-test
```

## Changelog

- **2.6.0** — desktop controls (USB tablet, fit/native scaling, fullscreen);
  Windows/Generic profiles; muted blue/grey dashboard with emoji navigation, protection
  status, command preview and session log viewer; saved display preferences;
  explicit UHCI controller for USB 1.1 tests, including q35 machines.

- **2.5.0** — plain ISO 9660 images boot as a USB CD-ROM (they never booted
  as a disk); boot-mode auto-detection reads the El Torito catalog;
  `--media auto|disk|cdrom`; per-user run directory so unprivileged CLI runs
  can log after a sudo TUI run; README rewritten.
- **2.4.0** — non-interactive CLI with `--dry-run`; snapshot mode; unmount
  guard; per-run logs; monitor on a unix socket; XDG config parsed as
  key=value.
- **2.3.0** — headless mode, ESC handling, dual-test state and ESP-based boot
  detection fixes.
- **2.2.x** — modular rewrite, OVMF management, format detection.
