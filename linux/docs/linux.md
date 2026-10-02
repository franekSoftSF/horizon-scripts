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
| `Horizon/` | `Omnissa-horizonagent-linux-x86_64-*.tar.gz`, `Horizon.Recording.Linux.Agent-*.tar.gz`, `vhci-hcd-1.15.tar.gz` (not in git) |
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
sudo ./vdi-imagemaint.sh recording   # Horizon Recording Agent (optional, asks for the password)
sudo ./vdi-imagemaint.sh apps        # apps/*.sh --install (Eclipse ...)
sudo ./vdi-imagemaint.sh optimize
sudo ./vdi-imagemaint.sh collab      # asks for every Session Collaboration value
sudo ./vdi-imagemaint.sh seal        # runs check first, then powers off -> snapshot
```

## Monthly (Day-2)

Power on the golden image, then run `sudo ./vdi-imagemaint.sh update --then-seal`. The tool unlocks the
image, runs `apt full-upgrade`, and seals it again. If a new kernel needs a reboot, reboot and then run `seal`.

## Download from GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/franekSoftSF/horizon-scripts/main/linux/get-vdi-imagemaint.sh | sudo bash
```

`get-vdi-imagemaint.sh` does the following:
- finds the newest `linux-v*` release (the repository also has Windows releases);
- downloads the release and checks its SHA-256 file;
- installs it into `/opt/vdi-imagemaint`.

Run the same command again to upgrade. Only the tool's own files are replaced; `vdi-imagemaint.conf`,
`Horizon/`, `certs/` and `apps/*.conf` stay as they are. Options: `--version 0.3.0`, `--dir <path>`, `--lang pl-PL`.

### Automatic upgrade

At the start of every run, the tool checks GitHub for a newer `linux-v*` release. If it finds one, it
installs the release in place (SHA-256 checked, local files kept) and starts the same command again with
the new version. It also refreshes the installed per-clone script. If GitHub cannot be reached, the run
continues with the installed version.

- `AUTO_UPGRADE="yes"` (default), `"ask"` or `"no"` in `vdi-imagemaint.conf`;
- `--no-upgrade` skips the upgrade for one run;
- `self-update` checks GitHub now, also when `AUTO_UPGRADE="no"`.

## Existing golden image (mode `adopt`)

If you have an image that was built without this tool, run `adopt` before anything else:

```bash
sudo ./vdi-imagemaint.sh adopt
```

You do not need to copy or edit `vdi-imagemaint.conf.example` first: `adopt` creates `vdi-imagemaint.conf`
from what it finds. The only question is the profile (university or business). The file covers locale, time zone,
keyboard, AD domain and workgroup, SSSD names and ID mapping, NFS server, export and `sec=` from fstab or autofs,
SSO, USB, smart card, True SSO, Collaboration and Recording. If a `vdi-imagemaint.conf` already exists, it is left
unchanged: the detected values go to `vdi-imagemaint.conf.detected` and the differences are listed.

1. **Detects** the current state:
   - desktop sessions and the display manager;
   - the domain join method (SSSD or winbind/Samba) and the machine keytab;
   - how home directories are mounted (fstab, autofs or local);
   - the Horizon agent: its configuration, `OfflineJoinDomain`, `RunOnceScript` and USB components.
2. **Previews** what `prepare`, `domain`, `nfs` and the agent configuration would change. For every file
   it shows a `diff`, with passwords and secrets masked. Nothing is written.
3. **Asks** which steps to keep. A kept step is marked *adopted*: `prepare`/`domain`/`nfs` never run on it
   again, not even after a tool upgrade, unless you pass `--force`. `-y` keeps every step it detected.
4. **Records the agent version** without reinstalling the agent. Omnissa documents no version file, so the
   tool asks for the version (YYMM-y.y.y-build) or reads `ADOPT_AGENT_VERSION`. It also asks whether the
   agent was installed with the options of the current configuration. If not, the next `agent` run with the
   same version reruns the installer once with the configured options.
5. **Keeps the existing join and per-clone script**:
   - With a winbind/Samba join, `OfflineJoinDomain` is left unchanged.
   - An existing `RunOnceScript` (for example a `net ads join` rejoin) is chained through
     `/etc/vdi-imagemaint/runonce.local`. It runs before the SSSD/NFS restart.
   - `check` accepts the adopted desktop, join method and home directories.

If `check` reports L21 (no USB VHCI driver) on an adopted image, run `sudo ./vdi-imagemaint.sh usb`: it builds the driver with the patch from the installed agent, or from the agent archive in `Horizon/`, without reinstalling the agent.

After `adopt`, use `check`, then `agent` (upgrade), `recording`, `apps`, `optimize`, `collab` and `seal` as usual.
The docs recommend building golden images from a fresh installation and never from a cloned system.

## Logons fail after the image was powered off (Kerberos / SSSD)

Symptom: the golden image was powered off for a while, or a snapshot was reverted, and now logons
stop working. This follows from how SSSD and Kerberos behave with AD; the Omnissa docs do not cover it.

