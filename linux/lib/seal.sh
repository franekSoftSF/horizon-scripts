# shellcheck shell=bash
# Mode "seal": last step before the golden-image snapshot. Mode "unlock" reverses it.
# Only reversible changes are tracked in seal-state.json; cleanups (logs, caches)
# are one-way by nature.

SSH_KEYS_DROPIN="/etc/systemd/system/ssh.service.d/50-vdi-imagemaint-hostkeys.conf"
SEAL_APT_GUARD="/etc/apt/apt.conf.d/99vdi-imagemaint-sealed"
SEAL_DPKG_GUARD="/etc/dpkg/dpkg.cfg.d/99vdi-imagemaint-sealed"
SEAL_POLKIT_RULES="/etc/polkit-1/rules.d/50-vdi-imagemaint-sealed.rules"
SEAL_POLKIT_POWER="/etc/polkit-1/rules.d/40-vdi-imagemaint-sealed-power.rules"
SEAL_DCONF="/etc/dconf/db/local.d/60-vdi-imagemaint-sealed"

mode_seal() {
    logt STEP step_seal
    if ! mode_check; then
        if [[ ${FORCE:-0} == 1 ]]; then
            logt WARN seal_forced
        else
            logt ERR seal_blocked
            exit 1
        fi
    fi

    local u
    for u in $SEAL_DISABLE_UNITS; do unit_off seal "$u" disable; done
    for u in $SEAL_MASK_UNITS; do unit_off seal "$u" mask; done

    seal_ssh_keys
    seal_cleanup
    [[ $SEAL_QUIET_USERS == yes ]] && seal_quiet_users
    # Last: from here on apt/dpkg refuse to change packages until unlock.
    [[ $SEAL_BLOCK_PACKAGES == yes ]] && seal_block_packages
    state_update seal '.sealed = true | .sealedAt = $d | .version = $v | .kernel = $k | .profile = $p' \
        --arg d "$(date -Is)" --arg v "$VDI_VERSION" --arg k "$(uname -r)" --arg p "$PROFILE"
    logt OK seal_done

    case $SEAL_POWEROFF in
        yes) run systemctl poweroff ;;
        ask) confirm "$(t ask_poweroff)" && run systemctl poweroff ;;
    esac
    return 0
}

seal_ssh_keys() {
    [[ $SEAL_RESET_SSH_KEYS == yes ]] || return 0
    unit_known ssh.service || return 0
    # sshd -t fails without host keys; generate them first if a clone ever boots without RunOnce.
    write_file seal "$SSH_KEYS_DROPIN" 0644 <<'EOF'
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
EOF
    run systemctl daemon-reload
    rm -f /etc/ssh/ssh_host_*
    logt OK seal_ssh_keys_removed
}

