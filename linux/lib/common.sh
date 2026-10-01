# shellcheck shell=bash
# VDI-ImageMaint for Linux - shared helpers: config, i18n, logging, state, tracked changes.
# Sourced by vdi-imagemaint.sh; expects VDI_ROOT to be set.

VDI_VERSION="0.3.2"
STATE_DIR="/var/lib/vdi-imagemaint"
LOG_DIR="/var/log/vdi-imagemaint"
LOG_FILE="${LOG_DIR}/vdi-imagemaint-$(date +%Y%m%d).log"
MANAGED_MARK="# Managed by VDI-ImageMaint - local edits are overwritten"

# ---------------------------------------------------------------- config ---
# Order: defaults -> local (to learn PROFILE) -> profile defaults -> local again (local wins).
load_config() {
    local local_conf=${VDI_CONF:-${VDI_ROOT}/vdi-imagemaint.conf}
    # shellcheck source=../conf/defaults.conf
    . "${VDI_ROOT}/conf/defaults.conf"
    [[ -f $local_conf ]] && . "$local_conf"
    local profile_conf="${VDI_ROOT}/conf/profile-${PROFILE}.conf"
    if [[ -f $profile_conf ]]; then
        . "$profile_conf"
    else
        PROFILE_INVALID=$PROFILE
    fi
    [[ -f $local_conf ]] && . "$local_conf"
    CONF_FILE=$local_conf
}

# Fail when a required setting is empty or still holds the example value.
require_conf() {
    local name missing=0
    for name in "$@"; do
        if [[ -z ${!name:-} || ${!name} == *example* ]]; then
            log ERR "$(t conf_missing "$name" "$CONF_FILE")"
            missing=1
        fi
    done
    ((missing == 0)) || exit 2
}

# ------------------------------------------------------------------ i18n ---
# English table is always loaded; the second language only overrides keys, so a
# missing translation falls back to English instead of printing the raw key.
load_lang() {
    local lang=${VDI_LANG:-}
    if [[ -z $lang ]]; then
        case ${LC_ALL:-${LC_MESSAGES:-${LANG:-}}} in
            pl*) lang="pl-PL" ;;
            *) lang="en-US" ;;
        esac
    fi
    declare -gA MSG=()
    # shellcheck source=../lang/en-US.sh
    . "${VDI_ROOT}/lang/en-US.sh"
    if [[ $lang != "en-US" && -f "${VDI_ROOT}/lang/${lang}.sh" ]]; then
        . "${VDI_ROOT}/lang/${lang}.sh"
    fi
    VDI_LANG=$lang
}

# t KEY [printf args...] - translated message
t() {
    local key=$1
    shift
    local fmt=${MSG[$key]:-$key}
    # shellcheck disable=SC2059  # format strings come from the string table
    printf -- "$fmt" "$@"
}

# --------------------------------------------------------------- logging ---
log() {
    local level=$1
    shift
    local msg="$*" color="" reset=""
    if [[ -t 2 ]]; then
        reset=$'\e[0m'
        case $level in
            OK) color=$'\e[32m' ;;
            WARN) color=$'\e[33m' ;;
            ERR) color=$'\e[31m' ;;
            STEP) color=$'\e[1;36m' ;;
        esac
    fi
    printf '%s%-4s %s%s\n' "$color" "$level" "$msg" "$reset" >&2
    if [[ -w $LOG_DIR ]]; then
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$msg" >>"$LOG_FILE"
    fi
}

# logt LEVEL KEY [args...]
logt() {
    local level=$1
    shift
    log "$level" "$(t "$@")"
}

