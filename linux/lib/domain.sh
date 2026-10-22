# shellcheck shell=bash
# Mode "domain": Kerberos + SSSD + realmd/adcli on the golden image, following
# "Configure SSSD Offline Domain Join for Linux Desktops" (Horizon 8 docs): the image
# is joined once with SSSD, OfflineJoinDomain=sssd (mode agent) makes ClonePrep create
# a computer account + keytab per clone.
# Optional certificate logon, following "Configure True SSO with SSSD on Ubuntu/Debian
# Desktops" and "Configure Smart Card Redirection With SSSD for Ubuntu/Debian Desktops":
# CA chain in /etc/sssd/pki/sssd_auth_ca_db.pem, [pam] pam_cert_auth, certmap rule,
# PKINIT in krb5.conf (a certificate logon still gets a TGT for the NFS krb5 homes).
#
# Since 0.9.0 the certificate part lives in its own SSSD snippet (CERT_SNIPPET), so it
# can be added to an adopted image without rewriting sssd.conf, and it carries what the
# sssd-smartcard project measured on a real host (SSSD 2.9/2.10):
#   - certmap rule pinned to the issuing CA + EKU msScLogin; map by userPrincipalName
#     (the AD attribute) or sAMAccountName - also for alternative UPN suffixes;
#   - local_auth_policy = enable:smartcard (SSSD >= 2.9.3, Debian 13): without it the AD
#     provider reads and verifies the certificate and still asks for a password;
#   - revocation: OCSP fails closed when the clones cannot reach the responder; with a
#     CRL file every CA in the bundle needs a current CRL, refreshed by a timer.

SSSD_CA_DB="/etc/sssd/pki/sssd_auth_ca_db.pem"
CERT_SNIPPET="/etc/sssd/conf.d/50-vdi-imagemaint-certlogon.conf"
CERT_CRL_FILE="/etc/sssd/pki/sssd_auth_crl.pem"
CERT_CRL_CONF="/etc/vdi-imagemaint/crl.conf"
CERT_CRL_SCRIPT="/usr/local/sbin/vdi-imagemaint-crl-refresh"

domain_defaults() {
    AD_REALM=${AD_REALM:-${AD_DOMAIN^^}}
    if [[ -z $AD_WORKGROUP ]]; then
        AD_WORKGROUP=${AD_DOMAIN%%.*}
        AD_WORKGROUP=${AD_WORKGROUP^^}
    fi
}

# Joined = realmd lists the domain AND the machine keytab holds a principal of its realm.
# realmd alone is not enough: it reports a domain as configured as soon as smb.conf says
# "security = ads" (or sssd.conf names it) - written by an earlier run that never joined
# (0.9.1 on the VM: "Already joined", no password prompt, then SSSD would not start).
domain_is_joined() {
    domain_realm_listed && domain_has_keytab
}

domain_realm_listed() {
    command -v realm >/dev/null 2>&1 && realm list --name-only 2>/dev/null | grep -qix "$AD_DOMAIN"
}

domain_has_keytab() {
    klist -k /etc/krb5.keytab 2>/dev/null | grep -qi "@${AD_REALM:-${AD_DOMAIN^^}}\$"
}

# realmd claims the domain but there is no keytab: move the configuration that makes it
# think so out of the way (originals are kept by file_track), so realm join runs.
domain_clear_stale_join() {
    local f
    domain_realm_listed || return 0
    logt WARN domain_stale_join "$AD_DOMAIN"
    for f in /etc/samba/smb.conf /etc/sssd/sssd.conf; do
        [[ -f $f ]] || continue
        file_track build "$f"
        run mv -f "$f" "${f}.vdi-prejoin"
    done
}

cert_logon_enabled() {
    [[ $TRUESSO_ENABLE == yes || $SMARTCARD_ENABLE == yes ]]
}

