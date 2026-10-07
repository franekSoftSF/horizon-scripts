#!/bin/bash
# VDI-ImageMaint for Linux - golden-image maintenance for Debian 12 (MATE) desktops
# on Omnissa Horizon Instant Clone (Horizon Linux Agent, SSSD offline domain join,
# True SSO / smart card, NFSv4 + Kerberos home directories).
#
# Build (once):  prepare -> domain -> nfs -> agent -> (reboot) -> recording -> apps -> optimize -> collab -> check -> seal
# Existing image: adopt (detect, preview, keep) -> agent/recording/apps -> optimize -> check -> seal
# Day-2 (monthly): update --then-seal          Reverse a seal: unlock
#
# Usage: sudo ./vdi-imagemaint.sh <mode> [options]   (no mode = interactive menu)

set -Eeuo pipefail
shopt -s nullglob

VDI_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

# shellcheck source=lib/common.sh
. "${VDI_ROOT}/lib/common.sh"
for _lib in base domain kerberos nfs nfsmount vhci agent recording adoptconf adopt selfupdate courses collab optimize update seal check; do
    # shellcheck disable=SC1090
    . "${VDI_ROOT}/lib/${_lib}.sh"
done
unset _lib

usage() {
    t usage_text "$(basename "$0")"
}

menu() {
    local choice
    local -a modes=(adopt prepare domain kerberos nfs nfsmount agent usb recording apps courses optimize collab check seal update unlock fido status diag self-update)
    while true; do
        printf '\n%s\n' "$(t menu_title "$VDI_VERSION" "$PROFILE")"
        local i=1 m
        for m in "${modes[@]}"; do
            printf '  %2d) %-9s %s\n' "$i" "$m" "$(t "menu_${m}")"
            ((i += 1))
        done
        printf '   q) %s\n' "$(t menu_quit)"
        read -r -p "$(t menu_prompt) " choice || return 0
        [[ $choice == [qQ] ]] && return 0
        if [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#modes[@]})); then
            MODE=${modes[choice - 1]}
            # Separate process: errexit stays effective inside the step, and a
            # failing step does not end the menu.
            if ! VDI_CONF=$CONF_FILE bash "${VDI_ROOT}/vdi-imagemaint.sh" "$MODE" --lang "$VDI_LANG"; then
                # check exits 1 when it found errors: that is its result, not a failure.
                [[ $MODE == check ]] || logt WARN menu_step_failed "$MODE"
            fi
        fi
    done
}

dispatch() {
    case $1 in
        adopt) mode_adopt ;;
        prepare) run_step prepare mode_prepare ;;
        domain) run_step domain mode_domain ;;
        kerberos) mode_kerberos ;;
        diag) mode_diag ;;
        nfs) run_step nfs mode_nfs ;;
        nfsmount) mode_nfsmount ;;
        agent) mode_agent ;;
        usb) mode_usb ;;
        recording) mode_recording ;;
        apps) mode_apps ;;
        courses) mode_courses ;;
        optimize) mode_optimize ;;
        collab) mode_collab ;;
        update) mode_update ;;
        seal) mode_seal ;;
        unlock) mode_unlock ;;
        check) mode_check || exit 1 ;;
        fido) mode_fido ;;
        status) mode_status ;;
        self-update) mode_self_update ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main() {
    MODE=menu
    local -a rest=() orig_args=("$@")
    while (($#)); do
        case $1 in
            -h | --help) MODE=help ;;
            --lang) VDI_LANG_ARG=${2:-}; shift ;;
            --config) VDI_CONF=${2:-}; shift ;;
            --force) FORCE=1 ;;
            --then-seal) THEN_SEAL=1 ;;
            --revert) REVERT=1 ;;
            -y | --yes) ASSUME_YES=1 ;;
            --no-upgrade) NO_UPGRADE=1 ;;
            -*) rest+=("$1") ;;
            *) MODE=$1 ;;
        esac
        shift
    done

    load_config
    [[ -n ${VDI_LANG_ARG:-} ]] && VDI_LANG=$VDI_LANG_ARG
    load_lang

    if [[ $MODE == help ]]; then
        usage
        return 0
    fi
    if ((${#rest[@]})); then
        log ERR "$(t err_unknown_option "${rest[*]}")"
        exit 2
    fi
    if [[ -n ${PROFILE_INVALID:-} ]]; then
        log ERR "$(t err_profile "$PROFILE_INVALID")"
        exit 2
    fi

    trap 'on_error $LINENO' ERR
    init_runtime
    # Newer release on GitHub -> upgrade in place and start this command again.
    [[ $MODE == self-update ]] || self_update "${orig_args[@]}"
    selfupdate_sync_runonce
    ensure_jq
    if [[ $MODE == menu ]]; then
        menu
    else
        dispatch "$MODE"
    fi
}

main "$@"
