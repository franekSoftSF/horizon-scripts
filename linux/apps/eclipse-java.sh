#!/bin/bash
# VDI-ImageMaint for Linux - app component: Eclipse IDE + Java JDK for a MATE
# desktop on Omnissa Horizon Instant Clone with NFSv4 + Kerberos home directories.
#
# Run as root on the GOLDEN IMAGE, then seal, snapshot and push the image:
# existing instant-clone pools get it with Push Image, new pools from the snapshot.
# Works standalone (no other VDI-ImageMaint step required) and is idempotent.
#
# Design (why it looks like this):
#   - Eclipse is a read-only shared install in /opt/vdi-apps (versioned dir + symlink).
#     Per-user state lives in the NFS home (~/.eclipse, ~/eclipse-workspace), so it
#     survives the clone being thrown away at logoff.
#   - root cannot write to sec=krb5* NFS homes, and /etc/skel is never copied there,
#     so nothing per-user is prepared at build time: menu entries are system-wide and
#     the optional desktop icon is created at login, as the user.
#   - The launcher checks the home is writable (NFS mounted, Kerberos ticket valid)
#     before starting Eclipse, instead of letting Eclipse fail with odd lock errors.
#
# Usage: eclipse-java.sh [--install|--remove|--status] [--purge-java] [--yes]
#                        [--config FILE] [--lang en-US|pl-PL]

set -Eeuo pipefail

APP_VERSION="1.0.0"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APPS_ROOT="/opt/vdi-apps"
BIN_DIR="${APPS_ROOT}/bin"
LINK="${APPS_ROOT}/eclipse"
STATE_DIR="/var/lib/vdi-imagemaint"
STATE_FILE="${STATE_DIR}/apps-eclipse-java.state"
LOG_DIR="/var/log/vdi-imagemaint"
LOG_FILE="${LOG_DIR}/apps-eclipse-java-$(date +%Y%m%d).log"
CACHE_DIR="/var/cache/vdi-imagemaint/apps"
DESKTOP_FILE="/usr/share/applications/vdi-eclipse.desktop"
MENU_FILE="/etc/xdg/menus/applications-merged/vdi-apps.menu"
DIRECTORY_FILE="/usr/share/desktop-directories/vdi-apps.directory"
AUTOSTART_FILE="/etc/xdg/autostart/vdi-eclipse-user.desktop"
PROFILE_FILE="/etc/profile.d/vdi-java.sh"
ADOPTIUM_KEY="/usr/share/keyrings/adoptium.gpg"
ADOPTIUM_LIST="/etc/apt/sources.list.d/adoptium.list"
MANAGED_MARK="# Managed by VDI-ImageMaint (apps/eclipse-java.sh) - local edits are overwritten"

# ------------------------------------------------------------- defaults ---
# Override in eclipse-java.conf next to this script (see eclipse-java.conf.example).
VDI_LANG=""                   # en-US | pl-PL | empty = from $LANG
JAVA_SOURCE="temurin"         # temurin (Adoptium apt repo) | debian (openjdk-N-jdk) | none
JAVA_VERSION="25"             # JDK major the course uses (17, 21, 25 ...)
JAVA_EXTRA_PACKAGES=""        # e.g. "maven openjfx"
ECLIPSE_RELEASE="2026-09"     # EPP release train (YYYY-MM)
ECLIPSE_PACKAGE="java"        # java | jee | cpp | modeling ... (EPP package name)
ECLIPSE_ARCHIVE=""            # local .tar.gz; empty = apps/Apps/<name> next to this script, else download
ECLIPSE_MIRROR="https://download.eclipse.org/technology/epp/downloads/release"
ECLIPSE_VM="auto"             # auto | jdk | bundled  (auto = course JDK when Eclipse can run on it)
ECLIPSE_MIN_JAVA=""           # minimum Java to RUN Eclipse; empty = osgi.requiredJavaVersion from eclipse.ini
ECLIPSE_XMX="2048m"
ECLIPSE_KEEP="2"              # installed releases kept for rollback (current included)
ECLIPSE_WORKSPACE="@user.home/eclipse-workspace"
ECLIPSE_OSGI_LOCKING=""       # empty = Equinox default (NFSv4 has in-protocol locks); "none" only for broken NFS locking
ECLIPSE_P2_REPOS=""           # comma-separated p2 repositories for extra plugins
ECLIPSE_P2_FEATURES=""        # comma-separated installable units, e.g. "org.eclipse.wb.core.feature.feature.group"
MENU_SUBMENU=""               # extra MATE submenu (e.g. "Courses"); empty = Applications > Programming only
MENU_SUBMENU_PL=""            # Polish name of that submenu (e.g. "Zajęcia")
DESKTOP_ICON="no"             # yes = icon on every user's desktop, created at login as the user
KEEP_DOWNLOAD="no"            # yes = keep the downloaded archive in /var/cache (image grows by ~370 MB)

