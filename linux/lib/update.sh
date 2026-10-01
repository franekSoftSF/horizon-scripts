# shellcheck shell=bash
# Mode "update": monthly Day-2 cycle on the golden image (no rejoin, no rebuild).
# A sealed image is unlocked first; "--then-seal" seals again when no reboot is pending.

mode_update() {
    logt STEP step_update
    if is_sealed; then
        logt INFO update_unlocking
        mode_unlock
    fi
    local pkg before after
    before=$(newest_kernel)
    for pkg in $APT_HOLD_PACKAGES; do
        run apt-mark hold "$pkg"
    done

    apt_get update
    apt_get full-upgrade
    apt_get autoremove --purge
    after=$(newest_kernel)
    [[ $before != "$after" ]] && logt WARN update_new_kernel "$before" "$after"
    logt OK update_done

    if reboot_pending; then
        logt WARN reboot_needed
        [[ ${THEN_SEAL:-0} == 1 ]] && logt WARN update_seal_after_reboot
        return 0
    fi
    if [[ ${THEN_SEAL:-0} == 1 ]]; then
        mode_seal
    fi
}
