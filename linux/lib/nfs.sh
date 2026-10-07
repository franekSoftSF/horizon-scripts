# shellcheck shell=bash
# Mode "nfs": NFSv4 home directories with Kerberos (autofs, rpc.gssd, idmapd).
# Mount happens as the user: pam_sss puts the TGT in FILE:/tmp/krb5cc_<uid>,
# rpc.gssd picks it up (with True SSO / smart card the TGT comes from PKINIT). The
# machine keytab comes from the Horizon offline domain join on every clone.
# The credential cache must stay a FILE in /tmp - rpc.gssd does not read KCM caches.

NFS_SSSD_SNIPPET="/etc/sssd/conf.d/50-vdi-imagemaint-nfs.conf"

mode_nfs() {
    logt STEP step_nfs
    if [[ $NFS_ENABLE != yes ]]; then
        logt INFO nfs_disabled
        return 0
    fi
    require_conf NFS_SERVER NFS_EXPORT AD_DOMAIN
    if [[ $NFS_MODE == fstab ]]; then
        apt_install nfs-common
    else
        apt_install nfs-common autofs
    fi
    nfs_write_files
    if systemctl is-active --quiet sssd.service; then
        run systemctl restart sssd.service
    fi

    install -d -m 0755 "$(nfs_mountpoint)"
    run systemctl enable nfs-client.target
    run systemctl restart nfs-client.target || true
    if [[ $NFS_MODE == fstab ]]; then
        run systemctl daemon-reload
        # mount-on-first-access unit generated from fstab
        run systemctl restart remote-fs.target || true
    else
        run systemctl enable autofs.service
        run systemctl restart autofs.service
    fi
    [[ -s /etc/krb5.keytab ]] || logt WARN nfs_no_keytab
    nfs_check_server
    logt OK nfs_done "${NFS_SERVER}:${NFS_EXPORT}" "$(nfs_mountpoint)" "$NFS_SEC"
}

# All files of the NFS step (also used by "adopt" in preview mode).
nfs_mountpoint() {
    if [[ $NFS_MODE == fstab ]]; then
        printf '%s' "${NFS_MOUNTPOINT:-$HOME_ROOT}"
    else
        printf '%s' "$HOME_ROOT"
    fi
}

# fstab mode: one line for the share, replaced in place (matched by mount point) or appended;
# mounted on first access because a sec=krb5 mount during boot is not reliable.
nfs_write_fstab() {
    local mp line tmp
    mp=$(nfs_mountpoint)
    line="${NFS_SERVER}:${NFS_EXPORT} ${mp} nfs4 vers=${NFS_VERS},sec=${NFS_SEC},${NFS_OPTIONS},_netdev,x-systemd.automount,x-systemd.mount-timeout=30 0 0"
    tmp=$(mktemp)
    awk -v mp="$mp" -v line="$line" '
        $1 !~ /^#/ && $2 == mp && ($3 == "nfs" || $3 == "nfs4") { if (!done) print line; done = 1; next }
        { print }
        END { if (!done) print line }
    ' /etc/fstab >"$tmp"
    write_file build /etc/fstab 0644 <"$tmp"
    rm -f "$tmp"
}

nfs_write_files() {
    local idmap=${NFS_IDMAP_DOMAIN:-$AD_DOMAIN}
    write_file build /etc/idmapd.conf 0644 <<EOF
${MANAGED_MARK}
[General]
Verbosity = 0
Domain = ${idmap}

[Mapping]
Nobody-User = nobody
Nobody-Group = nogroup
EOF

    write_file build /etc/default/nfs-common 0644 <<EOF
${MANAGED_MARK}
NEED_STATD=
NEED_IDMAPD=yes
NEED_GSSD=yes
EOF

    if [[ $NFS_MODE == fstab ]]; then
        nfs_write_fstab
    else
        write_file build /etc/auto.master.d/vdi-home.autofs 0644 <<EOF
${MANAGED_MARK}
${HOME_ROOT} /etc/auto.vdi-home --timeout=${NFS_AUTOFS_TIMEOUT} --ghost
EOF
        # "&" = the looked-up key (user name): HOME_ROOT/jan -> server:/export/home/jan
        write_file build /etc/auto.vdi-home 0644 <<EOF
${MANAGED_MARK}
* -fstype=nfs,vers=${NFS_VERS},sec=${NFS_SEC},${NFS_OPTIONS} ${NFS_SERVER}:${NFS_EXPORT}/&
EOF
    fi

    # conf.d snippet, so NFS homes keep working even if sssd.conf is regenerated
    # (e.g. by realm or the agent): home under the autofs map, FILE ticket cache for rpc.gssd.
    write_file build "$NFS_SSSD_SNIPPET" 0600 <<EOF
${MANAGED_MARK}
[domain/${AD_DOMAIN}]
override_homedir = ${HOME_ROOT}/%u
krb5_ccname_template = FILE:/tmp/krb5cc_%U
EOF
}

nfs_check_server() {
    if getent hosts "$NFS_SERVER" >/dev/null; then
        logt OK nfs_server_resolves "$NFS_SERVER"
    else
        logt WARN nfs_server_unresolved "$NFS_SERVER"
    fi
}
