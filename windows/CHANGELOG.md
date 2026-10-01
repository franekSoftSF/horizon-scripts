# Changelog

## VDI-ImageMaint 2.0.0 – in progress

### Added
- Tests: `windows/tests` (Pester 5, 60 tests, run in Windows PowerShell 5.1 and PowerShell 7 by`Invoke-Tests.ps1`):
  EN/PL key and placeholder parity, every used key defined, file encoding/CRLF/parsing, pure functions (versions, names,
  winget table, argument text, JSON), ODT XML, unattend.xml, install plan on TestDrive, seal baseline (HKCU), download
  helpers (mocked network and signatures), mode/handler consistency; PSScriptAnalyzer with `windows/PSScriptAnalyzerSettings.psd1`.
- Set-FSLogixConfig: `Set-Reg` is an advanced function with ShouldProcess (-WhatIf flows through it).
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
