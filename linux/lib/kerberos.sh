# shellcheck shell=bash
# Kerberos / SSSD robustness for golden images and instant clones.
#
# Symptom this prevents: after the golden image was powered off for a while (or a
# snapshot was reverted), logons stop working - SSSD cannot authenticate to AD.
# Causes and what is done (SSSD/MIT Kerberos behaviour; not covered by the Omnissa docs):
#   1. SSSD rotates the machine account password every 30 days on its own
#      (ad_maximum_machine_account_password_age). AD keeps only the current and the
#      previous password, so an image/snapshot whose keytab is older than that no longer
#      authenticates. -> automatic rotation off on the image; "update" rotates it on
#      purpose (adcli update) right before the new snapshot, so every snapshot carries a
#      current keytab.
#   2. SSSD starts before the clock is synchronised; more than 5 minutes of skew breaks
#      Kerberos and SSSD goes offline. -> sssd waits for time-sync.target
#      (systemd-time-wait-sync, max 90 s), and the per-clone script syncs time first.
#   3. User tickets expire in long sessions (NFS krb5 homes stop working).
#      -> renewable tickets renewed by SSSD.
# Written as conf.d snippet + systemd drop-ins, so sssd.conf of adopted images stays untouched.

KRB_SSSD_SNIPPET="/etc/sssd/conf.d/60-vdi-imagemaint-kerberos.conf"
KRB_SSSD_DROPIN="/etc/systemd/system/sssd.service.d/50-vdi-imagemaint-timesync.conf"
KRB_WAITSYNC_DROPIN="/etc/systemd/system/systemd-time-wait-sync.service.d/50-vdi-imagemaint.conf"

# Only for SSSD joins (an adopted winbind image manages its own machine password).
kerberos_applies() {
    unit_known sssd.service || return 1
    [[ $(state_get build '.adopted.join // empty') == winbind ]] && step_adopted domain && return 1
    return 0
}

# The SSSD domain actually configured on this machine (first entry of "domains" in
# sssd.conf); AD_DOMAIN only as fallback and never an example value.
krb_domain() {
    local d
    d=$(sed -nE 's/^[[:space:]]*domains[[:space:]]*=[[:space:]]*//p' /etc/sssd/sssd.conf 2>/dev/null |
        head -n1 | cut -d, -f1 | tr -d '[:space:]' || true)
    [[ -n $d ]] || d=$AD_DOMAIN
    [[ -n $d && $d != *example* ]] || return 1
    printf '%s' "$d"
}

# Remove what kerberos_harden wrote and bring SSSD back (safety net).
kerberos_undo() {
    rm -f "$KRB_SSSD_SNIPPET" "$KRB_SSSD_DROPIN" "$KRB_WAITSYNC_DROPIN"
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart sssd.service 2>/dev/null || true
}

kerberos_harden() {
    if ! kerberos_applies; then
        logt INFO krb_not_sssd
        return 0
    fi
    local dom
    if ! dom=$(krb_domain); then
        logt WARN krb_no_domain
        return 0
    fi
    logt INFO krb_harden "$dom"
    # Baseline: only a config check that passed before and fails now counts against us.
    local precheck=0
    if [[ ${PREVIEW:-0} != 1 ]] && command -v sssctl >/dev/null 2>&1 && sssctl config-check >/dev/null 2>&1; then
        precheck=1
    fi
    write_file build "$KRB_SSSD_SNIPPET" 0600 <<EOF
${MANAGED_MARK}
[domain/${dom}]
# No automatic machine password change: a snapshot taken later must keep a keytab that
# AD still accepts. "vdi-imagemaint.sh update" rotates it on purpose (adcli update).
ad_maximum_machine_account_password_age = 0
# Renew user tickets during long sessions (NFS sec=krb5* homes).
krb5_renewable_lifetime = 7d
krb5_renew_interval = 60m
krb5_store_password_if_offline = True
EOF
    # Waiting for the clock only makes sense when systemd-timesyncd keeps it (time-wait-sync
    # follows timesyncd; with chrony or VMware Tools it would only delay every boot).
    local timesyncd=0
    systemctl is-active --quiet systemd-timesyncd.service 2>/dev/null && timesyncd=1
    if ((timesyncd)); then
        write_file build "$KRB_WAITSYNC_DROPIN" 0644 <<EOF
${MANAGED_MARK}
# Never block the boot for long when NTP is unreachable.
[Service]
TimeoutStartSec=90
EOF
        write_file build "$KRB_SSSD_DROPIN" 0644 <<EOF
${MANAGED_MARK}
# Start SSSD with a synchronised clock: Kerberos fails above 5 minutes of skew.
[Unit]
Wants=time-sync.target
After=time-sync.target
EOF
    else
        logt INFO krb_no_timesyncd
    fi
    [[ ${PREVIEW:-0} == 1 ]] && return 0
    run systemctl daemon-reload
    if ((timesyncd)) && unit_known systemd-timesyncd.service; then
        run systemctl enable systemd-time-wait-sync.service || true
    fi

    # Safety net: the configuration must validate and SSSD must come back up,
    # otherwise everything written here is removed again.
    if ((precheck)) && ! run sssctl config-check; then
        logt ERR krb_rolled_back "sssctl config-check"
        kerberos_undo
        return 1
    fi
    run systemctl restart sssd.service || true
    sleep 2
    if ! systemctl is-active --quiet sssd.service; then
        logt ERR krb_rolled_back "sssd.service"
        kerberos_undo
        return 1
    fi
    logt OK krb_hardened
}

# Rotate the machine account password now (monthly, before the snapshot) and verify it.
kerberos_rotate() {
    kerberos_applies || return 0
    [[ $MACHINE_PASSWORD_ROTATION == update ]] || return 0
    command -v adcli >/dev/null 2>&1 || return 0
    local dom
    dom=$(krb_domain) || return 0
    # Never rotate a keytab AD already rejects - that would not fix it.
    kerberos_testjoin || { logt WARN krb_rotate_failed; return 0; }
    if run adcli update --domain="$dom" --computer-password-lifetime="$MACHINE_PASSWORD_DAYS"; then
        # SSSD reads the new keytab on restart; its cache is kept (no sss_cache -E).
        run systemctl restart sssd.service || true
        logt OK krb_rotated "$MACHINE_PASSWORD_DAYS"
    else
        logt WARN krb_rotate_failed
    fi
}

# kerberos_testjoin -> 0 when the machine keytab is accepted by AD
kerberos_testjoin() {
    local dom
    command -v adcli >/dev/null 2>&1 || return 2
    dom=$(krb_domain) || return 2
    adcli testjoin --domain="$dom" >/dev/null 2>&1
}

# Mode "kerberos": apply the settings now and show the state.
mode_kerberos() {
    logt STEP step_kerberos
    kerberos_harden || true
    local dom
    dom=$(krb_domain || echo "?")
    if kerberos_testjoin; then
        logt OK chk_testjoin_ok "$dom"
    else
        logt ERR chk_testjoin_bad "$dom"
    fi
    log INFO "$(timedatectl show -p NTPSynchronized -p TimeUSec 2>/dev/null | tr '\n' ' ' || true)"
}
