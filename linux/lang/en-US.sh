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

Build (once):   prepare -> domain -> nfs -> agent -> reboot -> apps -> optimize -> collab -> check -> seal
Monthly:        update --then-seal       Reverse a seal: unlock

Modes:
  prepare    base packages, MATE + LightDM, locale, keyboard, time zone, NTP
  domain     krb5.conf, SSSD, realm join of the golden image, sudo, True SSO / smart card
  nfs        NFSv4 home directories with Kerberos (autofs, rpc.gssd, idmapd)
  agent      install/upgrade Horizon Linux Agent from Horizon/ (OfflineJoinDomain=sssd), RunOnce
  apps       run apps/*.sh --install (e.g. Eclipse)
  optimize   VDI tuning (services, MATE dconf, LightDM, journald, sysctl, I/O, polkit)
  collab     Session Collaboration settings - asks for each value (UAG link)
  check      read-only readiness checks (exit 1 on errors)
  seal       check + cleanup + block package changes + quiet desktop for users, then power off
  unlock     reverse seal
  update     unlock if sealed, apt full-upgrade, autoremove
  fido       FIDO2 redirection test inside a session on a clone
  status     tool version, profile, recorded changes

Options:
  --config FILE   configuration file (default: vdi-imagemaint.conf next to the tool)
  --lang en-US|pl-PL
  --revert        with optimize: undo all optimizations
  --then-seal     with update: seal when no reboot is pending
  --force         with seal: seal despite failed checks
  -y, --yes       answer yes to questions
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
MSG[agent_configured]='Agent configured for Instant Clone (OfflineJoinDomain=sssd, RunOnceScript): %s'
MSG[agent_done]='Horizon Linux Agent ready.'

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
MSG[chk_runonce_bad]='RunOnceScript "%s" missing or not executable.'
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
MSG[fido_none]='No FIDO2 device visible - redirection is not active (key plugged into the client? agent/client feature enabled?).'
MSG[menu_domain]='2. Active Directory: Kerberos, SSSD, join (+ True SSO / smart card)'
MSG[menu_fido]='Test FIDO2 redirection (inside a session on a clone)'
