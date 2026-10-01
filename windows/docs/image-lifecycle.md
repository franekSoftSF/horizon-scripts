# Golden image lifecycle – Build (with Generalize) and Day-2 (Update → Optimize → Finalize → Seal)

> Polish version: [pl/image-lifecycle.md](pl/image-lifecycle.md)
> Sources: Omnissa TechZone *Manually creating optimized Windows images for Horizon VMs*,
> Omnissa docs *OSOT Command Line Operations*, Omnissa KB 77253 *Troubleshooting Windows Sysprep Failures*.

## 1. Two phases, one rule

| Phase | When | Generalize (Sysprep) | Result |
|---|---|---|---|
| **Build** | New image, and every Windows **feature release** (24H2 → 25H2) | **Yes, mandatory, exactly once** | Clean, generalized golden VM with agents |
| **Day-2** | Monthly patches, app updates | **No** | Same golden VM, updated, re-optimized, re-finalized |

Why Generalize is not repeated in Day-2:
- Omnissa's order is **Optimize → Generalize → install Horizon agents → Finalize**. After the agents are in,
  generalizing again is outside the supported order (the agents, App Volumes and DEM are installed on a generalized OS).
- Every Generalize uses up a rearm (licensing), drops domain membership and rebuilds OOBE.
- Instant Clone pools use **ClonePrep** by default. It gives clones the golden image SID, so the golden
  image itself must be generalized once. Per-clone Sysprep customization is optional.
- Omnissa's own Day-2 guidance: re-enable Windows Update → update → **Optimize and Finalize again**.

**Feature releases: rebuild, do not upgrade in place.** An in-place-upgraded golden image is a common
source of Sysprep and OOBE problems. It also carries the old OS's leftovers into every clone.

## 2. Build phase – step by step

| # | Step | Tool / command | Why it matters on 24H2 / 25H2 |
|---|---|---|---|
| 1 | VM: UEFI + Secure Boot + vTPM, VMXNET3, PVSCSI, no floppy/serial | vSphere | vTPM is required by Windows 11. It also makes **automatic device encryption** possible, see step 4 |
| 2 | Install from a clean ISO. At the first OOBE screen press **Ctrl+Shift+F3** → **audit mode** (built-in Administrator) | – | OSOT Generalize **requires audit mode**. Do not create users and do not sign in with a Microsoft account |
| 3 | In audit mode, cancel the Sysprep dialog on every logon | – | Audit mode survives reboots |
| 4 | **Stop device encryption / BitLocker** immediately: `PreventDeviceEncryption=1`, BDESVC disabled, C: fully decrypted | `Test-SysprepReadiness.ps1` checks it | Recent Win11 builds turn on device encryption, and Sysprep then fails when it leaves audit mode. OSOT 2606+ does this in Optimize, earlier builds do not |
| 5 | **Block Store per-user updates**: policy `WindowsStore\AutoDownload=2`, do not open the Store | policy | A Store app updated for Administrator but not for all users fails Sysprep with `0x80073cf2` |
| 6 | VMware Tools → reboot | `packages.json` VMwareTools | – |
| 7 | Windows Update until nothing is pending, then reboot | `-Mode Update` | Sysprep refuses a pending reboot: `0x36b7 … updates that require a reboot` |
| 8 | Applications: M365 (ODT), new Teams **provisioned** (`teamsbootstrapper -p`), FSLogix, customer apps | `-Mode Packages` | **Provisioned** MSIX survive Sysprep. MSIX registered **only for the current user** do not |
| 9 | **OSOT Optimize** (profile JSON + common options) → reboot | `-Mode Optimize` | Removes provisioned Store apps you do not want. Always pass `--exclude MSTeams` with `-storeapp remove-all` |
| 10 | **Readiness check – must be all PASS** | `Scripts\Test-SysprepReadiness.ps1` (runs automatically in `-Mode Generalize`) | Catches every known blocker *before* Sysprep |
| 11 | **Snapshot "pre-generalize"** | vSphere | A failed Sysprep often leaves the VM unbootable. This snapshot is your rollback |
| 12 | **OSOT Generalize** (`-g <unattend.xml>`), reboot → OOBE via answer file | `-Mode Generalize` | OSOT cannot combine Generalize and Finalize in one run. A reboot is required between them |
| 13 | After the first logon wait 1–2 min (AppX provisioning), then remove per-user Copilot / BingSearch | `Get-AppxPackage -AllUsers Microsoft.Copilot \| Remove-AppxPackage -AllUsers` (same for `Microsoft.BingSearch`) | Recent builds install them for the current user during OOBE. That breaks Sysprep-based pool customization later |
| 14 | Horizon Agent (**Instant Clone** + **Media Optimization for Microsoft Teams**), DEM, App Volumes Agent → reboot | `packages.json` | Agents go **after** Generalize |
| 15 | **OSOT Finalize** (initial build set, see §4) | `-Mode Finalize` | – |
| 16 | **Seal** → shut down → snapshot → Push Image | `-Mode Seal -AsSystem -Shutdown` | – |