seal_cleanup() {
    logt INFO seal_cleaning
    apt_get clean
    # Kerberos tickets of whoever tested the master.
    kdestroy -A 2>/dev/null || true
    rm -f /tmp/krb5cc_* 2>/dev/null || true
    # The SSSD cache (/var/lib/sss) is deliberately NOT touched. Wiping it (until 0.5.1)
    # broke logons on a golden image: after the restart SSSD had no cached users and no
    # cached credentials, and when it could not reach a DC yet (clock not synced, slow
    # network) nobody could log on. SSSD refreshes its cache by itself.
    # DHCP leases: each clone must ask for its own.
    rm -f /var/lib/dhcp/*.leases /var/lib/NetworkManager/*.lease 2>/dev/null || true
    # Logs (our own log directory is kept for the audit trail).
    # Journal files are handled by journalctl, never truncated underneath journald.
    find /var/log \( -path "$LOG_DIR" -o -path /var/log/journal \) -prune -o -type f \
        \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -print0 | xargs -0r rm -f
    find /var/log \( -path "$LOG_DIR" -o -path /var/log/journal \) -prune -o -type f -print0 |
        xargs -0r truncate -s 0
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=1s >/dev/null 2>&1 || true
    # Temp files and shell history of local accounts (AD homes live on NFS).
    find /var/tmp -mindepth 1 -delete 2>/dev/null || true
    rm -f /root/.bash_history
    find /home -maxdepth 2 -name .bash_history -type f -delete 2>/dev/null || true
    logt OK seal_cleaned
}

# Package changes are refused for everybody, root included, until "unlock" (or "update",
# which unlocks first). dpkg pre-invoke covers apt, PackageKit and a manual "dpkg -i".
seal_block_packages() {
    local msg
    msg=$(t seal_guard_msg | tr -d "\"'")
    write_file seal "$SEAL_DPKG_GUARD" 0644 <<EOF
${MANAGED_MARK}
pre-invoke=echo "${msg}" >&2; exit 1
EOF
    write_file seal "$SEAL_APT_GUARD" 0644 <<EOF
// ${MANAGED_MARK#\# }
APT::Update::Pre-Invoke { "echo '${msg}' >&2; exit 1"; };
EOF
    logt OK seal_packages_blocked
}

# Desktop users never see package, colord or system-error pop-ups on a clone:
# PackageKit/apt actions are denied silently (no password prompt), colord is allowed,
# MATE housekeeping and network notifications are switched off.
seal_quiet_users() {
    if [[ -d /etc/polkit-1/rules.d ]]; then
        write_file seal "$SEAL_POLKIT_RULES" 0644 <<'EOF'
// Managed by VDI-ImageMaint (sealed image) - removed by "vdi-imagemaint.sh unlock".
polkit.addRule(function (action, subject) {
    if (subject.user == "root") {
        return polkit.Result.NOT_HANDLED;
    }
    if (action.id.indexOf("org.freedesktop.packagekit.") == 0 ||
        action.id.indexOf("org.debian.apt.") == 0) {
        return polkit.Result.NO;
    }
    if (action.id.indexOf("org.freedesktop.color-manager.") == 0) {
        return polkit.Result.YES;
    }
    return polkit.Result.NOT_HANDLED;
});
EOF
        # Instant clones are never shut down, rebooted or suspended by users - logoff
        # discards them. Without these rights MATE hides the buttons (it asks logind
        # CanPowerOff/CanReboot/CanSuspend) and GDM's login screen too (Debian-gdm is not
        # in "sudo"). Build admins in the sudo group keep them.
        if [[ $SEAL_HIDE_POWER == yes ]]; then
            write_file seal "$SEAL_POLKIT_POWER" 0644 <<'EOF'
// Managed by VDI-ImageMaint (sealed image) - removed by "vdi-imagemaint.sh unlock".
polkit.addRule(function (action, subject) {
    if (subject.user == "root" || subject.isInGroup("sudo")) {
        return polkit.Result.NOT_HANDLED;
    }
    if (/^org\.freedesktop\.login1\.(power-off|reboot|halt|suspend|hibernate|hybrid-sleep|suspend-then-hibernate)/.test(action.id)) {
        return polkit.Result.NO;
    }
    return polkit.Result.NOT_HANDLED;
});
EOF
        fi
    fi
    write_file seal "$SEAL_DCONF" 0644 <<EOF
${MANAGED_MARK}
[org/mate/settings-daemon/plugins/housekeeping]
active=false

[org/gnome/nm-applet]
disable-connected-notifications=true
disable-disconnected-notifications=true
disable-vpn-notifications=true
suppress-wireless-networks-available=true
EOF
    command -v dconf >/dev/null 2>&1 && run dconf update
    # No crash dumps (and no crash dialogs) on clones.
    write_file seal /etc/systemd/coredump.conf.d/50-vdi-imagemaint.conf 0644 <<EOF
${MANAGED_MARK}
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
    logt OK seal_users_quiet
}

mode_unlock() {
    logt STEP step_unlock
    if ! is_sealed; then
        logt INFO unlock_not_sealed
    fi
    units_restore seal
    files_restore seal
    run systemctl daemon-reload
    if command -v dconf >/dev/null 2>&1; then
        run dconf update
    fi
    if unit_known ssh.service && ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
        run ssh-keygen -A
        run systemctl restart ssh.service || true
    fi
    state_update seal '.sealed = false | .unlockedAt = $d' --arg d "$(date -Is)"
    logt OK unlock_done
}
