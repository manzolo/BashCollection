#!/usr/bin/env bash
# Functional test for usb-boot-test.
# Exercises the non-interactive CLI in --dry-run mode against synthetic disk
# images, asserting on the generated QEMU command line and on boot-mode
# auto-detection. Never launches QEMU and needs no root.
set -euo pipefail

BIN="${PKG_BIN:-/usr/local/bin/usb-boot-test}"
[[ -x "$BIN" ]] || { echo "binary not found: $BIN" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "ASSERTION FAILED: $*" >&2; exit 1; }

# Build fixtures with sfdisk (util-linux) — no root needed on plain files.
truncate -s 64M "$WORK/gpt.img" "$WORK/mbr.img" "$WORK/hybrid.img"
: > "$WORK/empty.img"
printf 'label: gpt\nsize=32M, type=uefi\ntype=linux\n' | sfdisk -q "$WORK/gpt.img"
printf 'label: dos\ntype=83\n'                           | sfdisk -q "$WORK/mbr.img"
printf 'label: dos\nsize=32M, type=7\ntype=ef\n'         | sfdisk -q "$WORK/hybrid.img"

# Synthetic ISO 9660 images: a primary volume descriptor at sector 16 and,
# when boot platforms are given, an El Torito boot record (sector 17) pointing
# at a boot catalog (sector 19) whose validation entry / section headers carry
# the platform ids (00 = BIOS, EF = UEFI). Enough for detection; no real boot.
mk_iso() {   # mk_iso FILE [bios|uefi ...]
    local f="$1"; shift
    truncate -s 128K "$f"
    _put() { printf "$2" | dd of="$f" bs=1 seek="$1" conv=notrunc 2>/dev/null; }
    _pid() { [[ "$1" == uefi ]] && printf '\\xef' || printf '\\x00'; }
    _put $((16 * 2048)) '\x01CD001'
    [[ $# -gt 0 ]] || return 0
    _put $((17 * 2048)) '\x00CD001\x01EL TORITO SPECIFICATION'
    _put $((17 * 2048 + 0x47)) '\x13\x00\x00\x00'          # catalog at LBA 19
    local cat=$((19 * 2048)) off=64
    _put "$cat" "\x01$(_pid "$1")"; _put $((cat + 30)) '\x55\xaa'
    _put $((cat + 32)) '\x88'                                 # default entry
    shift
    while [[ $# -gt 0 ]]; do                                   # extra platforms
        _put $((cat + off)) "\x91$(_pid "$1")"; _put $((cat + off + 32)) '\x88'
        off=$((off + 64)); shift
    done
}
mk_iso "$WORK/plain.iso"                 # ISO 9660, no boot catalog
mk_iso "$WORK/bios.iso"   bios
mk_iso "$WORK/uefi.iso"   uefi
mk_iso "$WORK/both.iso"   bios uefi
mk_iso "$WORK/hybrid.iso" bios uefi
printf 'label: dos\nsize=64K, type=ef\n' | sfdisk -q "$WORK/hybrid.iso"   # isohybrid-like: ISO + MBR/ESP

run() {
    # run <expected-rc> <args...>; output captured in $OUT
    local want_rc="$1"; shift
    local rc=0
    OUT=$("$BIN" "$@" 2>&1) || rc=$?
    if [[ $rc -ne $want_rc ]]; then
        echo "$OUT" >&2
        fail "'usb-boot-test $*' exited $rc, expected $want_rc"
    fi
}
expect()     { grep -qF -- "$1" <<< "$OUT" || { echo "$OUT" >&2; fail "output lacks: $1"; }; }
expect_not() { grep -qF -- "$1" <<< "$OUT" && { echo "$OUT" >&2; fail "output must not contain: $1"; }; return 0; }

echo "→ --version / --help"
run 0 --version;  expect "USB Boot Tester v"
run 0 --help;     expect "--dry-run"

echo "→ dry-run BIOS, explicit hardware"
run 0 --dry-run --bios --ram 1024 --cores 1 --usb 2.0 --vga none "$WORK/gpt.img"
expect "# boot-mode: bios"
expect "qemu-system-x86_64"
expect "-m 1024"
expect "cores=1,"
expect "ich9-usb-ehci1"
expect "-display none"
expect "snapshot=on"
expect "format=raw"
expect "unix:"
expect_not "-nographic"
expect_not "pflash"
expect_not "-bios"
expect_not "4444"

echo "→ USB controller variants"
run 0 --dry-run --bios --usb 1.1 "$WORK/mbr.img"; expect "usb-storage,bus=uhci.0"
run 0 --dry-run --bios --usb 3.0 "$WORK/mbr.img"; expect "qemu-xhci"

echo "→ --no-snapshot"
run 0 --dry-run --bios --no-snapshot "$WORK/mbr.img"
expect "# snapshot:  false"
expect_not "snapshot=on"

echo "→ desktop defaults and USB tablet routing"
run 0 --dry-run --bios "$WORK/mbr.img"
expect "zoom-to-fit=on"
expect "full-screen=off"
expect "usb-tablet,bus=xhci.0"
run 0 --dry-run --bios --usb 2.0 "$WORK/mbr.img"
expect "usb-storage,bus=ehci.0"
expect "piix3-usb-uhci,id=tablet-usb"
expect "usb-tablet,bus=tablet-usb.0"
run 0 --dry-run --bios --usb 1.1 "$WORK/mbr.img"
expect "-device usb-tablet,bus=uhci.0"
expect_not "tablet-usb"

echo "→ display overrides and headless isolation"
run 0 --dry-run --bios --mouse relative --scale native --fullscreen "$WORK/mbr.img"
expect_not "usb-tablet"
expect "zoom-to-fit=off"
expect "full-screen=on"
run 0 --dry-run --bios --fullscreen --windowed "$WORK/mbr.img"
expect "full-screen=off"
run 0 --dry-run --bios --vga none --fullscreen --usb 2.0 "$WORK/mbr.img"
expect "-display none"
expect_not "usb-tablet"
expect_not "tablet-usb"
expect_not "gtk"

echo "→ Windows profile, explicit overrides and protection"
run 0 --dry-run --bios --profile windows "$WORK/mbr.img"
expect "-m 8192"
expect "cores=4,threads=1,sockets=1"
expect "-vga std"
expect "snapshot=on"
expect "usb-storage,bus=xhci.0"
expect "-nic none"
expect_not "audiodev"
run 0 --dry-run --bios --no-snapshot --profile windows --ram 4096 --cores 2 --vga none "$WORK/mbr.img"
expect "-m 4096"
expect "cores=2,"
expect "# snapshot:  false"
expect_not "gtk"
run 0 --dry-run --bios --profile windows --profile generic "$WORK/mbr.img"
expect "-m 2048"
expect "-vga virtio"

echo "→ boot-mode auto-detection"
run 0 --dry-run --auto --vga none "$WORK/gpt.img";    expect "# boot-mode: uefi"
run 0 --dry-run --auto --vga none "$WORK/mbr.img";    expect "# boot-mode: bios"
run 0 --dry-run --auto --vga none "$WORK/hybrid.img"; expect "# boot-mode: uefi"
run 0 --dry-run --auto --vga none "$WORK/empty.img";  expect "# boot-mode: uefi"
run 0 --dry-run --vga none "$WORK/mbr.img";           expect "# boot-mode: bios"   # auto is the default

echo "→ ISO 9660 images boot as a USB CD-ROM (El Torito), hybrid ISOs as a disk"
run 0 --dry-run --vga none "$WORK/plain.iso"
expect "# media:     cdrom (auto)"
expect "media=cdrom,readonly=on"
expect_not "snapshot=on"
expect "# boot-mode: uefi (auto: ISO 9660 without El Torito boot catalog"
run 0 --dry-run --vga none "$WORK/bios.iso";   expect "# boot-mode: bios (auto: ISO 9660, El Torito BIOS boot entry only)"
run 0 --dry-run --vga none "$WORK/uefi.iso";   expect "# boot-mode: uefi (auto: ISO 9660, El Torito UEFI boot entry only)"
run 0 --dry-run --vga none "$WORK/both.iso";   expect "# boot-mode: uefi (auto: ISO 9660, El Torito UEFI+BIOS boot entries)"
run 0 --dry-run --vga none "$WORK/hybrid.iso"
expect "# media:     disk (auto)"
expect "# boot-mode: uefi (auto: EFI System Partition found)"
expect "snapshot=on"
expect_not "media=cdrom"

echo "→ --media override"
run 0 --dry-run --bios --vga none --media disk "$WORK/plain.iso"
expect "# media:     disk"
expect "snapshot=on"
expect_not "media=cdrom"
run 0 --dry-run --bios --vga none --media cdrom "$WORK/mbr.img"
expect "# media:     cdrom"
expect "media=cdrom,readonly=on"
expect "# snapshot:  n/a"

echo "→ --net / --sound / --format"
run 0 --dry-run --bios --net --sound --format qcow2 "$WORK/mbr.img"
expect "netdev=net0"
expect "intel-hda"
expect "format=qcow2"

echo "→ error handling"
run 2 --dry-run "$WORK/does-not-exist.img"
run 2 --bogus-option
run 2 --dry-run --ram abc "$WORK/mbr.img"
run 2 --dry-run --usb 4.0 "$WORK/mbr.img"
run 2 --dry-run --media dvd "$WORK/mbr.img"
run 2 --profile linux
run 2 --profile
run 2 --mouse
run 2 --scale
run 2 --dry-run --mouse broken "$WORK/mbr.img"
run 2 --dry-run --scale broken "$WORK/mbr.img"
run 2 --dry-run "$WORK/mbr.img" "$WORK/gpt.img"
run 2 --dry-run   # target required

echo "usb-boot-test functional test: PASS"

# The TUI/configuration regressions use the repository modules and temp files.
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bash "$TEST_DIR/ui-test.sh"
