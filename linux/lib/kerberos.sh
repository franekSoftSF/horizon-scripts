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
    if run timeout 120 adcli update --domain="$dom" --computer-password-lifetime="$MACHINE_PASSWORD_DAYS" </dev/null; then
        # SSSD reads the new keytab on restart; its cache is kept (no sss_cache -E).
        run systemctl restart sssd.service || true
        logt OK krb_rotated "$MACHINE_PASSWORD_DAYS"
    else
        logt WARN krb_rotate_failed
    fi
}

# Machine principal from the keytab (e.g. H8-DEBTEMP02$@STD.FIZYKA.PW.EDU.PL).
krb_machine_principal() {
    klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR>3 {print $2}' | grep -m1 '\$@' || true
}

# kerberos_kinit_test -> 0 accepted, 1 rejected by the KDC, 3 KDC not reachable, 4 inconclusive.
# A Kerberos login with the machine keytab into a memory cache: quick, read-only.
kerberos_kinit_test() {
    local princ rc=0 out
    command -v kinit >/dev/null 2>&1 || return 4
    princ=$(krb_machine_principal)
    [[ -n $princ ]] || return 4
    out=$(timeout 20 kinit -k -t /etc/krb5.keytab -c MEMORY:vdi-imagemaint "$princ" </dev/null 2>&1) || rc=$?
    [[ -w $LOG_DIR ]] && printf 'kinit -k %s (rc=%s): %s\n' "$princ" "$rc" "$out" >>"$LOG_FILE"
    ((rc == 0)) && return 0
    ((rc == 124 || rc == 137)) && return 3
    case ${out,,} in
        *"preauthentication failed"* | *"not found in kerberos database"* | *"password incorrect"* | *"key version"*) return 1 ;;
        *"cannot contact"* | *"cannot find kdc"* | *"cannot resolve"*) return 3 ;;
    esac
    return 4
}

# kerberos_testjoin -> 0 accepted by AD, 1 rejected, 2 not checkable, 3 timed out / unreachable.
# First kinit with the machine keytab (direct, seconds); adcli testjoin only when kinit
# is inconclusive. adcli may wait long for a DC or ask on the terminal: never from stdin,
# never longer than KRB_ADCLI_TIMEOUT seconds. All output goes to the log.
KRB_ADCLI_TIMEOUT=30
kerberos_testjoin() {
    local dom rc=0 out
    kerberos_kinit_test || rc=$?
    case $rc in
        0 | 1 | 3) return "$rc" ;;
    esac
    rc=0
    command -v adcli >/dev/null 2>&1 || return 2
    dom=$(krb_domain) || return 2
    out=$(timeout "$KRB_ADCLI_TIMEOUT" adcli testjoin --domain="$dom" </dev/null 2>&1) || rc=$?
    [[ -w $LOG_DIR ]] && printf 'adcli testjoin (rc=%s): %s\n' "$rc" "$out" >>"$LOG_FILE"
    case $rc in
        0) return 0 ;;
        124 | 137) return 3 ;;
        *) return 1 ;;
    esac
}

# Mode "kerberos": apply the settings now and show the state.
mode_kerberos() {
    logt STEP step_kerberos
    kerberos_harden || true
    local dom
    dom=$(krb_domain || echo "?")
    local rc=0
    kerberos_testjoin || rc=$?
    case $rc in
        0) logt OK chk_testjoin_ok "$dom" ;;
        1) logt ERR chk_testjoin_bad "$dom" ;;
        3) logt WARN chk_testjoin_timeout "$dom" "$KRB_ADCLI_TIMEOUT" ;;
        *) logt WARN chk_testjoin_unknown "$dom" ;;
    esac
    log INFO "$(timedatectl show -p NTPSynchronized -p TimeUSec 2>/dev/null | tr '\n' ' ' || true)"
}

