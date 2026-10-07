# shellcheck shell=bash
# Automatic upgrade of the tool itself from GitHub releases (linux-v*).
# Runs at the start of every mode (AUTO_UPGRADE=yes|ask|no, --no-upgrade skips it once):
#   newest linux-v* release > VDI_VERSION -> get-vdi-imagemaint.sh installs it in place
#   (SHA-256 checked; vdi-imagemaint.conf, Horizon/, certs/, apps/*.conf kept), then the
#   same command is started again with the new version.
# No network or no GitHub: the run continues with the installed version.

SELFUPDATE_REPO="franekSoftSF/horizon-scripts"

# newest released version, empty when it cannot be determined (offline, rate limit)
selfupdate_latest() {
    curl -fsS --connect-timeout 5 --max-time 15 \
        "https://api.github.com/repos/${SELFUPDATE_REPO}/releases?per_page=100" 2>/dev/null |
        grep -oE '"tag_name": *"linux-v[0-9][^"]*"' | sed -E 's/.*"linux-v([^"]+)"/\1/' | sort -V | tail -n1 || true
}

# self_update ORIGINAL_ARGS... - may replace the running process (exec)
self_update() {
    [[ ${VDI_SELFUPDATE_DONE:-0} == 1 || ${NO_UPGRADE:-0} == 1 || $AUTO_UPGRADE == no ]] && return 0
    export VDI_SELFUPDATE_DONE=1    # once per command, also for menu sub-steps
    command -v curl >/dev/null 2>&1 || return 0
    local latest
    latest=$(selfupdate_latest)
    if [[ -z $latest ]]; then
        logt INFO selfupdate_unreachable
        return 0
    fi
    if [[ $(version_cmp "$VDI_VERSION" "$latest") != -1 ]]; then
        logt OK selfupdate_current "$VDI_VERSION"
        return 0
    fi
    logt INFO selfupdate_available "$VDI_VERSION" "$latest"
    if [[ $AUTO_UPGRADE == ask ]] && ! confirm "$(t selfupdate_q "$latest")"; then
        return 0
    fi
    # Run a copy: the installer replaces get-vdi-imagemaint.sh in VDI_ROOT while it runs.
    local getter rc=0
    getter=$(mktemp /tmp/vdi-get.XXXXXX)
    cp "${VDI_ROOT}/get-vdi-imagemaint.sh" "$getter"
    bash "$getter" --version "$latest" --dir "$VDI_ROOT" --lang "$VDI_LANG" 2>&1 |
        { if [[ -w $LOG_DIR ]]; then tee -a "$LOG_FILE"; else cat; fi; } || rc=$?
    rm -f "$getter"
    if ((rc != 0)); then
        logt WARN selfupdate_failed "$latest"
        return 0
    fi
    logt OK selfupdate_done "$latest"
    exec bash "${VDI_ROOT}/vdi-imagemaint.sh" "$@"
}

# Keep the installed per-clone script in line with the tool version (it is a copy).
selfupdate_sync_runonce() {
    [[ -f $RUNONCE_TARGET && -f ${VDI_ROOT}/files/runonce.sh ]] || return 0
    cmp -s "${VDI_ROOT}/files/runonce.sh" "$RUNONCE_TARGET" && return 0
    install -m 0700 -o root -g root "${VDI_ROOT}/files/runonce.sh" "$RUNONCE_TARGET"
    logt OK selfupdate_runonce "$RUNONCE_TARGET"
}

# Mode "self-update": check now, also when AUTO_UPGRADE=no.
mode_self_update() {
    logt STEP step_selfupdate
    AUTO_UPGRADE=yes NO_UPGRADE=0 VDI_SELFUPDATE_DONE=0 self_update self-update --no-upgrade
}