# run CMD... - log the command, mirror its output into the log, keep its exit code.
run() {
    log INFO "\$ $*"
    if [[ -w $LOG_DIR ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        "$@"
    fi
}

on_error() {
    local rc=$? line=$1
    log ERR "$(t err_unexpected "$rc" "$line" "${BASH_COMMAND:-?}")"
    exit "$rc"
}

init_runtime() {
    if [[ $EUID -ne 0 ]]; then
        log ERR "$(t err_root)"
        exit 1
    fi
    install -d -m 0750 "$LOG_DIR" "$STATE_DIR" "${STATE_DIR}/backup"
    log INFO "$(t start_banner "$VDI_VERSION" "$MODE" "$PROFILE" "$VDI_LANG")"
}

# yes/no prompt; ASSUME_YES=1 answers yes.
confirm() {
    local answer
    [[ ${ASSUME_YES:-0} == 1 ]] && return 0
    read -r -p "$(t prompt_yes_no "$1") " answer || return 1
    [[ $answer =~ ^([yYtT]|yes|tak)$ ]]
}

# ------------------------------------------------------------------- apt ---
apt_get() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l run apt-get -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

apt_install() {
    apt_get install "$@"
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# jq is needed for the state files before anything else runs.
ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    logt INFO installing_dep jq
    apt_get update >/dev/null
    apt_install jq
}

# ----------------------------------------------------------------- state ---
# One JSON file per section (build, optimize, seal) in STATE_DIR:
# { "units": { "<unit>": "<original is-enabled>" }, "files": { "<path>": "backup|created" }, ... }
state_file() {
    printf '%s/%s-state.json' "$STATE_DIR" "$1"
}

state_init() {
    local f
    f=$(state_file "$1")
    [[ -s $f ]] || printf '{"units":{},"files":{}}\n' >"$f"
}

# state_update SECTION JQ_FILTER [jq args...]
state_update() {
    local section=$1 filter=$2
    shift 2
    local f tmp
    state_init "$section"
    f=$(state_file "$section")
    tmp=$(mktemp "${f}.XXXXXX")
    jq "$@" "$filter" "$f" >"$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$f"
}

# state_get SECTION JQ_FILTER [jq args...] - raw output, empty when the file is missing
state_get() {
    local section=$1 filter=$2
    shift 2
    local f
    f=$(state_file "$section")
    [[ -s $f ]] || return 0
    jq -r "$@" "$filter" "$f"
}

# Fingerprint of the effective configuration (defaults + profile + local file).
config_fingerprint() {
    cat "${VDI_ROOT}/conf/defaults.conf" "${VDI_ROOT}/conf/profile-${PROFILE}.conf" \
        "$CONF_FILE" 2>/dev/null | sha256sum | cut -c1-16
}

# run_step MODE FUNCTION - skip a build step already done by this tool version with the
# same configuration (use --force to run it again); record it when it succeeds.
run_step() {
    local mode=$1 fn=$2 fp done_ver done_fp done_at
    fp=$(config_fingerprint)
    done_ver=$(state_get build '.steps[$m].version // empty' --arg m "$mode")
    done_fp=$(state_get build '.steps[$m].config // empty' --arg m "$mode")
    done_at=$(state_get build '.steps[$m].at // empty' --arg m "$mode")
    if [[ $(state_get build '.steps[$m].adopted // false' --arg m "$mode") == true && ${FORCE:-0} != 1 ]]; then
        logt OK step_adopted "$mode" "$done_at"
        return 0
    fi
    if [[ $done_ver == "$VDI_VERSION" && $done_fp == "$fp" && ${FORCE:-0} != 1 ]]; then
        logt OK step_already_done "$mode" "$done_ver" "$done_at"
        return 0
    fi
    [[ -n $done_ver ]] && logt INFO step_rerun "$mode" "$done_ver" "$VDI_VERSION"
    "$fn"
    state_update build '.steps[$m] = {version: $v, config: $c, at: $d}' \
        --arg m "$mode" --arg v "$VDI_VERSION" --arg c "$fp" --arg d "$(date -Is)"
}

step_adopted() {
    [[ $(state_get build '.steps[$m].adopted // false' --arg m "$1") == true ]]
}

is_sealed() {
    [[ $(state_get seal '.sealed // false') == "true" ]]
}

# ----------------------------------------------------- tracked unit changes ---
unit_known() {
    [[ -n $(systemctl list-unit-files --no-legend --no-pager "$1" 2>/dev/null) ]]
}

unit_enabled_state() {
    systemctl is-enabled "$1" 2>/dev/null || true
}

# unit_off SECTION UNIT disable|mask - remembers the original state once, so a
# second run (idempotent) never overwrites the true original with "disabled".
unit_off() {
    local section=$1 unit=$2 action=$3 orig
    if ! unit_known "$unit"; then
        logt INFO unit_absent "$unit"
        return 0
    fi
    orig=$(unit_enabled_state "$unit")
    if [[ -z $(state_get "$section" '.units[$u] // empty' --arg u "$unit") ]]; then
        state_update "$section" '.units[$u] = $o' --arg u "$unit" --arg o "${orig:-unknown}"
    fi
    case $action in
        mask) [[ $orig == masked ]] || run systemctl mask --now "$unit" ;;
        *) [[ $orig == disabled || $orig == masked ]] || run systemctl disable --now "$unit" ;;
    esac
}

units_restore() {
    local section=$1 unit orig
    while IFS=$'\t' read -r unit orig; do
        [[ -n $unit ]] || continue
        case $orig in
            masked) ;;
            enabled | enabled-runtime)
                run systemctl unmask "$unit" || true
                run systemctl enable --now "$unit" || logt WARN unit_restore_failed "$unit"
                ;;
            *) run systemctl unmask "$unit" || true ;;
        esac
        logt OK unit_restored "$unit" "$orig"
    done < <(state_get "$section" '.units | to_entries[] | "\(.key)\t\(.value)"')
    state_update "$section" '.units = {}'
}

# ----------------------------------------------------- tracked file changes ---
# file_track SECTION PATH - keep the pre-tool original once (or note it did not exist).
file_track() {
    local section=$1 path=$2
    [[ -z $(state_get "$section" '.files[$p] // empty' --arg p "$path") ]] || return 0
    if [[ -e $path ]]; then
        install -d -m 0750 "$(dirname "${STATE_DIR}/backup/${section}${path}")"
        cp -a "$path" "${STATE_DIR}/backup/${section}${path}"
        state_update "$section" '.files[$p] = "backup"' --arg p "$path"
    else
        state_update "$section" '.files[$p] = "created"' --arg p "$path"
    fi
}

