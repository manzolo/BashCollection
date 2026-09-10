#!/usr/bin/env bash
# Configuration and TUI actions without root, a display or a real target.
set -euo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK" XDG_CONFIG_HOME="$WORK/config"
unset SUDO_USER
# shellcheck source=../../vm/ventoy/ventoy-usb-test.sh
source "$TEST_DIR/../../vm/ventoy/ventoy-usb-test.sh"
mkdir -p "$RUN_DIR"
fail() { echo "ASSERTION FAILED: $*" >&2; exit 1; }
log_info() { :; }
log_warn() { :; }

echo "→ profiles preserve target, boot mode and protection"
: > "$WORK/target.img"
DISK="$WORK/target.img" BIOS_MODE=bios SNAPSHOT=true NETWORK=true SOUND=true
apply_hardware_profile windows
[[ "$MEMORY/$VGA_MODE/$MOUSE_MODE/$DISPLAY_SCALE" == 8192/std/tablet/fit ]] || fail 'Windows defaults'
[[ "$DISK/$BIOS_MODE/$SNAPSHOT/$NETWORK/$SOUND" == "$WORK/target.img/bios/true/true/true" ]] || fail 'profile changed target or protection'
SNAPSHOT=false
apply_hardware_profile generic
[[ "$MEMORY/$VGA_MODE/$SNAPSHOT" == 2048/virtio/false ]] || fail 'Generic defaults or explicit write choice'

echo "→ new settings round-trip and legacy configuration compatibility"
MOUSE_MODE=relative DISPLAY_SCALE=native FULLSCREEN=true
save_config
reset_to_defaults
load_config
[[ "$MOUSE_MODE/$DISPLAY_SCALE/$FULLSCREEN" == relative/native/true ]] || fail 'settings round-trip'
printf 'MEMORY="4096"\nVGA_MODE="std"\n' > "$CONFIG_FILE"
reset_to_defaults
load_config
[[ "$MEMORY/$MOUSE_MODE/$DISPLAY_SCALE/$FULLSCREEN" == 4096/tablet/fit/false ]] || fail 'legacy config defaults'
printf 'MOUSE_MODE="broken"\nDISPLAY_SCALE="broken"\nFULLSCREEN="broken"\n' > "$CONFIG_FILE"
load_config
[[ "$MOUSE_MODE/$DISPLAY_SCALE/$FULLSCREEN" == tablet/fit/false ]] || fail 'invalid config accepted'

echo "→ cancelling profile and display dialogs preserves settings"
whiptail() { return 1; }
MEMORY=4096 MOUSE_MODE=relative DISPLAY_SCALE=native
profile_menu
display_menu
[[ "$MEMORY/$MOUSE_MODE/$DISPLAY_SCALE" == 4096/relative/native ]] || fail 'cancel changed settings'

echo "→ command preview matches TUI CPU topology without changing state"
DISK="$WORK/target.img" BIOS_MODE=bios THREADS=2 SOCKETS=2
SNAPSHOT=true FULLSCREEN=true
whiptail() {
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --textbox ]]; then
            cp "$2" "$WORK/preview.txt"
            return 0
        fi
        shift
    done
    return 1
}
preview_command
grep -qF 'cores=4,threads=2,sockets=2' "$WORK/preview.txt" || fail 'preview CPU topology'
grep -qF 'snapshot=on' "$WORK/preview.txt" || fail 'preview snapshot'
grep -qF 'zoom-to-fit=off,full-screen=on' "$WORK/preview.txt" || fail 'preview display'
[[ "$DISK/$BIOS_MODE/$THREADS/$SOCKETS" == "$WORK/target.img/bios/2/2" ]] || fail 'preview changed state'
[[ -z "$(find "$RUN_DIR" -name 'preview.*' -print -quit)" ]] || fail 'preview temporary file leaked'

echo "→ dashboard sizes follow terminal dimensions"
tput() { [[ "$1" == lines ]] && echo 24 || echo 80; }
ui_dimensions
[[ "$UI_HEIGHT/$UI_WIDTH/$UI_LIST_HEIGHT" == 22/76/11 ]] || fail '80x24 dashboard'
tput() { [[ "$1" == lines ]] && echo 50 || echo 160; }
ui_dimensions
[[ "$UI_HEIGHT/$UI_WIDTH/$UI_LIST_HEIGHT" == 28/100/11 ]] || fail 'large dashboard'
echo "usb-boot-test configuration/TUI test: PASS"
