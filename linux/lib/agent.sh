# shellcheck shell=bash
# Mode "agent": install or upgrade the Horizon Linux Agent (tarball) following
# "Install Horizon Agent on a Linux Machine" / "Upgrade Horizon Agent on a Linux Machine":
#   1. mandatory dependency packages (Debian: gnome-shell-extension-appindicator,
#      libnss3-tools; audio: pulseaudio-utils; open-vm-tools; krb5-user for SSSD join)
#   2. unpack the tarball, then the VHCI driver for USB redirection (needs the patch
#      shipped in the tarball), then install_viewagent.sh with the feature flags
#   3. viewagent-custom.conf for Instant Clone (OfflineJoinDomain=sssd, SSO, RunOnce)
# Re-running with the same archive and flags does nothing; a newer archive upgrades
# (same flags - the tarball does not keep the old feature selection); an older one is
# refused unless --force. Installed version/flags are recorded in build-state.json
# (Omnissa documents no version file for the tarball install).

RUNONCE_TARGET="/usr/local/sbin/vdi-imagemaint-runonce.sh"
AGENT_DEPENDENCIES="gnome-shell-extension-appindicator libnss3-tools pulseaudio-utils open-vm-tools krb5-user"

agent_find_archive() {
    if [[ -n $HORIZON_AGENT_ARCHIVE ]]; then
        printf '%s' "$HORIZON_AGENT_ARCHIVE"
        return 0
    fi
    find "${VDI_ROOT}/Horizon" -maxdepth 1 -type f -iname '*horizonagent-linux*.tar.gz' -printf '%f\n' 2>/dev/null |
        sort -V | tail -n1 | sed "s|^|${VDI_ROOT}/Horizon/|"
}

# Omnissa-horizonagent-linux-x86_64-YYMM-y.y.y-xxxxxxx.tar.gz -> "YYMM-y.y.y-xxxxxxx"
agent_archive_version() {
    basename "$1" | sed -nE 's/.*-([0-9]{4}-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+)\.tar\.gz$/\1/p'
}

# version_cmp A B -> prints -1, 0 or 1 (dash-separated parts compared as versions)
version_cmp() {
    [[ $1 == "$2" ]] && { echo 0; return 0; }
    if [[ $(printf '%s\n%s\n' "${1//-/.}" "${2//-/.}" | sort -V | head -n1) == "${1//-/.}" ]]; then
        echo -1
    else
        echo 1
    fi
}

# Install flags from the configuration (documented options of install_viewagent.sh).
agent_args() {
    local a="-A yes -M yes"
    a+=" -a $([[ $AUDIO_IN_ENABLE == yes ]] && echo yes || echo no)"
    a+=" -U $([[ $USB_ENABLE == yes || $FIDO_ENABLE == yes ]] && echo yes || echo no)"
    a+=" -T $([[ $TRUESSO_ENABLE == yes ]] && echo yes || echo no)"
    a+=" -m $([[ $SMARTCARD_ENABLE == yes ]] && echo yes || echo no)"
    [[ -n $HORIZON_AGENT_EXTRA_ARGS ]] && a+=" ${HORIZON_AGENT_EXTRA_ARGS}"
    printf '%s' "$a"
}

agent_installed() {
    agent_service >/dev/null 2>&1 || [[ -x /usr/lib/omnissa/viewagent/bin/uninstall_viewagent.sh ]]
}

