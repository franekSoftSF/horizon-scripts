# shellcheck shell=bash
# Mode "agent": install/upgrade the Horizon Linux Agent and configure it for
# Instant Clone: OfflineJoinDomain=sssd (the agent clones the golden image's SSSD
# join per clone - run mode "domain" first) and a per-clone RunOnce script.
# Agent version must match the Connection Server / vCenter backend.

RUNONCE_TARGET="/usr/local/sbin/vdi-imagemaint-runonce.sh"

agent_find_archive() {
    if [[ -n $HORIZON_AGENT_ARCHIVE ]]; then
        printf '%s' "$HORIZON_AGENT_ARCHIVE"
        return 0
    fi
    find "${VDI_ROOT}/Horizon" -maxdepth 1 -type f -iname '*linux*.tar.gz' -printf '%f\n' 2>/dev/null |
        sort -V | tail -n1 | sed "s|^|${VDI_ROOT}/Horizon/|"
}

mode_agent() {
    logt STEP step_agent
    local archive work installer
    archive=$(agent_find_archive)
    if [[ -z $archive || ! -f $archive ]]; then
        logt ERR agent_archive_missing "${VDI_ROOT}/Horizon"
        exit 1
    fi

    local args=$HORIZON_AGENT_ARGS
    [[ $TRUESSO_ENABLE == yes ]] && args+=" ${HORIZON_AGENT_ARGS_TRUESSO}"
    [[ $SMARTCARD_ENABLE == yes ]] && args+=" ${HORIZON_AGENT_ARGS_SMARTCARD}"
    [[ $FIDO_ENABLE == yes ]] && args+=" ${HORIZON_AGENT_ARGS_FIDO}"
    domain_is_joined || logt WARN agent_not_joined "$AD_DOMAIN"
    logt INFO agent_installing "$(basename "$archive")" "$args"
    work=$(mktemp -d /tmp/vdi-agent.XXXXXX)
    tar -xzf "$archive" -C "$work"
    installer=$(find "$work" -name install_viewagent.sh -print -quit)
    if [[ -z $installer ]]; then
        rm -rf "$work"
        logt ERR agent_installer_missing "$archive"
        exit 1
    fi
    # shellcheck disable=SC2086  # agent arguments are word-split on purpose
    (cd "$(dirname "$installer")" && run ./install_viewagent.sh $args) || {
        rm -rf "$work"
        logt ERR agent_install_failed
        exit 1
    }
    rm -rf "$work"

    agent_install_runonce
    agent_configure
    if [[ $FIDO_ENABLE == yes ]]; then
        # fido2-token for the "fido" probe on clones (a sealed image cannot install it later)
        apt_install --no-install-recommends fido2-tools
    fi
    logt OK agent_done
    logt WARN reboot_needed
}

agent_install_runonce() {
    file_track build "$RUNONCE_TARGET"
    install -m 0700 -o root -g root "${VDI_ROOT}/files/runonce.sh" "$RUNONCE_TARGET"
    logt OK file_written "$RUNONCE_TARGET"
}

agent_configure() {
    local dir conf kv
    if ! dir=$(agent_conf_dir); then
        logt ERR agent_conf_missing
        exit 1
    fi
    conf="${dir}/viewagent-custom.conf"

    export KV_SECTION=build
    set_kv "$conf" OfflineJoinDomain sssd
    set_kv "$conf" RunOnceScript "$RUNONCE_TARGET"
    set_kv "$conf" RunOnceScriptTimeout "$RUNONCE_TIMEOUT"
    set_kv "$conf" SSOEnable "$HORIZON_SSO"
    set_kv "$conf" SSOUserFormat "$SSO_USER_FORMAT"
    set_kv "$conf" KeyboardLayoutSync true
    for kv in $AGENT_EXTRA_SETTINGS; do
        [[ $kv == *=* ]] || continue
        set_kv "$conf" "${kv%%=*}" "${kv#*=}"
    done
    unset KV_SECTION
    chmod 0644 "$conf"
    logt OK agent_configured "$conf"
}
