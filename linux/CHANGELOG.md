# Changelog – VDI-ImageMaint for Linux

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
