# shellcheck shell=bash
# USB VHCI kernel driver for Horizon USB redirection (USB 3.0, FIDO2 keys), as in
# "System Requirements for Horizon Agent for Linux" -> "VHCI Driver for USB Redirection":
#   source  https://sourceforge.net/projects/usb-vhci/files/linux%20kernel%20module/ (vhci-hcd-1.15.tar.gz)
#   patch   <unpacked agent tarball>/resources/vhci/patch/vhci.patch
#   Debian  apt install patch g++ make linux-headers-$(uname -r); copy include/linux/usb/hcd.h
#           into linux/<kernel base version>/drivers/usb/core before make
# Installed through DKMS (the documented alternative) so it is rebuilt automatically
# when "update" installs a new kernel - otherwise the driver must be recompiled by hand.

VHCI_DKMS_NAME="usb-vhci-hcd"

vhci_source_archive() {
    local f="${VDI_ROOT}/Horizon/vhci-hcd-${VHCI_VERSION}.tar.gz"
    if [[ ! -s $f ]]; then
        logt INFO vhci_downloading "$VHCI_URL"
        curl -fsSL -o "$f" "$VHCI_URL" || {
            rm -f "$f"
            logt ERR vhci_source_missing "$f" "$VHCI_URL"
            return 1
        }
    fi
    printf '%s' "$f"
}

vhci_installed_for() {
    local kver=$1
    modinfo -k "$kver" usb-vhci-hcd >/dev/null 2>&1 && modinfo -k "$kver" usb-vhci-iocifc >/dev/null 2>&1
}

# vhci_install PATCH_FILE
vhci_install() {
    local patch=$1 src archive dest="/usr/src/${VHCI_DKMS_NAME}-${VHCI_VERSION}" state
    state=$(state_get build '.vhci.version // empty')
    if [[ $state == "$VHCI_VERSION" ]] && vhci_installed_for "$(uname -r)" && [[ ${FORCE:-0} != 1 ]]; then
        logt OK vhci_present "$VHCI_VERSION" "$(uname -r)"
        return 0
    fi
    if [[ ! -s $patch ]]; then
        logt ERR vhci_patch_missing "$patch"
        return 1
    fi
    if [[ -d /sys/firmware/efi ]] && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        logt WARN vhci_secure_boot
    fi
    logt INFO vhci_building "$VHCI_VERSION" "$(uname -r)"
    # linux-headers-amd64 follows the kernel meta-package, so DKMS can rebuild after "update".
    apt_install patch g++ make dkms "linux-headers-$(uname -r)" linux-headers-amd64
    archive=$(vhci_source_archive) || return 1

    src=$(mktemp -d /tmp/vdi-vhci.XXXXXX)
    tar -xzf "$archive" -C "$src"
    (cd "${src}/vhci-hcd-${VHCI_VERSION}" && patch -p1 <"$patch") >/dev/null || {
        logt ERR vhci_patch_failed "$patch"
        rm -rf "$src"
        return 1
    }

    if dkms status "${VHCI_DKMS_NAME}/${VHCI_VERSION}" 2>/dev/null | grep -q .; then
        run dkms remove "${VHCI_DKMS_NAME}/${VHCI_VERSION}" --all || true
    fi
    rm -rf "$dest"
    cp -r "${src}/vhci-hcd-${VHCI_VERSION}" "$dest"
    rm -rf "$src"

    # Debian step from the docs, done per kernel by DKMS before every build.
    cat >"${dest}/vdi-prebuild.sh" <<'EOF'
#!/bin/sh
# copy hcd.h for kernel $1 where the vhci Makefile expects it (Omnissa Debian build step)
set -e
kbase=$(echo "$1" | cut -d '-' -f 1)
mkdir -p "linux/${kbase}/drivers/usb/core"
cp "/lib/modules/$1/source/include/linux/usb/hcd.h" "linux/${kbase}/drivers/usb/core/"
EOF
    chmod 0755 "${dest}/vdi-prebuild.sh"
    cat >"${dest}/dkms.conf" <<EOF
PACKAGE_NAME="${VHCI_DKMS_NAME}"
PACKAGE_VERSION=${VHCI_VERSION}
MAKE_CMD_TMPL="make KVERSION=\$kernelver"
CLEAN="\$MAKE_CMD_TMPL clean"
PRE_BUILD="vdi-prebuild.sh \$kernelver"
BUILT_MODULE_NAME[0]="usb-vhci-iocifc"
DEST_MODULE_LOCATION[0]="/kernel/drivers/usb/host"
MAKE[0]="\$MAKE_CMD_TMPL"
BUILT_MODULE_NAME[1]="usb-vhci-hcd"
DEST_MODULE_LOCATION[1]="/kernel/drivers/usb/host"
MAKE[1]="\$MAKE_CMD_TMPL"
AUTOINSTALL="YES"
EOF
    run dkms add "${VHCI_DKMS_NAME}/${VHCI_VERSION}"
    run dkms build "${VHCI_DKMS_NAME}/${VHCI_VERSION}"
    run dkms install "${VHCI_DKMS_NAME}/${VHCI_VERSION}"
    if ! vhci_installed_for "$(uname -r)"; then
        logt ERR vhci_build_failed "$(uname -r)"
        return 1
    fi
    state_update build '.vhci = {version: $v, kernel: $k, at: $d}' \
        --arg v "$VHCI_VERSION" --arg k "$(uname -r)" --arg d "$(date -Is)"
    logt OK vhci_done "$VHCI_VERSION" "$(uname -r)"
}
