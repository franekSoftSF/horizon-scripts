# Changelog – VDI-ImageMaint for Linux

## 0.7.1 – 2026-10-08
- Course apps: Larch (python3-xraylarch with Larix, the XAS analysis GUI that follows Demeter's Athena/Artemis), ifeffit and feff85exafs - requested by lecturers (Demeter itself is not packaged in Debian). They land in Courses > Education. Verified on Debian 13 (Larch 0.9.81).

## 0.7.0 – 2026-10-08
- Debian 13 (trixie) supported next to Debian 12 (all packages verified on Debian 13). Horizon agent: Debian 13 needs 2606+ (Omnissa docs) - agent refuses older archives on Debian 13 (unless --force), check L27 warns.
- NFS_MODE="fstab": one NFS share on NFS_MOUNTPOINT in /etc/fstab, mounted on first access (x-systemd.automount), homes HOME_ROOT/<login> - the layout of the existing images (/home/STUDENT). adopt records it; check L12 understands it.

## 0.6.8 – 2026-10-08
- seal: users on instant clones see only "Log Out" (SEAL_HIDE_POWER=yes) - a polkit rule denies power-off, reboot, halt, suspend and hibernate to everybody outside the sudo group, so MATE, the logout dialog and the GDM login screen hide those buttons (also `systemctl poweroff` from a terminal). unlock removes it.

## 0.6.7 – 2026-10-08
- New mode `nfsmount`: NFS entries in /etc/fstab get `_netdev,x-systemd.automount,x-systemd.mount-timeout=30` (mount on first access) - on the VM the sec=krb5 home share sometimes did not mount at boot and stayed missing until a manual mount. fstab checked with findmnt --verify, original kept, `nfsmount --revert` restores it.
- check L26: NFS shares from fstab that are neither mounted nor automount points.

## 0.6.6 – 2026-10-08
- Machine password rotation is off by default (MACHINE_PASSWORD_ROTATION=off): with snapshots of the golden image a rotation leaves every older snapshot with a stale keytab (AD logons fail there), and on the VM `adcli update` did not finish within 120 s in the large AD anyway. Docs no longer claim that the previous password keeps older snapshots working.

## 0.6.5 – 2026-10-07
- diag: NFS section - fstab/autofs entries, mounted NFS (findmnt), rpc-gssd / nfs-client / autofs / rpc-statd state, rpc-gssd and kernel NFS messages, keytab principals, and for the user who ran sudo: ticket caches in /tmp and a 10 s home-directory access test as that user (by uid, without PAM).

## 0.6.4 – 2026-10-07
- Fix (VM): the self-upgrade printed "-fsSL: command not found" - get-vdi-imagemaint.sh replaced itself while bash was still reading it. The installer is now one block read completely before it runs, and the self-upgrade runs a temporary copy.
- Fix (VM): sudo/logons of AD users failed with "PAM account management error" - optimize disabled NetworkManager-wait-online, so SSSD could start before the network on the golden image and stay offline. Removed from the list; units an older version turned off but no longer listed are restored by the next optimize.

## 0.6.3 – 2026-10-07
- Fresh Debian has no curl: get-vdi-imagemaint.sh installs curl and ca-certificates when missing and can be started with wget; the procedure starts with step 0 (curl, sudo via `su -`). Release notes carry the complete procedure (docs/release-notes-template.md); stable releases/latest links.

## 0.6.2 – 2026-10-07
- courses installs the missing course applications first (COURSES_INSTALL, COURSES_PACKAGES: geany jupyter-notebook qtcreator octave jmol gnumeric texmaker texstudio; VS Code from a code_*.deb in Horizon/ or /install); packages not in the apt sources are reported; nothing is installed on a sealed image.
- get-vdi-imagemaint.sh creates Horizon/ and certs/, downloads the USB VHCI source (checked tarball) and says which Omnissa installers must be copied by hand.

## 0.6.1 – 2026-10-07
- Courses folder keeps the usual sub-categories in MATE: Courses > Programming / Education / Office / Graphics / Other (from each app's Categories, as the MATE menu places it; EN/PL names). GNOME stays one flat folder.
- COURSES_APPS also takes Geany, Jupyter Notebook and Jmol (seen in the VM's Programming/Education menus).
- Fix: the generated MATE menu file of 0.6.0 was invalid XML ("--" inside a comment), so MATE ignored it; Eclipse is now moved into Courses too. Test added for generated XML comments.

## 0.6.0 – 2026-10-07
- GDM is the display manager (Horizon SSO logs on through gdm-hzncred and starts MATE with SSODesktopType=UseMATE): prepare no longer switches to LightDM, check L11 accepts GDM or LightDM with a MATE session, LightDM tuning only when LightDM is used.
- New mode `courses`: one "Courses" folder (COURSES_FOLDER_NAME, PL "Zajęcia") for the course applications - GNOME app-grid folder via the dconf system db (locked with COURSES_LOCK=yes), MATE submenu via override copies in /usr/local/share/applications with Categories=X-VDI-Apps (merged with the Eclipse VDI-Apps menu). Apps from COURSES_APPS (default: octave gnumeric qtcreator code.desktop texmaker texstudio texdoctk) plus Eclipse; missing apps skipped. Run by apps, refreshed by update, `courses --revert` removes it.

## 0.5.4 – 2026-10-07
- L24 checks the machine keytab with `kinit -k` first (direct KDC login, seconds; principal taken from the keytab) and uses `adcli testjoin` only when kinit is inconclusive - on the VM adcli did not answer within 30 s in a large university domain.
- New mode `diag`: read-only diagnosis (time, realm, SSSD and its config check, keytab principals/kvno, kinit and adcli results, DNS, last SSSD journal lines, agent settings, runonce.log), shown and saved to /var/log/vdi-imagemaint/diag-*.txt with secrets masked - for desktops without clipboard.

## 0.5.3 – 2026-10-07
- check hung at L24 on the VM: `adcli testjoin` now runs with a 30 s limit and no terminal input; a timeout is a warning ("not verified"), the adcli output goes to the log. `adcli update` (password rotation) gets a 120 s limit and no terminal input.
- L07 shows the SSSD domain from sssd.conf instead of a configured example value.

## 0.5.2 – 2026-10-04
- Root cause of the golden-image outage (found by the user): seal stopped SSSD and deleted its cache (/var/lib/sss/db cache_*/timestamps_*, /var/lib/sss/mc). After the restart SSSD had no cached users and credentials, and without a reachable DC nobody could log on. Removed: seal no longer touches the SSSD cache; the per-clone script and the machine password rotation no longer run `sss_cache -E` (only the domain join does). Regression test added.

## 0.5.1 – 2026-10-02
- Safety after a VM incident (logons broken on a golden image): Kerberos settings use the SSSD domain from sssd.conf, never an example AD_DOMAIN; after writing them `sssctl config-check` and an SSSD restart must pass, otherwise everything is rolled back automatically; SSSD waits for time sync only when systemd-timesyncd keeps the clock; adopt asks before applying them; machine password rotation never runs on a keytab AD already rejects; L24 no longer suggests `domain --force`.

## 0.5.0 – 2026-10-02
- Kerberos/SSSD robustness (logons failing after the image was powered off): no automatic machine password change (ad_maximum_machine_account_password_age = 0, conf.d snippet); update rotates it with adcli before the snapshot (MACHINE_PASSWORD_ROTATION, MACHINE_PASSWORD_DAYS); sssd waits for time-sync.target (systemd-time-wait-sync, 90 s cap); renewable user tickets. Applied by domain and adopt, mode kerberos.
- Per-clone script: synchronises time before restarting SSSD/NFS and logs the keytab entries.
- check L24 (adcli testjoin, blocks seal on a rejected keytab), L25 (settings present).

## 0.4.2 – 2026-10-02
- VHCI: when the agent patch does not fit an unpacked vhci-hcd folder (changed by hand or patched for another agent version), the next source is tried and finally the pristine download; patches are dry-run first (no half-patched tree), the patch output goes to the log; downloads are checked to be real tarballs.

## 0.4.1 – 2026-10-02
- Installers are found in Horizon/ and in HORIZON_EXTRA_DIRS (default /install, the hand-made layout of existing images); agent installers may be .tar.gz or already unpacked folders, chosen by the version in the name (Omnissa 2506 over VMware 2406).
- VHCI source may be an unpacked vhci-hcd-1.15 folder; an already applied Omnissa patch is detected and not applied twice.
- adopt proposes the agent version from the newest installer found (e.g. /install/Omnissa-horizonagent-linux-x86_64-2506-8.16.0-...).

## 0.4.0 – 2026-10-02
- Automatic tool upgrade: every run checks the newest linux-v* GitHub release; a newer one is installed in place through get-vdi-imagemaint.sh (SHA-256, local files kept) and the same command restarts with it. AUTO_UPGRADE=yes|ask|no, --no-upgrade, mode self-update. Offline runs continue unchanged.
- The installed per-clone script is refreshed when the tool version changes it.

## 0.3.2 – 2026-10-02
- New mode `usb`: USB VHCI driver only (patch from the installed agent or the agent archive), for adopted images - no agent reinstall.
- check: missing agent installer dependencies are a warning when the agent is already installed; example Connection Server names are reported as "set the configuration", not as a DNS error.
- Menu: errors found by check are no longer shown as "step did not finish".
- Example configuration: HORIZON_CS_FQDN empty by default.
- adopt always installs the per-clone script and sets RunOnceScript (seal removes SSH host keys and relies on it); an existing RunOnceScript stays chained. Previously only images that already had a RunOnceScript got it.
- check L00: example values left in vdi-imagemaint.conf are listed, with a pointer to vdi-imagemaint.conf.detected.

## 0.3.1 – 2026-10-02
- `adopt` creates `vdi-imagemaint.conf` from the detected settings (locale, time zone, keyboard, AD domain/workgroup, SSSD names and ID mapping, NFS from fstab/autofs, SSO, USB, smart card, True SSO, Collaboration, Recording); asks only for the profile. An existing configuration is never overwritten: detected values go to `vdi-imagemaint.conf.detected` and differences are listed.
- `get-vdi-imagemaint.sh` points existing images to `adopt`.

## 0.3.0 – 2026-10-01
- New mode `adopt` for existing golden images: detects desktop/display manager, join method (SSSD / winbind), home directories and the Horizon agent; previews prepare/domain/nfs/agent changes as diffs (secrets masked, nothing written); marks kept steps as adopted (never rerun, also after tool upgrades, unless --force); records the agent version without reinstalling; keeps a non-SSSD OfflineJoinDomain and chains an existing RunOnceScript.
- `check` accepts adopted desktop, join service (sssd / winbind) and home directories.
- `write_file` / `set_kv` preview mode; RunOnce site hook runs before the SSSD/NFS restart (90 s).
- `get-vdi-imagemaint.sh`: download the newest linux-v* GitHub release, verify SHA-256, install or upgrade in place keeping local files.

## 0.2.0 – 2026-10-01
- Version awareness: build steps (prepare, domain, nfs) skipped when done by the same tool version with the same configuration (`--force` reruns); `status` lists steps and installed versions.
- Agent: version from the archive name, skip / reconfigure / upgrade / refuse downgrade; upgrade only without a running BlastServer; reboot tracked for check/seal.
- Agent dependencies per Omnissa docs (Debian): gnome-shell-extension-appindicator, libnss3-tools, pulseaudio-utils, open-vm-tools, krb5-user; flags built from settings (-a, -U, -T, -m).
- USB 3.0 redirection: VHCI driver 1.15 with the agent's vhci.patch, Debian hcd.h step, DKMS (rebuilt for new kernels); FIDO2 through USB (viewusb.IncludeVidPid).
- New mode `recording`: Horizon Recording Agent (-t template mode), password asked and masked, version-aware upgrade.
- `update` upgrades agent/Recording when newer archives are in Horizon/.
- SSSD per docs: ad_gpo_map_interactive = +gdm-hzncred; True SSO pam_p11_allowed_services, certmap, NetbiosDomain, PKINIT in [realms]; smart card packages + sss-smart-card-optional; SSODesktopType=UseMATE.

## 0.1.0 – 2026-10-01
- First version for Debian 12 + MATE on Horizon 2506 Instant Clone.
- Modes: prepare, domain, nfs, agent, apps, optimize (`--revert`), collab, check, seal, unlock, update (`--then-seal`), fido, status; interactive menu.
- Mode `domain`: krb5, SSSD, realm join of the golden image, sudo for AD groups; base for Horizon offline join.
- Optional True SSO / smart card logon (pcscd, OpenSC, PKINIT, SSSD pam_cert_auth, agent `-T`/`-m`).
- Mode `fido`: experimental FIDO2 redirection probe inside a session.
- Seal blocks package changes (dpkg pre-invoke, apt Update::Pre-Invoke, PackageKit masked) and silences user pop-ups (polkit, dconf, coredumps).
- Session Collaboration asked interactively, including the invitation link (UAG URL).
- English/Polish string tables, profiles university/business, tracked and reversible changes in `/var/lib/vdi-imagemaint/*-state.json`.