mode_domain() {
    logt STEP step_domain
    require_conf AD_DOMAIN AD_JOIN_USER
    domain_defaults

    # Package list of the Debian True SSO / smart card SSSD procedures (superset of the plain join).
    apt_install --no-install-recommends sssd sssd-ad sssd-tools libnss-sss libpam-sss \
        realmd adcli krb5-user samba-common-bin libsasl2-modules-gssapi-mit
    if cert_logon_enabled; then
        domain_cert_packages
        domain_install_ca
    fi

    domain_write_krb5
    domain_check_dns

    local joined_now=0
    if domain_is_joined; then
        logt OK domain_already_joined "$AD_DOMAIN"
    else
        domain_clear_stale_join
        run realm discover "$AD_DOMAIN" || logt WARN domain_discover_failed "$AD_DOMAIN"
        domain_join
        joined_now=1
    fi
    # After the join: written before it, smb.conf alone made realmd report "joined".
    domain_write_smb

    domain_write_sssd
    domain_write_sudoers
    if [[ $NFS_ENABLE == yes ]]; then
        # Homes come from autofs; root cannot create them on a sec=krb5 export.
        run pam-auth-update --disable mkhomedir || true
    else
        run pam-auth-update --enable mkhomedir
    fi
    run systemctl enable sssd.service
    run systemctl restart sssd.service
    # Only right after a join: the cache then still holds entries of the previous
    # membership. On an image that was already joined it holds the cached credentials
    # that keep logons working while a DC is unreachable - leave it alone.
    ((joined_now)) && { run sss_cache -E || true; }
    if cert_logon_enabled; then
        domain_certlogon || exit 1
    else
        domain_certlogon_remove
    fi
    kerberos_harden || true
    logt OK domain_done "$AD_DOMAIN"
}