# ------------------------------------------------------------------ i18n ---
declare -A MSG_EN=(
    [usage]="Usage: %s [--install|--remove|--status] [--purge-java] [--yes] [--config FILE] [--lang en-US|pl-PL]"
    [err_root]="Run as root (sudo)."
    [err_unexpected]="Unexpected error (exit code %s) at line %s: %s"
    [err_arg]="Unknown argument: %s"
    [err_conf_value]="Invalid value %s=%s (allowed: %s)."
    [start]="Eclipse + Java component %s - mode %s, Eclipse %s (%s), Java %s from %s"
    [conf_loaded]="Configuration: %s"
    [os_unsupported]="Tested on Debian 12/13 amd64; this system is %s."
    [ask_continue]="Continue anyway?"
    [prompt_yes_no]="%s [y/N]"
    [aborted]="Aborted."
    [sealed]="The image is sealed by VDI-ImageMaint. Run 'unlock' first and 'seal' again afterwards."
    [step_java]="Java JDK %s (%s)"
    [java_none]="JAVA_SOURCE=none - no JDK installed; Eclipse runs on its bundled JRE."
    [java_no_candidate]="Package %s is not available on this system. Available JDKs: %s"
    [java_home]="JAVA_HOME = %s"
    [java_home_missing]="Cannot find javac of package %s."
    [java_alt_failed]="update-alternatives could not select %s (left on automatic)."
    [step_eclipse]="Eclipse IDE %s (%s) -> %s"
    [eclipse_present]="Already installed: %s"
    [archive_local]="Using local archive %s"
    [archive_download]="Downloading %s"
    [archive_bad_sum]="SHA-512 mismatch for %s - file removed. Download it again."
    [archive_sum_ok]="SHA-512 verified."
    [archive_no_sum]="No .sha512 file for %s - integrity cannot be verified."
    [archive_bad]="Archive %s does not contain eclipse/eclipse."
    [eclipse_extracted]="Extracted to %s"
    [p2_installing]="Installing plugins %s from %s"
    [p2_failed]="Plugin installation failed (see the log); Eclipse itself is installed."
    [vm_jdk]="Eclipse runs on the course JDK %s (also the default JRE for new projects)."
    [vm_bundled]="Eclipse runs on its bundled JRE; JDK %s is detected as an installed JRE."
    [vm_jdk_too_old]="JDK %s is older than Java %s required by Eclipse %s - using the bundled JRE."
    [initialized]="Shared configuration pre-initialised (faster first start for users)."
    [old_removed]="Removed old release %s"
    [step_menu]="MATE menu entries and launcher"
    [file_written]="Written: %s"
    [file_removed]="Removed: %s"
    [submenu]="Extra submenu: %s"
    [desktop_icon_on]="Desktop icon: created for each user at the next login."
    [desktop_icon_off]="Desktop icon: off (menu Applications > Programming)."
    [install_done]="Done. Next: test as a domain user, then seal, power off, snapshot and Push Image (existing pools) / use the snapshot for new pools."
    [step_remove]="Removing the Eclipse + Java component"
    [remove_done]="Removed. User data in the NFS homes (~/.eclipse, ~/eclipse-workspace) is not touched."
    [java_kept]="Java JDK kept (use --purge-java to remove it)."
    [step_status]="Status of the Eclipse + Java component"
    [st_eclipse]="Eclipse: %s"
    [st_java]="Java:    %s"
    [st_launcher]="Launcher: %s"
    [st_menu]="Menu entry: %s"
    [st_missing]="missing"
    [st_desktop_invalid]="desktop-file-validate reports problems in %s"
    [st_ok]="Component is complete."
    [st_bad]="Component is incomplete - run --install."
)

declare -A MSG_PL=(
    [usage]="Użycie: %s [--install|--remove|--status] [--purge-java] [--yes] [--config PLIK] [--lang en-US|pl-PL]"
    [err_root]="Uruchom jako root (sudo)."
    [err_unexpected]="Nieoczekiwany błąd (kod %s) w linii %s: %s"
    [err_arg]="Nieznany argument: %s"
    [err_conf_value]="Nieprawidłowa wartość %s=%s (dozwolone: %s)."
    [start]="Komponent Eclipse + Java %s - tryb %s, Eclipse %s (%s), Java %s z %s"
    [conf_loaded]="Konfiguracja: %s"
    [os_unsupported]="Testowane na Debian 12/13 amd64; ten system to %s."
    [ask_continue]="Kontynuować mimo to?"
    [prompt_yes_no]="%s [t/N]"
    [aborted]="Przerwano."
    [sealed]="Obraz jest zapieczętowany przez VDI-ImageMaint. Najpierw 'unlock', a potem ponownie 'seal'."
    [step_java]="Java JDK %s (%s)"
    [java_none]="JAVA_SOURCE=none - bez JDK; Eclipse działa na wbudowanym JRE."
    [java_no_candidate]="Pakiet %s nie jest dostępny w tym systemie. Dostępne JDK: %s"
    [java_home]="JAVA_HOME = %s"
    [java_home_missing]="Nie znaleziono javac z pakietu %s."
    [java_alt_failed]="update-alternatives nie mogło wybrać %s (pozostaje tryb automatyczny)."
    [step_eclipse]="Eclipse IDE %s (%s) -> %s"
    [eclipse_present]="Już zainstalowane: %s"
    [archive_local]="Używam lokalnego archiwum %s"
    [archive_download]="Pobieranie %s"
    [archive_bad_sum]="Niezgodna suma SHA-512 dla %s - plik usunięty. Pobierz go ponownie."
    [archive_sum_ok]="Suma SHA-512 poprawna."
    [archive_no_sum]="Brak pliku .sha512 dla %s - nie można sprawdzić integralności."
    [archive_bad]="Archiwum %s nie zawiera eclipse/eclipse."
    [eclipse_extracted]="Rozpakowano do %s"
    [p2_installing]="Instalacja wtyczek %s z %s"
    [p2_failed]="Instalacja wtyczek nie powiodła się (szczegóły w logu); sam Eclipse jest zainstalowany."
    [vm_jdk]="Eclipse działa na JDK %s z zajęć (domyślne JRE nowych projektów)."
    [vm_bundled]="Eclipse działa na wbudowanym JRE; JDK %s jest wykrywane jako zainstalowane JRE."
    [vm_jdk_too_old]="JDK %s jest starsze niż Java %s wymagana przez Eclipse %s - używam wbudowanego JRE."
    [initialized]="Wspólna konfiguracja zainicjowana (szybszy pierwszy start u użytkowników)."
    [old_removed]="Usunięto starą wersję %s"
    [step_menu]="Skróty w menu MATE i program uruchamiający"
    [file_written]="Zapisano: %s"
    [file_removed]="Usunięto: %s"
    [submenu]="Dodatkowe podmenu: %s"
    [desktop_icon_on]="Ikona na pulpicie: tworzona każdemu użytkownikowi przy następnym logowaniu."
    [desktop_icon_off]="Ikona na pulpicie: wyłączona (menu Aplikacje > Programowanie)."
    [install_done]="Gotowe. Dalej: test jako użytkownik domenowy, potem seal, wyłączenie, snapshot i Push Image (istniejące pule) / snapshot dla nowych pul."
    [step_remove]="Usuwanie komponentu Eclipse + Java"
    [remove_done]="Usunięto. Dane użytkowników w katalogach NFS (~/.eclipse, ~/eclipse-workspace) pozostają nietknięte."
    [java_kept]="Java JDK pozostawiona (--purge-java, aby ją usunąć)."
    [step_status]="Stan komponentu Eclipse + Java"
    [st_eclipse]="Eclipse: %s"
    [st_java]="Java:    %s"
    [st_launcher]="Program uruchamiający: %s"
    [st_menu]="Skrót w menu: %s"
    [st_missing]="brak"
    [st_desktop_invalid]="desktop-file-validate zgłasza problemy w %s"
    [st_ok]="Komponent jest kompletny."
    [st_bad]="Komponent jest niekompletny - uruchom --install."
)

