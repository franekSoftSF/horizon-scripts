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
    local idmap=${NFS_IDMAP_DOMAIN:-$AD_DOMAIN}

    apt_install nfs-common autofs

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

    write_file build /etc/auto.master.d/vdi-home.autofs 0644 <<EOF
${MANAGED_MARK}
${HOME_ROOT} /etc/auto.vdi-home --timeout=${NFS_AUTOFS_TIMEOUT} --ghost
EOF
    # "&" = the looked-up key (user name): HOME_ROOT/jan -> server:/export/home/jan
    write_file build /etc/auto.vdi-home 0644 <<EOF
${MANAGED_MARK}
* -fstype=nfs,vers=${NFS_VERS},sec=${NFS_SEC},${NFS_OPTIONS} ${NFS_SERVER}:${NFS_EXPORT}/&
EOF

    # conf.d snippet, so NFS homes keep working even if sssd.conf is regenerated
    # (e.g. by realm or the agent): home under the autofs map, FILE ticket cache for rpc.gssd.
    write_file build "$NFS_SSSD_SNIPPET" 0600 <<EOF
${MANAGED_MARK}
[domain/${AD_DOMAIN}]
override_homedir = ${HOME_ROOT}/%u
krb5_ccname_template = FILE:/tmp/krb5cc_%U
EOF
    if systemctl is-active --quiet sssd.service; then
        run systemctl restart sssd.service
    fi

    install -d -m 0755 "$HOME_ROOT"
    run systemctl enable nfs-client.target autofs.service
    run systemctl restart nfs-client.target || true
    run systemctl restart autofs.service
    [[ -s /etc/krb5.keytab ]] || logt WARN nfs_no_keytab
    nfs_check_server
    logt OK nfs_done "${NFS_SERVER}:${NFS_EXPORT}" "$HOME_ROOT" "$NFS_SEC"
}

nfs_check_server() {
    if getent hosts "$NFS_SERVER" >/dev/null; then
        logt OK nfs_server_resolves "$NFS_SERVER"
    else
        logt WARN nfs_server_unresolved "$NFS_SERVER"
    fi
}
