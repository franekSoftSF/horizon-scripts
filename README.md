# Horizon Scripts – VDI-ImageMaint

> Wersja polska: [README.pl.md](README.pl.md).

Golden-image maintenance tooling for **Omnissa Horizon Instant Clone** desktops:

| Tool | Platform | Folder |
|---|---|---|
| **VDI-ImageMaint for Windows** (PowerShell module 2.0) | Windows 11 Enterprise/Education, Horizon 2506+, FSLogix, DEM, App Volumes, Microsoft 365 Apps, new Teams | [`windows/`](windows/) |
| **VDI-ImageMaint for Linux** (Bash) | Debian 12 + MATE, Horizon Linux Agent, SSSD, True SSO / smart card, NFSv4 + Kerberos | [`linux/`](linux/) |

Both tools follow the same cycle – **Update → Optimize → Seal**, reversible with **Unlock** – and talk to the
administrator in **English or Polish**.

> Status: the code is statically checked and covered by offline tests (Pester 5 on Windows PowerShell 5.1 and
> PowerShell 7, PSScriptAnalyzer; Bash tests in a `debian:12` container, shellcheck). The full cycle still has to be
> tested end to end on a real Horizon VM. See [`status.md`](status.md) (Polish) for the current state.

---

## Why this project exists

An Instant Clone pool is only as good as its golden image. Every clone is created from the same snapshot and
is thrown away at logoff, so anything wrong in the image is multiplied across hundreds of desktops:

- **A pending reboot, a running update or a half-installed app** in the snapshot → every clone repeats it at
  logon (slow logons, CPU storms, broken apps).
- **Self-updating software** (Office, Teams, browsers, Adobe, Java) updates itself in each clone and throws the
  result away at logoff – wasted CPU, disk and network, and a different version on every desktop.
- **Forgotten optimizations** (OSOT, services, scheduled tasks) and **forgotten caches/logs** make the image
  bigger and logons slower.
- **Infrastructure agents** (VMware Tools, Horizon Agent, DEM, App Volumes, FSLogix) must match the backend
  version and must be installed in the right order with the right features.
- **Monthly patching by hand** is slow, error-prone and different every time, especially when it depends on
  one administrator's notes.

VDI-ImageMaint turns this into a **repeatable, logged, reversible procedure**:

1. **Update** – Windows Update, Microsoft 365 Apps, new Teams, Edge, winget apps and the packages from the
   manifest (`packages.json`), with automatic reboots and resume.
2. **Optimize** – Omnissa OS Optimization Tool (OSOT) with a template chosen per profile, run as the
   administrator (never as SYSTEM) so the HKCU settings reach the Default User.
3. **Seal** – turns off every self-updater, stops services, clears caches/logs/event logs, checks that no
   reboot is pending and records every change in `seal-state.json`.
4. **Unlock** – reads `seal-state.json` and reverses exactly what Seal changed, so the next maintenance
   window starts from a clean, writable image.

Two phases are kept apart on purpose (see [`windows/docs/image-lifecycle.md`](windows/docs/image-lifecycle.md)):

- **Build** – once per Windows feature release: install from ISO, infrastructure agents, Generalize
  (Sysprep), then the first Update/Optimize/Seal.
- **Day-2** – every month: Unlock → Update → Optimize → Seal, **without** Generalize, then a new snapshot and
  *Push Image* in Horizon.

### Design rules

- **Idempotent** – running a step twice gives the same result; every step can be resumed after a reboot.
- **Reversible** – every seal change is recorded and undone by Unlock.
- **Instant Clone aware** – no disk zeroing/compaction in OSOT Finalize, no pending reboot at Seal, Teams media
  optimization in place, FSLogix excludes only the folders Microsoft recommends.
- **Manifest-driven** – applications are described in `packages.json` (install command, detection,
  version source, seal action) and checked with `-Mode Validate` (JSON Schema for editor hints).