t() {
    local key=$1 fmt
    shift
    fmt=${MSG_EN[$key]:-$key}
    if [[ $VDI_LANG == pl-PL && -n ${MSG_PL[$key]:-} ]]; then
        fmt=${MSG_PL[$key]}
    fi
    # shellcheck disable=SC2059  # format strings come from the tables above
    printf -- "$fmt" "$@"
}

# --------------------------------------------------------------- logging ---
log() {
    local level=$1 color="" reset=""
    shift
    if [[ -t 2 ]]; then
        reset=$'\e[0m'
        case $level in
            OK) color=$'\e[32m' ;;
            WARN) color=$'\e[33m' ;;
            ERR) color=$'\e[31m' ;;
            STEP) color=$'\e[1;36m' ;;
        esac
    fi
    printf '%s%-4s %s%s\n' "$color" "$level" "$*" "$reset" >&2
    if [[ -d $LOG_DIR && -w $LOG_DIR ]]; then
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >>"$LOG_FILE"
    fi
}

logt() {
    local level=$1
    shift
    log "$level" "$(t "$@")"
}

die() {
    logt ERR "$@"
    exit 1
}

# run CMD... - log the command and mirror its output into the log, keep the exit code.
run() {
    log INFO "\$ $*"
    if [[ -d $LOG_DIR && -w $LOG_DIR ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return "${PIPESTATUS[0]}"
    fi
    "$@"
}

on_error() {
    local rc=$? line=$1
    log ERR "$(t err_unexpected "$rc" "$line" "${BASH_COMMAND:-?}")"
    exit "$rc"
}

confirm() {
    local answer
    [[ $ASSUME_YES == 1 ]] && return 0
    [[ -t 0 ]] || return 1
    read -r -p "$(t prompt_yes_no "$1") " answer || return 1
    [[ $answer =~ ^([yYtT]|yes|tak)$ ]]
}

apt_get() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l run apt-get -y -q \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# write_managed PATH MODE < content - atomic, unchanged files are left alone.
write_managed() {
    local path=$1 mode=$2 tmp
    install -d -m 0755 "$(dirname "$path")"
    tmp=$(mktemp "${path}.vdi.XXXXXX")
    cat >"$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 0
    fi
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path"
    logt OK file_written "$path"
}

remove_path() {
    local p
    for p in "$@"; do
        if [[ -e $p || -L $p ]]; then
            rm -rf -- "$p"
            logt OK file_removed "$p"
        fi
    done
}

state_set() {
    local key=$1 value=$2 tmp
    install -d -m 0750 "$STATE_DIR"
    touch "$STATE_FILE"
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    grep -v "^${key}=" "$STATE_FILE" >"$tmp" || true
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

state_get() {
    [[ -f $STATE_FILE ]] || return 0
    sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1
}

# ---------------------------------------------------------------- config ---
load_config() {
    local f=${CONF_FILE:-${SCRIPT_DIR}/eclipse-java.conf}
    if [[ -f $f ]]; then
        # shellcheck disable=SC1090
        . "$f"
        CONF_LOADED=$f
    fi
    if [[ -z $VDI_LANG ]]; then
        case ${LC_ALL:-${LC_MESSAGES:-${LANG:-}}} in
            pl*) VDI_LANG="pl-PL" ;;
            *) VDI_LANG="en-US" ;;
        esac
    fi
}

validate_config() {
    check_enum JAVA_SOURCE "$JAVA_SOURCE" "temurin debian none"
    check_enum ECLIPSE_VM "$ECLIPSE_VM" "auto jdk bundled"
    check_enum DESKTOP_ICON "$DESKTOP_ICON" "yes no"
    check_enum KEEP_DOWNLOAD "$KEEP_DOWNLOAD" "yes no"
    [[ $JAVA_VERSION =~ ^[0-9]+$ ]] || die err_conf_value JAVA_VERSION "$JAVA_VERSION" "17 21 25 ..."
    [[ $ECLIPSE_RELEASE =~ ^[0-9]{4}-[0-9]{2}$ ]] || die err_conf_value ECLIPSE_RELEASE "$ECLIPSE_RELEASE" "YYYY-MM"
    [[ $ECLIPSE_PACKAGE =~ ^[a-z0-9-]+$ ]] || die err_conf_value ECLIPSE_PACKAGE "$ECLIPSE_PACKAGE" "java jee cpp ..."
    [[ $ECLIPSE_KEEP =~ ^[1-9][0-9]*$ ]] || die err_conf_value ECLIPSE_KEEP "$ECLIPSE_KEEP" "1 2 3 ..."
    [[ -z $ECLIPSE_OSGI_LOCKING || $ECLIPSE_OSGI_LOCKING =~ ^(none|java.io|java.nio)$ ]] ||
        die err_conf_value ECLIPSE_OSGI_LOCKING "$ECLIPSE_OSGI_LOCKING" "'' none java.io java.nio"
}

check_enum() {
    local name=$1 value=$2 allowed=$3
    [[ " $allowed " == *" $value "* ]] || die err_conf_value "$name" "$value" "$allowed"
}

os_check() {
    local id="" version_id="" pretty="" arch
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        {
            id=$(. /etc/os-release && printf '%s' "${ID:-}")
            version_id=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
            pretty=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-}")
        }
    fi
    arch=$(dpkg --print-architecture 2>/dev/null || echo unknown)
    if [[ $id != debian || ! $version_id =~ ^(12|13)$ || $arch != amd64 ]]; then
        logt WARN os_unsupported "${pretty:-unknown} (${arch})"
        confirm "$(t ask_continue)" || die aborted
    fi
}

