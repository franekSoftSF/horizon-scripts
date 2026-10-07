# shellcheck shell=bash
# Mode "optimize": VDI tuning for a MATE desktop on Instant Clone.
# Every change is recorded in optimize-state.json; "optimize --revert" undoes it.

mode_optimize() {
    if [[ ${REVERT:-0} == 1 ]]; then
        optimize_revert
        return 0
    fi
    logt STEP step_optimize
    local u
    for u in $OPTIMIZE_DISABLE_UNITS; do unit_off optimize "$u" disable; done
    for u in $OPTIMIZE_MASK_UNITS; do unit_off optimize "$u" mask; done

    optimize_dconf
    optimize_lightdm
    optimize_autostart
    optimize_system
    optimize_polkit
    logt OK optimize_done
}

# System-wide MATE defaults via a dconf system database; performance keys are locked.
optimize_dconf() {
    local lock_enabled=false idle=0
    if ((SCREEN_LOCK_MINUTES > 0)); then
        lock_enabled=true
        idle=$SCREEN_LOCK_MINUTES
    fi
    write_file optimize /etc/dconf/profile/user 0644 <<'EOF'
user-db:user
system-db:local
EOF
    write_file optimize /etc/dconf/db/local.d/50-vdi-imagemaint 0644 <<EOF
${MANAGED_MARK}
# No compositing / animations: less CPU and less Blast encoding work.
[org/mate/marco/general]
compositing-manager=false
reduced-resources=true

[org/mate/desktop/interface]
enable-animations=false

# Solid background compresses best over Blast.
[org/mate/desktop/background]
picture-filename=''
color-shading-type='solid'
primary-color='${BACKGROUND_COLOR}'

# A VM must never suspend; screen power is the client's business.
[org/mate/power-manager]
sleep-computer-ac=0
sleep-display-ac=0
idle-dim-ac=false
button-power='nothing'

[org/mate/screensaver]
idle-activation-enabled=${lock_enabled}
lock-enabled=${lock_enabled}
mode='blank-only'

[org/mate/desktop/session]
idle-delay=${idle}

[org/mate/desktop/media-handling]
automount=false
automount-open=false

# Caja on NFS homes: no thumbnails, previews or item counts (each one is NFS I/O).
[org/mate/caja/preferences]
show-image-thumbnails='never'
preview-sound='never'
show-directory-item-counts='never'
executable-text-activation='display'

# No event sounds: less audio traffic over Blast.
[org/mate/desktop/sound]
event-sounds=false
input-feedback-sounds=false
EOF
    write_file optimize /etc/dconf/db/local.d/locks/50-vdi-imagemaint 0644 <<'EOF'
/org/mate/marco/general/compositing-manager
/org/mate/power-manager/sleep-computer-ac
/org/mate/power-manager/button-power
EOF
    run dconf update
}

optimize_lightdm() {
    # Only when LightDM is used (Horizon SSO images use GDM).
    [[ $(basename "$(cat /etc/X11/default-display-manager 2>/dev/null || echo none)") == lightdm ]] || return 0
    write_file optimize /etc/lightdm/lightdm.conf.d/50-vdi-imagemaint.conf 0644 <<EOF
${MANAGED_MARK}
[Seat:*]
user-session=mate
greeter-hide-users=true
greeter-show-manual-login=true
allow-guest=false
EOF
}

# Hidden=true in an /etc/xdg/autostart entry = treated as deleted for all users.
optimize_autostart() {
    local name f
    for name in $OPTIMIZE_AUTOSTART_DISABLE; do
        f="/etc/xdg/autostart/${name}.desktop"
        [[ -f $f ]] || continue
        grep -q '^Hidden=true' "$f" && continue
        file_track optimize "$f"
        printf 'Hidden=true\n' >>"$f"
        logt OK autostart_disabled "$name"
    done
}

optimize_system() {
    write_file optimize /etc/sysctl.d/90-vdi-imagemaint.conf 0644 <<EOF
${MANAGED_MARK}
vm.swappiness = ${OPTIMIZE_SWAPPINESS}
# keep directory/inode caches longer (NFS homes), flush dirty pages in smaller bursts
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
EOF
    run sysctl --system >/dev/null

    if [[ -n $OPTIMIZE_IO_SCHEDULER ]]; then
        write_file optimize /etc/udev/rules.d/60-vdi-imagemaint-iosched.rules 0644 <<EOF
${MANAGED_MARK}
ACTION=="add|change", KERNEL=="sd[a-z]*|nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="${OPTIMIZE_IO_SCHEDULER}"
EOF
        run udevadm control --reload-rules || true
        run udevadm trigger --subsystem-match=block --action=change || true
    fi

    if [[ $OPTIMIZE_TMPFS_TMP == yes && -f /usr/share/systemd/tmp.mount ]]; then
        file_track optimize /etc/systemd/system/tmp.mount
        cp /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount
        run systemctl daemon-reload
        run systemctl enable tmp.mount
        logt INFO tmpfs_next_boot
    fi

    if [[ $OPTIMIZE_JOURNAL_VOLATILE == yes ]]; then
        # Clone disks are discarded at logoff anyway; keep the journal in RAM.
        write_file optimize /etc/systemd/journald.conf.d/50-vdi-imagemaint.conf 0644 <<EOF
${MANAGED_MARK}
[Journal]
Storage=volatile
RuntimeMaxUse=64M
EOF
        run systemctl restart systemd-journald.service
    fi

    if [[ -d /etc/default/grub.d ]] || [[ -f /etc/default/grub ]]; then
        write_file optimize /etc/default/grub.d/90-vdi-imagemaint.cfg 0644 <<EOF
${MANAGED_MARK}
GRUB_TIMEOUT=${OPTIMIZE_GRUB_TIMEOUT}
EOF
        if command -v update-grub >/dev/null 2>&1; then
            run update-grub
        fi
    fi
}

# Users must not shut down, reboot or suspend an instant clone; logoff refreshes it.
optimize_polkit() {
    [[ $OPTIMIZE_DENY_POWER == yes && -d /etc/polkit-1/rules.d ]] || return 0
    write_file optimize /etc/polkit-1/rules.d/50-vdi-imagemaint-power.rules 0644 <<'EOF'
// Managed by VDI-ImageMaint (optimize) - removed by "optimize --revert".
polkit.addRule(function (action, subject) {
    if (subject.user == "root" || subject.isInGroup("sudo")) {
        return polkit.Result.NOT_HANDLED;
    }
    if (/^org\.freedesktop\.login1\.(power-off|reboot|suspend|hibernate|halt)/.test(action.id)) {
        return polkit.Result.NO;
    }
    return polkit.Result.NOT_HANDLED;
});
EOF
}

optimize_revert() {
    logt STEP step_optimize_revert
    units_restore optimize
    files_restore optimize
    command -v dconf >/dev/null 2>&1 && run dconf update
    run sysctl --system >/dev/null
    run systemctl daemon-reload
    run udevadm control --reload-rules || true
    run systemctl restart systemd-journald.service
    command -v update-grub >/dev/null 2>&1 && run update-grub
    logt OK optimize_reverted
}
