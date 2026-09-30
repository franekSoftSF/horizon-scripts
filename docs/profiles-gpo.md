# Profiles, OneDrive, GPO, DEM and FSLogix – recommended settings

> Polish version: [pl/profiles-gpo.md](pl/profiles-gpo.md).
> The OSOT and FSLogix parts of the table below are applied by `-Mode Configure`. GPO and DEM settings go
> into the domain (they are **not** baked into the image). Items marked **(verify)** must be tested on a
> test pool before you roll them out to customers.

## 1. Image profiles

| Area | University | Business | Graphics / designer (vGPU) |
|---|---|---|---|
| OSOT visual effects | `balanced` | `balanced` | `quality` + GPU acceleration kept in Office/Edge/Adobe |
| OSOT "Hardware Acceleration" items (7) | selected (software rendering) | selected | **cleared** |
| Thumbnail caching, ink collection | turned off | turned off | **kept** (image browsing, pen tablets) |
| App notifications (Teams calls/chat) | kept (wizard default) | kept | kept |
| OneDrive | per customer | **per-machine + KFM** | per-machine + KFM |
| FSLogix `SizeInMBs` | 30 000 | 50 000 | 100 000 |
| FSLogix `RoamIdentity` | – | yes | yes |
| FSLogix extra excludes | – | – | Adobe media cache |
| Microsoft 365 license (ODT product) | `O365ProPlusRetail` (A3/A5) | `O365ProPlusRetail` (E3/E5) or `O365BusinessRetail` (Business Premium only) | as for Business |
| winget suggestions | browsers, 7-Zip, Reader, VLC, VC++ | same | + Inkscape, Blender, Krita |

### Graphics / designer – beyond OSOT
- **vGPU**: NVIDIA vGPU profile sized to the apps (e.g. 2–4 GB framebuffer for 2D/Adobe, more for 3D).
  Install the NVIDIA guest driver and licensing token **before** Generalize, like VMware Tools.
- **Blast (Horizon GPO)**: raise *Max Frame Rate* to 60, turn on *High Color Accuracy* (H.264 4:4:4) or HEVC
  for colour-accurate work. This costs more bandwidth, so apply it only to the graphics pool. **(verify with the client devices)**
- **Colour management**: display ICC profiles on the client device; Horizon passes the image, not the ICC profile. **(verify)**
- **Pen tablets (Wacom etc.)**: USB redirection or the Horizon pen/stylus support, depending on the model. **(verify)**
- **Adobe Creative Cloud**: build the package in the Adobe Admin Console. Use Named User Licensing for staff and
  Shared Device Licensing for student labs. Check Adobe's current support statement for non-persistent VDI. **(verify)**
- **Scratch/cache**: point Photoshop/Premiere scratch disks and media cache to a local non-persistent disk
  (not into the FSLogix container). The Adobe media cache is excluded from the container by the wizard.
- **Fonts**: install them machine-wide in the image (per-user fonts would land in every container).

## 2. OneDrive that does not break on non-persistent VDI

Typical reasons why OneDrive "falls apart" on Instant Clones, and the fix for each:

