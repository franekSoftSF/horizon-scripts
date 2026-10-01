# VDI-ImageMaint for Linux – instructions

Golden-image tool for **Debian 12 + MATE** on **Omnissa Horizon 2506 Instant Clone**.
`linux/` = complete `/opt/vdi-imagemaint` on the VM. User docs: `docs/linux.md` (EN), `docs/pl/linux.md` (PL).
State and next steps: `status.md` / `status.json` in this folder (keep both in sync).

## Decisions (user, 2026-10-01)
- Debian 12 bookworm, MATE + LightDM, NFSv4 + Kerberos (sec=krb5p) homes via autofs.
- **SSSD/realm module `domain` is ours** (user reversed the earlier "Horizon does it" decision): it is
  required for Horizon offline join and for the planned **True SSO + smart card logon** (pam_cert_auth,
  PKINIT so NFS krb5 still gets a TGT). **FIDO2 redirection** is experimental – mode `fido` probes it.
- **Seal must block package changes** (apt/dpkg/PackageKit) and **show no errors/pop-ups to users**.
- Session Collaboration settings (incl. invitation link = UAG URL) are **asked interactively** (`collab`).
- Everything else: make the VDI faster (`optimize`).
- `apps/` belongs to the separate Eclipse/Java session – do not edit; mode `apps` runs `apps/*.sh --install --yes`.

## Conventions
- Bash, `set -Eeuo pipefail`, LF, UTF-8 (no BOM). Mode = `lib/<mode>.sh` with `mode_<name>()`.
- Every user-facing text via `t KEY` / `logt LEVEL KEY` from `lang/en-US.sh` + `lang/pl-PL.sh`
  (same keys and `%s` count – tests enforce it). Log levels INFO/OK/WARN/ERR/STEP.
- Change files only via `write_file` / `set_kv` / `file_track`, services via `unit_off`: originals are
  recorded once in `/var/lib/vdi-imagemaint/<section>-state.json` and restored by `--revert` / `unlock`.
- Settings live in `conf/defaults.conf` (documented there); profiles override, local config overrides both.
- Watch out: `cond && cmd` as the last line of a function returns 1 under `set -e`; use `if`.
- Instant clones are forked, not booted – per-clone work goes into `files/runonce.sh`.

## Verification
```bash
bash tests/run-tests.sh                       # works in WSL / any bash; tracked-file test needs jq
docker run --rm -v "<repo>/linux:/src:ro" debian:12 ...   # jq + shellcheck + seal/collab integration
```
Docker Desktop is installed (start it first). Nothing runs end-to-end without a VM with the Horizon agent;
say clearly what was tested in the container vs. on a VM.
