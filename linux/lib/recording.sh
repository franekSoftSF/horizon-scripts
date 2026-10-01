# shellcheck shell=bash
# Mode "recording": Horizon Recording Agent for Linux (tarball), as in "Using Horizon
# Recording" -> "Run the Linux Tarball Installer for Horizon Recording Agent":
#   prerequisites  Horizon Agent installed first; Horizon 8 2306+; server port 9443
#   install        sudo ./install.sh -u https://<server>:9443 -n <user> -p <password> [-s <thumbprint>] -t
#                  (-t for instant-clone / full-clone pools: clones get a configured agent)
#   upgrade        run the new tarball installer, then restart (no active recordings)
#   service        horizonrecording.service; pairing token /etc/omnissa/horizonrecording/pairingdata.json
# The password is asked for (or taken from VDI_REC_PASSWORD) and never written to the
# configuration or the log.

REC_SERVICE="horizonrecording.service"

recording_find_archive() {
    if [[ -n $REC_ARCHIVE ]]; then
        printf '%s' "$REC_ARCHIVE"
        return 0
    fi
    find "${VDI_ROOT}/Horizon" -maxdepth 1 -type f -iname 'Horizon.Recording.Linux.Agent-*.tar.gz' -printf '%f\n' 2>/dev/null |
        sort -V | tail -n1 | sed "s|^|${VDI_ROOT}/Horizon/|"
}

# Horizon.Recording.Linux.Agent-x.x.x.x.tar.gz -> x.x.x.x
recording_archive_version() {
    basename "$1" | sed -nE 's/^Horizon\.Recording\.Linux\.Agent-([0-9.]+)\.tar\.gz$/\1/p'
}

# rec_redact SECRET - copy stdin to stdout with every literal occurrence of SECRET masked
rec_redact() {
    local secret=$1 line
    while IFS= read -r line || [[ -n $line ]]; do
        printf '%s\n' "${line//"$secret"/********}"
    done
}

mode_recording() {
    logt STEP step_recording
    if [[ $REC_ENABLE != yes ]]; then
        logt INFO rec_disabled
        return 0
    fi
    require_conf REC_SERVER_URL REC_USERNAME
    if [[ ! $REC_SERVER_URL =~ ^https://[^[:space:]/]+:9443/?$ ]]; then
        logt ERR rec_url_invalid "$REC_SERVER_URL"
        exit 2
    fi
    if ! agent_installed; then
        logt ERR rec_needs_agent
        exit 1
    fi

    local archive version installed
    archive=$(recording_find_archive)
    if [[ -z $archive || ! -f $archive ]]; then
        logt ERR rec_archive_missing "${VDI_ROOT}/Horizon"
        exit 1
    fi
    version=$(recording_archive_version "$archive")
    [[ -n $version ]] || version="unknown-$(basename "$archive")"
    installed=$(state_get build '.recording.version // empty')

    if [[ -n $installed ]] && unit_known "$REC_SERVICE" && [[ ${FORCE:-0} != 1 ]]; then
        case $(version_cmp "$installed" "$version") in
            0)
                logt OK rec_up_to_date "$installed"
                return 0
                ;;
            1)
                logt ERR rec_downgrade "$installed" "$version"
                exit 1
                ;;
        esac
    fi
    logt INFO rec_installing "${installed:--}" "$version" "$REC_SERVER_URL"

    local password=${VDI_REC_PASSWORD:-}
    if [[ -z $password ]]; then
        read -r -s -p "$(t rec_password_prompt "$REC_USERNAME") " password || true
        echo >&2
    fi
    if [[ -z $password ]]; then
        logt ERR rec_password_missing
        exit 2
    fi

    local work installer
    local -a args=(-u "$REC_SERVER_URL" -n "$REC_USERNAME" -p "$password" -t)
    [[ -n $REC_THUMBPRINT ]] && args+=(-s "$REC_THUMBPRINT")
    work=$(mktemp -d /tmp/vdi-rec.XXXXXX)
    tar -xzf "$archive" -C "$work"
    installer=$(find "$work" -name install.sh -print -quit)
    if [[ -z $installer ]]; then
        rm -rf "$work"
        logt ERR rec_installer_missing "$archive"
        exit 1
    fi
    # Not through run(): the command line carries the password. Log a redacted copy.
    log INFO "\$ ./install.sh -u ${REC_SERVER_URL} -n ${REC_USERNAME} -p ******** -t${REC_THUMBPRINT:+ -s ${REC_THUMBPRINT}}"
    if ! (cd "$(dirname "$installer")" && ./install.sh "${args[@]}") 2>&1 | rec_redact "$password" |
        { if [[ -w $LOG_DIR ]]; then tee -a "$LOG_FILE"; else cat; fi; }; then
        rm -rf "$work"
        logt ERR rec_install_failed
        exit 1
    fi
    rm -rf "$work"
    unset password

    state_update build '.recording = {version: $v, server: $s, at: $d, tool: $t}' \
        --arg v "$version" --arg s "$REC_SERVER_URL" --arg d "$(date -Is)" --arg t "$VDI_VERSION"
    logt OK rec_done "$version"
    mark_reboot_required
    logt WARN reboot_needed
}