| Cause | Fix |
|---|---|
| OneDrive installed **per user** (Windows default): it reinstalls and resyncs on every new clone | Install **per machine**: `OneDriveSetup.exe /allusers` (package `OneDrive` in `packages.json`, enabled by the wizard). Download the current `OneDriveSetup.exe` into `Apps\` every month |
| OSOT removes OneDrive (`Remove OneDriveSync`) | The wizard clears these OSOT items when you answer "keep OneDrive" |
| OneDrive cache outside the profile container, or excluded from it | FSLogix **Profile Container** keeps `%LocalAppData%\Microsoft\OneDrive` in the VHDX. Do **not** exclude it (only `OneDrive\logs` is excluded) |
| **Known Folder Move and folder redirection at the same time** (GPO or DEM) | Choose **one**. With OneDrive: KFM only, no *Folder Redirection* GPO and no DEM folder redirection for Desktop/Documents/Pictures |
| The container fills up with downloaded files | Files On-Demand + Storage Sense dehydration (policies below). Size the container for the cache, not for the whole OneDrive |
| Sign-in prompts on every clone | Seamless sign-in (`SilentAccountConfig`) with Entra hybrid join / SSO. FSLogix `RoamIdentity=1` keeps the Entra ID tokens in the container **(verify on hybrid-joined Instant Clones)** |
| Old OneDrive build in the image | Seal blocks the OneDrive updater on clones, so refresh `OneDriveSetup.exe` in every monthly cycle |

### OneDrive policies (Computer, OneDrive ADMX – `HKLM\SOFTWARE\Policies\Microsoft\OneDrive`)
| Policy | Value |
|---|---|
| Silently sign in users to the OneDrive sync app with their Windows credentials (`SilentAccountConfig`) | Enabled |
| Use OneDrive Files On-Demand (`FilesOnDemandEnabled`) | Enabled |
| Silently move Windows known folders to OneDrive (`KFMSilentOptIn`) | Enabled, tenant ID; Desktop, Documents, Pictures |
| Prevent users from moving their Windows known folders back to their PC (`KFMBlockOptOut`) | Enabled |
| Prevent users from syncing personal OneDrive accounts (`DisablePersonalSync`) | Enabled (Business) |
| Allow syncing OneDrive accounts for only specific organizations (`AllowTenantList`) | Tenant ID (Business) |

Storage Sense (Computer, *System > Storage Sense*): *Allow Storage Sense* = Enabled,
*Configure Storage Sense Cloud Content dehydration threshold* = e.g. 14 days.

## 3. GPO – proposal

### Computer (VDI OU, loopback processing = Merge)
| Area | Setting | Value |
|---|---|---|
| Windows | Turn off Microsoft consumer experiences | Enabled |
| Windows | Show first sign-in animation | Disabled |
| Windows | Configure Logon Script Delay | Enabled, 0 minutes |
| Windows | Always wait for the network at computer startup and logon | Leave **not configured** unless you use GPO software installation or folder redirection |
| Windows Update | (none) – updates happen only in the golden image (Seal blocks them) | – |
| Horizon Agent (Omnissa ADMX) | Enable Media Optimization for Microsoft Teams | Enabled |
| Horizon Blast | Max Frame Rate | 30 (office), 60 (graphics pool) |
| Horizon Blast | High Color Accuracy / HEVC | graphics pool only **(verify)** |
| Horizon | Clipboard / client drive / USB redirection | Through DEM Horizon Smart Policies (per pool, per location) |
| FSLogix (ADMX) | Profile Container settings | **Either** GPO **or** `Set-FSLogixConfig.ps1` in the image – not both. GPO wins and is easier to change without a new image |
| Microsoft Edge | Startup boost (`StartupBoostEnabled`) | Disabled |
| Microsoft Edge | Continue running background apps when Edge is closed (`BackgroundModeEnabled`) | Disabled |
| Microsoft Edge | Hide the first-run experience (`HideFirstRunExperience`) | Enabled |
| Microsoft Edge | Sleeping tabs (`SleepingTabsEnabled`) | Enabled |
| Microsoft 365 Apps | Automatic updates | Disabled (also in the ODT XML and by Seal) |
| Outlook | Cached Exchange Mode sync period | 1 month (University), 3 months (Business). The OST stays in the FSLogix container |
| Teams | nothing extra for new Teams on Horizon, apart from Media Optimization above | – |

### User
| Area | Setting | Value |
|---|---|---|
| Office | Disable first run / privacy opt-in dialogs | Enabled |
| OneDrive | (all under Computer) | – |
| Start/Taskbar | Pinned layout | through DEM or an XML layout, not per-user GPO scripts |

## 4. DEM (Dynamic Environment Manager) – how to split work with FSLogix

Rule: **FSLogix holds the whole profile, DEM only configures.** Double roaming (FSLogix container plus DEM
personalization of the same app) is the most common reason why settings drift or "fall apart".

| Use DEM for | Do **not** use DEM for (with FSLogix Profile Container) |
|---|---|
| Horizon Smart Policies: clipboard, USB, client drives, printing, bandwidth – per pool and per client location | Personalization of apps whose data already lives in the container (Office, Teams, browsers, OneDrive) |
| Drive mappings, printers, environment variables, shortcuts, file type associations | Folder redirection of Desktop/Documents/Pictures when OneDrive KFM is on |
| Condition sets (pool, AD group, client IP range) – e.g. no USB storage for student pools | Roaming of `AppData\Local` caches |
| Application blocking (University labs), privilege elevation for chosen installers | |

DEM ADMX: *Run FlexEngine as Group Policy Extension* = Enabled. Configuration share on DFS close to the pools,
profile archive share only if you personalize anything.

## 5. FSLogix – per profile

Common to all (set by `Set-FSLogixConfig.ps1`):
- dynamic VHDX, `DeleteLocalProfileWhenVHDShouldApply=1`, `FlipFlopProfileDirectoryName=1`,
  `PreventLoginWithFailure=1`, `PreventLoginWithTempProfile=1`, `redirections.xml` excludes for caches,
- antivirus exclusions for VHD(X), FSLogix processes and the Horizon/App Volumes/DEM folders.

| | University | Business | Graphics |
|---|---|---|---|
| `SizeInMBs` | 30 000 | 50 000 | 100 000 |
| Include group | students + staff | staff | designers |
| Exclude | image admins | image admins | image admins |
| `RoamIdentity` | optional | 1 | 1 |
| Share | SMB with continuous availability, AV exclusions on the file server | same | same, on faster storage (large VHDX, big files) |
| Cloud Cache | only for multi-site | only for multi-site | not recommended (large containers) |