os_codename() {
    # shellcheck disable=SC1091
    (. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
}

image_sealed() {
    local f="${STATE_DIR}/seal-state.json"
    [[ -s $f ]] && grep -Eq '"sealed"[[:space:]]*:[[:space:]]*true' "$f"
}

# ------------------------------------------------------------------ java ---
java_package() {
    case $JAVA_SOURCE in
        temurin) printf 'temurin-%s-jdk' "$JAVA_VERSION" ;;
        debian) printf 'openjdk-%s-jdk' "$JAVA_VERSION" ;;
    esac
}

java_install() {
    if [[ $JAVA_SOURCE == none ]]; then
        logt INFO java_none
        JAVA_HOME_DIR=""
        return 0
    fi
    local pkg
    pkg=$(java_package)
    logt STEP step_java "$JAVA_VERSION" "$pkg"

    if [[ $JAVA_SOURCE == temurin ]]; then
        java_add_adoptium
    fi
    if ! pkg_installed "$pkg"; then
        if ! apt-cache policy "$pkg" 2>/dev/null | sed -n 's/^ *Candidate: *//p' | grep -qv '(none)'; then
            die java_no_candidate "$pkg" "$(apt-cache pkgnames 2>/dev/null | grep -E '^(openjdk|temurin)-[0-9]+-jdk$' | sort -V | tr '\n' ' ')"
        fi
    fi
    # shellcheck disable=SC2086  # package list is word-split on purpose
    apt_get install --no-install-recommends "$pkg" $JAVA_EXTRA_PACKAGES

    local javac
    javac=$(dpkg -L "$pkg" 2>/dev/null | grep -E '/bin/javac$' | head -n1 || true)
    [[ -n $javac ]] || die java_home_missing "$pkg"
    JAVA_HOME_DIR=$(dirname "$(dirname "$(readlink -f "$javac")")")
    logt OK java_home "$JAVA_HOME_DIR"

    # Make the course JDK the system default (java, javac, jshell in a terminal).
    local tool
    for tool in java javac jshell; do
        if update-alternatives --list "$tool" 2>/dev/null | grep -qx "${JAVA_HOME_DIR}/bin/${tool}"; then
            run update-alternatives --set "$tool" "${JAVA_HOME_DIR}/bin/${tool}" >/dev/null ||
                logt WARN java_alt_failed "$tool"
        fi
    done

    write_managed "$PROFILE_FILE" 0644 <<EOF
${MANAGED_MARK}
export JAVA_HOME="${JAVA_HOME_DIR}"
EOF
    state_set java_package "$pkg"
    state_set java_home "$JAVA_HOME_DIR"
}

java_add_adoptium() {
    local codename
    codename=$(os_codename)
    if [[ ! -s $ADOPTIUM_KEY ]]; then
        pkg_installed gnupg || apt_get install --no-install-recommends gnupg
        curl -fsSL --retry 3 https://packages.adoptium.net/artifactory/api/gpg/key/public |
            gpg --dearmor --yes -o "$ADOPTIUM_KEY"
        chmod 0644 "$ADOPTIUM_KEY"
    fi
    write_managed "$ADOPTIUM_LIST" 0644 <<EOF
deb [arch=amd64 signed-by=${ADOPTIUM_KEY}] https://packages.adoptium.net/artifactory/deb ${codename} main
EOF
    apt_get update
}

# java_major JAVA_HOME - prints the feature release (17, 21 ...) or nothing.
java_major() {
    local rel="$1/release" v=""
    [[ -f $rel ]] && v=$(sed -n 's/^JAVA_VERSION="\([0-9]*\).*/\1/p' "$rel")
    printf '%s' "$v"
}

# --------------------------------------------------------------- eclipse ---
eclipse_name() {
    printf 'eclipse-%s-%s-R-linux-gtk-x86_64.tar.gz' "$ECLIPSE_PACKAGE" "$ECLIPSE_RELEASE"
}

eclipse_dir() {
    printf '%s/eclipse-%s-%s' "$APPS_ROOT" "$ECLIPSE_PACKAGE" "$ECLIPSE_RELEASE"
}