| Cause | What the tool does (mode `kerberos`, also run by `domain` and `adopt`) |
|---|---|
| SSSD changes the machine account password on its own every 30 days. AD accepts only the current and the previous password, so an older snapshot or keytab is rejected. | `ad_maximum_machine_account_password_age = 0` in `/etc/sssd/conf.d/60-vdi-imagemaint-kerberos.conf`. `update` rotates the password on purpose (`adcli update`, when older than `MACHINE_PASSWORD_DAYS`=25) right before the new snapshot. |
| SSSD starts before the clock is synchronised, and Kerberos fails above 5 minutes of skew. | `sssd.service` waits for `time-sync.target` (`systemd-time-wait-sync`, at most 90 s). The per-clone script syncs time before restarting SSSD and NFS. |
| User tickets expire in long sessions, and the NFS krb5 homes stop working. | Renewable tickets (7 days), renewed every 60 minutes by SSSD. |

`check` L24 runs `adcli testjoin` and blocks `seal` when AD no longer accepts the keytab. Fix it by restoring a
snapshot whose keytab AD accepts, or by rejoining (back up `/etc/sssd/sssd.conf` first: `realm join` writes its own),
then take a new snapshot. The settings use the domain from `sssd.conf` (never an example value). After writing them the
tool runs `sssctl config-check` and restarts SSSD; if either fails, everything is rolled back. SSSD waits for the clock
only when `systemd-timesyncd` keeps it. Do not go back to snapshots that are
more than one password rotation old. On clones, `runonce.log` shows the time sync and the keytab entries.

## Versions and re-runs

- Each build step (`prepare`, `domain`, `nfs`) is recorded in `build-state.json` with the tool version,
  the time and a fingerprint of the configuration. If you run the step again with the same tool version
  and an unchanged configuration, it is skipped. `--force` runs it again.
- `status` shows the recorded steps, the agent version and options, the VHCI driver and Recording.

## Horizon agent: dependencies, USB 3.0, audio, upgrade

The source is "Desktops and Applications in Omnissa Horizon 8" (PDF, version 2606, provided by the user)
and the Horizon 8 2506 pages. Debian versions: 12.10 and 11.11 for 2506 (KB 87277); 12.13 and 13.3 for 2606.

- **Dependencies** (installed before the agent):
  - `gnome-shell-extension-appindicator` and `libnss3-tools`. Without them, the agent installer stops.
  - `pulseaudio-utils` for audio in/out on Debian 12.x.
  - `open-vm-tools` and `krb5-user`.
- **Installer options** come from the settings: `-A yes -M yes`, `-a` (audio-in, `AUDIO_IN_ENABLE`),
  `-U` (USB, `USB_ENABLE`), `-T` (True SSO) and `-m` (smart card). Add more documented options in
  `HORIZON_AGENT_EXTRA_ARGS`, for example `--webcam`.
- **USB 3.0 / VHCI** follows the documented order for the tarball installer: unpack the agent tarball,
  install the VHCI driver, then install the agent with `-U yes`. The steps:
  - The VHCI source (`vhci-hcd-1.15.tar.gz`) comes from `Horizon/`; if it is not there, the tool downloads
    it from the SourceForge link given in the docs.
  - The tool applies `resources/vhci/patch/vhci.patch` from the agent tarball.
  - The Debian `hcd.h` copy step runs as a DKMS `PRE_BUILD` script.
  - DKMS plus `linux-headers-amd64` rebuilds the driver for every new kernel that `update` installs.
    The docs require a rebuild after each kernel change.
  - With Secure Boot on, the modules must be signed and the MOK key enrolled. The tool only warns about this.
- **FIDO2** keys work through USB redirection (KB 6001193). `FIDO_ENABLE` forces USB on, and
  `FIDO_VIDPID` sets `viewusb.IncludeVidPid` in `/etc/omnissa/config`.
- **Version and upgrade**: the version is read from the archive name `...-YYMM-y.y.y-build.tar.gz`
  and recorded after installation (Omnissa documents no version file). The behaviour:
  - Same version and options: the installer is not run.
  - Same version with different options: the installer runs again with the new options.
  - Newer archive: upgrade. As the docs require, the installer runs again with all feature options, because
    the tarball does not keep them. BlastServer must not be running. A reboot is required afterwards, and
    `check`/`seal` wait for it.
  - Older archive: refused unless you pass `--force`.
  - `update` upgrades the agent and Recording automatically when `Horizon/` contains newer archives
    (`UPDATE_AGENTS`).

## Horizon Recording (mode `recording`)

The Recording Agent needs Horizon 8 2306 or later, the Horizon agent installed first, and port 9443 open
on the server. The tool:
- runs `install.sh -u https://<server>:9443 -n <user> -p <password> -t` from
  `Horizon.Recording.Linux.Agent-x.x.x.x.tar.gz`. `-t` is required for instant clones; `-s <thumbprint>`
  is optional;
- asks for the password, or reads it from `VDI_REC_PASSWORD`. The password is never stored and is masked in the log;
- tracks the version the same way as for the agent: same version is skipped, a newer one is an upgrade
  (then a reboot), and an older one is refused;
- leaves the pairing token `/etc/omnissa/horizonrecording/pairingdata.json` alone during seal.

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
