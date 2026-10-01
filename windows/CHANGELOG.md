# Changelog

## VDI-ImageMaint 2.0.0 – in progress

### Added
- **vCenter automation** - `Scripts\Invoke-GoldenVm.ps1` 1.0 (EN/PL, VMware PowerCLI, START menu **C** / **R**, settings in
  `vcenter.json` from `vcenter.example.json`): `-Action New` uploads the build ISO and creates the golden VM (Windows 11 guest,
  EFI + Secure Boot, no vTPM, PVSCSI, VMXNET3, thin disk, no floppy, `devices.hotplug=FALSE`, boot CD -> disk), connects the CDs,
  powers on and sends Enter for "Press any key"; `-Action Snapshot` (pre-generalize); `-Action Release` (VM off: CDs emptied,
  vTPM removed, snapshot `Gold <date>` for Push Image); `-ValidateOnly`. No credentials stored.
- **OSDCloud** (github.com/OSDeploy/OSD) - `New-BuildMedia.ps1 -Method OSDCloud` 1.1 (menu **O**): WinPE with VMware drivers that
  downloads Windows 11 24H2/25H2/26H2 from Microsoft (`Start-OSDCloud -ZTI`), a shutdown script copies `C:\install` and the
  audit-mode answer file to `C:\Windows\Panther`; `OSDCloud_NoPrompt.iso` -> `VDI-OSDCloud.iso`. Docs `docs/vcenter-osdcloud.md` (+pl).
- **New image installation** - `Scripts\New-BuildMedia.ps1` 1.0 (EN/PL, START menu **B**): writes `VDI-Build.iso` (UDF via the
  built-in IMAPI2, no ADK) with `autounattend.xml` + `C:\install`. With the Windows ISO on the first CD drive Setup runs
  without questions: UEFI partitions on disk 0, edition by name + generic KMS key, TPM check bypassed (golden image without
  vTPM, KB 85960; `-WithVtpm` to keep it), PreventDeviceEncryption + Store auto-updates off, straight into **audit mode**,
  copies `C:\install` and opens the menu (`-AutoStart Menu|Update|None`). No password on the media. Docs: image-lifecycle §2a.
- Configure: new step 3/8 "Java development" (now 8 steps): Temurin JDK 21 + 25 / 21 / 25 (the first one sets JAVA_HOME),
  Eclipse java/jee, workspace without prompt (University default), -Xmx, optional FSLogix exclusion of the Maven/Gradle
  caches (merged with the Graphics excludes); packages missing in older manifests are added from the template.
- **Windows 11 26H2 readiness** (new `Private\Windows.ps1`, EN/PL `Windows.psd1`): release table 24H2 (26100), 25H2 (26200),
  26H2 (26300), 26H1 (28000, not a VDI guest) with Horizon Agent minimum (KB 78714), OSOT minimum and servicing end.
  `Status`/`Update` show the release, servicing end and Horizon/OSOT support; the package plan warns when the Horizon
  Agent installer does not support the running release (e.g. 2506 on 25H2). `Update` **skips feature updates and
  enablement packages** (category Upgrades) unless the new manifest field `Windows.TargetRelease` names the release;
  then it pins `TargetReleaseVersion`/`TargetReleaseVersionInfo`. Docs: image-lifecycle.md section 7 (+pl).
- Test-SysprepReadiness: 26H2 known (C01 WARN: not in the Omnissa matrix yet; C17 OSOT WARN), 26H1 = FAIL, new **C21**
  vTPM in the golden image (WARN, KB 85960).
- **Horizon Agent silent install fixed**: `VDM_VC_MANAGED_AGENT=1` (required) and `ADDLOCAL={HorizonAgentFeatures}` with
  `Core,NGVC` - before, the silent install had no `VDM_VC_MANAGED_AGENT` and NGVC (Instant Clone Agent) is not a default
  of a silent install. Per-profile feature sets (Configure step 4), `{HorizonAgentOptions}` for extra MSI properties,
  MSI log in the tool's Logs, file pattern `*Horizon-Agent-x86*.exe`. `-Mode Validate` checks the property, Core/NGVC
  and unknown feature names (e.g. V4V, removed in 2412).
