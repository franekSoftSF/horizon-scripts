#!/bin/bash
# VDI-ImageMaint for Linux - download, verify and install/upgrade the tool from GitHub.
#
#   curl -fsSL https://raw.githubusercontent.com/franekSoftSF/horizon-scripts/main/linux/get-vdi-imagemaint.sh | sudo bash
#   sudo bash get-vdi-imagemaint.sh [--version 0.3.0] [--dir /opt/vdi-imagemaint] [--lang pl-PL]
#
# Picks the newest "linux-v*" release (the repository also has Windows releases), checks
# the SHA-256 file and unpacks into the install directory. An upgrade replaces only the
# tool's own files: vdi-imagemaint.conf, Horizon/, certs/, apps/*.conf and anything else
# you added stay untouched. Needs bash, curl, tar, sha256sum (all in a Debian base install).
# It also creates the working folders (Horizon/, certs/) and downloads what is freely
# available - the USB VHCI driver source; Omnissa installers need a login and are copied by hand.

set -Eeuo pipefail

REPO="franekSoftSF/horizon-scripts"
DEST="/opt/vdi-imagemaint"
VERSION=""
LANG_SEL=${LC_ALL:-${LANG:-}}

while (($#)); do
    case $1 in
        --version) VERSION=${2:-}; shift ;;
        --dir) DEST=${2:-}; shift ;;
        --lang) LANG_SEL=${2:-}; shift ;;
        -h | --help) sed -n '2,10p' "$0" 2>/dev/null || true; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

msg() {
    local en=$1 pl=$2
    shift 2
    # shellcheck disable=SC2059  # format strings are literals in this file
    if [[ $LANG_SEL == pl* ]]; then printf -- "$pl\n" "$@"; else printf -- "$en\n" "$@"; fi
}
die() {
    msg "$@" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "Run as root (sudo)." "Uruchom jako root (sudo)."
for c in curl tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "Missing command: %s (apt install %s)" "Brak polecenia: %s (apt install %s)" "$c" "$c"
done

if [[ -z $VERSION ]]; then
    VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=100" |
        grep -oE '"tag_name": *"linux-v[0-9][^"]*"' | sed -E 's/.*"linux-v([^"]+)"/\1/' | sort -V | tail -n1) || true
    [[ -n $VERSION ]] || die "No linux-v* release found in %s." "Nie znaleziono wydania linux-v* w %s." "$REPO"
fi
VERSION=${VERSION#linux-v}
FILE="vdi-imagemaint-linux-${VERSION}.tar.gz"
URL="https://github.com/${REPO}/releases/download/linux-v${VERSION}"

INSTALLED=""
[[ -r ${DEST}/lib/common.sh ]] && INSTALLED=$(sed -n 's/^VDI_VERSION="\(.*\)"/\1/p' "${DEST}/lib/common.sh")
msg "Release %s -> %s (installed: %s)" "Wydanie %s -> %s (zainstalowane: %s)" "$VERSION" "$DEST" "${INSTALLED:-none}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "${WORK}/${FILE}" "${URL}/${FILE}" ||
    die "Download failed: %s" "Pobieranie nie powiodło się: %s" "${URL}/${FILE}"
curl -fsSL -o "${WORK}/${FILE}.sha256" "${URL}/${FILE}.sha256" ||
    die "Download failed: %s" "Pobieranie nie powiodło się: %s" "${URL}/${FILE}.sha256"
(cd "$WORK" && sha256sum -c --quiet "${FILE}.sha256") ||
    die "SHA-256 check failed - not installed." "Suma SHA-256 się nie zgadza - nie zainstalowano."
msg "SHA-256 OK" "SHA-256 OK"

tar -xzf "${WORK}/${FILE}" -C "$WORK"
[[ -x ${WORK}/vdi-imagemaint/vdi-imagemaint.sh ]] ||
    die "Unexpected archive layout." "Nieoczekiwana zawartość archiwum."

install -d -m 0755 "$DEST"
# Tool-owned directories are replaced as a whole (removes files dropped in the new version).
for d in lib lang conf files docs tests; do
    rm -rf "${DEST:?}/${d}"
done
cp -a "${WORK}/vdi-imagemaint/." "${DEST}/"
chown -R root:root "$DEST"

# Working folders and the freely downloadable package (kept on upgrades).
install -d -m 0755 "${DEST}/Horizon" "${DEST}/certs"
VHCI_FILE="${DEST}/Horizon/vhci-hcd-1.15.tar.gz"
VHCI_SRC="https://sourceforge.net/projects/usb-vhci/files/linux%20kernel%20module/vhci-hcd-1.15.tar.gz/download"
if [[ -s $VHCI_FILE ]] && tar -tzf "$VHCI_FILE" >/dev/null 2>&1; then
    :
elif curl -fsSL --connect-timeout 10 --max-time 120 -o "${VHCI_FILE}.part" "$VHCI_SRC" &&
    tar -tzf "${VHCI_FILE}.part" >/dev/null 2>&1; then
    mv -f "${VHCI_FILE}.part" "$VHCI_FILE"
    msg "Downloaded: %s" "Pobrano: %s" "$VHCI_FILE"
else
    rm -f "${VHCI_FILE}.part"
    msg "USB VHCI source not downloaded (offline?) - the tool downloads it later when needed." \
        "Nie pobrano źródeł USB VHCI (brak sieci?) - narzędzie pobierze je później, gdy będą potrzebne."
fi
if ! ls "${DEST}"/Horizon/*horizonagent-linux* /install/*horizonagent-linux* >/dev/null 2>&1; then
    msg "Copy the Horizon Linux Agent (Omnissa-horizonagent-linux-x86_64-*.tar.gz, Customer Connect login) to %s/Horizon/ - optional: Horizon.Recording.Linux.Agent-*.tar.gz, code_*.deb (VS Code)." \
        "Skopiuj Horizon Linux Agent (Omnissa-horizonagent-linux-x86_64-*.tar.gz, wymaga logowania w Customer Connect) do %s/Horizon/ - opcjonalnie: Horizon.Recording.Linux.Agent-*.tar.gz, code_*.deb (VS Code)." "$DEST"
fi

if [[ ! -f ${DEST}/vdi-imagemaint.conf ]]; then
    msg "Existing golden image: sudo %s/vdi-imagemaint.sh adopt  (creates vdi-imagemaint.conf from what it finds)" \
        "Istniejący obraz: sudo %s/vdi-imagemaint.sh adopt  (tworzy vdi-imagemaint.conf z wykrytych ustawień)" "$DEST"
    msg "New image: cp %s/vdi-imagemaint.conf.example %s/vdi-imagemaint.conf, edit it, then sudo %s/vdi-imagemaint.sh" \
        "Nowy obraz: cp %s/vdi-imagemaint.conf.example %s/vdi-imagemaint.conf, uzupełnij, potem sudo %s/vdi-imagemaint.sh" \
        "$DEST" "$DEST" "$DEST"
else
    msg "Your vdi-imagemaint.conf, Horizon/ and certs/ were kept." "Twój vdi-imagemaint.conf, Horizon/ i certs/ zostały zachowane."
fi
msg "VDI-ImageMaint for Linux %s installed in %s." "VDI-ImageMaint dla Linuksa %s zainstalowany w %s." "$VERSION" "$DEST"
