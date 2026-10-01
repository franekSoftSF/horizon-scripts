# Downloads – what to put in `C:\install` and where to get it

Installers are **never** stored in git (`.gitignore`).

## Automatic: `-Mode Download` (START.cmd option 2)

These packages are downloaded automatically into the right folders. The publisher signature is checked,
ZIP archives are extracted, unchanged files are kept and older versions are removed:

| Package | Folder | Signature check |
|---|---|---|
| Office Deployment Tool `setup.exe` | `Office\` | Microsoft |
| New Teams bootstrapper + `MSTeams-x64.msix` (offline provisioning) | `Teams\` | Microsoft (MSIX: checked by Windows at install) |
| FSLogix ZIP (newest) | `FSLogix\` | Microsoft, every EXE inside the archive |
| OneDrive `OneDriveSetup.exe` (per machine) | `Apps\` | Microsoft |
| `LGPO.exe` (extracted from LGPO.zip) | `OSOT\` | Microsoft |
| `sdelete64.exe` (extracted from SDelete.zip) | `OSOT\` | Microsoft |
| VMware Tools x64 (newest) | `Horizon\` | VMware / Broadcom |

The list lives in `Modules\VDI-ImageMaint\Templates\downloads.json`; copy it to `C:\install\downloads.json` to
change it. Option 8 of the menu (monthly cycle) downloads fresh packages first.

## Manual

Everything else needs a login or a version choice. Download it yourself, verify the digital signature
(`Get-AuthenticodeSignature <file>` → `Valid`, publisher Microsoft / Omnissa / Broadcom) and copy it to the
folder listed below. `-Mode Download` prints this list at the end.

> Polish version: [pl/downloads.md](pl/downloads.md)

## Windows and patches

| Item | Folder | Source | Notes |
|---|---|---|---|
| Windows 11 Enterprise ISO (24H2 / 25H2) | – (VM build) | Microsoft 365 admin center → Volume Licensing, or Visual Studio subscriptions | Use a clean ISO for every feature release. Do **not** in-place upgrade the golden image (see image-lifecycle.md) |
| Cumulative updates (MSU) | `Patches\` | <https://www.catalog.update.microsoft.com> | 24H2/25H2 use **checkpoint** CUs: keep the checkpoint MSU and the latest CU in the same folder |
| Application patches (MSP) | `Patches\` | Vendor | Enabled in `packages.json` only on purpose (`PatchesMsp`) |

## OS Optimization Tool (OSOT)

| Item | Folder | Source | Notes |
|---|---|---|---|
| Omnissa Horizon OS Optimization Tool (`OmnissaHorizonOSOptimizationTool-x86_64-*.exe`) | `OSOT\` | Omnissa Customer Connect → Downloads → Horizon → *OS Optimization Tool*; docs: <https://docs.omnissa.com/Optimizing-Images-for-Horizon/OptimizingImagesforHorizon> | **Minimum 2603 for Windows 11 25H2**; **2606+ recommended** (turns off device encryption and BitLocker, the #1 cause of Sysprep failures on recent builds) |
| `Optimize.json` (selections) | `OSOT\` | Exported from the OSOT GUI: Optimize → *Export Selections* | Version it per profile (university / business) |
| `LGPO.exe` | `OSOT\` (copied to `System32` for Finalize) | Microsoft Security Compliance Toolkit: <https://www.microsoft.com/en-us/download/details.aspx?id=55319> (`LGPO.zip`) | Needed by Finalize step **8** (local group policies) |
| `sdelete64.exe` | `OSOT\` | Sysinternals: <https://learn.microsoft.com/en-us/sysinternals/downloads/sdelete> | Finalize step **7** (zero free space). **Initial build only**, never in the Day-2 cycle on Instant Clone |

## Omnissa / VMware components (versions must match the backend)

| Item | Folder | Source | Notes |
|---|---|---|---|
| VMware Tools x64 | `Horizon\` | <https://packages.vmware.com/tools/releases/latest/windows/x64/> | Install first, before everything else |
| Omnissa Horizon Agent (`Omnissa-Horizon-Agent-x86_64-*.exe`) | `Horizon\` | Omnissa Customer Connect → Horizon 8 → matching version (2506) | Install **after Generalize**. Keep the *Instant Clone* feature. Keep *Media Optimization for Microsoft Teams* |
| Dynamic Environment Manager agent (`Omnissa Dynamic Environment Manager*x64.msi`) | `Horizon\` | Omnissa Customer Connect → DEM | After Horizon Agent |
| App Volumes Agent | `Horizon\` | Omnissa Customer Connect → App Volumes (matching the Manager) | Last of the agents; needs the Manager address (`Variables` in `packages.json`) |
| Horizon GPO bundle (ADMX) | – (domain SYSVOL) | Omnissa Customer Connect → Horizon 8 → *GPO Bundle* | Needed for the Teams optimization and Blast policies |

## Microsoft 365, Teams, FSLogix, Edge

| Item | Folder | Source | Notes |
|---|---|---|---|
| Office Deployment Tool (`setup.exe`) | `Office\` | <https://www.microsoft.com/en-us/download/details.aspx?id=49117> | Configuration XML from <https://config.office.com>: `SharedComputerLicensing=1`, `Updates Enabled="FALSE"`, `FORCEAPPSHUTDOWN=TRUE`, `Display Level="None"` |
| New Teams bootstrapper (`teamsbootstrapper.exe`) | `Teams\` | <https://go.microsoft.com/fwlink/?linkid=2243204> | Provision for all users: `teamsbootstrapper.exe -p` (online) or `-p -o <msix>` (offline) |
| New Teams MSIX x64 (`MSTeams-x64.msix`) | `Teams\` | <https://go.microsoft.com/fwlink/?linkid=2196106> | For offline provisioning. VDI guidance: <https://learn.microsoft.com/en-us/microsoftteams/new-teams-vdi-requirements-deploy> |
| FSLogix (`FSLogix_<version>.zip`) | `FSLogix\` | <https://aka.ms/fslogix_download>, release notes: <https://learn.microsoft.com/en-us/fslogix/overview-release-notes> | Do not unpack, the tool does it |
| Microsoft Edge for Business (MSI x64) | `Apps\` | <https://www.microsoft.com/edge/business/download> | Only if Edge is installed or repaired offline |
| OneDrive per-machine (`OneDriveSetup.exe`) | `Apps\` | <https://go.microsoft.com/fwlink/?linkid=844652> | Installed with `/allusers` (package `OneDrive`). Refresh every month - Seal blocks the OneDrive updater on clones |
| NVIDIA vGPU guest driver + license token | – (before Generalize) | NVIDIA Licensing Portal (matching the host vGPU manager) | Graphics profile only |
| App Installer / winget | – | <https://aka.ms/getwinget> | OSOT and LTSC often remove it; needed for `-Mode Update` |

## Optional

| Item | Source | Notes |
|---|---|---|
| Windows ADK – Windows System Image Manager | <https://learn.microsoft.com/windows-hardware/get-started/adk-install> | Only to edit or validate a custom `unattend.xml` |
| VMware PowerCLI | PowerShell Gallery (`Install-Module VMware.PowerCLI`) | Roadmap item 5 (snapshot + push image) |