# CA chain that issues logon certificates (True SSO enrollment CA and/or smart card CA),
# PEM files listed in CERT_CA_FILES (relative paths = certs/ next to the tool).
domain_install_ca() {
    local f path bundle=""
    for f in $CERT_CA_FILES; do
        path=$f
        [[ $path == /* ]] || path="${VDI_ROOT}/certs/${f}"
        if [[ ! -s $path ]]; then
            logt ERR cert_ca_missing "$path"
            exit 1
        fi
        if ! openssl x509 -in "$path" -noout 2>/dev/null; then
            logt ERR cert_ca_invalid "$path"
            exit 1
        fi
        bundle+=$(cat "$path")$'\n'
    done
    if [[ -z $bundle ]]; then
        logt ERR cert_ca_none
        exit 1
    fi
    printf '%s' "$bundle" | write_file build "$SSSD_CA_DB" 0644
}

# ------------------------------------------------------------ certificate logon ---
domain_cert_packages() {
    # Debian True SSO / smart card SSSD procedures; krb5-pkinit gives the TGT after a
    # certificate logon (NFS sec=krb5* homes), openssl/curl check and fetch CRLs.
    apt_install --no-install-recommends libpam-pkcs11 krb5-pkinit openssl curl
    if [[ $SMARTCARD_ENABLE == yes ]]; then
        apt_install pcscd pcsc-tools pkg-config libpam-pkcs11 opensc libengine-pkcs11-openssl libnss3-tools
        run systemctl enable --now pcscd.socket
    fi
}

# cert_split FILE... DIR - every certificate of the PEM files as DIR/certN.pem
cert_split() {
    local dir=${!#} f
    for f in "${@:1:$#-1}"; do
        awk -v d="$dir" -v b="$(basename "$f")" '
            /-----BEGIN CERTIFICATE-----/ {n++}
            n {print > (d "/" b "." n ".pem")}
            /-----END CERTIFICATE-----/ {close(d "/" b "." n ".pem")}' "$f"
    done
}

cert_subject() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253,-esc_msb 2>/dev/null | sed 's/^subject=//'; }
cert_issuer() { openssl x509 -in "$1" -noout -issuer -nameopt RFC2253,-esc_msb 2>/dev/null | sed 's/^issuer=//'; }

# cert_ere STRING - POSIX ERE for exactly STRING (sss-certmap: escape ^ . [ $ ( ) | * + ? { \)
cert_ere() {
    printf '^%s$' "$(printf '%s' "$1" | sed -E 's/[]\^.[$()|*+?{}\\]/\\&/g')"
}

# cert_ca_path NAME - a CA file from the config: absolute, or in certs/ next to the tool
cert_ca_path() {
    [[ $1 == /* ]] && printf '%s' "$1" || printf '%s' "${VDI_ROOT}/certs/$1"
}

# cert_issuer_dn VALUE - the DN to pin for one logon type (TRUESSO_ISSUER_CA / SMARTCARD_ISSUER_CA):
#   "none" = no pin; a PEM file = its subject; empty = auto: the only issuing (non-root)
#   CA among CERT_CA_FILES, or the root when the bundle holds nothing else.
# Prints nothing when it cannot decide.
cert_issuer_dn() {
    local value=$1 tmp f path n=0 subj iss only="" roots=0 rootsubj=""
    [[ $value == none ]] && return 0
    if [[ -n $value ]]; then
        path=$(cert_ca_path "$value")
        [[ -s $path ]] && cert_subject "$path"
        return 0
    fi
    tmp=$(mktemp -d)
    local -a files=()
    for f in $CERT_CA_FILES; do
        path=$(cert_ca_path "$f")
        [[ -s $path ]] && files+=("$path")
    done
    ((${#files[@]})) && cert_split "${files[@]}" "$tmp"
    for f in "$tmp"/*.pem; do
        [[ -e $f ]] || continue
        subj=$(cert_subject "$f")
        iss=$(cert_issuer "$f")
        if [[ $subj == "$iss" ]]; then
            roots=$((roots + 1))
            rootsubj=$subj
        else
            n=$((n + 1))
            only=$subj
        fi
    done
    rm -rf "$tmp"
    if ((n == 1)); then
        printf '%s' "$only"
    elif ((n == 0 && roots == 1)); then
        printf '%s' "$rootsubj"
    fi
}

# cert_rule NAME ISSUER_DN PRIORITY - one [certmap] section. Components are concatenated
# (an infix "&&" breaks the rule - measured); map by the AD attribute userPrincipalName,
# with sAMAccountName for UPNs whose prefix is the logon name. No "domains =": the accounts
# are in this domain, also when the certificate carries an alternative UPN suffix.
cert_rule() {
    local match="<EKU>msScLogin"
    [[ -n $2 ]] && match="<ISSUER>$(cert_ere "$2")${match}"
    cat <<EOF

[certmap/${AD_DOMAIN}/$1]
matchrule = ${match}
maprule = (|(userPrincipalName={subject_principal})(sAMAccountName={subject_principal.short_name}))
priority = $3
EOF
}

sssd_version_ge() {
    local v
    v=$(dpkg-query -W -f='${Version}' sssd 2>/dev/null) || return 1
    [[ -n $v ]] && dpkg --compare-versions "$v" ge "$1"
}

# sssd_conf_get SECTION KEY - value from /etc/sssd/sssd.conf (the main file only)
sssd_conf_get() {
    awk -v sec="[$1]" -v key="$2" '
        /^[[:space:]]*\[/ {cur = $0; gsub(/[[:space:]]/, "", cur); next}
        cur == sec {
            line = $0; sub(/^[[:space:]]*/, "", line)
            k = line; sub(/[[:space:]]*=.*/, "", k)
            if (k == key) { sub(/^[^=]*=[[:space:]]*/, "", line); print line; exit }
        }' /etc/sssd/sssd.conf 2>/dev/null
}

