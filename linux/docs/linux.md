# VDI-ImageMaint for Linux (Debian 12, MATE, Instant Clone)

Golden-image tooling for **Debian 12 (bookworm) + MATE** desktops on **Omnissa Horizon 2506
Instant Clone**: SSSD on the golden image + Horizon offline domain join per clone, optional
True SSO / smart card logon, experimental FIDO2 redirection test, NFSv4 + Kerberos home directories. Same lifecycle as the Windows tool: **Build → Update → Optimize → Seal**,
reversible with **Unlock**. Profiles: `university`, `business`. Messages in English and Polish.

## Layout

The repository folder `linux/` is the complete `/opt/vdi-imagemaint` on the VM.

| Path | Purpose |
|---|---|
| `vdi-imagemaint.sh` | entry point (no arguments = menu) |
| `vdi-imagemaint.conf.example` | copy to `vdi-imagemaint.conf` (git-ignored) and adjust |
| `conf/defaults.conf`, `conf/profile-*.conf` | every setting with its default; profile defaults |
| `lib/*.sh` | one file per mode + `common.sh` (config, i18n, logging, tracked changes) |
| `lang/en-US.sh`, `lang/pl-PL.sh` | string tables (English primary) |
| `files/runonce.sh` | per-clone script, installed as `/usr/local/sbin/vdi-imagemaint-runonce.sh` |
| `certs/` | CA certificates (PEM) for True SSO / smart card logon (not in git) |
| `apps/*.sh` | optional application installers, run by mode `apps` – e.g. [Eclipse + Java](../../docs/linux-eclipse-java.md) |
| `Horizon/` | Horizon Linux Agent `*linux*.tar.gz` (not in git) |
| `tests/run-tests.sh` | offline tests |

On the VM, logs are in `/var/log/vdi-imagemaint/` and state is in `/var/lib/vdi-imagemaint/`. There is one
`<section>-state.json` per section: `build`, `optimize` and `seal`. Each original file is backed up once.

## Build (once per golden image)

```bash
sudo cp -r linux /opt/vdi-imagemaint && cd /opt/vdi-imagemaint
sudo cp vdi-imagemaint.conf.example vdi-imagemaint.conf && sudo nano vdi-imagemaint.conf
sudo ./vdi-imagemaint.sh prepare     # packages, MATE + LightDM, locale, time (NTP = AD)
sudo ./vdi-imagemaint.sh domain      # krb5, SSSD, realm join (asks for the join password), True SSO / smart card
sudo ./vdi-imagemaint.sh nfs         # autofs + NFSv4 sec=krb5p, idmapd, SSSD snippet
sudo ./vdi-imagemaint.sh agent       # Horizon agent, OfflineJoinDomain=sssd, RunOnceScript
sudo reboot
sudo ./vdi-imagemaint.sh apps        # apps/*.sh --install (Eclipse ...)
sudo ./vdi-imagemaint.sh optimize
sudo ./vdi-imagemaint.sh collab      # asks for every Session Collaboration value
sudo ./vdi-imagemaint.sh seal        # runs check first, then powers off -> snapshot
```

## Monthly (Day-2)

Power on the golden image, then run `sudo ./vdi-imagemaint.sh update --then-seal`. The tool unlocks the
image, runs `apt full-upgrade`, and seals it again. If a new kernel needs a reboot, reboot and then run `seal`.

## What each mode changes

- **domain**: writes `krb5.conf`, `sssd.conf` and `smb.conf` and joins the golden image with `realm join`
  (adcli). Grants sudo to AD groups. With `OfflineJoinDomain=sssd`, the Horizon agent then creates a computer
  account and keytab for every clone. Ticket caches are `FILE:/tmp/krb5cc_%U` because rpc.gssd cannot read KCM.
  - **True SSO / smart card** (`TRUESSO_ENABLE`, `SMARTCARD_ENABLE`): installs pcscd, OpenSC and krb5-pkinit
    and writes the CA chain from `certs/` to `/etc/sssd/pki/sssd_auth_ca_db.pem`. Sets `pam_cert_auth` and
    adds `pkinit_anchors` to krb5.conf, so a certificate logon also gets a TGT and NFS krb5p keeps working.
    The agent is installed with `-T yes` / `-m yes`.
  - **FIDO2** (`FIDO_ENABLE`, experimental): `fido2-tools` is installed before seal. Run `fido` inside a Horizon
    session on a clone, with a key plugged into the client. It lists the FIDO2 devices that the desktop sees.