# Sets ARCHIVE to a verified archive (no subshell: DOWNLOADED must survive).
eclipse_get_archive() {
    local name archive sum_file expected actual
    name=$(eclipse_name)
    if [[ -n $ECLIPSE_ARCHIVE ]]; then
        archive=$ECLIPSE_ARCHIVE
    elif [[ -f "${SCRIPT_DIR}/Apps/${name}" ]]; then
        archive="${SCRIPT_DIR}/Apps/${name}"
    fi
    if [[ -n ${archive:-} ]]; then
        logt INFO archive_local "$archive"
        sum_file="${archive}.sha512"
    else
        install -d -m 0755 "$CACHE_DIR"
        archive="${CACHE_DIR}/${name}"
        sum_file="${archive}.sha512"
        if [[ ! -s $archive ]]; then
            logt INFO archive_download "${ECLIPSE_MIRROR}/${ECLIPSE_RELEASE}/R/${name}"
            curl -fL --retry 3 --connect-timeout 20 -o "${archive}.part" \
                "${ECLIPSE_MIRROR}/${ECLIPSE_RELEASE}/R/${name}" >&2
            mv -f "${archive}.part" "$archive"
        fi
        curl -fsSL --retry 3 -o "$sum_file" "${ECLIPSE_MIRROR}/${ECLIPSE_RELEASE}/R/${name}.sha512" || rm -f "$sum_file"
        DOWNLOADED=1
    fi

    if [[ -s $sum_file ]]; then
        expected=$(awk '{print tolower($1); exit}' "$sum_file")
        actual=$(sha512sum "$archive" | awk '{print $1}')
        if [[ $expected != "$actual" ]]; then
            [[ ${DOWNLOADED:-0} == 1 ]] && rm -f "$archive" "$sum_file"
            die archive_bad_sum "$archive"
        fi
        logt OK archive_sum_ok
    else
        logt WARN archive_no_sum "$archive"
        confirm "$(t ask_continue)" || die aborted
    fi
    ARCHIVE=$archive
}

eclipse_install() {
    local dir archive tmp
    dir=$(eclipse_dir)
    logt STEP step_eclipse "$ECLIPSE_RELEASE" "$ECLIPSE_PACKAGE" "$dir"
    install -d -m 0755 "$APPS_ROOT" "$BIN_DIR"

    if [[ -x "${dir}/eclipse" && -f "${dir}/.vdi-installed" ]]; then
        logt OK eclipse_present "$dir"
    else
        eclipse_get_archive
        archive=$ARCHIVE
        tmp=$(mktemp -d "${APPS_ROOT}/.extract.XXXXXX")
        TMP_EXTRACT=$tmp
        run tar -xzf "$archive" -C "$tmp" --no-same-owner
        [[ -x "${tmp}/eclipse/eclipse" ]] || die archive_bad "$archive"
        rm -rf -- "$dir"
        mv "${tmp}/eclipse" "$dir"
        rm -rf -- "$tmp"
        TMP_EXTRACT=""
        cp -p "${dir}/eclipse.ini" "${dir}/eclipse.ini.orig"
        logt OK eclipse_extracted "$dir"
        eclipse_p2_install "$dir"
        if [[ ${DOWNLOADED:-0} == 1 && $KEEP_DOWNLOAD != yes ]]; then
            rm -f "$archive" "${archive}.sha512"
        fi
        date -Is >"${dir}/.vdi-installed"
    fi

    eclipse_write_ini "$dir"
    eclipse_write_customization "$dir"
    eclipse_initialize "$dir"

    # Read-only for users: no p2 self-update, per-user changes go to ~/.eclipse.
    chown -R root:root "$dir"
    chmod -R u+rwX,go+rX,go-w "$dir"
    ln -sfn "$dir" "$LINK"
    state_set eclipse_dir "$dir"
    state_set eclipse_release "$ECLIPSE_RELEASE"
    state_set installed_at "$(date -Is)"
    eclipse_prune "$dir"
}

# Runs Eclipse headless as root with a throw-away HOME, so /root/.eclipse never ends up in the image.
eclipse_headless() {
    local dir=$1 home rc=0
    shift
    home=$(mktemp -d /tmp/vdi-eclipse-home.XXXXXX)
    HOME=$home run timeout 900 "${dir}/eclipse" -nosplash -consoleLog "$@" || rc=$?
    rm -rf -- "$home"
    return "$rc"
}

eclipse_p2_install() {
    local dir=$1 profile
    [[ -n $ECLIPSE_P2_REPOS && -n $ECLIPSE_P2_FEATURES ]] || return 0
    logt INFO p2_installing "$ECLIPSE_P2_FEATURES" "$ECLIPSE_P2_REPOS"
    profile=$(sed -n 's/^eclipse\.p2\.profile=//p' "${dir}/configuration/config.ini" | tr -d '\r')
    eclipse_headless "$dir" -application org.eclipse.equinox.p2.director \
        -repository "$ECLIPSE_P2_REPOS" -installIU "$ECLIPSE_P2_FEATURES" \
        -destination "$dir" ${profile:+-profile "$profile"} ||
        logt WARN p2_failed
}

# Java needed to RUN this Eclipse (2026-09: 25), from the release's own eclipse.ini.
eclipse_min_java() {
    local v=$ECLIPSE_MIN_JAVA
    [[ -n $v ]] || v=$(sed -n 's/^-Dosgi\.requiredJavaVersion=\([0-9]*\).*/\1/p' "$1/eclipse.ini.orig" | tr -d '\r' | head -n1)
    printf '%s' "${v:-21}"
}

# Which JVM runs Eclipse. Prints a bin directory, or nothing for the bundled JustJ JRE.
# Sets JDK_BELOW_MIN=1 when the course JDK is too old to run Eclipse (then it is only
# an installed JRE for projects and the compiler defaults are pinned to it).
eclipse_vm_dir() {
    local dir=$1 major min
    if [[ -z ${JAVA_HOME_DIR:-} ]]; then
        return 0
    fi
    major=$(java_major "$JAVA_HOME_DIR")
    min=$(eclipse_min_java "$dir")
    if [[ -n $major ]] && ((major < min)); then
        JDK_BELOW_MIN=1
    fi
    if [[ $ECLIPSE_VM == bundled ]]; then
        logt INFO vm_bundled "${major:-$JAVA_VERSION}"
    elif [[ ${JDK_BELOW_MIN:-0} == 0 || $ECLIPSE_VM == jdk ]]; then
        if [[ ${JDK_BELOW_MIN:-0} == 1 ]]; then
            logt WARN vm_jdk_too_old "${major:-?}" "$min" "$ECLIPSE_RELEASE"
        else
            logt OK vm_jdk "$major"
        fi
        printf '%s/bin' "$JAVA_HOME_DIR"
    else
        logt WARN vm_jdk_too_old "${major:-?}" "$min" "$ECLIPSE_RELEASE"
        logt INFO vm_bundled "$major"
    fi
}