# The certificate_verification value for CERT_REVOCATION (SSSD_CERT_VERIFICATION, when set,
# is used as it is).
cert_verification() {
    if [[ -n $SSSD_CERT_VERIFICATION ]]; then
        printf '%s' "$SSSD_CERT_VERIFICATION"
        return 0
    fi
    case ${CERT_REVOCATION:-ocsp} in
        ocsp) ;;                                   # SSSD default
        soft_ocsp) printf 'soft_ocsp' ;;
        crl) printf 'no_ocsp, crl_file=%s' "$CERT_CRL_FILE" ;;
        none) printf 'no_ocsp' ;;
    esac
}

# local_auth_policy for the domain: add enable:smartcard to what is there (2.9.3+).
cert_local_auth_policy() {
    local cur
    sssd_version_ge 2.9.3 || return 0
    cur=$(sssd_conf_get "domain/${AD_DOMAIN}" local_auth_policy)
    if [[ $cur == *only* ]]; then
        logt WARN cert_lap_only "$cur"
        return 0
    fi
    [[ $cur == *enable:smartcard* ]] && return 0
    printf '%s' "${cur:+${cur}, }enable:smartcard"
}

# CRL set + refresh timer (CERT_REVOCATION=crl). The first fetch must succeed: a crl_file
# that does not exist rejects every certificate.
domain_cert_crl() {
    if [[ -z $CERT_CRL_URLS ]]; then
        logt ERR cert_crl_no_urls
        return 1
    fi
    # Fetch with the new URLs first; the configuration the timer uses is replaced only
    # when that succeeded (a wrong URL leaves the working setup as it was).
    if [[ ${PREVIEW:-0} != 1 ]]; then
        local tconf rc=0
        tconf=$(mktemp)
        printf 'CA_DB="%s"\nCRL_FILE="%s"\nCRL_URLS="%s"\n' "$SSSD_CA_DB" "$CERT_CRL_FILE" "$CERT_CRL_URLS" >"$tconf"
        file_track build "$CERT_CRL_FILE"
        VDI_CRL_CONF=$tconf bash "${VDI_ROOT}/files/crl-refresh.sh" 2>&1 |
            while IFS= read -r l; do log INFO "$l"; done || rc=$?
        rm -f "$tconf"
        if ((rc != 0)) || [[ ! -s $CERT_CRL_FILE ]]; then
            logt ERR cert_crl_failed "$CERT_CRL_URLS"
            return 1
        fi
    fi
    write_file build "$CERT_CRL_CONF" 0644 <<EOF
${MANAGED_MARK}
CA_DB="${SSSD_CA_DB}"
CRL_FILE="${CERT_CRL_FILE}"
CRL_URLS="${CERT_CRL_URLS}"
EOF
    write_file build "$CERT_CRL_SCRIPT" 0755 <"${VDI_ROOT}/files/crl-refresh.sh"
    write_file build /etc/systemd/system/vdi-imagemaint-crl.service 0644 <<EOF
${MANAGED_MARK}
[Unit]
Description=VDI-ImageMaint: refresh the CRL file used by SSSD
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${CERT_CRL_SCRIPT}
EOF
    write_file build /etc/systemd/system/vdi-imagemaint-crl.timer 0644 <<EOF
${MANAGED_MARK}
# Runs on the golden image and on every instant clone. Persistent: a VM that was off
# past the CRL's next update refreshes at once instead of rejecting every certificate.
[Unit]
Description=VDI-ImageMaint: refresh the SSSD CRL file hourly

[Timer]
OnCalendar=hourly
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    [[ ${PREVIEW:-0} == 1 ]] && return 0
    run systemctl daemon-reload
    run systemctl enable --now vdi-imagemaint-crl.timer
    logt OK cert_crl_ok "$CERT_CRL_FILE"
}