- **Bilingual** – English is the primary language of code, logs and docs; every user-facing message also
  exists in Polish (`-Language auto|en|pl`).
- **Nothing secret in git** – installers, ISOs, certificates and local configuration stay out of the
  repository (see `windows/docs/downloads.md` for where to get each binary).

---

## Use case 1 – University (students and staff, shared labs)

**Situation.** A university runs one or more Instant Clone pools for computer labs, libraries and remote
access. Thousands of students log on to shared desktops; sessions are short and spread across the day, with
peaks at the start of classes. Images must carry teaching software (Java/Eclipse, IDEs, statistics, office,
browsers) and are rebuilt between semesters. The IT team is small and often relies on student assistants.

**Problems VDI-ImageMaint solves here**

- **Logon storms** at the start of a class – OSOT `balanced` template, store apps removed (except Calculator,
  Photos, Snipping Tool, Sticky Notes and Teams), self-updaters off, nothing pending in the snapshot.
- **Many users, little storage** – FSLogix containers of 30 GB per user, cache folders excluded via
  `redirections.xml`, the profile is deleted locally at logoff.
- **Teaching software that changes every semester** – applications live in the manifest; `-Mode Download`
  fetches installers, `-Mode Validate` checks the manifest before the maintenance window.
  Example: Temurin JDK 21/25 and Eclipse IDE installed per machine, with the workspace in the FSLogix container
  (see [`windows/docs/eclipse-java.md`](windows/docs/eclipse-java.md)).
- **Licensing** – Microsoft 365 Apps for enterprise (`O365ProPlusRetail`, A3/A5) with Shared Computer
  Activation; ready-made Office deployment templates per language (PL, EN, DE, FR, PL+EN).
- **Linux labs** – the Linux tool builds Debian 12 + MATE desktops joined to Active Directory through SSSD,
  with NFSv4 Kerberos home directories, optional smart card / True SSO logon and Eclipse + Java for programming
  classes. `seal` blocks package installation and hides update pop-ups, so students cannot change the image.
- **Handover between people** – one menu (`START.cmd` on Windows, `vdi-imagemaint.sh` without arguments on
  Linux) walks through the steps in order, in Polish or English, and every run is logged.

## Use case 2 – Business customers (knowledge workers, Teams-heavy)

**Situation.** A company hosts desktops for office staff who spend the day in Microsoft Teams, Outlook,
OneDrive/SharePoint and line-of-business apps. Users expect the same experience as on a laptop: their files,
signatures and Teams settings follow them, calls and screen sharing work smoothly, and security is enforced.

**Problems VDI-ImageMaint solves here**

- **Teams on VDI** – new Teams provisioned machine-wide (`teamsbootstrapper -p`), auto-update off in the sealed
  image, Horizon Agent installed with *Media Optimization for Microsoft Teams*, OSOT never removes the Teams
  app, notifications kept until verified on the clone.
- **User data and identity** – OneDrive per machine with Known Folder Move, FSLogix containers of 50 GB with
  `RoamIdentity`, DEM for application settings and folder redirection (see
  [`windows/docs/profiles-gpo.md`](windows/docs/profiles-gpo.md) for the recommended GPO/DEM/FSLogix split).
- **Security and compliance** – antivirus, firewall, SmartScreen and Security Center stay enabled (Defender for
  Endpoint in VDI mode), FSLogix/Horizon/App Volumes/DEM antivirus exclusions applied, read-only Sysprep
  readiness check before Generalize, and a log of every change for audits.
- **Predictable monthly patching** – `Update -ThenSeal` runs the whole Day-2 cycle in one step, with the
  Windows feature release pinned (`Windows.TargetRelease`) until Horizon and OSOT support the next one.
- **Licensing** – `O365ProPlusRetail` (E3/E5) or `O365BusinessRetail` (Business Premium), chosen in the
  wizard.
- **Designers and power users** – an optional *Graphics* profile for vGPU pools: OSOT `quality` with hardware
  acceleration kept, 100 GB containers, Adobe media cache excluded from the profile.

