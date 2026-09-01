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
run 0 --dry-run --bios --usb 1.1 "$WORK/mbr.img"; expect " -usb "
run 0 --dry-run --bios --usb 3.0 "$WORK/mbr.img"; expect "qemu-xhci"

echo "→ --no-snapshot"
run 0 --dry-run --bios --no-snapshot "$WORK/mbr.img"
expect "# snapshot:  false"
expect_not "snapshot=on"

echo "→ boot-mode auto-detection"
run 0 --dry-run --auto --vga none "$WORK/gpt.img";    expect "# boot-mode: uefi"
run 0 --dry-run --auto --vga none "$WORK/mbr.img";    expect "# boot-mode: bios"
run 0 --dry-run --auto --vga none "$WORK/hybrid.img"; expect "# boot-mode: uefi"
run 0 --dry-run --auto --vga none "$WORK/empty.img";  expect "# boot-mode: uefi"
run 0 --dry-run --vga none "$WORK/mbr.img";           expect "# boot-mode: bios"   # auto is the default

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
run 2 --dry-run "$WORK/mbr.img" "$WORK/gpt.img"
run 2 --dry-run   # target required

echo "usb-boot-test functional test: PASS"