mode_agent() {
    logt STEP step_agent
    local archive version args installed_ver installed_args action
    archive=$(agent_find_archive)
    if [[ -z $archive || ! -f $archive ]]; then
        logt ERR agent_archive_missing "${VDI_ROOT}/Horizon"
        exit 1
    fi
    version=$(agent_archive_version "$archive")
    [[ -n $version ]] || version="unknown-$(basename "$archive")"
    args=$(agent_args)
    installed_ver=$(state_get build '.agent.version // empty')
    installed_args=$(state_get build '.agent.args // empty')

    if ! agent_installed; then
        action=install
    elif [[ -z $installed_ver ]]; then
        action=upgrade
        logt WARN agent_version_unknown
    else
        case $(version_cmp "$installed_ver" "$version") in
            0) if [[ $installed_args == "$args" && ${FORCE:-0} != 1 ]]; then action=skip; else action=reconfigure; fi ;;
            -1) action=upgrade ;;
            1)
                if [[ ${FORCE:-0} == 1 ]]; then
                    action=downgrade
                else
                    logt ERR agent_downgrade "$installed_ver" "$version"
                    exit 1
                fi
                ;;
        esac
    fi

    domain_is_joined || logt WARN agent_not_joined "$AD_DOMAIN"
    if [[ $action == skip ]]; then
        logt OK agent_up_to_date "$installed_ver" "$args"
        # Configuration and per-clone script are still enforced (idempotent).
        agent_install_runonce
        agent_configure
        return 0
    fi
    logt INFO agent_action "$action" "${installed_ver:--}" "$version" "$args"

    # Upgrade prerequisite: BlastServer must not run (no active session).
    if [[ $action != install ]] && grep -sqx BlastServer /proc/[0-9]*/comm; then
        logt ERR agent_blast_running
        exit 1
    fi

    # shellcheck disable=SC2086  # package list is word-split on purpose
    apt_install $AGENT_DEPENDENCIES
    [[ $FIDO_ENABLE == yes ]] && apt_install --no-install-recommends fido2-tools libfido2-1

    local work installer dir
    work=$(mktemp -d /tmp/vdi-agent.XXXXXX)
    tar -xzf "$archive" -C "$work"
    installer=$(find "$work" -name install_viewagent.sh -print -quit)
    if [[ -z $installer ]]; then
        rm -rf "$work"
        logt ERR agent_installer_missing "$archive"
        exit 1
    fi
    dir=$(dirname "$installer")

    # Documented order for the tarball: unpack -> VHCI driver -> agent with -U yes.
    if [[ $USB_ENABLE == yes || $FIDO_ENABLE == yes ]]; then
        vhci_install "${dir}/resources/vhci/patch/vhci.patch" || {
            rm -rf "$work"
            exit 1
        }
    fi

    # shellcheck disable=SC2086  # agent arguments are word-split on purpose
    (cd "$dir" && run ./install_viewagent.sh $args) || {
        rm -rf "$work"
        logt ERR agent_install_failed
        exit 1
    }
    rm -rf "$work"
    state_update build '.agent = {version: $v, args: $a, archive: $f, at: $d, tool: $t}' \
        --arg v "$version" --arg a "$args" --arg f "$(basename "$archive")" \
        --arg d "$(date -Is)" --arg t "$VDI_VERSION"

    agent_install_runonce
    agent_configure
    logt OK agent_done "$version"
    mark_reboot_required
    logt WARN reboot_needed
}

agent_install_runonce() {
    if [[ -f $RUNONCE_TARGET ]] && cmp -s "${VDI_ROOT}/files/runonce.sh" "$RUNONCE_TARGET"; then
        return 0
    fi
    file_track build "$RUNONCE_TARGET"
    install -m 0700 -o root -g root "${VDI_ROOT}/files/runonce.sh" "$RUNONCE_TARGET"
    logt OK file_written "$RUNONCE_TARGET"
}

agent_configure() {
    local dir conf kv oj
    if ! dir=$(agent_conf_dir); then
        logt ERR agent_conf_missing
        exit 1
    fi
    conf="${dir}/viewagent-custom.conf"
    domain_defaults

    export KV_SECTION=build
    if oj=$(adopt_offline_join); then
        set_kv "$conf" OfflineJoinDomain "$oj"
    else
        logt INFO agent_offlinejoin_kept "${ADOPT_PREVIEW_JOIN:-$(state_get build '.adopted.join')}"
    fi
    set_kv "$conf" RunOnceScript "$RUNONCE_TARGET"
    set_kv "$conf" RunOnceScriptTimeout "$RUNONCE_TIMEOUT"
    set_kv "$conf" SSOEnable "$HORIZON_SSO"
    set_kv "$conf" SSOUserFormat "$SSO_USER_FORMAT"
    set_kv "$conf" SSODesktopType UseMATE
    set_kv "$conf" KeyboardLayoutSync true
    # True SSO with SSSD on Debian: "NetbiosDomain = MYDOMAIN"
    [[ $TRUESSO_ENABLE == yes ]] && set_kv "$conf" NetbiosDomain "$AD_WORKGROUP"
    # FIDO2 keys go through USB redirection (KB 6001193): allow the key's VID/PID.
    if [[ $FIDO_ENABLE == yes && -n $FIDO_VIDPID ]]; then
        set_kv "${dir}/config" viewusb.IncludeVidPid "$FIDO_VIDPID" " = "
    fi
    for kv in $AGENT_EXTRA_SETTINGS; do
        [[ $kv == *=* ]] || continue
        set_kv "$conf" "${kv%%=*}" "${kv#*=}"
    done
    unset KV_SECTION
    [[ ${PREVIEW:-0} == 1 ]] && return 0
    chmod 0644 "$conf"
    logt OK agent_configured "$conf"
}