# domain_certlogon - write CERT_SNIPPET (True SSO and/or smart card) and prove SSSD takes it:
# sssctl config-check + restart, rolled back if either fails.
domain_certlogon() {
    local tdn="" sdn="" rules="" verif lap old="" precheck=0
    if [[ $TRUESSO_ENABLE == yes ]]; then
        tdn=$(cert_issuer_dn "$TRUESSO_ISSUER_CA")
        if [[ -n $tdn ]]; then
            logt OK cert_issuer_pinned TrueSSO "$tdn"
        elif [[ $TRUESSO_ISSUER_CA != none ]]; then
            logt WARN cert_issuer_unpinned TrueSSO TRUESSO_ISSUER_CA
        fi
        rules+=$(cert_rule truesso "$tdn" 10)
    fi
    if [[ $SMARTCARD_ENABLE == yes ]]; then
        sdn=$(cert_issuer_dn "$SMARTCARD_ISSUER_CA")
        if [[ -n $sdn ]]; then
            logt OK cert_issuer_pinned SmartCard "$sdn"
        elif [[ $SMARTCARD_ISSUER_CA != none ]]; then
            logt WARN cert_issuer_unpinned SmartCard SMARTCARD_ISSUER_CA
        fi
        # One rule is enough when both come from the same CA.
        if [[ $TRUESSO_ENABLE != yes || $sdn != "$tdn" ]]; then
            rules+=$(cert_rule smartcard "$sdn" 20)
        fi
    fi
    if [[ ${CERT_REVOCATION:-ocsp} == crl && -z $SSSD_CERT_VERIFICATION ]]; then
        domain_cert_crl || return 1
    fi
    verif=$(cert_verification)
    lap=$(cert_local_auth_policy)
    if [[ ${PREVIEW:-0} != 1 ]] && command -v sssctl >/dev/null 2>&1 && sssctl config-check >/dev/null 2>&1; then
        precheck=1
    fi
    [[ -f $CERT_SNIPPET ]] && old=$(cat "$CERT_SNIPPET")
    write_file build "$CERT_SNIPPET" 0600 <<EOF
${MANAGED_MARK}
# Certificate logon (Horizon True SSO / smart card) - written by vdi-imagemaint.sh domain.
${verif:+
[sssd]
certificate_verification = ${verif}
}
[pam]
pam_cert_auth = True
# Horizon SSO (also True SSO) logs in through the gdm-hzncred PAM service.
pam_p11_allowed_services = +gdm-hzncred
pam_cert_db_path = ${SSSD_CA_DB}
p11_child_timeout = 30
${lap:+
[domain/${AD_DOMAIN}]
# SSSD >= 2.9.3: without it the AD provider verifies the certificate and then asks for a password.
local_auth_policy = ${lap}
}${rules}
EOF
    [[ ${PREVIEW:-0} == 1 ]] && return 0
    chown root:root "$CERT_SNIPPET"

    if [[ $SMARTCARD_ENABLE == yes ]]; then
        if [[ -f /usr/share/pam-configs/sss-smart-card-optional ]]; then
            run pam-auth-update --disable sss-smart-card-required --enable sss-smart-card-optional
        else
            # Debian 12: libpam-sss 2.8 has no smart card profile.
            logt WARN cert_pam_manual "auth [success=ok default=ignore] pam_sss.so allow_missing_name try_cert_auth"
        fi
    fi
    grep -q pkinit_anchors /etc/krb5.conf 2>/dev/null || logt WARN cert_pkinit_missing

    if ((precheck)) && ! run sssctl config-check; then
        logt ERR krb_rolled_back "sssctl config-check"
        domain_certlogon_restore "$old"
        return 1
    fi
    run systemctl restart sssd.service || true
    sleep 2
    if ! systemctl is-active --quiet sssd.service; then
        logt ERR krb_rolled_back "sssd.service"
        domain_certlogon_restore "$old"
        return 1
    fi
    logt OK cert_logon_done
}

domain_certlogon_restore() {
    if [[ -n $1 ]]; then
        printf '%s\n' "$1" >"$CERT_SNIPPET"
    else
        rm -f "$CERT_SNIPPET"
    fi
    run systemctl restart sssd.service || true
}