- **optimize** (undo with `optimize --revert`):
  - Disables services that a VM does not need, such as bluetooth, ModemManager, avahi, plocate, fwupd,
    anacron and exim4. Masks sleep, suspend and hibernate.
  - MATE settings through dconf: no compositing or animations, solid background, no power saving, and no
    thumbnails, previews or item counts in Caja on NFS. Disables event sounds.
  - LightDM: hides the user list and disables the guest account.
  - System: journald in RAM, sysctl tuning, I/O scheduler `none`, and `/tmp` in RAM (optional).
  - polkit: users cannot shut down, reboot or suspend the clone.
- **seal** (undo with `unlock`):
  - Runs `check`, disables the apt timers and unattended-upgrades, and masks PackageKit.
  - Cleans caches, logs, tickets, the SSSD cache and DHCP leases. Removes the SSH host keys; the RunOnce
    script creates new ones on each clone.
  - **Blocks package changes for everyone until unlock**: dpkg `pre-invoke` and apt `Update::Pre-Invoke`
    refuse `apt update`, `apt install` and `dpkg -i`. Package queries still work.
  - **Hides pop-ups from users**: polkit denies PackageKit and apt actions without a password prompt and
    allows colord without the "authentication required" dialog. Turns off MATE housekeeping and
    network notifications and disables core dumps.
- **collab** asks for every value; `-y` takes the defaults from the config file. It writes
  `CollaborationEnable` to `viewagent-custom.conf` and `collaboration.serverUrl` (invitation link,
  e.g. the UAG URL), `enableEmail`, `enableControlPassing` and `maxCollabors` to the agent's `config` file.

## Applications (mode `apps`)

`apps` runs every `apps/*.sh --install --yes` and stops at the first failure. Each installer keeps its own
state and log in `/var/lib/vdi-imagemaint/` and `/var/log/vdi-imagemaint/`. It refuses to run on a
sealed image, so run `apps` before `seal`.

- **Eclipse + Java** (`apps/eclipse-java.sh`, v1.0.0): Eclipse 2026-09 needs Java 25 to run, so the
  default JDK is Temurin 25 from the Adoptium apt repository. Files go to `/opt/vdi-apps/`.
  Details: [docs/linux-eclipse-java.md](../../docs/linux-eclipse-java.md).

## Known limits

- **Teams**: the Linux agent has no Media Optimization for Teams. The `business` profile installs
  Edge, so Teams runs as a web app.
- **FIDO2**: whether the Linux agent 2506 redirects FIDO2 devices is to be tested (mode `fido`).
  The install switch, if any, goes into `HORIZON_AGENT_ARGS_FIDO`.
- **GPO**: ADSys is Ubuntu-only (most features need Ubuntu Pro) and is not available for Debian 12.
  `samba-gpupdate` needs a Samba/winbind machine account, which the SSSD offline join does not create.
  Use SSSD `ad_gpo_access_control` for logon rights and this tool or DEM-like scripts for settings.
- Agent install switches (`-T`, `-m`) and configuration keys (`OfflineJoinDomain`, `RunOnceScript`, `CollaborationEnable`,
  `collaboration.*`) follow the Horizon Linux agent documentation. Verify them for the agent build you deploy.
- Instant clones are forked, not booted. Anything that must differ per clone belongs in
  `files/runonce.sh` or `/etc/vdi-imagemaint/runonce.local`. `/etc/machine-id` is shared by all clones.

## Verification

`bash tests/run-tests.sh` checks syntax, line endings, EN/PL key and placeholder parity, keys used in the
code, config precedence, tracked-file restore and `set_kv`. Shellcheck uses `linux/.shellcheckrc`.
