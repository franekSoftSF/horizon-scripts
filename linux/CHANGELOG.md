# Changelog – VDI-ImageMaint for Linux

## 0.1.0 – 2026-10-01
- First version for Debian 12 + MATE on Horizon 2506 Instant Clone.
- Modes: prepare, domain, nfs, agent, apps, optimize (`--revert`), collab, check, seal, unlock, update (`--then-seal`), fido, status; interactive menu.
- Mode `domain`: krb5, SSSD, realm join of the golden image, sudo for AD groups; base for Horizon offline join.
- Optional True SSO / smart card logon (pcscd, OpenSC, PKINIT, SSSD pam_cert_auth, agent `-T`/`-m`).
- Mode `fido`: experimental FIDO2 redirection probe inside a session.
- Seal blocks package changes (dpkg pre-invoke, apt Update::Pre-Invoke, PackageKit masked) and silences user pop-ups (polkit, dconf, coredumps).
- Session Collaboration asked interactively, including the invitation link (UAG URL).
- English/Polish string tables, profiles university/business, tracked and reversible changes in `/var/lib/vdi-imagemaint/*-state.json`.
