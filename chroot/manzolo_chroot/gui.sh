setup_gui_support() {
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        log "Setting up graphical support (X11) - EXPERIMENTAL"
        warning "GUI support is experimental and may cause host system instability"

        if ! ensure_chroot_user; then
            error "Failed to ensure chroot user setup, GUI support may fail"
            ENABLE_GUI_SUPPORT=false
            return 1
        fi

        if [[ -n "${DISPLAY:-}" ]]; then
            log "Configuring X11 display access (using shared /tmp/.X11-unix)"
            
            # Ensure /tmp/.X11-unix has correct permissions
            if [[ -d "/tmp/.X11-unix" ]]; then
                run_with_privileges chmod 1777 "/tmp/.X11-unix" || \
                    warning "Failed to set permissions on /tmp/.X11-unix"
                debug "Permissions on /tmp/.X11-unix: $(ls -ld /tmp/.X11-unix)"
            else
                warning "/tmp/.X11-unix does not exist on host"
            fi
            
            # Copy Xauthority to appropriate user's home in chroot
            local chroot_user="${CHROOT_USER:-root}"
            local xauthority_path="/home/$ORIGINAL_USER/.Xauthority"
            local chroot_xauth_path
            if [[ "$chroot_user" == "root" ]]; then
                chroot_xauth_path="$ROOT_MOUNT/root/.Xauthority"
            else
                chroot_xauth_path="$ROOT_MOUNT/home/$chroot_user/.Xauthority"
            fi
            if [[ -f "$xauthority_path" ]]; then
                log "Copying Xauthority file to $chroot_xauth_path"
                run_with_privileges cp "$xauthority_path" "$chroot_xauth_path" && \
                run_with_privileges chown "$chroot_user:$chroot_user" "$chroot_xauth_path" && \
                run_with_privileges chmod 600 "$chroot_xauth_path" || \
                    warning "Failed to setup X11 authentication for $chroot_user"
                debug "Xauthority in chroot: $(ls -l $chroot_xauth_path 2>/dev/null || echo 'not found')"
            else
                warning "Xauthority file not found at $xauthority_path - X11 authentication may fail"
            fi

            # Allow local connections for the chroot user
            if command -v xhost &> /dev/null; then
                log "Configuring xhost for local access"
                xhost +local: || warning "Failed to configure xhost"
                debug "xhost settings: $(xhost)"
            else
                warning "xhost not found, X11 authentication may fail"
            fi
        else
            warning "DISPLAY not set, X11 support will not work"
            ENABLE_GUI_SUPPORT=false
            return 1
        fi

        # Temporarily disable Wayland support to isolate X11 issues
        # if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        #     log "Configuring Wayland display access (using shared /run/user)"
        #     local original_uid=$(id -u "$ORIGINAL_USER")
        #     run_with_privileges mkdir -p "$ROOT_MOUNT/run/user/$original_uid" || \
        #         warning "Failed to ensure Wayland runtime dir in chroot"
        #     run_with_privileges chmod 700 "$ROOT_MOUNT/run/user/$original_uid" || \
        #         warning "Failed to set permissions on Wayland runtime dir"
        #     run_with_privileges chown "$original_uid:$original_uid" "$ROOT_MOUNT/run/user/$original_uid" || \
        #         warning "Failed to set ownership on Wayland runtime dir"
        #     debug "Permissions on /run/user/$original_uid: $(ls -ld $ROOT_MOUNT/run/user/$original_uid)"
        # fi

        # Ensure /dev/pts permissions
        run_with_privileges chmod 1777 "$ROOT_MOUNT/dev/pts" || \
            warning "Failed to set permissions on /dev/pts in chroot"
        debug "Permissions on /dev/pts: $(ls -ld $ROOT_MOUNT/dev/pts)"

        log "Graphical support setup complete (experimental mode)"
        warning "Monitor your host system for stability issues"
    fi
}