# eclipse.ini is regenerated from the pristine copy every run (idempotent).
eclipse_write_ini() {
    local dir=$1 vm line skip_next=0 in_vmargs=0 out
    JDK_BELOW_MIN=0
    eclipse_vm_dir "$dir" >"${dir}/.vdi-vm" # not $(...): JDK_BELOW_MIN must survive
    vm=$(cat "${dir}/.vdi-vm")
    rm -f "${dir}/.vdi-vm"
    out=$(mktemp "${dir}/eclipse.ini.XXXXXX")
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if ((skip_next)); then
            skip_next=0
            continue
        fi
        if ((in_vmargs == 0)); then
            if [[ $line == -vm && -n $vm ]]; then
                skip_next=1
                continue
            fi
            if [[ $line == -vmargs ]]; then
                [[ -n $vm ]] && printf -- '-vm\n%s\n' "$vm" >>"$out"
                printf -- '-vmargs\n' >>"$out"
                in_vmargs=1
                continue
            fi
        else
            case $line in
                -Xmx* | -Dosgi.instance.area.default=* | -Dosgi.locking=* | -Declipse.pluginCustomization=*) continue ;;
            esac
        fi
        printf '%s\n' "$line" >>"$out"
    done <"${dir}/eclipse.ini.orig"
    if ((in_vmargs == 0)); then
        [[ -n $vm ]] && printf -- '-vm\n%s\n' "$vm" >>"$out"
        printf -- '-vmargs\n' >>"$out"
    fi
    {
        printf -- '-Xmx%s\n' "$ECLIPSE_XMX"
        printf -- '-Dosgi.instance.area.default=%s\n' "$ECLIPSE_WORKSPACE"
        printf -- '-Declipse.pluginCustomization=%s/vdi-plugin_customization.ini\n' "$dir"
        if [[ -n $ECLIPSE_OSGI_LOCKING ]]; then printf -- '-Dosgi.locking=%s\n' "$ECLIPSE_OSGI_LOCKING"; fi
    } >>"$out"
    if cmp -s "$out" "${dir}/eclipse.ini"; then
        rm -f "$out"
    else
        chmod 0644 "$out"
        mv -f "$out" "${dir}/eclipse.ini"
        logt OK file_written "${dir}/eclipse.ini"
        rm -f "${dir}/.vdi-initialized"
    fi
}

# Product defaults for every new workspace; users can still change them.
eclipse_write_customization() {
    local dir=$1 compiler=""
    if [[ ${JDK_BELOW_MIN:-0} == 1 ]]; then
        # Eclipse runs on a newer JRE than the course JDK: compile for the course level by default.
        compiler="# Course JDK ${JAVA_VERSION} is older than the JRE running Eclipse: pin the compiler level.
org.eclipse.jdt.core/org.eclipse.jdt.core.compiler.compliance=${JAVA_VERSION}
org.eclipse.jdt.core/org.eclipse.jdt.core.compiler.source=${JAVA_VERSION}
org.eclipse.jdt.core/org.eclipse.jdt.core.compiler.codegen.targetPlatform=${JAVA_VERSION}
org.eclipse.jdt.core/org.eclipse.jdt.core.compiler.release=enabled"
    fi
    write_managed "${dir}/vdi-plugin_customization.ini" 0644 <<EOT
${MANAGED_MARK}
# The install is read-only and versioned with the golden image: no update checks.
org.eclipse.equinox.p2.ui.sdk.scheduler/enabled=false
# Oomph: no startup setup tasks and no preference recorder dialogs in labs.
org.eclipse.oomph.setup.ui/skip.startup.tasks=true
org.eclipse.oomph.setup.ui/enable.preference.recorder=false
# Same encoding on every clone and on the students' own machines.
org.eclipse.core.resources/encoding=UTF-8
# Find the course JDK in /usr/lib/jvm in every (also old) workspace.
org.eclipse.jdt.launching/org.eclipse.jdt.launching.PREF_DETECT_VMS_AT_STARTUP=true
${compiler}
EOT
}

# Only after a change of eclipse.ini or plugins (it takes a while).
eclipse_initialize() {
    local dir=$1
    [[ -f "${dir}/.vdi-initialized" ]] && return 0
    if eclipse_headless "$dir" -initialize; then
        date -Is >"${dir}/.vdi-initialized"
        logt OK initialized
    fi
}

# Keep the newest ECLIPSE_KEEP releases of this package (the current one always stays).
eclipse_prune() {
    local current=$1 d n=0
    while IFS= read -r d; do
        [[ $d == "$current" ]] && continue
        n=$((n + 1))
        if ((n >= ECLIPSE_KEEP)); then
            rm -rf -- "$d"
            logt OK old_removed "$d"
        fi
    done < <(find "$APPS_ROOT" -mindepth 1 -maxdepth 1 -type d -name "eclipse-${ECLIPSE_PACKAGE}-*" | sort -rV)
}

# ------------------------------------------------------------------ menu ---
eclipse_icon() {
    local dir=$1 src size
    for size in 256 48 32 16; do
        src=$(find "${dir}/plugins" -maxdepth 2 -path '*org.eclipse.platform_*' -name "eclipse${size}.png" 2>/dev/null | head -n1)
        [[ -n $src ]] || continue
        install -D -m 0644 "$src" "/usr/share/icons/hicolor/${size}x${size}/apps/vdi-eclipse.png"
    done
    if [[ ! -f /usr/share/icons/hicolor/256x256/apps/vdi-eclipse.png && -f "${dir}/icon.xpm" ]]; then
        install -D -m 0644 "${dir}/icon.xpm" /usr/share/pixmaps/vdi-eclipse.xpm
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null || true
    fi
}

