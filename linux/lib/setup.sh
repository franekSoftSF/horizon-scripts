# shellcheck shell=bash
# Mode "setup": guided build of a NEW golden image (a fresh Debian 12 / 13).
#   1. asks for the settings (domain, join account, NFS, True SSO / smart card, time zone,
#      keyboard, USB, microphone) and writes them to vdi-imagemaint.conf - the current
#      value is the default, Enter keeps it, -y keeps all of them;
#   2. offers the build steps in order (prepare -> domain -> nfs -> agent -> reboot ->
#      recording -> apps -> courses -> optimize -> collab -> check), one question each.
# Every step runs as its own process, exactly as from the menu; finished steps are
# remembered, so after the reboot (or a failure) "setup" continues where it stopped.
# "adopt" on a fresh image starts this instead of adopting steps that never ran.

SETUP_STEPS=(prepare domain nfs agent recording apps courses optimize collab check)

# conf_set FILE KEY VALUE - replace KEY="..." in FILE (last occurrence wins when sourced,
# so all occurrences are replaced) or append it.
conf_set() {
    local file=$1 key=$2 value tmp
    value=$(conf_quote "$3")
    tmp=$(mktemp)
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        awk -v k="$key" -v v="$value" '
            index($0, k "=") == 1 { print k "=" v; next }
            { print }' "$file" >"$tmp"
    else
        { cat "$file" 2>/dev/null || true; printf '%s=%s\n' "$key" "$value"; } >"$tmp"
    fi
    cat "$tmp" >"$file"
    rm -f "$tmp"
}

# setup_ask VAR QUESTION_KEY [CHOICES] - ask with the current value as default; CHOICES
# ("a|b|c") are enforced; "-" clears an optional value.
setup_ask() {
    local var=$1 q=$2 choices=${3:-} cur answer
    cur=${!var-}
    [[ $cur == *example* ]] && cur=""
    while true; do
        if [[ ${ASSUME_YES:-0} == 1 ]]; then
            answer=$cur
        else
            read -r -p "$(t "$q")${choices:+ (${choices//|/ / })} [${cur}]: " answer || answer=""
            [[ -z $answer ]] && answer=$cur
            [[ $answer == - ]] && answer=""
        fi
        if [[ -n $choices && " ${choices//|/ } " != *" ${answer,,} "* ]]; then
            logt WARN setup_choice "${choices//|/, }"
            [[ ${ASSUME_YES:-0} == 1 ]] && return 1
            continue
        fi
        [[ -n $choices ]] && answer=${answer,,}
        printf -v "$var" '%s' "$answer"
        SETUP_KEYS+=("$var")
        return 0
    done
}

setup_yes_no() { # VAR QUESTION_KEY
    local var=$1
    if ask_yes "$(t "$2")" "$([[ ${!var} == yes ]] && echo yes || echo no)"; then
        printf -v "$var" yes
    else
        printf -v "$var" no
    fi
    SETUP_KEYS+=("$var")
}

setup_settings() {
    SETUP_KEYS=()
    logt STEP setup_settings_title
    setup_ask PROFILE setup_q_profile "university|business"
    setup_ask AD_DOMAIN setup_q_domain
    setup_ask AD_JOIN_USER setup_q_join_user
    setup_ask AD_COMPUTER_OU setup_q_ou
    setup_ask AD_ACCESS_GROUPS setup_q_access
    setup_ask AD_SUDO_GROUPS setup_q_sudo
    setup_ask TIMEZONE setup_q_timezone
    setup_ask KEYBOARD_LAYOUT setup_q_keyboard
    setup_ask DEFAULT_LOCALE setup_q_locale

    setup_yes_no NFS_ENABLE setup_q_nfs
    if [[ $NFS_ENABLE == yes ]]; then
        setup_ask NFS_MODE setup_q_nfs_mode "fstab|autofs"
        setup_ask NFS_SERVER setup_q_nfs_server
        setup_ask NFS_EXPORT setup_q_nfs_export
        setup_ask HOME_ROOT setup_q_home_root
        if [[ $NFS_MODE == fstab ]]; then
            [[ -z $NFS_MOUNTPOINT ]] && NFS_MOUNTPOINT=$HOME_ROOT
            setup_ask NFS_MOUNTPOINT setup_q_nfs_mountpoint
        fi
        setup_ask NFS_SEC setup_q_nfs_sec "krb5|krb5i|krb5p"
    fi

    setup_yes_no TRUESSO_ENABLE setup_q_truesso
    setup_yes_no SMARTCARD_ENABLE setup_q_smartcard
    if [[ $TRUESSO_ENABLE == yes || $SMARTCARD_ENABLE == yes ]]; then
        local found
        found=$(find "${VDI_ROOT}/certs" -maxdepth 1 -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) \
            -printf '%f ' 2>/dev/null || true)
        logt INFO setup_certs_found "${VDI_ROOT}/certs" "${found:-none}"
        [[ -z $CERT_CA_FILES && -n $found ]] && CERT_CA_FILES=${found% }
        setup_ask CERT_CA_FILES setup_q_ca_files
        setup_ask CERT_REVOCATION setup_q_revocation "ocsp|soft_ocsp|crl|none"
        [[ $CERT_REVOCATION == crl ]] && setup_ask CERT_CRL_URLS setup_q_crl_urls
    fi
    setup_yes_no USB_ENABLE setup_q_usb
    setup_yes_no AUDIO_IN_ENABLE setup_q_audio_in

    # Summary, then write.
    logt STEP setup_summary_title
    local k
    for k in "${SETUP_KEYS[@]}"; do
        printf '  %-18s = %s\n' "$k" "${!k}"
    done
    if ! ask_yes "$(t setup_q_save "$CONF_FILE")" yes; then
        logt WARN setup_not_saved
        exit 1
    fi
    if [[ ! -f $CONF_FILE ]]; then
        printf '# vdi-imagemaint.conf - written by "vdi-imagemaint.sh setup" %s\n' "$(date -Is)" >"$CONF_FILE"
    fi
    for k in "${SETUP_KEYS[@]}"; do
        conf_set "$CONF_FILE" "$k" "${!k}"
    done
    chmod 0640 "$CONF_FILE"
    logt OK setup_saved "$CONF_FILE"
}

