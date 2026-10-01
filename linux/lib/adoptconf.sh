# shellcheck shell=bash
# Part of mode "adopt": build vdi-imagemaint.conf from what the existing image already
# uses, so an adopted image needs no hand-written configuration.
#   - no vdi-imagemaint.conf yet -> it is created from the detected values
#   - vdi-imagemaint.conf exists  -> left untouched; the detected values go to
#     vdi-imagemaint.conf.detected and the differences are shown
# Only values that are actually found are written; everything else keeps the defaults
# of conf/defaults.conf and the chosen profile.

# ini_get FILE KEY - first "key = value" (any section), value only
ini_get() {
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null | head -n1 | sed -E 's/[[:space:]]+$//' || true
}

# conf_quote VALUE - double-quoted, safe to source
conf_quote() {
    local v=$1
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    v=${v//\$/\\\$}
    v=${v//\`/\\\`}
    printf '"%s"' "$v"
}

# Detected settings, in output order: ADOPT_CFG_KEYS + ADOPT_CFG[key]=value
adopt_cfg_set() {
    [[ -n $2 ]] || return 0
    [[ -n ${ADOPT_CFG[$1]+x} ]] || ADOPT_CFG_KEYS+=("$1")
    ADOPT_CFG[$1]=$2
}

adopt_detect_config() {
    declare -gA ADOPT_CFG=()
    ADOPT_CFG_KEYS=()
    local v sssd=/etc/sssd/sssd.conf realm_info=""

    # --- profile (the only question; -y keeps the default)
    local profile=$PROFILE
    if [[ ${ASSUME_YES:-0} != 1 ]]; then
        read -r -p "$(t adopt_q_profile "$profile") " v || v=""
        [[ $v == university || $v == business ]] && profile=$v
    fi
    adopt_cfg_set PROFILE "$profile"

    # --- locale / time
    adopt_cfg_set DEFAULT_LOCALE "$(sed -n 's/^LANG=//p' /etc/default/locale 2>/dev/null | tr -d '"' || true)"
    adopt_cfg_set KEYBOARD_LAYOUT "$(sed -n 's/^XKBLAYOUT=//p' /etc/default/keyboard 2>/dev/null | tr -d '"' || true)"
    v=$(timedatectl show -p Timezone --value 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||' || true)
    adopt_cfg_set TIMEZONE "$v"

    # --- Active Directory
    command -v realm >/dev/null 2>&1 && realm_info=$(realm list 2>/dev/null || true)
    v=$(sed -n 's/^ *domain-name: //p' <<<"$realm_info" | head -n1 || true)
    [[ -n $v ]] || v=$(ini_get "$sssd" domains | cut -d, -f1)
    [[ -n $v ]] || v=$(ini_get /etc/krb5.conf default_realm | tr '[:upper:]' '[:lower:]')
    [[ -n $v ]] || v=$(ini_get /etc/samba/smb.conf realm | tr '[:upper:]' '[:lower:]')
    adopt_cfg_set AD_DOMAIN "$v"
    adopt_cfg_set AD_WORKGROUP "$(ini_get /etc/samba/smb.conf workgroup)"
    adopt_cfg_set AD_ACCESS_GROUPS "$(ini_get "$sssd" simple_allow_groups)"
    v=$(ini_get "$sssd" use_fully_qualified_names)
    [[ -n $v ]] && adopt_cfg_set SSSD_FQ_NAMES "$([[ ${v,,} == true ]] && echo true || echo false)"
    v=$(ini_get "$sssd" ldap_id_mapping)
    [[ -n $v ]] && adopt_cfg_set SSSD_ID_MAPPING "$([[ ${v,,} == false ]] && echo false || echo true)"

    # --- home directories: fstab first, then an autofs map
    local line src mnt opts
    line=$(awk '$1 !~ /^#/ && ($3 == "nfs" || $3 == "nfs4") {print $1, $2, $4; exit}' /etc/fstab 2>/dev/null || true)
    if [[ -n $line ]]; then
        read -r src mnt opts <<<"$line"
        adopt_cfg_set NFS_ENABLE yes
        adopt_cfg_set NFS_SERVER "${src%%:*}"
        adopt_cfg_set NFS_EXPORT "${src#*:}"
        adopt_cfg_set HOME_ROOT "$mnt"
        [[ $opts =~ sec=(krb5[ip]?) ]] && adopt_cfg_set NFS_SEC "${BASH_REMATCH[1]}"
    else
        line=$(grep -rhsE '^[^#].*(fstype=nfs|[[:alnum:].-]+:/)' /etc/auto.master.d /etc/auto.* 2>/dev/null |
            grep -v '^/' | head -n1 || true)
        if [[ -n $line ]]; then
            src=$(grep -oE '[[:alnum:].-]+:/[^[:space:]]*' <<<"$line" | head -n1 || true)
            src=${src%/&}
            adopt_cfg_set NFS_ENABLE yes
            adopt_cfg_set NFS_SERVER "${src%%:*}"
            adopt_cfg_set NFS_EXPORT "${src#*:}"
            [[ $line =~ sec=(krb5[ip]?) ]] && adopt_cfg_set NFS_SEC "${BASH_REMATCH[1]}"
            v=$(ini_get "$sssd" override_homedir)
            [[ $v == */%u ]] && adopt_cfg_set HOME_ROOT "${v%/%u}"
        else
            adopt_cfg_set NFS_ENABLE no
        fi
    fi

    # --- Horizon agent features and settings
    local dir custom="" agentcfg=""
    if dir=$(agent_conf_dir); then
        custom="${dir}/viewagent-custom.conf"
        agentcfg="${dir}/config"
    fi
    if [[ -n $custom ]]; then
        adopt_cfg_set HORIZON_SSO "$(ini_get "$custom" SSOEnable)"
        adopt_cfg_set SSO_USER_FORMAT "$(ini_get "$custom" SSOUserFormat)"
        v=$(ini_get "$custom" CollaborationEnable)
        adopt_cfg_set COLLAB_ENABLE "$v"
        v=$(ini_get "$custom" RunOnceScriptTimeout)
        adopt_cfg_set RUNONCE_TIMEOUT "$v"
    fi
    if [[ -n $agentcfg ]]; then
        adopt_cfg_set COLLAB_SERVER_URL "$(ini_get "$agentcfg" 'collaboration\.serverUrl')"
        adopt_cfg_set COLLAB_EMAIL "$(ini_get "$agentcfg" 'collaboration\.enableEmail')"
        adopt_cfg_set COLLAB_CONTROL_PASSING "$(ini_get "$agentcfg" 'collaboration\.enableControlPassing')"
        adopt_cfg_set COLLAB_MAX "$(ini_get "$agentcfg" 'collaboration\.maxCollabors')"
        adopt_cfg_set FIDO_VIDPID "$(ini_get "$agentcfg" 'viewusb\.IncludeVidPid')"
    fi
    if agent_installed; then
        if [[ -n $(find /usr/lib/omnissa /usr/lib/vmware -maxdepth 4 -name '*usbarbitrator*' 2>/dev/null | head -n1 || true) ]]; then
            adopt_cfg_set USB_ENABLE yes
        else
            adopt_cfg_set USB_ENABLE no
        fi
    fi

    # --- certificate logon (True SSO / smart card)
    if grep -qiE '^[[:space:]]*pam_cert_auth[[:space:]]*=[[:space:]]*true' "$sssd" 2>/dev/null; then
        if grep -q '^\[certmap/' "$sssd" 2>/dev/null || [[ -n $custom && -n $(ini_get "$custom" NetbiosDomain) ]]; then
            adopt_cfg_set TRUESSO_ENABLE yes
        fi
        pkg_installed pcscd && adopt_cfg_set SMARTCARD_ENABLE yes
        [[ -s /etc/sssd/pki/sssd_auth_ca_db.pem ]] && adopt_cfg_set CERT_CA_FILES /etc/sssd/pki/sssd_auth_ca_db.pem
    fi

    if unit_known horizonrecording.service; then adopt_cfg_set REC_ENABLE yes; fi
    return 0
}

adopt_render_config() {
    local k
    printf '# shellcheck shell=bash disable=SC2034\n'
    printf '# %s\n' "$(t adopt_config_header "$VDI_VERSION" "$(date -Is)" "$(hostname -f 2>/dev/null || hostname)")"
    printf '# %s\n\n' "$(t adopt_config_header2)"
    for k in "${ADOPT_CFG_KEYS[@]}"; do
        printf '%s=%s\n' "$k" "$(conf_quote "${ADOPT_CFG[$k]}")"
    done
}

# Create vdi-imagemaint.conf (or .detected next to an existing one), then reload it.
adopt_config() {
    logt STEP adopt_config_title
    adopt_detect_config
    local k tmp
    for k in "${ADOPT_CFG_KEYS[@]}"; do
        log INFO "  ${k}=${ADOPT_CFG[$k]}"
    done
    tmp=$(mktemp)
    adopt_render_config >"$tmp"
    if [[ ! -f $CONF_FILE ]]; then
        install -m 0640 -o root -g root "$tmp" "$CONF_FILE"
        logt OK adopt_config_created "$CONF_FILE"
    else
        install -m 0640 -o root -g root "$tmp" "${CONF_FILE}.detected"
        logt WARN adopt_config_exists "$CONF_FILE" "${CONF_FILE}.detected"
        (
            # shellcheck disable=SC1090
            . "$CONF_FILE"
            for k in "${ADOPT_CFG_KEYS[@]}"; do
                if [[ ${!k:-} != "${ADOPT_CFG[$k]}" ]]; then
                    logt WARN adopt_config_diff "$k" "${!k:-<default>}" "${ADOPT_CFG[$k]}"
                fi
            done
        )
    fi
    rm -f "$tmp"
    load_config
}
