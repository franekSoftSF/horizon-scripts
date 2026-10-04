# Changelog – VDI-ImageMaint for Linux

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
