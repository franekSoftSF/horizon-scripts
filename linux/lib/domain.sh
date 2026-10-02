# shellcheck shell=bash
# Mode "domain": Kerberos + SSSD + realmd/adcli on the golden image, following
# "Configure SSSD Offline Domain Join for Linux Desktops" (Horizon 8 docs): the image
# is joined once with SSSD, OfflineJoinDomain=sssd (mode agent) makes ClonePrep create
# a computer account + keytab per clone.
# Optional certificate logon, following "Configure True SSO with SSSD on Ubuntu/Debian
# Desktops" and "Configure Smart Card Redirection With SSSD for Ubuntu/Debian Desktops":
# CA chain in /etc/sssd/pki/sssd_auth_ca_db.pem, [pam] pam_cert_auth, certmap rule,
# PKINIT in krb5.conf (a certificate logon still gets a TGT for the NFS krb5 homes).

SSSD_CA_DB="/etc/sssd/pki/sssd_auth_ca_db.pem"

domain_defaults() {
    AD_REALM=${AD_REALM:-${AD_DOMAIN^^}}
    if [[ -z $AD_WORKGROUP ]]; then
        AD_WORKGROUP=${AD_DOMAIN%%.*}
        AD_WORKGROUP=${AD_WORKGROUP^^}
    fi
}

domain_is_joined() {
    command -v realm >/dev/null 2>&1 && realm list --name-only 2>/dev/null | grep -qix "$AD_DOMAIN"
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
        apt_install --no-install-recommends libpam-pkcs11 krb5-pkinit
        domain_install_ca
    fi
    if [[ $SMARTCARD_ENABLE == yes ]]; then
        apt_install pcscd pcsc-tools pkg-config libpam-pkcs11 opensc libengine-pkcs11-openssl libnss3-tools
        run systemctl enable --now pcscd.socket
    fi

    domain_write_krb5
    domain_write_smb
    domain_check_dns

    if domain_is_joined; then
        logt OK domain_already_joined "$AD_DOMAIN"
    else
        run realm discover "$AD_DOMAIN" || logt WARN domain_discover_failed "$AD_DOMAIN"
        domain_join
    fi

    domain_write_sssd
    domain_write_sudoers
    if [[ $NFS_ENABLE == yes ]]; then
        # Homes come from autofs; root cannot create them on a sec=krb5 export.
        run pam-auth-update --disable mkhomedir || true
    else
        run pam-auth-update --enable mkhomedir
    fi
    if [[ $SMARTCARD_ENABLE == yes ]]; then
        run pam-auth-update --disable sss-smart-card-required --enable sss-smart-card-optional
    fi
    run systemctl enable sssd.service
    run systemctl restart sssd.service
    run sss_cache -E || true
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
    local access homedir pam_section="" cert_opts="" certmap=""
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
    if cert_logon_enabled; then
        [[ -n $SSSD_CERT_VERIFICATION ]] && cert_opts="certificate_verification = ${SSSD_CERT_VERIFICATION}"
        pam_section="
[pam]
pam_cert_auth = True
pam_p11_allowed_services = +gdm-hzncred
pam_cert_db_path = ${SSSD_CA_DB}
p11_child_timeout = 30"
        certmap="
[certmap/${AD_DOMAIN}/truesso]
matchrule = <EKU>msScLogin
maprule = (|(userPrincipal={subject_principal})(samAccountName={subject_principal.short_name}))
domains = ${AD_DOMAIN}
priority = 10"
    fi
    write_file build /etc/sssd/sssd.conf 0600 <<EOF
${MANAGED_MARK}
[sssd]
domains = ${AD_DOMAIN}
config_file_version = 2
services = nss, pam
${cert_opts}
${pam_section}

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
${certmap}
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