# write_file SECTION PATH MODE < content - atomic write, original tracked, unchanged files untouched.
write_file() {
    local section=$1 path=$2 mode=$3 tmp
    if [[ ${PREVIEW:-0} == 1 ]]; then
        preview_file "$path"
        return 0
    fi
    install -d "$(dirname "$path")"
    tmp=$(mktemp "${path}.vdi.XXXXXX")
    cat >"$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        logt INFO file_unchanged "$path"
        return 0
    fi
    file_track "$section" "$path"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path"
    logt OK file_written "$path"
}

# preview_file PATH < content - show what write_file would change, write nothing.
# Values of password/secret/authtok keys are masked in the diff.
preview_file() {
    local path=$1 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        logt OK preview_same "$path"
    else
        logt WARN preview_change "$path"
        diff -u --label "${path} (now)" --label "${path} (tool)" \
            "$([[ -f $path ]] && echo "$path" || echo /dev/null)" "$tmp" |
            sed -E -e 's/^([-+ ][^=]*(pass|secret|authtok)[^=]*=).*/\1 ********/I' -e 's/^/    /' >&2 || true
    fi
    rm -f "$tmp"
}

# set_kv FILE KEY VALUE [SEP] - set "KEY<SEP>VALUE" in a flat conf file, replacing the
# first live or commented "KEY =" line. SEP is what gets written ("=" or " = ").
set_kv() {
    local file=$1 key=$2 value=$3 sep=${4:-=} section=${KV_SECTION:-build} kre line cur
    kre=$(printf '%s' "$key" | sed -e 's/[][\.*^$+?(){}|/]/\\&/g')
    if [[ ${PREVIEW:-0} == 1 ]]; then
        cur=$(grep -E "^[[:space:]]*${kre}[[:space:]]*=" "$file" 2>/dev/null | tail -n1 |
            sed -E 's/^[^=]*=[[:space:]]*//') || true
        if [[ $cur == "$value" ]]; then
            logt OK preview_kv_same "$file" "$key" "$value"
        else
            logt WARN preview_kv_change "$file" "$key" "${cur:-<unset>}" "$value"
        fi
        return 0
    fi
    file_track "$section" "$file"
    touch "$file"
    line=$(printf '%s%s%s' "$key" "$sep" "$value" | sed -e 's/[\/&|]/\\&/g')
    if grep -Eq "^[#[:space:]]*${kre}[[:space:]]*=" "$file"; then
        sed -i -E "0,/^[#[:space:]]*${kre}[[:space:]]*=.*/s|^[#[:space:]]*${kre}[[:space:]]*=.*|${line}|" "$file"
    else
        printf '%s%s%s\n' "$key" "$sep" "$value" >>"$file"
    fi
}

files_restore() {
    local section=$1 path how
    while IFS=$'\t' read -r path how; do
        [[ -n $path ]] || continue
        if [[ $how == backup && -e "${STATE_DIR}/backup/${section}${path}" ]]; then
            cp -a "${STATE_DIR}/backup/${section}${path}" "$path"
        else
            rm -f "$path"
        fi
        logt OK file_restored "$path"
    done < <(state_get "$section" '.files | to_entries[] | "\(.key)\t\(.value)"')
    state_update "$section" '.files = {}'
    rm -rf "${STATE_DIR}/backup/${section:?}"
}

# ------------------------------------------------------------------ misc ---
os_check() {
    local id="" version_id=""
    # shellcheck disable=SC1091
    [[ -r /etc/os-release ]] && . /etc/os-release
    id=${ID:-}
    version_id=${VERSION_ID:-}
    if [[ $id != debian || $version_id != 12 ]]; then
        logt WARN os_unsupported "${PRETTY_NAME:-unknown}"
        return 1
    fi
}

# Horizon renamed /etc/vmware -> /etc/omnissa in newer Linux agents; support both.
agent_conf_dir() {
    local d
    for d in /etc/omnissa /etc/vmware; do
        [[ -f "${d}/viewagent-custom.conf" || -d "${d}/viewagent" || -f "${d}/viewagent-config.txt" ]] && {
            printf '%s' "$d"
            return 0
        }
    done
    return 1
}

agent_service() {
    local s
    for s in viewagent.service omnissa-viewagent.service; do
        unit_known "$s" && {
            printf '%s' "$s"
            return 0
        }
    done
    return 1
}

newest_kernel() {
    local k
    k=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n1)
    printf '%s' "$k"
}

# mark_reboot_required - an installer asked for a restart (Horizon agent, Recording agent).
mark_reboot_required() {
    state_update build '.rebootRequiredSince = $d' --arg d "$(date +%s)"
}

reboot_pending() {
    [[ -e /run/reboot-required ]] && return 0
    local since boot
    since=$(state_get build '.rebootRequiredSince // empty')
    boot=$(date -d "$(uptime -s 2>/dev/null || echo now)" +%s 2>/dev/null || echo 0)
    [[ -n $since && $since -ge $boot ]] && return 0
    local k
    k=$(newest_kernel)
    [[ -n $k && $k != "$(uname -r)" ]]
}