- Java development: packages `TemurinJDK21` (JAVA_HOME, PATH, .jar) and `TemurinJDK25` (Temurin MSI, fixed `INSTALLDIR`
  `jdk-21` / `jdk-25`, so monthly upgrades keep the path) and `EclipseJava` - new `Scripts\Install-Eclipse.ps1` 1.0 (EN/PL,
  -WhatIf): extracts the newest EPP ZIP to `%ProgramFiles%\Eclipse\java` (eclipse.exe signature checked), re-applies only the
  configuration when the release is current, sets the workspace in the FSLogix container, `plugin_customization.ini`
  (update check and Oomph startup tasks off, JDK detection at startup on), Start menu shortcut, Uninstall entry, `-Uninstall`.
  `-Mode Download` fetches the three (Adoptium API; Eclipse release read from `release.xml` - new catalog fields
  `ReleaseUrl`/`ReleasePattern` fill `{Release}` in `Url`). Docs `docs/eclipse-java.md` (+pl): FSLogix workspace, DEM folder
  redirection of Documents/Desktop to UNC, checks on a clone.
- `-Mode Validate` (+ START menu V): types, allowed values, unique Ids, regexes, Detect fields, `{Variables}`, files,
  OSOT Finalize steps (2/7 warnings for Instant Clone), OSOT removing Teams, FSLogixConfig without a share, Build Ids;
  typo suggestions for field names. Runs automatically: PackageList shows the findings, Packages/Update/PostGeneralize
  stop on errors. `Templates\packages.schema.json` + `"$schema"` in packages.json for editor hints (VS Code).
- Office XML templates `Office\Templates`: `O365ProPlusRetail` and `O365BusinessRetail` x pl-pl, en-us, de-de, fr-fr,
  pl-pl + en-us; all Shared Computer Activation (Business needs Business Premium), MonthlyEnterprise, no updates,
  silent. Configure step 2 offers the same language presets (+ other code).
- Tests: `windows/tests` (Pester 5, 60 tests, run in Windows PowerShell 5.1 and PowerShell 7 by`Invoke-Tests.ps1`):
  EN/PL key and placeholder parity, every used key defined, file encoding/CRLF/parsing, pure functions (versions, names,
  winget table, argument text, JSON), ODT XML, unattend.xml, install plan on TestDrive, seal baseline (HKCU), download
  helpers (mocked network and signatures), mode/handler consistency; PSScriptAnalyzer with `windows/PSScriptAnalyzerSettings.psd1`.
- **Set-FSLogixConfig 1.1.0**: English code/help, EN/PL messages (inline table), `-Language auto|en|pl`; `Set-Reg` is an
  advanced function with ShouldProcess; AV report file `AV-exclusions_<date>.txt`; redirections.xml written by 1.0
  (Polish comment) is not rewritten when its content is unchanged.
- `-Mode Download`: Office Deployment Tool, Teams bootstrapper + MSIX, FSLogix ZIP, OneDrive, LGPO.exe, sdelete64.exe and
  VMware Tools are downloaded into the right folders - Authenticode publisher check (every EXE inside the FSLogix ZIP),
  ZIP extraction, SHA-256 compare (unchanged files kept), older versions removed; manual items listed at the end.
  Catalog `Templates\downloads.json`, override `C:\install\downloads.json`.
