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

kerberos_harden() {
    if ! kerberos_applies; then
        logt INFO krb_not_sssd
        return 0
    fi
    domain_defaults
    logt INFO krb_harden "$AD_DOMAIN"
    write_file build "$KRB_SSSD_SNIPPET" 0600 <<EOF
${MANAGED_MARK}
[domain/${AD_DOMAIN}]
# No automatic machine password change: a snapshot taken later must keep a keytab that
# AD still accepts. "vdi-imagemaint.sh update" rotates it on purpose (adcli update).
ad_maximum_machine_account_password_age = 0
# Renew user tickets during long sessions (NFS sec=krb5* homes).
krb5_renewable_lifetime = 7d
krb5_renew_interval = 60m
krb5_store_password_if_offline = True
EOF
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
    [[ ${PREVIEW:-0} == 1 ]] && return 0
    run systemctl daemon-reload
    if unit_known systemd-time-wait-sync.service; then
        run systemctl enable systemd-time-wait-sync.service || true
    fi
    run systemctl restart sssd.service || true
    logt OK krb_hardened
}

# Rotate the machine account password now (monthly, before the snapshot) and verify it.
kerberos_rotate() {
    kerberos_applies || return 0
    [[ $MACHINE_PASSWORD_ROTATION == update ]] || return 0
    command -v adcli >/dev/null 2>&1 || return 0
    domain_defaults
    if run adcli update --domain="$AD_DOMAIN" --computer-password-lifetime="$MACHINE_PASSWORD_DAYS"; then
        run sss_cache -E || true
        run systemctl restart sssd.service || true
        logt OK krb_rotated "$MACHINE_PASSWORD_DAYS"
    else
        logt WARN krb_rotate_failed
    fi
}

# kerberos_testjoin -> 0 when the machine keytab is accepted by AD
kerberos_testjoin() {
    command -v adcli >/dev/null 2>&1 || return 2
    adcli testjoin --domain="$AD_DOMAIN" >/dev/null 2>&1
}

# Mode "kerberos": apply the settings now and show the state.
mode_kerberos() {
    logt STEP step_kerberos
    kerberos_harden
    domain_defaults
    if kerberos_testjoin; then
        logt OK chk_testjoin_ok "$AD_DOMAIN"
    else
        logt ERR chk_testjoin_bad "$AD_DOMAIN"
    fi
    log INFO "$(timedatectl show -p NTPSynchronized -p TimeUSec 2>/dev/null | tr '\n' ' ' || true)"
}
