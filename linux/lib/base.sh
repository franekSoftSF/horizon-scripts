# shellcheck shell=bash
# Mode "prepare": base OS for a Horizon Linux desktop - packages, MATE session + GDM,
# locale, keyboard, time zone, time sync, VMware Tools. Build step, run once.

mode_prepare() {
    logt STEP step_prepare
    os_check || confirm "$(t ask_continue_unsupported)" || exit 1

    apt_get update
    apt_get full-upgrade
    # shellcheck disable=SC2086  # package lists are word-split on purpose
    apt_install $BASE_PACKAGES

    prepare_locale
    prepare_time
    prepare_desktop
    [[ $INSTALL_EDGE == yes ]] && prepare_edge
    if [[ -n $EXTRA_PACKAGES ]]; then
        # shellcheck disable=SC2086
        apt_install $EXTRA_PACKAGES
    fi

    run systemctl enable --now open-vm-tools.service || true
    logt OK prepare_done
    reboot_pending && logt WARN reboot_needed
    return 0
}

prepare_locale() {
    local loc
    logt INFO locale_set "$LOCALES" "$DEFAULT_LOCALE" "$KEYBOARD_LAYOUT"
    file_track build /etc/locale.gen
    for loc in $LOCALES; do
        # uncomment "# pl_PL.UTF-8 UTF-8" style lines, append when missing
        if grep -Eq "^#?[[:space:]]*${loc//./\\.}[[:space:]]" /etc/locale.gen; then
            sed -i -E "s/^#?[[:space:]]*(${loc//./\\.}[[:space:]].*)/\1/" /etc/locale.gen
        else
            printf '%s %s\n' "$loc" "${loc##*.}" >>/etc/locale.gen
        fi
    done
    run locale-gen
    run update-locale "LANG=${DEFAULT_LOCALE}"

    KV_SECTION=build set_kv /etc/default/keyboard XKBLAYOUT "\"${KEYBOARD_LAYOUT}\""
    run setupcon --save-only 2>/dev/null || true
}

prepare_time() {
    local ntp=${NTP_SERVERS:-$AD_DOMAIN}
    logt INFO time_set "$TIMEZONE" "$ntp"
    run timedatectl set-timezone "$TIMEZONE"
    # Guest time comes from AD (Kerberos), not from the ESXi host.
    if command -v vmware-toolbox-cmd >/dev/null 2>&1; then
        run vmware-toolbox-cmd timesync disable || true
    fi
    pkg_installed systemd-timesyncd || apt_install systemd-timesyncd
    write_file build /etc/systemd/timesyncd.conf.d/50-vdi-imagemaint.conf 0644 <<EOF
${MANAGED_MARK}
[Time]
NTP=${ntp}
EOF
    run systemctl enable systemd-timesyncd.service
    run systemctl restart systemd-timesyncd.service
    run timedatectl set-ntp true
}

prepare_desktop() {
    logt INFO desktop_install "$DESKTOP_PACKAGES"
    # GDM stays the display manager: Horizon SSO logs on through the gdm-hzncred PAM
    # service and starts the MATE session (SSODesktopType=UseMATE in viewagent-custom.conf).
    echo "gdm3 shared/default-x-display-manager select gdm3" | debconf-set-selections
    # shellcheck disable=SC2086
    apt_install $DESKTOP_PACKAGES
    printf '/usr/sbin/gdm3\n' >/etc/X11/default-display-manager
    DEBIAN_FRONTEND=noninteractive run dpkg-reconfigure gdm3 || true
    run systemctl set-default graphical.target
}

prepare_edge() {
    local key=/usr/share/keyrings/microsoft.gpg
    logt INFO edge_install
    if [[ ! -s $key ]]; then
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o "$key"
        chmod 0644 "$key"
    fi
    write_file build /etc/apt/sources.list.d/microsoft-edge.list 0644 <<EOF
deb [arch=amd64 signed-by=${key}] https://packages.microsoft.com/repos/edge stable main
EOF
    apt_get update
    apt_install microsoft-edge-stable
}
