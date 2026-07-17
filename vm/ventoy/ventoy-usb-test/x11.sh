# X11 forwarding helpers — when the script is invoked via sudo, root has no
# DISPLAY/XAUTHORITY of its own, so QEMU's GTK backend fails with
# "Authorization required, but no authorization protocol specified".
# We inherit the invoking user's X credentials and grant local root access.

# shellcheck disable=SC2034  # used by revoke_x11_for_root and confirm_and_run
X11_ROOT_GRANTED=false

setup_x11_for_root() {
    # Only relevant when running as root under sudo with a graphical session.
    [[ "$EUID" -eq 0 ]] || return 0
    [[ -n "${SUDO_USER:-}" ]] || return 0

    local user_home
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [[ -n "$user_home" ]] || return 0

    # Inherit DISPLAY from invoking user if not already set.
    if [[ -z "${DISPLAY:-}" ]]; then
        local user_display
        user_display=$(sudo -u "$SUDO_USER" sh -c 'printf %s "${DISPLAY:-}"' 2>/dev/null || true)
        [[ -n "$user_display" ]] && export DISPLAY="$user_display"
    fi
    [[ -n "${DISPLAY:-}" ]] || return 0

    # Inherit XAUTHORITY: prefer the invoking user's env var, fall back to
    # ~/.Xauthority. Required for GTK to authenticate against the X server.
    if [[ -z "${XAUTHORITY:-}" ]] || [[ ! -r "${XAUTHORITY:-}" ]]; then
        local user_xauth
        user_xauth=$(sudo -u "$SUDO_USER" sh -c 'printf %s "${XAUTHORITY:-}"' 2>/dev/null || true)
        if [[ -n "$user_xauth" ]] && [[ -r "$user_xauth" ]]; then
            export XAUTHORITY="$user_xauth"
        elif [[ -r "$user_home/.Xauthority" ]]; then
            export XAUTHORITY="$user_home/.Xauthority"
        fi
    fi

    # Grant local root access to the X server. Safe: only same-host root,
    # not network clients. Revoked on exit via revoke_x11_for_root.
    if command -v xhost >/dev/null 2>&1; then
        if sudo -u "$SUDO_USER" \
                DISPLAY="$DISPLAY" \
                XAUTHORITY="${XAUTHORITY:-}" \
                xhost +SI:localuser:root >/dev/null 2>&1; then
            X11_ROOT_GRANTED=true
            log_info "X11 access granted to root (DISPLAY=$DISPLAY)"
        else
            log_warn "Failed to grant X11 access to root; GTK display may fail"
        fi
    fi
}

revoke_x11_for_root() {
    [[ "${X11_ROOT_GRANTED:-false}" == "true" ]] || return 0
    [[ -n "${SUDO_USER:-}" ]] || return 0
    sudo -u "$SUDO_USER" \
        DISPLAY="${DISPLAY:-}" \
        XAUTHORITY="${XAUTHORITY:-}" \
        xhost -SI:localuser:root >/dev/null 2>&1 || true
    X11_ROOT_GRANTED=false
}
