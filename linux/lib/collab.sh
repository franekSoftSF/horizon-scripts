# shellcheck shell=bash
# Mode "collab": Horizon Session Collaboration on the Linux agent. Asks for every
# value (defaults from the config file; -y takes them unasked), shows a summary,
# then writes:
#   viewagent-custom.conf  CollaborationEnable
#   config                 collaboration.* (serverUrl = link in invitations, e.g. the UAG URL)
# Key names follow the Horizon Linux agent documentation - verify them against the
# agent version you deploy before rolling out.

# ask VAR KIND QUESTION_KEY - KIND: bool | url | number
ask() {
    local var=$1 kind=$2 question=$3 answer
    while true; do
        if [[ ${ASSUME_YES:-0} == 1 ]]; then
            answer=${!var}
        else
            read -r -p "$(t "$question") [${!var}]: " answer || answer=""
            answer=${answer:-${!var}}
        fi
        case $kind in
            bool)
                case ${answer,,} in
                    y | yes | t | tak | true | 1) answer=true ;;
                    n | no | nie | false | 0) answer=false ;;
                    *) answer="" ;;
                esac
                ;;
            url) [[ -z $answer || $answer =~ ^https://[^[:space:]/]+(:[0-9]+)?(/[^[:space:]]*)?$ ]] || answer="!" ;;
            number) [[ $answer =~ ^[0-9]+$ ]] || answer="" ;;
        esac
        if [[ -n $answer && $answer != "!" ]] || [[ $kind == url && -z $answer ]]; then
            printf -v "$var" '%s' "$answer"
            return 0
        fi
        logt WARN collab_invalid "${!var}"
        [[ ${ASSUME_YES:-0} == 1 ]] && exit 2
    done
}

mode_collab() {
    logt STEP step_collab
    local dir custom config
    if ! dir=$(agent_conf_dir); then
        logt ERR agent_conf_missing
        exit 1
    fi
    custom="${dir}/viewagent-custom.conf"
    config="${dir}/config"

    ask COLLAB_ENABLE bool collab_q_enable
    if [[ $COLLAB_ENABLE == true ]]; then
        ask COLLAB_SERVER_URL url collab_q_url
        ask COLLAB_EMAIL bool collab_q_email
        ask COLLAB_CONTROL_PASSING bool collab_q_control
        ask COLLAB_MAX number collab_q_max
    fi

    logt INFO collab_summary "$COLLAB_ENABLE" "${COLLAB_SERVER_URL:--}" "$COLLAB_EMAIL" \
        "$COLLAB_CONTROL_PASSING" "$COLLAB_MAX"
    confirm "$(t collab_q_apply "$dir")" || {
        logt INFO collab_cancelled
        return 0
    }

    export KV_SECTION=build
    set_kv "$custom" CollaborationEnable "$COLLAB_ENABLE"
    if [[ $COLLAB_ENABLE == true ]]; then
        if [[ -n $COLLAB_SERVER_URL ]]; then
            set_kv "$config" collaboration.serverUrl "$COLLAB_SERVER_URL" " = "
        fi
        set_kv "$config" collaboration.enableEmail "$COLLAB_EMAIL" " = "
        set_kv "$config" collaboration.enableControlPassing "$COLLAB_CONTROL_PASSING" " = "
        set_kv "$config" collaboration.maxCollabors "$COLLAB_MAX" " = "
    fi
    unset KV_SECTION
    chmod 0644 "$custom" "$config" 2>/dev/null || true
    logt OK collab_done "$custom" "$config"
    logt WARN collab_restart
}

# Mode "apps": optional application installers in apps/*.sh (self-contained,
# own state files). Contract: "<script> --install --yes" installs or updates idempotently.
mode_apps() {
    logt STEP step_apps
    local script found=0
    for script in "${VDI_ROOT}"/apps/*.sh; do
        found=1
        logt INFO apps_running "$(basename "$script")"
        if bash "$script" --install --yes; then
            logt OK apps_done "$(basename "$script")"
        else
            logt ERR apps_failed "$(basename "$script")"
            exit 1
        fi
    done
    ((found)) || logt INFO apps_none "${VDI_ROOT}/apps"
}
