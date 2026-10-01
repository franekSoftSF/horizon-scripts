# shellcheck shell=bash disable=SC2034,SC2154  # MSG is declared -A by load_lang
# VDI-ImageMaint for Linux - English string table (primary language).
# printf format strings; every key must also exist in pl-PL.sh (tests/run-tests.sh checks it).

# --- common ---
MSG[start_banner]='VDI-ImageMaint for Linux %s - mode: %s, profile: %s, language: %s'
MSG[err_root]='Run as root (sudo).'
MSG[err_unexpected]='Unexpected error (exit code %s) at line %s: %s'
MSG[err_unknown_option]='Unknown option: %s'
MSG[err_profile]='Unknown profile "%s" (expected: university, business).'
MSG[conf_missing]='Setting %s is empty or still the example value - set it in %s'
MSG[prompt_yes_no]='%s [y/N]:'
MSG[installing_dep]='Installing required tool: %s'
MSG[unit_absent]='Unit %s is not installed - skipped.'
MSG[unit_restore_failed]='Could not re-enable %s.'
MSG[unit_restored]='Restored %s (original state: %s).'
MSG[file_unchanged]='Unchanged: %s'
MSG[file_written]='Written: %s'
MSG[file_restored]='Restored: %s'
MSG[os_unsupported]='Supported OS is Debian 12 (bookworm); found: %s'
MSG[reboot_needed]='A reboot is required before the next step.'

# --- menu / usage ---
MSG[menu_title]='=== VDI-ImageMaint for Linux %s (profile: %s) ==='
MSG[menu_prepare]='1. Base system: packages, MATE + LightDM, locale, time'
MSG[menu_nfs]='3. NFSv4 + Kerberos home directories (autofs)'
MSG[menu_agent]='4. Horizon Linux Agent (Instant Clone, offline join) - then reboot'
MSG[menu_optimize]='6. VDI optimization (reversible: optimize --revert)'
MSG[menu_check]='8. Readiness check (read-only)'
MSG[menu_seal]='9. Seal before snapshot (blocks packages, quiet for users)'
MSG[menu_update]='Monthly: unlock, apt full-upgrade (then seal again)'
MSG[menu_unlock]='Reverse the seal'
MSG[menu_status]='Show tool state'
MSG[menu_quit]='Quit'
MSG[menu_prompt]='Choose:'
MSG[menu_step_failed]='Step "%s" did not finish - see the log.'
MSG[usage_text]='Usage: sudo %s <mode> [options]

Build (once):   prepare -> domain -> nfs -> agent -> reboot -> recording -> apps -> optimize -> collab -> check -> seal
Existing image: adopt -> agent/recording/apps -> optimize -> collab -> check -> seal
Monthly:        update --then-seal       Reverse a seal: unlock

