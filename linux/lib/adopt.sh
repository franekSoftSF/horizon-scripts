# shellcheck shell=bash
# Mode "adopt": take over an EXISTING golden image without rebuilding it.
#   1. detect what is there (desktop / display manager, domain join method, home
#      directories, Horizon agent, RunOnceScript) and write vdi-imagemaint.conf from it
#      (lib/adoptconf.sh) - no hand-written configuration needed
#   2. preview what prepare / domain / nfs / agent configuration would change
#      (diff of every file, nothing written)
#   3. mark the chosen steps as "adopted": run_step never runs them again (only --force),
#      record the installed agent version without reinstalling it, keep an existing
#      RunOnceScript (chained from the tool's per-clone script), and remember the join
#      method so the agent configuration and the checks respect it.
# Afterwards optimize / collab / recording / apps / check / seal / update work as usual.

# ask_yes QUESTION DEFAULT(yes|no) - -y takes the default
ask_yes() {
    local q=$1 def=$2 answer hint="[y/N]"
    [[ $def == yes ]] && hint="[Y/n]"
    [[ $VDI_LANG == pl-PL ]] && { [[ $def == yes ]] && hint="[T/n]" || hint="[t/N]"; }
    if [[ ${ASSUME_YES:-0} == 1 ]]; then
        [[ $def == yes ]]
        return
    fi
    read -r -p "${q} ${hint} " answer || answer=""
    [[ -z $answer ]] && answer=$def
    [[ ${answer,,} =~ ^(y|yes|t|tak)$ ]]
}

adopt_detect_desktop() {
    local sessions dm
    sessions=$(find /usr/share/xsessions -maxdepth 1 -name '*.desktop' -printf '%f ' 2>/dev/null | sed 's/\.desktop//g' || true)
    dm=$(basename "$(cat /etc/X11/default-display-manager 2>/dev/null || echo none)")
    [[ -n $dm ]] || dm=none
    ADOPT_DM=$dm
    ADOPT_SESSIONS=$sessions
    logt INFO adopt_desktop "${sessions:-none}" "$dm" "$(systemctl get-default 2>/dev/null || echo ?)"
}

# Sets ADOPT_JOIN: sssd | winbind | none
adopt_detect_domain() {
    local realm_info=""
    ADOPT_JOIN=none
    if command -v realm >/dev/null 2>&1; then
        realm_info=$(realm list 2>/dev/null || true)
    fi
    if grep -q 'client-software: sssd' <<<"$realm_info" || systemctl is-active --quiet sssd.service 2>/dev/null; then
        ADOPT_JOIN=sssd
    fi
    if grep -q 'client-software: winbind' <<<"$realm_info" || systemctl is-active --quiet winbind.service 2>/dev/null; then
        ADOPT_JOIN=winbind
    fi
    logt INFO adopt_domain "$ADOPT_JOIN" "$(sed -n 's/^ *realm-name: //p' <<<"$realm_info" | head -n1 || true)" \
        "$([[ -s /etc/krb5.keytab ]] && echo yes || echo no)"
}

# Sets ADOPT_HOMES: fstab | autofs | local
adopt_detect_homes() {
    ADOPT_HOMES=local
    if grep -Eq '^[^#]+[[:space:]]nfs4?[[:space:]]' /etc/fstab 2>/dev/null; then
        ADOPT_HOMES=fstab
    elif grep -rqsE 'fstype=nfs|:/' /etc/auto.master /etc/auto.master.d /etc/auto.* 2>/dev/null; then
        ADOPT_HOMES=autofs
    fi
    logt INFO adopt_homes "$ADOPT_HOMES" \
        "$(sed -nE 's/^[[:space:]]*(override_homedir|fallback_homedir)[[:space:]]*=[[:space:]]*//p' /etc/sssd/sssd.conf 2>/dev/null | head -n1 || true)"
}

# Best effort only: Omnissa documents no version file for the tarball install.
# 1. a version string in the installed agent's small text files
# 2. the newest installer next to the tool or in HORIZON_EXTRA_DIRS (e.g. /install) -
#    usually the one that was installed; the user confirms it
adopt_guess_agent_version() {
    local d v=""
    for d in /usr/lib/omnissa/viewagent /usr/lib/vmware/viewagent; do
        [[ -d $d ]] || continue
        v=$(find "$d" -maxdepth 3 -type f \( -iname '*version*' -o -iname '*build*' -o -iname '*.txt' \) -size -64k \
            -exec grep -hoE '\b2[0-9]{3}-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\b' {} + 2>/dev/null | sort -V | tail -n1 || true)
        break
    done
    if [[ -z $v ]]; then
        d=$(agent_find_archive)
        [[ -n $d ]] && v=$(agent_archive_version "$d")
    fi
    printf '%s' "$v"
}