menu_install() {
    logt STEP step_menu
    pkg_installed zenity || apt_get install --no-install-recommends zenity
    eclipse_icon "$LINK"
    launcher_write
    user_init_write

    local categories="Development;IDE;Java;"
    [[ -n $MENU_SUBMENU ]] && categories+="X-VDI-Apps;"
    write_managed "$DESKTOP_FILE" 0644 <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Eclipse IDE for Java
Name[pl]=Eclipse IDE dla Javy
GenericName=Java IDE
GenericName[pl]=Środowisko programistyczne Java
Comment=Write, run and debug Java programs (Eclipse ${ECLIPSE_RELEASE}, JDK ${JAVA_VERSION})
Comment[pl]=Pisanie, uruchamianie i debugowanie programów w Javie (Eclipse ${ECLIPSE_RELEASE}, JDK ${JAVA_VERSION})
Exec=${BIN_DIR}/vdi-eclipse
Icon=vdi-eclipse
Terminal=false
StartupNotify=true
StartupWMClass=Eclipse
Categories=${categories}
Keywords=java;eclipse;ide;programming;programowanie;
EOF

    if [[ -n $MENU_SUBMENU ]]; then
        logt INFO submenu "$MENU_SUBMENU"
        write_managed "$DIRECTORY_FILE" 0644 <<EOF
[Desktop Entry]
Type=Directory
Name=${MENU_SUBMENU}
Name[pl]=${MENU_SUBMENU_PL:-$MENU_SUBMENU}
Icon=applications-development
EOF
        write_managed "$MENU_FILE" 0644 <<'EOF'
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
<!-- Managed by VDI-ImageMaint (apps/eclipse-java.sh) -->
<Menu>
  <Name>Applications</Name>
  <Menu>
    <Name>VDI-Apps</Name>
    <Directory>vdi-apps.directory</Directory>
    <Include>
      <Category>X-VDI-Apps</Category>
    </Include>
  </Menu>
</Menu>
EOF
    else
        remove_path "$MENU_FILE" "$DIRECTORY_FILE"
    fi

    if [[ $DESKTOP_ICON == yes ]]; then
        write_managed "$AUTOSTART_FILE" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=VDI Eclipse desktop icon
Exec=${BIN_DIR}/vdi-eclipse-user-init
OnlyShowIn=MATE;
NoDisplay=true
X-MATE-Autostart-Phase=Applications
X-MATE-Autostart-Notify=false
EOF
        logt INFO desktop_icon_on
    else
        remove_path "$AUTOSTART_FILE"
        logt INFO desktop_icon_off
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications || true
    fi
}

# The launcher: refuse to start Eclipse on an unusable NFS home (no ticket / not mounted).
launcher_write() {
    write_managed "${BIN_DIR}/vdi-eclipse" 0755 <<'EOF'
#!/bin/bash
# Managed by VDI-ImageMaint (apps/eclipse-java.sh) - starts the shared Eclipse install.
# Eclipse keeps its workspace and settings in the NFS home; without a writable home
# (no Kerberos ticket, home not mounted) it fails with confusing lock errors, so check first.
case ${LC_ALL:-${LC_MESSAGES:-${LANG:-}}} in
    pl*)
        m_title="Eclipse"
        m_nohome="Twój katalog domowy (%s) jest niedostępny do zapisu.\n\nNajczęściej wygasł bilet Kerberos albo katalog sieciowy (NFS) nie został zamontowany. Wyloguj się i zaloguj ponownie. Jeśli problem wraca, zgłoś go do helpdesku."
        m_noticket="Brak ważnego biletu Kerberos. Eclipse uruchomi się, ale zapisywanie plików w katalogu domowym może przestać działać.\n\nZapisz pracę, wyloguj się i zaloguj ponownie."
        ;;
    *)
        m_title="Eclipse"
        m_nohome="Your home folder (%s) is not writable.\n\nUsually the Kerberos ticket has expired or the network (NFS) home is not mounted. Log off and log on again. If it keeps happening, contact the helpdesk."
        m_noticket="No valid Kerberos ticket. Eclipse will start, but saving to your home folder may stop working.\n\nSave your work, log off and log on again."
        ;;
esac

notify() {
    local kind=$1 text=$2
    if [[ -n ${DISPLAY:-} ]] && command -v zenity >/dev/null 2>&1; then
        zenity "--${kind}" --title="$m_title" --width=420 --text="$text" 2>/dev/null
    else
        printf '%b\n' "$text" >&2
    fi
}

probe="${HOME}/.vdi-write-test.$$"
if ! (: >"$probe") 2>/dev/null; then
    # shellcheck disable=SC2059
    notify error "$(printf "$m_nohome" "$HOME")"
    logger -t vdi-eclipse "home ${HOME} not writable for ${USER:-?}" 2>/dev/null
    exit 1
fi
rm -f "$probe"

if [[ $(stat -f -c %T "$HOME" 2>/dev/null) == nfs* ]] && command -v klist >/dev/null 2>&1 && ! klist -s 2>/dev/null; then
    notify warning "$m_noticket"
    logger -t vdi-eclipse "no valid Kerberos ticket for ${USER:-?}" 2>/dev/null
fi

# SWT on X11 (MATE + Horizon Blast).
export GDK_BACKEND=x11
exec /opt/vdi-apps/eclipse/eclipse "$@"
EOF
}

# Runs at login as the user (XDG autostart): puts the launcher on the desktop once.
# A user who deletes the icon keeps it deleted (marker in the NFS home).
user_init_write() {
    write_managed "${BIN_DIR}/vdi-eclipse-user-init" 0755 <<'EOF'
#!/bin/bash
# Managed by VDI-ImageMaint (apps/eclipse-java.sh) - runs as the user at MATE login.
marker="${XDG_CONFIG_HOME:-$HOME/.config}/vdi-imagemaint/eclipse-desktop-icon"
[[ -e $marker ]] && exit 0
src=/usr/share/applications/vdi-eclipse.desktop
[[ -f $src ]] || exit 0
desk=$(xdg-user-dir DESKTOP 2>/dev/null)
[[ -n $desk && $desk != "$HOME" ]] || desk="$HOME/Desktop"
mkdir -p "$desk" "$(dirname "$marker")" 2>/dev/null || exit 0
dst="${desk}/vdi-eclipse.desktop"
if cp -f "$src" "$dst" 2>/dev/null; then
    chmod 0755 "$dst"
    gio set "$dst" metadata::trusted true 2>/dev/null || true
    : >"$marker"
fi
exit 0
EOF
}

