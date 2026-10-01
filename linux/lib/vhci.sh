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

# VHCI source candidates, best first: unpacked folders and .tar.gz in the source dirs,
# then the download (pristine source from the URL in the Omnissa docs).
vhci_source_candidates() {
    local f
    find_sources "vhci-hcd-${VHCI_VERSION}" d | while IFS= read -r f; do
        [[ -f ${f}/Makefile ]] && printf '%s\n' "$f"
    done
    find_sources "vhci-hcd-${VHCI_VERSION}.tar.gz" f
    printf 'download\n'
}

# vhci_download -> prints the downloaded .tar.gz (checked to be a real gzip tarball)
vhci_download() {
    local f="${VDI_ROOT}/Horizon/vhci-hcd-${VHCI_VERSION}.tar.gz"
    install -d "${VDI_ROOT}/Horizon"
    if [[ ! -s $f ]] || ! tar -tzf "$f" >/dev/null 2>&1; then
        logt INFO vhci_downloading "$VHCI_URL"
        if ! curl -fsSL -o "$f" "$VHCI_URL" || ! tar -tzf "$f" >/dev/null 2>&1; then
            rm -f "$f"
            logt ERR vhci_source_missing "$f" "$VHCI_URL"
            return 1
        fi
    fi
    printf '%s' "$f"
}

# vhci_prepare SOURCE PATCH WORKDIR - copy/unpack SOURCE into WORKDIR/vhci-hcd-<v> and make
# sure the Omnissa patch is in (applied now, or already there). Never touches SOURCE.
# Returns 1 when the patch does not fit this source; patch output goes to the log.
vhci_prepare() {
    local src=$1 patch=$2 work=$3 dir out
    dir="${work}/vhci-hcd-${VHCI_VERSION}"
    rm -rf "$dir"
    if [[ -d $src ]]; then
        cp -r "$src" "$dir"
        (cd "$dir" && make clean >/dev/null 2>&1) || true
    else
        tar -xzf "$src" -C "$work" || return 1
    fi
    [[ -d $dir ]] || return 1
    logt INFO vhci_source "$src"
    if (cd "$dir" && patch -p1 -R --dry-run -s <"$patch") >/dev/null 2>&1; then
        logt INFO vhci_already_patched
        return 0
    fi
    # Dry run first: a failing patch must not leave a half-patched tree behind.
    if out=$(cd "$dir" && patch -p1 --dry-run <"$patch" 2>&1); then
        (cd "$dir" && patch -p1 -s <"$patch")
        return 0
    fi
    logt WARN vhci_patch_no_fit "$src"
    [[ -w $LOG_DIR ]] && printf '%s\n' "$out" >>"$LOG_FILE"
    return 1
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
    # A folder unpacked by hand may be patched already - or changed so that this agent's
    # patch no longer fits (e.g. patched for an older agent): then fall back to the next
    # candidate, finally the pristine download.
    local cand ok=0
    src=$(mktemp -d /tmp/vdi-vhci.XXXXXX)
    while IFS= read -r cand; do
        if [[ $cand == download ]]; then
            cand=$(vhci_download) || break
        fi
        if vhci_prepare "$cand" "$patch" "$src"; then
            ok=1
            break
        fi
    done < <(vhci_source_candidates)
    if ((ok == 0)); then
        logt ERR vhci_patch_failed "$patch"
        rm -rf "$src"
        return 1
    fi

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

# Mode "usb": USB VHCI driver only, for an image whose agent is already installed
# (e.g. adopted) - the agent is not reinstalled. The patch comes from the installed
# agent (resources/vhci/patch, as for the RPM install) or from the newest agent
# archive in Horizon/ (as for the tarball install).
mode_usb() {
    logt STEP step_usb
    local patch="" d work="" archive
    for d in /usr/lib/omnissa/viewagent /usr/lib/vmware/viewagent; do
        [[ -s ${d}/resources/vhci/patch/vhci.patch ]] && { patch="${d}/resources/vhci/patch/vhci.patch"; break; }
    done
    if [[ -z $patch ]]; then
        archive=$(agent_find_archive)
        if [[ -z $archive || ! -e $archive ]]; then
            logt ERR usb_no_patch "$(source_dirs | tr '\n' ' ')"
            exit 1
        fi
        if [[ -d $archive ]]; then
            patch=$(find "$archive" -path '*resources/vhci/patch/vhci.patch' -print -quit)
        else
            work=$(mktemp -d /tmp/vdi-usb.XXXXXX)
            tar -xzf "$archive" -C "$work"
            patch=$(find "$work" -path '*resources/vhci/patch/vhci.patch' -print -quit)
        fi
        if [[ -z $patch ]]; then
            [[ -n $work ]] && rm -rf "$work"
            logt ERR vhci_patch_missing "$archive"
            exit 1
        fi
        logt INFO usb_patch_from "$(basename "$archive")"
    fi
    if ! vhci_install "$patch"; then
        [[ -n $work ]] && rm -rf "$work"
        exit 1
    fi
    [[ -n $work ]] && rm -rf "$work"
    # USB redirection also needs the agent's USB component (installed with -U yes).
    if [[ -z $(find /usr/lib/omnissa /usr/lib/vmware -maxdepth 4 -name '*usbarbitrator*' 2>/dev/null | head -n1 || true) ]]; then
        logt WARN usb_agent_component_missing
    fi
    logt WARN reboot_needed
    mark_reboot_required
}