If Sysprep fails, read `C:\Windows\System32\Sysprep\Panther\setuperr.log` and `setupact.log`.
After a clone fails, read `C:\Windows\Panther\` and `C:\Windows\Panther\UnattendGC\`.
`Test-SysprepReadiness.ps1` prints the last errors from these logs.

## 3. Day-2 cycle (monthly)

```
Unlock → Update (packages, M365, Teams -p, winget, Windows Update, reboots) →
OSOT Optimize (again – updates re-enable services/tasks) → OSOT Finalize (Day-2 set) →
Seal -AsSystem -Shutdown → snapshot → Push Image
```
No Generalize here. Also skip zeroing free space (Finalize 7) and Compact (2).

## 4. OSOT settings for fast boot and logon (Instant Clone)

An Instant Clone boots by forking a running parent VM, so "fast start" really means three things:
fast ClonePrep, a short first logon, and no background work on the clone right after it is created.

| Lever | Setting | Effect |
|---|---|---|
| .NET precompile | Finalize **0** (NGEN) after every .NET update | Clones do not compile .NET in the background. Without it, Windows compiles when idle and can hold a full core for up to an hour per clone |
| Component store | Finalize **1** (DISM cleanup) after updates | Smaller image, less I/O |
| Disk cleanup / event logs | Finalize **3**, **4** | Smaller delta, clean logs per clone |
| SysMain (Superfetch) | Finalize **5** | Pointless on non-persistent clones, costs I/O at boot |
| Local policies | Finalize **8** (needs `LGPO.exe`) | OSOT settings as local GPO |
| Provisioned Store apps | `-storeapp remove-all --exclude <keep list incl. MSTeams>` | Every provisioned app is registered at a user's first logon. Fewer apps means a faster first logon |
| Scheduled maintenance | OSOT template (default) + VDI-ImageMaint Seal | No maintenance, defrag or update tasks on clones |
| Windows / Office / Store updates | `-windowsupdate disable -officeupdate disable` + Seal | No update storms after Push Image |
| Compact | Finalize **2** – **off** | CPU cost to decompress, no benefit on Instant Clone |
| Zero free space | Finalize **7** – only on the initial build, and only if you then export thin | – |
| Default user profile | Finalize **6** – **to verify** on a test clone before enabling for customers | Clears the default profile; test the effect on OSOT HKCU→Default User sync |

Current `packages.json` Finalize: `0 1 3 4 5 6 8`. Proposed: Build `0 1 3 4 5 8 9 10 11` (+7 if exporting),
Day-2 `0 1 3 4 5 8 10 11`. Step 6 is added only after the test clone confirms it.

## 5. Profiles: University vs Business (OSOT common options)

| Option | University | Business | Notes |
|---|---|---|---|
| `-visualeffect` | `balanced` | `balanced` (`quality` + `enablehardwareacceleration` with vGPU) | Smooth fonts and icon shadows stay on in `balanced` |
| `-storeapp` | `remove-all --exclude Calculator Photos ScreenSketch StickyNotes MSTeams` | `remove-all --exclude Calculator Photos ScreenSketch MSTeams` | **Never remove MSTeams** |
| `-notification` | `disable` | **`enable` until verified** | Needs a test that Teams call/chat toasts still show when OSOT disables notifications |
| `-onedrive` | per customer | `enable` (Known Folder Move) | – |
| `-windowsSearch` | `searchboxasicon` | `searchboxasicon` | Start search must work – checked on the clone |
| `-antivirus`, `-securitycenter`, `-firewall`, `-smartscreen` | keep defaults (enabled) | keep defaults (enabled) | Business: Defender for Endpoint in VDI mode |
| `-hvci` | disable (default) | per security policy | – |

## 6. Microsoft Teams on Horizon – what the image must have

- New Teams **provisioned** (`teamsbootstrapper -p`), `HKLM\SOFTWARE\Microsoft\Teams\disableAutoUpdate=1` (Seal).
- Horizon Agent feature **Media Optimization for Microsoft Teams** installed. The GPO *Enable Media Optimization
  for Microsoft Teams* comes from the Horizon GPO bundle.
- FSLogix excludes only Microsoft-recommended Teams folders (see Set-FSLogixConfig.ps1).
- OSOT `-storeapp … --exclude MSTeams`.
- Clone check (roadmap 7): Teams reports *Omnissa/VMware Media Optimized*, calls and screen share are offloaded,
  and notifications show.