# Has STEP already been done by this tool on this image?
setup_step_done() {
    local m=$1
    [[ -n $(state_get build '.wizard[$m] // empty' --arg m "$m") ]] && return 0
    [[ -n $(state_get build '.steps[$m].version // empty' --arg m "$m") ]] && return 0
    [[ $m == agent && -n $(state_get build '.agent.version // empty') ]] && return 0
    return 1
}

# Is STEP needed with these settings? Prints the reason to skip it otherwise.
setup_step_skip_reason() {
    case $1 in
        nfs) [[ $NFS_ENABLE == yes ]] || t setup_skip_nfs ;;
        recording) [[ -n $(recording_find_archive 2>/dev/null || true) ]] || t setup_skip_recording ;;
    esac
}

setup_run_step() {
    # Its own process, as from the menu: errexit stays effective inside the step and a
    # failing step ends only that step.
    VDI_CONF=$CONF_FILE bash "${VDI_ROOT}/vdi-imagemaint.sh" "$1" --lang "$VDI_LANG" --no-upgrade
}

setup_steps() {
    local m reason
    logt STEP setup_steps_title
    for m in "${SETUP_STEPS[@]}"; do
        if setup_step_done "$m"; then
            logt OK setup_step_done "$m"
            continue
        fi
        reason=$(setup_step_skip_reason "$m")
        if [[ -n $reason ]]; then
            logt INFO setup_step_skipped "$m" "$reason"
            continue
        fi
        if [[ $m == agent && -z $(agent_find_archive) ]]; then
            logt WARN setup_agent_missing "${VDI_ROOT}/Horizon/" "$(agent_min_yymm)"
            logt INFO setup_resume
            return 0
        fi
        if ! ask_yes "$(t setup_q_step "$m" "$(t "menu_${m}")")" yes; then
            # "No" skips this step (it is offered again next time); Ctrl+C ends setup.
            logt INFO setup_step_skipped "$m" "$(t setup_skip_user)"
            continue
        fi
        if ! setup_run_step "$m"; then
            # check exits 1 when it found errors: that is its result, not a failure.
            if [[ $m != check ]]; then
                logt ERR setup_step_failed "$m"
                logt INFO setup_resume
                return 1
            fi
        fi
        state_update build '.wizard[$m] = $d' --arg m "$m" --arg d "$(date -Is)"
        if [[ $m == agent ]] || reboot_pending; then
            logt WARN setup_reboot_needed
            logt INFO setup_resume
            if ask_yes "$(t setup_q_reboot)" yes; then
                run systemctl reboot
            fi
            return 0
        fi
    done
    logt OK setup_all_done
}

mode_setup() {
    logt STEP step_setup
    if is_sealed; then
        logt ERR cert_sealed
        exit 1
    fi
    os_check || logt WARN adopt_os_untested
    # Settings once; on a resumed run (after the reboot) they are kept unless asked.
    if [[ -z $(state_get build '.wizard.settings // empty') ]] || ask_yes "$(t setup_q_change_settings)" no; then
        setup_settings
        state_update build '.wizard.settings = $d' --arg d "$(date -Is)"
        load_config
    fi
    setup_steps
}

# A fresh image: nothing to adopt. True when there is no domain join, no Horizon agent
# and no NFS homes (the values come from adopt_detect_*).
adopt_is_fresh_image() {
    [[ $ADOPT_JOIN == none && $ADOPT_AGENT == no && $ADOPT_HOMES == local ]]
}