# ----------------------------------------------------------------- modes ---
mode_install() {
    os_check
    # A sealed image refuses package changes (dpkg/apt guard) until "vdi-imagemaint.sh unlock".
    image_sealed && die sealed
    if ! pkg_installed curl || ! pkg_installed ca-certificates; then
        apt_get update
        apt_get install --no-install-recommends curl ca-certificates
    fi
    java_install
    eclipse_install
    menu_install
    state_set component_version "$APP_VERSION"
    logt OK install_done
}

mode_remove() {
    logt STEP step_remove
    remove_path "$DESKTOP_FILE" "$MENU_FILE" "$DIRECTORY_FILE" "$AUTOSTART_FILE" \
        "${BIN_DIR}/vdi-eclipse" "${BIN_DIR}/vdi-eclipse-user-init" "$LINK" \
        /usr/share/pixmaps/vdi-eclipse.xpm
    find /usr/share/icons/hicolor -name 'vdi-eclipse.png' -delete 2>/dev/null || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && { gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null || true; }
    local d
    while IFS= read -r d; do remove_path "$d"; done < <(find "$APPS_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'eclipse-*' 2>/dev/null)
    rmdir "$BIN_DIR" "$APPS_ROOT" 2>/dev/null || true
    command -v update-desktop-database >/dev/null 2>&1 && { update-desktop-database -q /usr/share/applications || true; }

    if [[ $PURGE_JAVA == 1 ]]; then
        local pkg
        pkg=$(state_get java_package)
        [[ -n $pkg ]] && pkg_installed "$pkg" && apt_get purge "$pkg"
        remove_path "$PROFILE_FILE" "$ADOPTIUM_LIST" "$ADOPTIUM_KEY"
        apt_get autoremove --purge
        rm -f "$STATE_FILE"
    else
        logt INFO java_kept
        [[ -f $STATE_FILE ]] && sed -i -E '/^(eclipse_|installed_at|component_version)/d' "$STATE_FILE"
    fi
    logt OK remove_done
}

mode_status() {
    logt STEP step_status
    local ok=1 dir java v
    dir=$(readlink -f "$LINK" 2>/dev/null || true)
    if [[ -n $dir && -x "${dir}/eclipse" ]]; then
        logt INFO st_eclipse "$dir (-vm $(grep -A1 '^-vm$' "${dir}/eclipse.ini" | tail -n1))"
    else
        logt WARN st_eclipse "$(t st_missing)"
        ok=0
    fi
    java=$(state_get java_home)
    if [[ -n $java && -x "${java}/bin/javac" ]]; then
        v=$("${java}/bin/javac" -version 2>&1 | head -n1)
        logt INFO st_java "$v ($java)"
    elif [[ $JAVA_SOURCE != none ]]; then
        logt WARN st_java "$(t st_missing)"
        ok=0
    fi
    if [[ -x ${BIN_DIR}/vdi-eclipse ]]; then logt INFO st_launcher "${BIN_DIR}/vdi-eclipse"; else
        logt WARN st_launcher "$(t st_missing)"
        ok=0
    fi
    if [[ -f $DESKTOP_FILE ]]; then
        logt INFO st_menu "$DESKTOP_FILE"
        if command -v desktop-file-validate >/dev/null 2>&1 && ! desktop-file-validate "$DESKTOP_FILE" >/dev/null 2>&1; then
            logt WARN st_desktop_invalid "$DESKTOP_FILE"
        fi
    else
        logt WARN st_menu "$(t st_missing)"
        ok=0
    fi
    if ((ok)); then logt OK st_ok; else
        logt WARN st_bad
        return 1
    fi
}

cleanup() {
    [[ -n ${TMP_EXTRACT:-} && -d $TMP_EXTRACT ]] && rm -rf -- "$TMP_EXTRACT"
    return 0
}

main() {
    MODE="install"
    ASSUME_YES=0
    PURGE_JAVA=0
    CONF_FILE=""
    CONF_LOADED=""
    local lang_arg=""
    while (($#)); do
        case $1 in
            --install) MODE=install ;;
            --remove) MODE=remove ;;
            --status) MODE=status ;;
            --purge-java) PURGE_JAVA=1 ;;
            -y | --yes) ASSUME_YES=1 ;;
            --config) CONF_FILE=${2:?}; shift ;;
            --lang) lang_arg=${2:?}; shift ;;
            -h | --help) MODE=help ;;
            *) load_config; die err_arg "$1" ;;
        esac
        shift
    done
    load_config
    [[ -n $lang_arg ]] && VDI_LANG=$lang_arg
    if [[ $MODE == help ]]; then
        t usage "$(basename "$0")"
        printf '\n'
        return 0
    fi
    [[ $EUID -eq 0 ]] || die err_root
    validate_config
    install -d -m 0750 "$LOG_DIR"
    trap 'on_error $LINENO' ERR
    trap cleanup EXIT
    logt INFO start "$APP_VERSION" "$MODE" "$ECLIPSE_RELEASE" "$ECLIPSE_PACKAGE" "$JAVA_VERSION" "$JAVA_SOURCE"
    [[ -n $CONF_LOADED ]] && logt INFO conf_loaded "$CONF_LOADED"
    case $MODE in
        install) mode_install ;;
        remove) mode_remove ;;
        status) mode_status || exit 1 ;;
    esac
}

main "$@"