Modes:
  adopt      existing image: detect, create vdi-imagemaint.conf, preview (diff), keep steps, record agent version
  prepare    base packages, MATE + LightDM, locale, keyboard, time zone, NTP
  domain     krb5.conf, SSSD, realm join of the golden image, sudo, True SSO / smart card
  nfs        NFSv4 home directories with Kerberos (autofs, rpc.gssd, idmapd)
  agent      install/upgrade Horizon agent (version-aware; dependencies, USB VHCI driver, audio), RunOnce
  usb        USB VHCI driver only (adopted image, agent not reinstalled)
  recording  Horizon Recording Agent (-t template mode; asks for the server password)
  apps       run apps/*.sh --install (e.g. Eclipse)
  optimize   VDI tuning (services, MATE dconf, LightDM, journald, sysctl, I/O, polkit)
  collab     Session Collaboration settings - asks for each value (UAG link)
  check      read-only readiness checks (exit 1 on errors)
  seal       check + cleanup + block package changes + quiet desktop for users, then power off
  unlock     reverse seal
  update     unlock if sealed, apt full-upgrade, autoremove
  fido       FIDO2 redirection test inside a session on a clone
  status     tool version, profile, recorded changes
  self-update  check GitHub now and upgrade the tool (also when AUTO_UPGRADE=no)

Options:
  --config FILE   configuration file (default: vdi-imagemaint.conf next to the tool)
  --lang en-US|pl-PL
  --revert        with optimize: undo all optimizations
  --then-seal     with update: seal when no reboot is pending
  --force         seal despite failed checks; rerun a done step; reinstall or downgrade agents
  -y, --yes       answer yes to questions
  --no-upgrade    skip the automatic tool upgrade for this run
'

# --- prepare ---
MSG[step_prepare]='PREPARE - base system'
MSG[ask_continue_unsupported]='This OS is not supported. Continue anyway?'
MSG[locale_set]='Locales: %s, default %s, keyboard %s'
MSG[time_set]='Time zone %s, NTP: %s'
MSG[desktop_install]='Installing desktop: %s'
MSG[edge_install]='Installing Microsoft Edge (packages.microsoft.com)'
MSG[prepare_done]='Base system ready.'

# --- DNS ---
MSG[dns_srv_missing]='DNS record %s not found - check the DNS servers of this VM.'

# --- nfs ---
MSG[step_nfs]='NFS - home directories (NFSv4 + Kerberos)'
MSG[nfs_disabled]='NFS_ENABLE is not "yes" - skipped.'
MSG[nfs_no_keytab]='No /etc/krb5.keytab on the golden image - NFS homes can only be tested on a clone (the Horizon offline join creates the keytab).'
MSG[nfs_server_resolves]='NFS server %s resolves.'
MSG[nfs_server_unresolved]='NFS server %s does not resolve in DNS.'
MSG[nfs_done]='Homes: %s mounted on demand under %s (sec=%s).'

# --- agent ---
MSG[step_agent]='AGENT - Horizon Linux Agent'
MSG[agent_archive_missing]='No Horizon Linux Agent archive (*linux*.tar.gz) in %s.'
MSG[agent_installing]='Installing %s with: %s'
MSG[agent_installer_missing]='install_viewagent.sh not found in %s.'
MSG[agent_install_failed]='Horizon Linux Agent installation failed.'
MSG[agent_conf_missing]='Agent configuration directory (/etc/omnissa or /etc/vmware) not found.'
MSG[agent_configured]='Agent configured for Instant Clone (OfflineJoinDomain, SSO, RunOnceScript): %s'
MSG[agent_done]='Horizon Linux Agent %s ready.'

# --- optimize ---
MSG[step_optimize]='OPTIMIZE - VDI tuning'
MSG[autostart_disabled]='Autostart disabled: %s'
MSG[optimize_done]='Optimization done (undo: optimize --revert).'
MSG[step_optimize_revert]='OPTIMIZE --revert - undoing optimizations'
MSG[optimize_reverted]='Optimizations reverted.'

# --- update ---
MSG[step_update]='UPDATE - packages'
MSG[update_unlocking]='Image is sealed - unlocking first.'
MSG[update_new_kernel]='New kernel %s -> %s: verify the Horizon agent supports it.'
MSG[update_done]='Packages updated.'
MSG[update_seal_after_reboot]='Reboot, then run: seal'

# --- seal / unlock ---
MSG[step_seal]='SEAL - prepare for snapshot'
MSG[seal_blocked]='Seal stopped: fix the ERR results above (or use --force).'
MSG[seal_forced]='Seal continues despite failed checks (--force).'
MSG[seal_ssh_keys_removed]='SSH host keys removed - every clone generates its own.'
MSG[seal_cleaning]='Cleaning caches, logs, tickets and leases.'
MSG[seal_cleaned]='Cleanup done.'
MSG[seal_done]='Image sealed. Power off and take the snapshot for the Instant Clone pool.'
MSG[ask_poweroff]='Power off now?'
MSG[step_unlock]='UNLOCK - reversing seal'
MSG[unlock_not_sealed]='Image is not sealed - restoring whatever is recorded.'
MSG[unlock_done]='Seal reversed - the image can be changed.'

# --- check / status ---
MSG[step_check]='CHECK - readiness'
MSG[chk_os_ok]='Debian 12.'
MSG[chk_os_bad]='OS is not Debian 12 - not tested.'
MSG[chk_reboot_pending]='Reboot pending (running kernel %s, installed %s).'
MSG[chk_reboot_none]='No reboot pending.'
MSG[chk_dpkg_broken]='dpkg reports broken or half-installed packages (dpkg --audit).'
MSG[chk_dpkg_ok]='Package database consistent.'
MSG[chk_agent_ok]='Horizon agent service %s enabled.'
MSG[chk_agent_missing]='Horizon agent service is missing or disabled.'
MSG[chk_agent_conf_missing]='viewagent-custom.conf not found.'
MSG[chk_offlinejoin_ok]='OfflineJoinDomain=sssd.'
MSG[chk_offlinejoin_bad]='OfflineJoinDomain=sssd is not set in %s.'
MSG[chk_runonce_ok]='RunOnceScript %s present.'
MSG[chk_runonce_bad]='RunOnceScript "%s" missing or not executable - run adopt (existing image) or agent; seal removes the SSH host keys and relies on it.'
MSG[chk_sssd_ok]='SSSD running.'
MSG[chk_sssd_bad]='SSSD not running.'
MSG[chk_time_ok]='Time synchronized (NTP).'
MSG[chk_time_bad]='Time not synchronized - Kerberos fails above 5 minutes of skew.'
MSG[chk_dns_ok]='DNS SRV records for %s found.'
MSG[chk_desktop_ok]='LightDM + MATE session.'
MSG[chk_desktop_bad]='LightDM is not the display manager or the MATE session is missing.'
MSG[chk_nfs_ok]='NFS homes configured under %s.'
MSG[chk_nfs_bad]='NFS homes incomplete (autofs, /etc/auto.vdi-home or idmapd Domain).'
MSG[chk_vmtools_ok]='open-vm-tools running.'
MSG[chk_vmtools_bad]='open-vm-tools not running.'
MSG[chk_held]='Packages on hold: %s'
MSG[chk_local_users]='Local accounts present (keep only the build admin): %s'
MSG[chk_disk_low]='Only %s MB free on /.'
MSG[chk_disk_ok]='%s MB free on /.'
MSG[chk_optimized]='Optimization applied.'
MSG[chk_not_optimized]='Optimization not applied (mode optimize).'
MSG[chk_summary]='Result: %s error(s), %s warning(s).'
MSG[step_status]='STATUS'
MSG[status_line]='Version %s, profile %s, config %s'
MSG[status_sealed]='Image is SEALED.'
MSG[status_unsealed]='Image is not sealed.'

# --- collab / apps / seal additions ---
MSG[menu_apps]='5. Additional applications (apps/*.sh, e.g. Eclipse)'
MSG[menu_collab]='7. Session Collaboration (asks for every setting, UAG link)'
MSG[seal_guard_msg]='VDI image is sealed - package changes are blocked. Run: vdi-imagemaint.sh unlock (or update)'
MSG[seal_packages_blocked]='Package changes blocked (apt update, apt install, dpkg -i) until unlock.'
MSG[seal_users_quiet]='Desktop users get no package, colord or error pop-ups.'
MSG[tmpfs_next_boot]='/tmp in RAM from the next boot.'
MSG[step_collab]='COLLAB - Horizon Session Collaboration'
MSG[collab_q_enable]='Enable Session Collaboration? (yes/no)'
MSG[collab_q_url]='Link in invitations - external URL, e.g. the UAG (https://..., empty = agent default)'
MSG[collab_q_email]='Allow invitations by e-mail? (yes/no)'
MSG[collab_q_control]='Allow collaborators to take keyboard/mouse control? (yes/no)'
MSG[collab_q_max]='Maximum number of collaborators per session'
MSG[collab_invalid]='Invalid value - try again (current default: %s).'
MSG[collab_summary]='Collaboration: enabled=%s, link=%s, e-mail=%s, control passing=%s, max=%s'
MSG[collab_q_apply]='Write these settings to the agent configuration in %s?'
MSG[collab_cancelled]='Nothing changed.'
MSG[collab_done]='Written: %s, %s'
MSG[collab_restart]='Restart the agent (or the VM) for the change to take effect; clones get it with the next image push.'
MSG[step_apps]='APPS - additional applications'
MSG[apps_running]='Running %s --install'
MSG[apps_done]='%s finished.'
MSG[apps_failed]='%s failed - see its output above.'
MSG[apps_none]='No application scripts in %s.'

# --- domain / certificate logon / FIDO ---
MSG[step_domain]='DOMAIN - Active Directory (SSSD) for Instant Clone offline join'
MSG[dns_srv_ok]='AD domain controllers found in DNS for %s.'
MSG[domain_already_joined]='Already joined to %s.'
MSG[domain_joining]='Joining %s as %s (computer: %s) - enter the password when asked.'
MSG[domain_join_failed]='Joining %s failed - see the output above.'
MSG[sudoers_invalid]='sudoers entry for "%s" is invalid - not written.'
MSG[domain_done]='Domain %s configured.'
MSG[agent_not_joined]='The golden image is not joined to %s - run the domain step first.'
MSG[chk_joined_ok]='Golden image joined to %s, keytab present.'
MSG[chk_joined_bad]='Not joined to %s or /etc/krb5.keytab missing (mode domain).'
MSG[cert_ca_missing]='CA certificate %s not found (CERT_CA_FILES).'
MSG[cert_ca_invalid]='%s is not a PEM certificate.'
MSG[cert_ca_none]='True SSO / smart card enabled but CERT_CA_FILES is empty.'
MSG[chk_cert_ok]='Certificate logon ready (SSSD CA database, pam_cert_auth, pcscd).'
MSG[chk_cert_bad]='Certificate logon incomplete: SSSD CA database, pam_cert_auth or pcscd.socket missing (mode domain).'
MSG[chk_fido_ok]='fido2-token present for the FIDO2 redirection test.'
MSG[chk_fido_bad]='fido2-token missing - run mode agent with FIDO_ENABLE=yes before seal.'
MSG[step_fido]='FIDO - FIDO2 redirection test (run inside a Horizon session on a clone)'
MSG[fido_tools_missing_sealed]='fido2-token is missing and the image is sealed - set FIDO_ENABLE=yes and rebuild.'
MSG[fido_found]='FIDO2 devices visible in this session: %s - redirection works at device level.'
MSG[fido_none]='No FIDO2 device visible - connect the key through USB redirection in the Horizon client (USB_ENABLE/FIDO_ENABLE, VHCI driver).'
MSG[menu_domain]='2. Active Directory: Kerberos, SSSD, join (+ True SSO / smart card)'
MSG[menu_fido]='Test FIDO2 redirection (inside a session on a clone)'

# --- 0.2.0: versions, agent dependencies, USB VHCI, Recording ---
MSG[step_already_done]='Step %s already done by version %s (%s) with the same configuration - skipped (--force runs it again).'
MSG[step_rerun]='Step %s was done by version %s - running again for %s or a changed configuration.'
MSG[agent_version_unknown]='Horizon agent is installed but its version was not recorded by this tool - running the installer as an upgrade.'
MSG[agent_downgrade]='Installed agent %s is newer than the archive %s - refused (use --force to downgrade).'
MSG[agent_up_to_date]='Horizon agent %s already installed with the same options (%s) - installer not run.'
MSG[agent_action]='Agent %s: installed %s, archive %s, options: %s'
MSG[agent_blast_running]='BlastServer is running (active session) - log off all sessions or reboot, then run the upgrade (Omnissa prerequisite).'
MSG[vhci_downloading]='Downloading the USB VHCI driver source: %s'
MSG[vhci_source_missing]='USB VHCI source %s missing and download from %s failed - copy it to Horizon/.'
MSG[vhci_present]='USB VHCI driver %s already installed for kernel %s.'
MSG[vhci_patch_missing]='VHCI patch %s not found in the agent archive.'
MSG[vhci_secure_boot]='UEFI Secure Boot is on: the VHCI modules must be signed and the MOK enrolled (see the Omnissa VHCI steps).'
MSG[vhci_building]='Building USB VHCI driver %s for kernel %s (DKMS).'
MSG[vhci_patch_failed]='Applying %s to the VHCI source failed.'
MSG[vhci_build_failed]='USB VHCI modules are not available for kernel %s after the DKMS build.'
MSG[vhci_done]='USB VHCI driver %s installed for kernel %s (rebuilt automatically for new kernels).'
MSG[step_recording]='RECORDING - Horizon Recording Agent'
MSG[rec_disabled]='REC_ENABLE is not "yes" - skipped.'
MSG[rec_url_invalid]='REC_SERVER_URL "%s" must be https://<server>:9443.'
MSG[rec_needs_agent]='Install the Horizon agent first (mode agent) - the Recording Agent requires it.'
MSG[rec_archive_missing]='No Horizon.Recording.Linux.Agent-*.tar.gz in %s.'
MSG[rec_up_to_date]='Horizon Recording Agent %s already installed - skipped (--force reinstalls).'
MSG[rec_downgrade]='Installed Recording Agent %s is newer than the archive %s - refused (use --force).'
MSG[rec_installing]='Recording Agent: installed %s, archive %s, server %s (template mode -t).'
MSG[rec_password_prompt]='Password of %s on the Horizon Recording Server:'
MSG[rec_password_missing]='No password given - nothing installed.'
MSG[rec_installer_missing]='install.sh not found in %s.'
MSG[rec_install_failed]='Horizon Recording Agent installation failed - see the output above.'
MSG[rec_done]='Horizon Recording Agent %s installed.'
MSG[domain_discover_failed]='realm discover %s failed - check DNS before joining.'
MSG[chk_deps_ok]='Agent dependency packages installed.'
MSG[chk_deps_missing]='Agent dependency packages missing:%s (mode agent).'
MSG[chk_vhci_ok]='USB VHCI driver available for kernel %s.'
MSG[chk_vhci_bad]='USB VHCI driver missing for kernel %s - USB redirection (USB 3.0, FIDO2) will not work. Run mode usb.'
MSG[chk_rec_ok]='Horizon Recording Agent service enabled.'
MSG[chk_rec_bad]='Horizon Recording Agent service missing or disabled (mode recording).'
MSG[chk_cs_ok]='Connection Server %s resolves in DNS.'
MSG[chk_cs_bad]='Connection Server %s does not resolve - the agent cannot reach the broker.'
MSG[menu_recording]='Horizon Recording Agent (asks for the server password)'
MSG[update_agent_newer]='Newer Horizon agent in Horizon/: %s -> %s - upgrading.'
MSG[update_rec_newer]='Newer Horizon Recording Agent in Horizon/: %s -> %s - upgrading.'

# --- 0.3.0: adopt ---
MSG[step_adopt]='ADOPT - take over an existing golden image'
MSG[adopt_sealed]='The image is sealed - run unlock first.'
MSG[adopt_os_untested]='This OS is not Debian 12 - detection and preview still run; nothing is changed without your answer.'
MSG[adopt_desktop]='Desktop sessions: %s; display manager: %s; default target: %s'
MSG[adopt_domain]='Domain join: %s; realm: %s; machine keytab: %s'
MSG[adopt_homes]='Home directories: %s; SSSD home setting: %s'
MSG[adopt_agent]='Horizon agent installed: %s; config: %s; OfflineJoinDomain: %s; RunOnceScript: %s; USB components: %s'
MSG[adopt_preview_title]='PREVIEW - what the build steps would change (nothing is written)'
MSG[adopt_preview_step]='--- step %s'
MSG[adopt_preview_dm]='prepare would switch the display manager from %s to lightdm.'
MSG[adopt_preview_mate]='prepare would install the MATE desktop (no MATE session found).'
MSG[adopt_preview_locale]='prepare would change the system locale from %s to %s.'
MSG[adopt_preview_tz]='prepare would change the time zone from %s to %s.'
MSG[preview_same]='unchanged: %s'
MSG[preview_change]='would change: %s'
MSG[preview_kv_same]='unchanged: %s %s=%s'
MSG[preview_kv_change]='would change: %s %s: %s -> %s'
MSG[adopt_decide_title]='DECIDE - adopted steps are kept as they are and never run by the tool (only with --force)'
MSG[adopt_q_step]='Keep the existing configuration for step %s (found: %s)?'
MSG[adopt_step_marked]='Step %s adopted - the tool will not overwrite it.'
MSG[adopt_agent_known]='Agent version %s already recorded.'
MSG[adopt_q_agent_version]='Installed Horizon agent version (YYMM-y.y.y-build) [%s]:'
MSG[adopt_agent_version_unknown]='Agent version not recorded - mode agent will run the installer as an upgrade.'
MSG[adopt_q_agent_args]='Was the agent installed with the options of the current configuration (%s)?'
MSG[adopt_agent_recorded]='Agent recorded as %s (options: %s) - not reinstalled.'
MSG[adopt_runonce_chained]='Existing RunOnceScript %s kept: called from the tool per-clone script.'
MSG[adopt_done]='Image adopted. Kept steps: %s. Next: check, then optimize / collab / seal as needed.'
MSG[agent_offlinejoin_kept]='OfflineJoinDomain left unchanged (adopted image joined with %s).'
MSG[step_adopted]='Step %s was adopted from the existing image (%s) - skipped (--force applies the tool settings).'
MSG[chk_offlinejoin_adopted]='OfflineJoinDomain set (adopted image, join method %s).'
MSG[chk_join_service_ok]='%s running.'
MSG[chk_join_service_bad]='%s not running.'
MSG[chk_desktop_adopted]='Adopted desktop with display manager %s (not the tested LightDM + MATE).'
MSG[chk_nfs_adopted]='Home directories adopted from the existing image (%s).'
MSG[menu_adopt]='0. Existing image: detect, preview, keep (adopt)'

# --- 0.3.1: adopt creates the configuration ---
MSG[adopt_q_profile]='Profile for this image - university or business [%s]:'
MSG[adopt_config_title]='CONFIG - settings detected on this image'
MSG[adopt_config_header]='Created by VDI-ImageMaint %s adopt on %s (%s) from the settings found on this image.'
MSG[adopt_config_header2]='All other settings use conf/defaults.conf and the profile; add or change values here.'
MSG[adopt_config_created]='Configuration created from the detected settings: %s'
MSG[adopt_config_exists]='%s already exists and was not changed - detected values written to %s'
MSG[adopt_config_diff]='differs: %s: configuration %s, detected %s'

# --- 0.3.2 ---
MSG[chk_deps_missing_installed]='Agent installer dependencies missing:%s - the installed agent runs without them; install them before the next agent upgrade.'
MSG[chk_cs_example]='HORIZON_CS_FQDN is still the example value %s - set the real Connection Server name in vdi-imagemaint.conf (or leave it empty).'
MSG[step_usb]='USB - VHCI driver for USB redirection (agent not reinstalled)'
MSG[usb_no_patch]='No VHCI patch in the installed agent and no agent archive in %s - copy Omnissa-horizonagent-linux-x86_64-*.tar.gz there.'
MSG[usb_patch_from]='VHCI patch taken from %s.'
MSG[usb_agent_component_missing]='The agent has no USB component (installed without -U yes): run mode agent with USB_ENABLE="yes" (same version: --force) so USB redirection works.'
MSG[menu_usb]='USB redirection driver (VHCI) only - also for an adopted image'
MSG[adopt_runonce_set]='Per-clone script %s set as RunOnceScript in %s (new SSH host keys and SSSD/NFS refresh on every clone).'
MSG[chk_conf_example]='Example values still in the configuration:%s - set them in %s.'
MSG[chk_conf_example_detected]='Example values still in the configuration:%s - the values found on this image are in %s (copy them over).'

# --- 0.4.0: self-update ---
MSG[selfupdate_unreachable]='GitHub not reachable - continuing with the installed version.'
MSG[selfupdate_current]='VDI-ImageMaint %s is the newest release.'
MSG[selfupdate_available]='Newer VDI-ImageMaint release: %s -> %s.'
MSG[selfupdate_q]='Upgrade the tool to %s now?'
MSG[selfupdate_failed]='Upgrade to %s failed - continuing with the installed version.'
MSG[selfupdate_done]='Tool upgraded to %s - starting the command again with the new version.'
MSG[selfupdate_runonce]='Per-clone script %s updated to this tool version.'
MSG[step_selfupdate]='SELF-UPDATE - check GitHub for a newer release'
MSG[menu_self-update]='Upgrade this tool from GitHub now'