# Mode "diag": read-only diagnosis of logon/Kerberos/SSSD/agent in one screen, also saved
# to the log folder (for desktops without clipboard: take a screenshot or copy the file).
# Secret values are masked; nothing is changed.
mode_diag() {
    logt STEP step_diag
    local f dir
    f="${LOG_DIR}/diag-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "== VDI-ImageMaint ${VDI_VERSION} diag $(date -Is) on $(hostname -f 2>/dev/null || hostname)"
        echo "== os: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}") kernel $(uname -r)"
        echo "== time"; timedatectl show -p NTPSynchronized -p Timezone -p TimeUSec 2>&1 || true
        echo "== realm list"; timeout 15 realm list 2>&1 || true
        echo "== sssd"; systemctl is-active sssd.service 2>&1 || true
        timeout 15 sssctl config-check 2>&1 || true
        ls -l /etc/sssd/conf.d/ 2>&1 || true
        sed -nE '/^\[|domains|id_provider|access_provider|ad_gpo|fully_qualified|homedir|password_age|krb5_/p' \
            /etc/sssd/sssd.conf /etc/sssd/conf.d/*.conf 2>/dev/null || true
        echo "== keytab (principal, kvno; no keys)"
        klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR>3 {print $1, $2}' | sort -u | head -n 10 || true
        echo "== kinit -k (machine keytab against the KDC)"
        local rc=0
        kerberos_kinit_test || rc=$?
        echo "result: $(case $rc in 0) echo ACCEPTED ;; 1) echo REJECTED ;; 3) echo "KDC NOT REACHABLE" ;; *) echo INCONCLUSIVE ;; esac)"
        tail -n 1 "$LOG_FILE" 2>/dev/null || true
        echo "== adcli testjoin (max ${KRB_ADCLI_TIMEOUT} s)"
        timeout "$KRB_ADCLI_TIMEOUT" adcli testjoin --domain="$(krb_domain || echo "$AD_DOMAIN")" </dev/null 2>&1 || echo "rc=$?"
        echo "== DNS"; dig +short -t SRV "_ldap._tcp.$(krb_domain || echo "$AD_DOMAIN")" 2>&1 | head -n 5 || true
        echo "== sssd journal (last 20)"; journalctl -u sssd -b --no-pager 2>&1 | tail -n 20 || true
        echo "== Horizon agent"
        if dir=$(agent_conf_dir); then
            grep -E '^[[:space:]]*(OfflineJoinDomain|RunOnceScript|SSOEnable|SSOUserFormat|SSODesktopType)' "${dir}/viewagent-custom.conf" 2>&1 || true
        fi
        systemctl is-active viewagent.service 2>&1 || true
        echo "== NFS"
        grep -E '^[^#].*[[:space:]]nfs4?[[:space:]]' /etc/fstab 2>/dev/null | sed 's/^/fstab: /' || echo "fstab: no nfs entry"
        grep -rhsE '(fstype=nfs|[[:alnum:].-]+:/)' /etc/auto.master.d /etc/auto.* 2>/dev/null | grep -v '^#' | sed 's/^/autofs: /' | head -n 5 || true
        findmnt -t nfs,nfs4 -o TARGET,SOURCE,OPTIONS 2>/dev/null || echo "mounted: none"
        local u
        for u in rpc-gssd.service nfs-client.target autofs.service rpc-statd.service; do
            printf '%s: %s/%s\n' "$u" "$(systemctl is-enabled "$u" 2>&1 | head -n1 || true)" "$(systemctl is-active "$u" 2>&1 | head -n1 || true)"
        done
        echo "-- rpc-gssd journal (last 10)"; journalctl -b -u rpc-gssd --no-pager 2>&1 | tail -n 10 || true
        echo "-- kernel NFS/RPC (last 10)"; journalctl -k -b --no-pager 2>/dev/null | grep -iE 'nfs|rpc|gss' | tail -n 10 || true
        echo "-- keytab principals for NFS"; klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR>3 {print $2}' | grep -iE '^(nfs|host)/|\$@' | sort -u | head -n 6 || true
        # The user who ran sudo: their ticket cache and a home access test as that user
        # (by uid, without PAM; rpc.gssd finds the ticket by uid). Never blocks longer than 10 s.
        if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
            local uid gid home
            uid=$(id -u "$SUDO_USER" 2>/dev/null || echo "?")
            gid=$(id -g "$SUDO_USER" 2>/dev/null || echo "?")
            home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
            echo "-- user ${SUDO_USER} uid=${uid} home=${home:-?}"
            find /tmp -maxdepth 1 -name "krb5cc_${uid}*" -printf '%M %u %p\n' 2>/dev/null | grep . || echo "no FILE ticket cache in /tmp"
            if [[ -n $home && $uid != "?" ]]; then
                timeout 10 setpriv --reuid="$uid" --regid="$gid" --clear-groups ls -ld "$home" 2>&1 || echo "home access rc=$?"
            fi
        fi
        echo "== runonce.log (last 10)"; tail -n 10 "${LOG_DIR}/runonce.log" 2>/dev/null || echo "-"
    } 2>&1 | sed -E 's/((pass|secret|authtok)[^=:]*[=:]).*/\1 ********/I' | tee "$f"
    chmod 0640 "$f"
    logt OK diag_saved "$f"
}