### Profile summary

| Setting | University | Business | Graphics (vGPU) |
|---|---|---|---|
| OSOT visual effects | `balanced` | `balanced` | `quality` + GPU acceleration |
| FSLogix `SizeInMBs` | 30 000 | 50 000 | 100 000 |
| FSLogix `RoamIdentity` | optional | yes | yes |
| OneDrive | per customer | per machine + KFM | per machine + KFM |
| Microsoft 365 Apps | `O365ProPlusRetail` (A3/A5) | `O365ProPlusRetail` (E3/E5) or `O365BusinessRetail` | as Business |

---

## Quick start – Windows

1. Copy [`windows/install/`](windows/install/) to `C:\install` on the golden-image VM and add the binaries
   (Office, FSLogix, Horizon Agent, OSOT, …) as described in [`windows/docs/downloads.md`](windows/docs/downloads.md).
2. Double-click `C:\install\START.cmd` (menu in English or Polish), or run the steps directly:

```powershell
.\VDI-ImageMaint.ps1 -Mode Configure                          # wizard: profile, Office, FSLogix, Java/Eclipse, OSOT, apps
.\VDI-ImageMaint.ps1 -Mode Validate                           # check packages.json
.\VDI-ImageMaint.ps1 -Mode Download                           # fetch installers
.\VDI-ImageMaint.ps1 -Mode Update -AutoReboot -ThenSeal -Shutdown   # monthly cycle in one step
.\VDI-ImageMaint.ps1 -Mode Unlock                             # before the next maintenance window
.\VDI-ImageMaint.ps1 -Mode Status -Language pl
```

Logs and state: `C:\ProgramData\VDI-ImageMaint\`. Changes: [`windows/CHANGELOG.md`](windows/CHANGELOG.md).

## Quick start – Linux

Copy [`linux/`](linux/) to `/opt/vdi-imagemaint`, copy `vdi-imagemaint.conf.example` to `vdi-imagemaint.conf`,
then run `sudo ./vdi-imagemaint.sh` for the menu. Details: [`linux/docs/linux.md`](linux/docs/linux.md).

## Tests

```powershell
.\windows\tests\Invoke-Tests.ps1     # Pester 5 (PS 5.1 + pwsh 7) and PSScriptAnalyzer
```

```bash
linux/tests/run-tests.sh             # offline tests (run in a debian:12 container)
```

## Documentation

| Topic | English | Polish |
|---|---|---|
| Image lifecycle (Build vs Day-2, OSOT, Teams, Windows releases) | [image-lifecycle.md](windows/docs/image-lifecycle.md) | [pl](windows/docs/pl/image-lifecycle.md) |
| Profiles, OneDrive, GPO, DEM, FSLogix | [profiles-gpo.md](windows/docs/profiles-gpo.md) | [pl](windows/docs/pl/profiles-gpo.md) |
| Where to download installers | [downloads.md](windows/docs/downloads.md) | [pl](windows/docs/pl/downloads.md) |
| Java / Eclipse on Windows | [eclipse-java.md](windows/docs/eclipse-java.md) | [pl](windows/docs/pl/eclipse-java.md) |
| Linux tool | [linux.md](linux/docs/linux.md) | [pl](linux/docs/pl/linux.md) |
| Java / Eclipse on Linux | [linux-eclipse-java.md](docs/linux-eclipse-java.md) | [pl](docs/pl/linux-eclipse-java.md) |

## License

[MIT](LICENSE) © 2026 Szymon Frankiewicz. Third-party installers and tools (Omnissa OSOT, Horizon Agent, FSLogix,
Microsoft 365 Apps, …) are not part of this repository and keep their own licenses.

## Disclaimer

Omnissa Horizon, Microsoft 365, FSLogix and other product names belong to their owners. This project is not
affiliated with or endorsed by them. Test every change on a pilot pool before rolling it out to production.