- OSOT Finalize copies `LGPO.exe` (step 8) / `sdelete64.exe` (step 7) to System32 when needed (signature checked).
- Update-Teams provisions offline (`teamsbootstrapper -p -o MSTeams-x64.msix`) when the MSIX is in `Teams\`.
- START menu: option 2 = download; numbering follows the work order (1-3 setup, 4-7 build, 8-9 monthly);
  option 8 downloads fresh packages before the monthly cycle; the menu passes its folder (`-InstallDir`) to the tool.

### Changed
- Repository: the Windows tool moved to `windows/` (`windows/install` = C:\install, `windows/docs`, this changelog);
  `linux/` holds the separate Linux tool.
- Split into the module `Modules\VDI-ImageMaint` (Private per area, Public `Invoke-VdiImageMaint`);
  `VDI-ImageMaint.ps1` is a thin entry point with the same parameters.
- **English is the primary language**, Polish the second: all ~400 messages in `en-US\*.psd1` / `pl-PL\*.psd1`,
  new parameter `-Language auto|en|pl` (auto = Polish on Polish Windows). Code and comments in English.
- Language-neutral data: plan actions (install/update/skip/current/missing), Inventory status
  (Blocked/Active/NoUpdater/NotDetected), CSV columns (`packages.csv`, `detected-updaters.csv`), detected updater
  type (Task/Service). **Inventory CSV file and column names changed** (were Polish).
- Default manifest moved to `Templates\packages.default.json` (English, with Build, Winget and OneDrive).
- No `exit` inside functions: reboot scheduling ends the run through a restart signal (exit code 0).
- `ConvertFrom-WingetTable`: pure parser of the winget table (testable).
- The START menu passes its language to the tools.

## VDI-ImageMaint 1.10.0 – 2026-09-30

### Added
- `START.cmd` + `Scripts\Start-Menu.ps1`: double-click launcher (UAC, unblock, EN/PL menu with the steps in order).
- `Update -ThenSeal`: monthly cycle in one step (update with reboots, Seal as SYSTEM, Finalize, optional shutdown).
- Configure: third profile **Graphics** (OSOT `quality`, GPU acceleration kept in Office/Edge/Adobe, thumbnails and
  ink kept; FSLogix 100 GB, Adobe media cache excluded, `RoamIdentity`); Business/Graphics add `-RoamIdentity`.
- OneDrive for users who keep data there: per-machine package `OneDrive` (`/allusers`), wizard clears the OSOT
  OneDrive removal items and enables the package.
- `docs/profiles-gpo.md` (+pl): profiles, OneDrive on non-persistent VDI, GPO, DEM and FSLogix recommendations.
- winget catalog: Graphics profile, Blender, Krita.

## VDI-ImageMaint 1.9.0 – 2026-09-30

### Added
- `-Mode Configure`: step-by-step wizard – profile (University/Business), Microsoft 365 (license, channel, one main
  language + optional proofing/full second language, excluded apps) → `Office\Configuration_x64.xml` + `Uninstall.xml`,
  FSLogix (share, size, groups → `FSLogixConfig` arguments, config version bump), App Volumes, build locale,
  OSOT (keep Teams notifications, keep OneDrive → `Optimize.json`), winget apps picked in Out-GridView
  (`-NoGui` = console list). Every file is backed up (`.bak_<date>`).
- `install/winget-catalog.json`: curated apps with the auto-update blocking method shown in the picker.
- `Winget.Install` in the manifest: missing apps are installed machine-wide in `Packages`/`Update`, shown in
  `PackageList` and updated by `Update` (no per-user installs on VDI).
- Seal blocks Adobe Acrobat/Reader updates (FeatureLockDown `bUpdater=0`, AdobeARMservice, update task).

### Changed
- Repository layout: `install/` is the complete `C:\install` (`VDI-ImageMaint.ps1`, `Scripts\Set-FSLogixConfig.ps1`,
  `Scripts\Test-SysprepReadiness.ps1`).
- `Office\Configuration_x64.xml`: `Updates Enabled=FALSE`, `FORCEAPPSHUTDOWN=TRUE`, `Display Level=None`;
  `Uninstall.xml` uses `Remove All`.

## VDI-ImageMaint 1.8.0 / Set-FSLogixConfig 1.0.1 – 2026-09-30

### Added
- `-Mode Generalize` (image build, once per Windows feature release, in audit mode):
  - fixes the known Sysprep blockers: Store `AutoDownload=2`, `PreventDeviceEncryption` + BDESVC,
    decryption of C:, Copilot/BingSearch per user, optionally `-RemoveUnprovisionedAppx`;
  - runs `Test-SysprepReadiness.ps1` as a gate; requires `-SnapshotConfirmed`;
  - generates `unattend.xml` (PnpSysprep `PersistAllDeviceInstalls`, optional `SkipRearm`, locale/time zone,
    AutoLogon of the built-in administrator, FirstLogonCommands → PostGeneralize);
  - runs OSOT `-g` (or `sysprep.exe`, `-GeneralizeEngine Sysprep`), verifies `ImageState`, then reboots.
- `-Mode PostGeneralize` (started automatically after OOBE): removes Copilot/BingSearch, installs
  `Build.PostGeneralizePackages` with reboots and resume, disables AutoLogon, runs Seal as SYSTEM and
  Finalize with `Osot.FinalizeBuild`.
- Manifest: optional `Build` section and `Osot.FinalizeBuild` (backward compatible).
- `Scripts/Test-SysprepReadiness.ps1` 0.1 (20 checks, EN/PL).

### Fixed
- B1: apps with `SystemComponent=0` were hidden from Inventory, Discover and detection.
- B2: `ps1` packages run via `-EncodedCommand`: single quotes and arrays in `Arguments` work; existing
  double-quoted entries behave the same.
- B3: `Set-FSLogixConfig.ps1 -WhatIf` ended with an error (transcript).
- B4: Seal/Optimize record the baseline **before** OSOT, so Unlock restores the real original service state.
- B5: `-AsSystem` forwards all parameters (e.g. `-NoBlockDetected`, `-InstallDir`, `-Manifest`).
- B6: pending-reboot check runs before OSOT Optimize also with `-AsSystem`.
- B7: Update retries Unlock as SYSTEM when protected services/tasks could not be restored.
- S2: downloaded `teamsbootstrapper.exe` must have a valid Microsoft signature; it is also looked up in `C:\install`.
- S3/S5: `Stop-Transcript` in `finally` guarded; `Get-RegValue` with empty path.
- S9: warning when the FSLogix include group cannot be read.

## 1.7.3 – baseline
- Initial version in git.
