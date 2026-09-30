# Changelog

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
- `tools/Test-SysprepReadiness.ps1` 0.1 (20 checks, EN/PL).

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