# Certificate logon switched off: remove the snippet (and the CRL timer) again.
domain_certlogon_remove() {
    [[ -f $CERT_SNIPPET || -f /etc/systemd/system/vdi-imagemaint-crl.timer ]] || return 0
    [[ ${PREVIEW:-0} == 1 ]] && return 0
    run systemctl disable --now vdi-imagemaint-crl.timer 2>/dev/null || true
    rm -f "$CERT_SNIPPET" /etc/systemd/system/vdi-imagemaint-crl.timer /etc/systemd/system/vdi-imagemaint-crl.service
    run systemctl daemon-reload || true
    run systemctl restart sssd.service || true
    logt OK cert_logon_removed
}

# Adopted image (domain step taken over, sssd.conf not ours): add only the certificate
# logon part - packages, CA bundle, the snippet - and leave the rest of SSSD as it is.
domain_certlogon_adopted() {
    step_adopted domain || return 0
    # --force ran the whole mode_domain already.
    [[ ${FORCE:-0} == 1 ]] && return 0
    if ! cert_logon_enabled; then
        domain_certlogon_remove
        return 0
    fi
    if is_sealed; then
        logt ERR cert_sealed
        exit 1
    fi
    logt STEP step_certlogon
    require_conf AD_DOMAIN
    domain_defaults
    domain_cert_packages
    domain_install_ca
    domain_certlogon || exit 1
}

