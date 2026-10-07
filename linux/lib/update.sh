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

    # Newer Horizon / Recording archives in Horizon/ -> upgrade them in the same cycle.
    if [[ $UPDATE_AGENTS == yes ]]; then
        update_agents
    fi
    # Fresh machine password right before the new snapshot (see lib/kerberos.sh).
    kerberos_rotate
    # Override copies of the course apps follow the updated packages.
    if [[ -s $(state_file courses) ]]; then
        mode_courses
    fi

    if reboot_pending; then
        logt WARN reboot_needed
        [[ ${THEN_SEAL:-0} == 1 ]] && logt WARN update_seal_after_reboot
        return 0
    fi
    if [[ ${THEN_SEAL:-0} == 1 ]]; then
        mode_seal
    fi
}

update_agents() {
    local archive version installed
    archive=$(agent_find_archive)
    if [[ -n $archive && -e $archive ]] && agent_installed; then
        version=$(agent_archive_version "$archive")
        installed=$(state_get build '.agent.version // empty')
        if [[ -n $version && -n $installed && $(version_cmp "$installed" "$version") == -1 ]]; then
            logt INFO update_agent_newer "$installed" "$version"
            mode_agent
        fi
    fi
    if [[ $REC_ENABLE == yes ]]; then
        archive=$(recording_find_archive)
        installed=$(state_get build '.recording.version // empty')
        if [[ -n $archive && -f $archive && -n $installed ]]; then
            version=$(recording_archive_version "$archive")
            if [[ -n $version && $(version_cmp "$installed" "$version") == -1 ]]; then
                logt INFO update_rec_newer "$installed" "$version"
                mode_recording
            fi
        fi
    fi
}