adopt_detect_agent() {
    local dir conf="" usb=no
    ADOPT_AGENT=no
    ADOPT_RUNONCE=""
    ADOPT_OFFLINEJOIN=""
    if agent_installed; then
        ADOPT_AGENT=yes
        if dir=$(agent_conf_dir); then
            conf="${dir}/viewagent-custom.conf"
            ADOPT_OFFLINEJOIN=$(sed -nE 's/^[[:space:]]*OfflineJoinDomain[[:space:]]*=[[:space:]]*//p' "$conf" 2>/dev/null | tail -n1 || true)
            ADOPT_RUNONCE=$(sed -nE 's/^[[:space:]]*RunOnceScript[[:space:]]*=[[:space:]]*//p' "$conf" 2>/dev/null | tail -n1 || true)
        fi
        [[ -n $(find /usr/lib/omnissa /usr/lib/vmware -maxdepth 4 -name '*usbarbitrator*' 2>/dev/null | head -n1 || true) ]] && usb=yes
    fi
    logt INFO adopt_agent "$ADOPT_AGENT" "${conf:-?}" "${ADOPT_OFFLINEJOIN:-<unset>}" "${ADOPT_RUNONCE:-<unset>}" "$usb"
}

adopt_preview() {
    logt STEP adopt_preview_title
    (
        PREVIEW=1
        domain_defaults
        logt INFO adopt_preview_step prepare
        [[ $ADOPT_DM == lightdm ]] || logt WARN adopt_preview_dm "$ADOPT_DM"
        [[ " $ADOPT_SESSIONS " == *" mate "* ]] || logt WARN adopt_preview_mate
        local cur_lang cur_tz
        cur_lang=$(sed -n 's/^LANG=//p' /etc/default/locale 2>/dev/null | tr -d '"' || true)
        cur_tz=$(timedatectl show -p Timezone --value 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||' || true)
        [[ $cur_lang == "$DEFAULT_LOCALE" ]] || logt WARN adopt_preview_locale "${cur_lang:-?}" "$DEFAULT_LOCALE"
        [[ $cur_tz == "$TIMEZONE" ]] || logt WARN adopt_preview_tz "${cur_tz:-?}" "$TIMEZONE"
        printf '%s\n[Time]\nNTP=%s\n' "$MANAGED_MARK" "${NTP_SERVERS:-$AD_DOMAIN}" |
            write_file build /etc/systemd/timesyncd.conf.d/50-vdi-imagemaint.conf 0644

        logt INFO adopt_preview_step domain
        domain_write_krb5
        domain_write_smb
        domain_write_sssd

        if [[ $NFS_ENABLE == yes ]]; then
            logt INFO adopt_preview_step nfs
            nfs_write_files
        fi

        if [[ $ADOPT_AGENT == yes ]]; then
            logt INFO adopt_preview_step agent
            # Show the agent configuration as it will be once the domain step is kept.
            # shellcheck disable=SC2030  # preview-only, scoped to this subshell on purpose
            [[ $ADOPT_JOIN != none && $ADOPT_JOIN != sssd ]] && ADOPT_PREVIEW_JOIN=$ADOPT_JOIN
            agent_configure
        fi
    )
}

mode_adopt() {
    logt STEP step_adopt
    if is_sealed; then
        logt ERR adopt_sealed
        exit 1
    fi
    os_check || logt WARN adopt_os_untested
    adopt_detect_desktop
    adopt_detect_domain
    adopt_detect_homes
    adopt_detect_agent
    adopt_config
    adopt_preview

    logt STEP adopt_decide_title
    local -a adopted=()
    if ask_yes "$(t adopt_q_step prepare "$ADOPT_DM")" yes; then adopted+=(prepare); fi
    if [[ $ADOPT_JOIN != none ]] && ask_yes "$(t adopt_q_step domain "$ADOPT_JOIN")" yes; then adopted+=(domain); fi
    if [[ $ADOPT_HOMES != local || $NFS_ENABLE != yes ]] && ask_yes "$(t adopt_q_step nfs "$ADOPT_HOMES")" yes; then
        adopted+=(nfs)
    fi

    local m fp
    fp=$(config_fingerprint)
    for m in "${adopted[@]}"; do
        state_update build '.steps[$m] = {version: $v, config: $c, at: $d, adopted: true}' \
            --arg m "$m" --arg v "$VDI_VERSION" --arg c "$fp" --arg d "$(date -Is)"
        logt OK adopt_step_marked "$m"
    done
    state_update build '.adopted = {at: $d, tool: $t, join: $j, homes: $h, displayManager: $dm, steps: $s}' \
        --arg d "$(date -Is)" --arg t "$VDI_VERSION" --arg j "$ADOPT_JOIN" --arg h "$ADOPT_HOMES" \
        --arg dm "$ADOPT_DM" --argjson s "$(printf '%s\n' "${adopted[@]}" | jq -R . | jq -sc 'map(select(length > 0))')"

    adopt_agent
    # Same Kerberos/SSSD safety net as a built image (conf.d + drop-ins, sssd.conf untouched);
    # rolled back automatically when SSSD does not accept it.
    if [[ $ADOPT_JOIN == sssd ]] && ask_yes "$(t adopt_q_kerberos)" yes; then
        kerberos_harden || true
    fi
    logt OK adopt_done "${adopted[*]:-none}"
}

adopt_agent() {
    [[ $ADOPT_AGENT == yes ]] || return 0
    adopt_runonce
    local guess version args
    if [[ -n $(state_get build '.agent.version // empty') ]]; then
        logt OK adopt_agent_known "$(state_get build '.agent.version')"
        return 0
    fi
    guess=${ADOPT_AGENT_VERSION:-$(adopt_guess_agent_version)}
    version=$guess
    if [[ ${ASSUME_YES:-0} != 1 ]]; then
        read -r -p "$(t adopt_q_agent_version "${guess:-?}") " version || version=""
        version=${version:-$guess}
    fi
    if [[ ! $version =~ ^[0-9]{4}-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
        logt WARN adopt_agent_version_unknown
        return 0
    fi
    args=$(agent_args)
    if ! ask_yes "$(t adopt_q_agent_args "$args")" no; then
        args="adopted-unknown"
    fi
    state_update build '.agent = {version: $v, args: $a, archive: "adopted", at: $d, tool: $t}' \
        --arg v "$version" --arg a "$args" --arg d "$(date -Is)" --arg t "$VDI_VERSION"
    logt OK adopt_agent_recorded "$version" "$args"
}

# The tool's per-clone script must run on every clone: seal removes the SSH host keys
# and relies on it to create new ones. An existing RunOnceScript (e.g. winbind rejoin)
# is kept and chained through /etc/vdi-imagemaint/runonce.local.
adopt_runonce() {
    local dir conf
    dir=$(agent_conf_dir) || return 0
    conf="${dir}/viewagent-custom.conf"
    if [[ -n $ADOPT_RUNONCE && $ADOPT_RUNONCE != "$RUNONCE_TARGET" && -x $ADOPT_RUNONCE ]]; then
        printf '#!/bin/sh\n%s\n# RunOnceScript of the adopted image, chained by the VDI-ImageMaint per-clone script.\nexec %q\n' \
            "$MANAGED_MARK" "$ADOPT_RUNONCE" | write_file build /etc/vdi-imagemaint/runonce.local 0700
        logt OK adopt_runonce_chained "$ADOPT_RUNONCE"
    fi
    agent_install_runonce
    KV_SECTION=build set_kv "$conf" RunOnceScript "$RUNONCE_TARGET"
    KV_SECTION=build set_kv "$conf" RunOnceScriptTimeout "$RUNONCE_TIMEOUT"
    logt OK adopt_runonce_set "$RUNONCE_TARGET" "$conf"
}

# OfflineJoinDomain value for agent_configure: sssd unless an adopted image joined differently.
adopt_offline_join() {
    # shellcheck disable=SC2031  # set only inside the adopt preview subshell
    local join=${ADOPT_PREVIEW_JOIN:-}
    if [[ -n $join ]]; then
        return 1
    fi
    join=$(state_get build '.adopted.join // empty')
    if step_adopted domain && [[ -n $join && $join != sssd ]]; then
        return 1
    fi
    printf 'sssd'
}