domain_write_krb5() {
    local realms=""
    if cert_logon_enabled; then
        # KDCs come from DNS (dns_lookup_kdc); KRB5_KDC pins one for PKINIT if needed.
        realms="
[realms]
    ${AD_REALM} = {
        pkinit_anchors = FILE:${SSSD_CA_DB}
        pkinit_eku_checking = kpServerAuth${KRB5_KDC:+
        kdc = ${KRB5_KDC}
        pkinit_kdc_hostname = ${KRB5_KDC}}
    }"
    fi
    write_file build /etc/krb5.conf 0644 <<EOF
${MANAGED_MARK}
[libdefaults]
    default_realm = ${AD_REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    # FILE caches in /tmp are what rpc.gssd looks for (NFS sec=krb5*)
    default_ccache_name = FILE:/tmp/krb5cc_%{uid}
${realms}

[domain_realm]
    .${AD_DOMAIN} = ${AD_REALM}
    ${AD_DOMAIN} = ${AD_REALM}
EOF
}

# samba-common-bin ("net ads") is used by some offline-join paths; keep smb.conf consistent with SSSD.
domain_write_smb() {
    write_file build /etc/samba/smb.conf 0644 <<EOF
${MANAGED_MARK}
[global]
    workgroup = ${AD_WORKGROUP}
    realm = ${AD_REALM}
    security = ads
    kerberos method = secrets and keytab
    client signing = yes
    client use spnego = yes
    log file = /var/log/samba/%m.log
EOF
}

domain_check_dns() {
    if [[ -z $(dig +short -t SRV "_ldap._tcp.${AD_DOMAIN}" 2>/dev/null) ]]; then
        logt WARN dns_srv_missing "_ldap._tcp.${AD_DOMAIN}"
    else
        logt OK dns_srv_ok "$AD_DOMAIN"
    fi
}

domain_join() {
    local args=(join --verbose --membership-software=adcli --client-software=sssd --user="$AD_JOIN_USER")
    [[ -n $AD_COMPUTER_OU ]] && args+=(--computer-ou="$AD_COMPUTER_OU")
    [[ $SSSD_ID_MAPPING == false ]] && args+=(--automatic-id-mapping=no)
    logt INFO domain_joining "$AD_DOMAIN" "$AD_JOIN_USER" "$(hostname -s)"
    # Interactive: realm prompts for the join account password; never pass it on the command line.
    if ! realm "${args[@]}" "$AD_DOMAIN"; then
        logt ERR domain_join_failed "$AD_DOMAIN"
        exit 1
    fi
}

domain_write_sssd() {
    local access homedir
    if [[ -n $AD_ACCESS_GROUPS ]]; then
        access="access_provider = simple
simple_allow_groups = ${AD_ACCESS_GROUPS}"
    else
        access="access_provider = ad"
    fi
    if [[ $NFS_ENABLE == yes ]]; then
        homedir="override_homedir = ${HOME_ROOT}/%u"
    else
        homedir="fallback_homedir = /home/%u"
        [[ $SSSD_FQ_NAMES == true ]] && homedir="fallback_homedir = /home/%u@%d"
    fi
    # Certificate logon (pam_cert_auth, certmap, revocation) is in $CERT_SNIPPET.
    write_file build /etc/sssd/sssd.conf 0600 <<EOF
${MANAGED_MARK}
[sssd]
domains = ${AD_DOMAIN}
config_file_version = 2
services = nss, pam

[domain/${AD_DOMAIN}]
id_provider = ad
auth_provider = ad
chpass_provider = ad
${access}
ad_domain = ${AD_DOMAIN}
krb5_realm = ${AD_REALM}
realmd_tags = manages-system joined-with-adcli
cache_credentials = True
krb5_store_password_if_offline = True
krb5_ccname_template = FILE:/tmp/krb5cc_%U
krb5_renewable_lifetime = 7d
krb5_renew_interval = 60m
default_shell = /bin/bash
ldap_id_mapping = $([[ $SSSD_ID_MAPPING == false ]] && echo False || echo True)
use_fully_qualified_names = $([[ $SSSD_FQ_NAMES == true ]] && echo True || echo False)
${homedir}
# Horizon SSO logs in through the gdm-hzncred PAM service.
ad_gpo_map_interactive = +gdm-hzncred
# Documented for Debian 12 (sssd bug 1934997) and for the cloned VMs.
ad_gpo_access_control = permissive
dyndns_update = $([[ $SSSD_DYNDNS == true ]] && echo True || echo False)
dyndns_refresh_interval = 43200
dyndns_update_ptr = False
EOF
    [[ ${PREVIEW:-0} == 1 ]] || chown root:root /etc/sssd/sssd.conf
}

domain_write_sudoers() {
    local f=/etc/sudoers.d/vdi-imagemaint g lines="" tmp
    local -a groups
    if [[ -z $AD_SUDO_GROUPS ]]; then
        if [[ -e $f ]]; then
            file_track build "$f"
            rm -f "$f"
        fi
        return 0
    fi
    IFS=',' read -r -a groups <<<"$AD_SUDO_GROUPS"
    for g in "${groups[@]}"; do
        g=$(printf '%s' "$g" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/ /\\ /g')
        [[ -n $g ]] && lines+="%${g} ALL=(ALL:ALL) ALL"$'\n'
    done
    tmp=$(mktemp)
    printf '%s\n%s' "$MANAGED_MARK" "$lines" >"$tmp"
    if visudo -cf "$tmp" >/dev/null; then
        write_file build "$f" 0440 <"$tmp"
    else
        logt ERR sudoers_invalid "$AD_SUDO_GROUPS"
    fi
    rm -f "$tmp"
}

# Mode "fido": FIDO2 redirection probe - run INSIDE a Horizon session on a clone with a
# security key plugged into the client. Lists the FIDO2 devices the desktop can see.
mode_fido() {
    logt STEP step_fido
    if ! command -v fido2-token >/dev/null 2>&1; then
        if is_sealed; then
            logt ERR fido_tools_missing_sealed
            exit 1
        fi
        apt_install --no-install-recommends fido2-tools
    fi
    local devices
    devices=$(fido2-token -L 2>/dev/null || true)
    if [[ -n $devices ]]; then
        logt OK fido_found "$(printf '%s' "$devices" | wc -l)"
        log INFO "$devices"
    else
        logt WARN fido_none
    fi
    if [[ -e /dev/hidraw0 ]]; then
        log INFO "hidraw: $(find /dev -maxdepth 1 -name 'hidraw*' -printf '%f ' 2>/dev/null)"
    fi
}
