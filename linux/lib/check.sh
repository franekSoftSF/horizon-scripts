# shellcheck shell=bash
# Mode "check": read-only readiness checks before Seal / snapshot.
# Returns 0 when there is no ERR result (WARN does not block Seal).

CHECK_ERR=0
CHECK_WARN=0

check_result() {
    local level=$1 id=$2
    shift 2
    case $level in
        ERR) ((CHECK_ERR += 1)) ;;
        WARN) ((CHECK_WARN += 1)) ;;
    esac
    log "$level" "[${id}] $(t "$@")"
}

mode_check() {
    logt STEP step_check
    CHECK_ERR=0
    CHECK_WARN=0
    domain_defaults

    local k example=""
    for k in AD_DOMAIN AD_JOIN_USER AD_COMPUTER_OU NFS_SERVER HORIZON_CS_FQDN COLLAB_SERVER_URL REC_SERVER_URL REC_USERNAME; do
        [[ ${!k:-} == *example* ]] && example+=" $k"
    done
    if [[ -n $example ]]; then
        if [[ -f ${CONF_FILE}.detected ]]; then
            check_result WARN L00 chk_conf_example_detected "$example" "${CONF_FILE}.detected"
        else
            check_result WARN L00 chk_conf_example "$example" "$CONF_FILE"
        fi
    fi

    if os_check 2>/dev/null; then check_result OK L01 chk_os_ok; else check_result WARN L01 chk_os_bad; fi

    if reboot_pending; then
        check_result ERR L02 chk_reboot_pending "$(uname -r)" "$(newest_kernel)"
    else
        check_result OK L02 chk_reboot_none
    fi

    if [[ -n $(dpkg --audit 2>/dev/null) ]]; then
        check_result ERR L03 chk_dpkg_broken
    else
        check_result OK L03 chk_dpkg_ok
    fi

    local svc dir conf
    if svc=$(agent_service) && [[ $(unit_enabled_state "$svc") == enabled ]]; then
        check_result OK L04 chk_agent_ok "$svc"
    else
        check_result ERR L04 chk_agent_missing
    fi

    if dir=$(agent_conf_dir) && conf="${dir}/viewagent-custom.conf" && [[ -f $conf ]]; then
        local want_oj
        want_oj=$(adopt_offline_join || true)
        if [[ -z $want_oj ]] && grep -Eqi '^[[:space:]]*OfflineJoinDomain[[:space:]]*=[[:space:]]*[a-z]+' "$conf"; then
            check_result OK L05 chk_offlinejoin_adopted "$(state_get build '.adopted.join')"
        elif grep -Eqi '^[[:space:]]*OfflineJoinDomain[[:space:]]*=[[:space:]]*sssd' "$conf"; then
            check_result OK L05 chk_offlinejoin_ok
        else
            check_result ERR L05 chk_offlinejoin_bad "$conf"
        fi
        local ro
        ro=$(sed -nE 's/^[[:space:]]*RunOnceScript[[:space:]]*=[[:space:]]*//p' "$conf" | tail -n1)
        if [[ -n $ro && -x $ro ]]; then
            check_result OK L06 chk_runonce_ok "$ro"
        else
            check_result ERR L06 chk_runonce_bad "${ro:-<unset>}"
        fi
    else
        check_result ERR L05 chk_agent_conf_missing
    fi

    local join_svc=sssd.service
    [[ $(state_get build '.adopted.join // empty') == winbind ]] && step_adopted domain && join_svc=winbind.service
    if [[ -s /etc/krb5.keytab ]] && { domain_is_joined || step_adopted domain; }; then
        check_result OK L07 chk_joined_ok "$(krb_domain || echo "$AD_DOMAIN")"
    else
        check_result ERR L07 chk_joined_bad "$AD_DOMAIN"
    fi

    if systemctl is-active --quiet "$join_svc"; then
        check_result OK L08 chk_join_service_ok "$join_svc"
    else
        check_result ERR L08 chk_join_service_bad "$join_svc"
    fi

    if kerberos_applies; then
        local kdom
        kdom=$(krb_domain || echo "?")
        local krc=0
        kerberos_testjoin || krc=$?
        case $krc in
            0) check_result OK L24 chk_testjoin_ok "$kdom" ;;
            1) check_result ERR L24 chk_testjoin_bad "$kdom" ;;
            3) check_result WARN L24 chk_testjoin_timeout "$kdom" "$KRB_ADCLI_TIMEOUT" ;;
            *) check_result WARN L24 chk_testjoin_unknown "$kdom" ;;
        esac
        if [[ -f $KRB_SSSD_SNIPPET ]]; then
            check_result OK L25 chk_krb_hardened
        else
            check_result WARN L25 chk_krb_not_hardened
        fi
    fi

    if cert_logon_enabled; then
        if [[ -s $SSSD_CA_DB ]] && grep -q '^pam_cert_auth = True' /etc/sssd/sssd.conf 2>/dev/null &&
            [[ $(unit_enabled_state pcscd.socket) == enabled ]]; then
            check_result OK L18 chk_cert_ok
        else
            check_result ERR L18 chk_cert_bad
        fi
    fi
    if [[ $FIDO_ENABLE == yes ]]; then
        if command -v fido2-token >/dev/null 2>&1; then
            check_result OK L19 chk_fido_ok
        else
            check_result WARN L19 chk_fido_bad
        fi
    fi

    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; then
        check_result OK L09 chk_time_ok
    else
        check_result WARN L09 chk_time_bad
    fi

    if [[ -n $(dig +short -t SRV "_ldap._tcp.${AD_DOMAIN}" 2>/dev/null) ]]; then
        check_result OK L10 chk_dns_ok "$AD_DOMAIN"
    else
        check_result WARN L10 dns_srv_missing "_ldap._tcp.${AD_DOMAIN}"
    fi

    local dm
    dm=$(basename "$(cat /etc/X11/default-display-manager 2>/dev/null || echo none)")
    if [[ ($dm == gdm3 || $dm == lightdm) && -f /usr/share/xsessions/mate.desktop ]]; then
        check_result OK L11 chk_desktop_ok "$dm"
    elif step_adopted prepare && [[ -s /etc/X11/default-display-manager ]] &&
        [[ -n $(find /usr/share/xsessions -maxdepth 1 -name '*.desktop' 2>/dev/null | head -n1) ]]; then
        check_result WARN L11 chk_desktop_adopted "$(basename "$(cat /etc/X11/default-display-manager)")"
    else
        check_result ERR L11 chk_desktop_bad
    fi

    if step_adopted nfs; then
        check_result OK L12 chk_nfs_adopted "$(state_get build '.adopted.homes // empty')"
    elif [[ $NFS_ENABLE == yes ]]; then
        if [[ $(unit_enabled_state autofs.service) == enabled && -f /etc/auto.vdi-home ]] &&
            grep -q "^Domain = ${NFS_IDMAP_DOMAIN:-$AD_DOMAIN}\$" /etc/idmapd.conf 2>/dev/null &&
            [[ -f $NFS_SSSD_SNIPPET ]]; then
            check_result OK L12 chk_nfs_ok "$HOME_ROOT"
        else
            check_result ERR L12 chk_nfs_bad
        fi
    fi

    if systemctl is-active --quiet open-vm-tools.service; then
        check_result OK L13 chk_vmtools_ok
    else
        check_result ERR L13 chk_vmtools_bad
    fi

    local held
    held=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
    [[ -n $held ]] && check_result INFO L14 chk_held "$held"

    local users
    users=$(awk -F: '$3 >= 1000 && $3 < 60000 {printf "%s ", $1}' /etc/passwd)
    if [[ -n $users ]]; then
        check_result WARN L15 chk_local_users "$users"
    fi

    local free_mb
    free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if ((free_mb < 2048)); then
        check_result WARN L16 chk_disk_low "$free_mb"
    else
        check_result OK L16 chk_disk_ok "$free_mb"
    fi

    if [[ -s $(state_file optimize) ]]; then
        check_result OK L17 chk_optimized
    else
        check_result WARN L17 chk_not_optimized
    fi

    local pkg missing=""
    for pkg in $AGENT_DEPENDENCIES; do pkg_installed "$pkg" || missing+=" $pkg"; done
    if [[ -z $missing ]]; then
        check_result OK L20 chk_deps_ok
    else
        # The documented dependencies are checked by the agent INSTALLER; an agent that is
        # already installed runs without them - they are needed again for the next upgrade.
        if agent_installed; then
            check_result WARN L20 chk_deps_missing_installed "$missing"
        else
            check_result ERR L20 chk_deps_missing "$missing"
        fi
    fi

    if [[ $USB_ENABLE == yes || $FIDO_ENABLE == yes ]]; then
        local k
        k=$(newest_kernel)
        if vhci_installed_for "$(uname -r)" && { [[ -z $k ]] || vhci_installed_for "$k"; }; then
            check_result OK L21 chk_vhci_ok "$(uname -r)"
        else
            check_result ERR L21 chk_vhci_bad "${k:-$(uname -r)}"
        fi
    fi

    if [[ $REC_ENABLE == yes ]]; then
        if [[ $(unit_enabled_state "$REC_SERVICE") == enabled ]]; then
            check_result OK L22 chk_rec_ok
        else
            check_result ERR L22 chk_rec_bad
        fi
    fi

    local cs
    for cs in $HORIZON_CS_FQDN; do
        if [[ $cs == *example* ]]; then
            check_result WARN L23 chk_cs_example "$cs"
        elif getent hosts "$cs" >/dev/null; then
            check_result OK L23 chk_cs_ok "$cs"
        else
            check_result ERR L23 chk_cs_bad "$cs"
        fi
    done

    logt STEP chk_summary "$CHECK_ERR" "$CHECK_WARN"
    ((CHECK_ERR == 0))
}

mode_status() {
    local f
    logt STEP step_status
    log INFO "$(t status_line "$VDI_VERSION" "$PROFILE" "$CONF_FILE")"
    for f in build optimize seal; do
        if [[ -s $(state_file "$f") ]]; then
            log INFO "${f}: $(jq -c '{units: (.units|length), files: (.files|length)} + (del(.units,.files))' "$(state_file "$f")")"
        fi
    done
    if [[ -s $(state_file build) ]]; then
        local line
        while IFS= read -r line; do
            log INFO "$line"
        done < <(jq -r '(.steps // {} | to_entries[] | "step \(.key): \(.value.version) \(.value.at)"),
            (if .agent then "agent: \(.agent.version) [\(.agent.args)] \(.agent.at)" else empty end),
            (if .vhci then "vhci: \(.vhci.version) (kernel \(.vhci.kernel))" else empty end),
            (if .recording then "recording: \(.recording.version) \(.recording.server)" else empty end)' \
            "$(state_file build)")
    fi
    if is_sealed; then logt WARN status_sealed; else logt INFO status_unsealed; fi
}
