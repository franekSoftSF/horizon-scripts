# shellcheck shell=bash
# Mode "nfsmount": NFS home shares from /etc/fstab are mounted on first access instead of
# during boot. On the VM a sec=krb5 mount from fstab sometimes failed at boot (network /
# DNS / rpc-gssd / machine Kerberos not ready yet) and was not retried - the home share was
# missing until a manual mount. With x-systemd.automount the mount happens when somebody
# first opens the directory, when all of that is ready.
#   adds to every nfs/nfs4 entry: _netdev,x-systemd.automount,x-systemd.mount-timeout=30
#   original fstab backed up (state section nfsmount); "nfsmount --revert" restores it.

NFSMOUNT_OPTS="_netdev x-systemd.automount x-systemd.mount-timeout=30"

# nfsmount_entries -> "mountpoint<TAB>options" of the nfs/nfs4 lines in fstab
nfsmount_entries() {
    awk '$1 !~ /^#/ && ($3 == "nfs" || $3 == "nfs4") {print $2 "\t" $4}' /etc/fstab 2>/dev/null || true
}

mode_nfsmount() {
    if [[ ${REVERT:-0} == 1 ]]; then
        logt STEP step_nfsmount_revert
        files_restore nfsmount
        run systemctl daemon-reload
        logt OK nfsmount_reverted
        logt WARN reboot_needed
        mark_reboot_required
        return 0
    fi
    logt STEP step_nfsmount
    if [[ -z $(nfsmount_entries) ]]; then
        logt INFO nfsmount_none
        return 0
    fi
    local tmp changed=0
    tmp=$(mktemp)
    # Rewrite only the 4th field of nfs/nfs4 lines; comments and other lines stay byte-identical.
    awk -v add="$NFSMOUNT_OPTS" '
        BEGIN { n = split(add, want, " ") }
        $1 !~ /^#/ && ($3 == "nfs" || $3 == "nfs4") {
            opts = $4
            for (i = 1; i <= n; i++) {
                key = want[i]; sub(/=.*/, "", key)
                if (("," opts ",") !~ ("," key "[,=]")) opts = opts "," want[i]
            }
            if (opts != $4) { $4 = opts; changed = 1 }
            print; next
        }
        { print }
    ' /etc/fstab >"$tmp"
    if cmp -s "$tmp" /etc/fstab; then
        rm -f "$tmp"
        logt OK nfsmount_already
        return 0
    fi
    changed=1
    # Validate the new fstab before it replaces the old one - only a verification that
    # passed for the current fstab and fails for the new one counts (an existing,
    # unrelated fstab issue must not block this change).
    if command -v findmnt >/dev/null 2>&1 &&
        findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1 &&
        ! findmnt --verify --tab-file "$tmp" >/dev/null 2>&1; then
        logt ERR nfsmount_invalid
        rm -f "$tmp"
        exit 1
    fi
    write_file nfsmount /etc/fstab 0644 <"$tmp"
    rm -f "$tmp"
    local mp opts
    while IFS=$'\t' read -r mp opts; do
        logt OK nfsmount_entry "$mp" "$opts"
    done < <(nfsmount_entries)
    run systemctl daemon-reload
    ((changed)) && logt WARN reboot_needed
    mark_reboot_required
}

# check: an fstab NFS share that is neither mounted nor an automount point
nfsmount_check() {
    local mp opts bad=""
    while IFS=$'\t' read -r mp opts; do
        [[ -n $mp ]] || continue
        [[ $opts == *x-systemd.automount* ]] && continue
        findmnt -rn -t nfs,nfs4 "$mp" >/dev/null 2>&1 || bad+=" $mp"
    done < <(nfsmount_entries)
    printf '%s' "$bad"
}
