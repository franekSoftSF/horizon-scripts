#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Golden image maintenance for Windows 11 VDI (Omnissa Horizon Instant Clone): update, optimize (OSOT),
    block automatic updates before publishing (Seal), build with Generalize (Sysprep). English / Polish.

.DESCRIPTION
    Thin entry point - the logic lives in Modules\VDI-ImageMaint. The easiest start: double-click START.cmd.

    Modes (-Mode):
      Configure      Step-by-step wizard: profile (University / Business / Graphics), Microsoft 365 (license,
                     channel, language, apps) -> Office\Configuration_x64.xml, FSLogix, App Volumes, build locale,
                     OSOT (Teams notifications, OneDrive, visual effects) -> Optimize.json, winget apps (picker)
                     -> packages.json. Every file is backed up (.bak_<date>).
      Download       Downloads the freely available packages (Office Deployment Tool, Teams bootstrapper + MSIX,
                     FSLogix, OneDrive, LGPO, SDelete, VMware Tools) into the right C:\install folders: signature
                     check, ZIP extraction, unchanged files kept, older versions removed. Catalog:
                     Modules\VDI-ImageMaint\Templates\downloads.json (override: C:\install\downloads.json).
      Status         Report: services, scheduled tasks, policies, pending reboot, seal state.
      WingetList     Dry run: what winget would update and what is skipped.
      Init           Creates the C:\install structure and the default packages.json.
      Discover       Builds manifest entries for files in C:\install that have none (x86 variants -> Ignore);
                     result in packages.discovered.json (-Apply: directly into packages.json + backup).
      Optimize       OSOT optimization with the "Osot" section of the manifest.
      Finalize       OSOT finalize (-f) with the "Osot" section of the manifest.
      PackageList    Install plan of the manifest packages and winget apps (dry run).
      Packages       Installs the manifest packages and the Winget.Install apps.
      Inventory      Packages (Win32, provisioned MSIX, winget export) with the auto-update blocking status
                     -> %ProgramData%\VDI-ImageMaint\Inventory\<date>\ (CSV + JSON).
      Unlock         Restores exactly what Seal changed (seal-state.json).
      Update         Unlock + OSOT enable updates + packages + winget installs + Defender, Microsoft 365, Visual Studio,
                     Edge, Teams (teamsbootstrapper -p), winget updates, Windows Update. -AutoReboot reboots and resumes;
                     -ThenSeal seals the image at the end (monthly cycle in one step).
      Seal           OSOT Optimize, then blocks automatic updates (Windows Update, Store, Microsoft 365, Edge, Chrome,
                     Teams, Firefox, VS Code, Visual Studio, Notepad++, OneDrive, K-Lite, Adobe Reader) and DETECTS other
                     third-party updaters (except AV and VDI); optional -Cleanup; Inventory; OSOT Finalize.
      Generalize     IMAGE BUILD (once per Windows release, in audit mode): fixes known Sysprep blockers, readiness
                     check, generated unattend.xml (AutoLogon + FirstLogonCommands), OSOT -g (Sysprep), reboot.
                     Requires -SnapshotConfirmed. After OOBE PostGeneralize starts automatically.
      PostGeneralize (started automatically after OOBE) removes Copilot/BingSearch, installs the agents from
                     Build.PostGeneralizePackages (reboots + resume), disables AutoLogon, Seal as SYSTEM, Finalize.

    Seal records the original state in %ProgramData%\VDI-ImageMaint\seal-state.json, so Unlock restores exactly
    what was changed. VDI infrastructure components (VMware Tools, Horizon Agent, DEM, App Volumes Agent) are
    updated only by enabled manifest packages - their versions must match the backend.

.EXAMPLE
    .\VDI-ImageMaint.ps1 -Mode Configure
    .\VDI-ImageMaint.ps1 -Mode PackageList
.EXAMPLE
    # Monthly cycle: update with automatic reboots, seal as SYSTEM, shut down
    .\VDI-ImageMaint.ps1 -Mode Update -AutoReboot -ThenSeal -Shutdown
.EXAMPLE
    # Seal only, with cleanup, then shut down before the snapshot
    .\VDI-ImageMaint.ps1 -Mode Seal -Cleanup -AsSystem -Shutdown
.EXAMPLE
    # Image build: after Optimize + reboot, in audit mode, after taking the "pre-generalize" snapshot
    .\VDI-ImageMaint.ps1 -Mode Generalize -SnapshotConfirmed -Shutdown
.EXAMPLE
    # Polish messages regardless of the Windows language
    .\VDI-ImageMaint.ps1 -Mode Status -Language pl

.NOTES
    Version 2.0.0. Logs: %ProgramData%\VDI-ImageMaint\Logs
    -AsSystem is recommended for Seal/Unlock: some services and tasks (WaaSMedicSvc, UpdateOrchestrator)
    are protected and an administrator cannot change them.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Init', 'Configure', 'Download', 'Discover', 'Status', 'Inventory', 'WingetList', 'PackageList', 'Packages', 'Optimize', 'Finalize', 'Unlock', 'Update', 'Seal', 'Generalize', 'PostGeneralize')]
    [string]$Mode,

    # --- Messages: auto (Polish Windows -> pl, otherwise en), en, pl ---
    [ValidateSet('auto', 'en', 'pl')]
    [string]$Language = 'auto',

    # --- Package folder ---
    [string]$InstallDir = 'C:\install',

    # --- OSOT (Omnissa OS Optimization Tool); defaults are in the "Osot" section of packages.json ---
    [switch]$SkipOsot,
    [string]$OsotPath,                 # a specific exe (default: the newest one in -InstallDir)
    [switch]$OsotOptimize,             # force optimization in Seal
    [switch]$OsotSkipOptimize,         # Seal without optimization (only Windows/Office Update off)
    [string]$OsotTemplate,             # e.g. 'Omnissa Templates\Windows 10, 11 and Server 2022, 2025'
    [string]$OsotLevel,                # e.g. 'recommended'; empty = template default
    [string]$OsotFinalize,             # e.g. 'all' or '0 1 3 4 10'; 'none' = no finalize
    [string[]]$OsotExtraArgs = @(),    # extra OSOT common options, e.g. '-onedrive','disable'

    # --- Package platform ---
    [string]$Manifest,                 # default <InstallDir>\packages.json (created automatically)
    [switch]$SkipPackages,             # Update without manifest packages
    [string[]]$PackageIds,             # only these manifest Ids
    [switch]$Apply,                    # Discover: write the result to packages.json (with a backup)
    [switch]$AutoReboot,               # reboot + automatic resume after logon
    [switch]$ThenSeal,                 # Update: when finished (no pending reboot) Seal as SYSTEM right away
    [int]$MaxRounds = 5,               # reboot limit with -AutoReboot
    [int]$ResumeRound = 0,             # (internal) round number after a resume

    # --- Update ---
    [switch]$SkipWindowsUpdate,
    [switch]$SkipOffice,
    [switch]$SkipVisualStudio,
    [switch]$SkipEdge,
    [switch]$SkipWinget,
    [int]$OfficeWaitMinutes = 10,
    [string[]]$WingetIds = @(
        'Mozilla.Firefox',
        'Microsoft.VisualStudioCode',
        '7zip.7zip',
        'Notepad++.Notepad++',
        'CodecGuide.K-LiteCodecPack.Mega',
        'Microsoft.VCRedist.2013.x64',
        'Microsoft.VCRedist.2013.x86',
        'Microsoft.VCRedist.2015+.x64',
        'Microsoft.VCRedist.2015+.x86'
    ),
    # Update everything winget detects (with the exclusions below) instead of the -WingetIds list
    [switch]$WingetAll,
    # Include packages with an unknown version (may be reinstalled on every run)
    [switch]$WingetIncludeUnknown,
    # Regex matched against the name OR the id - such packages are skipped with -WingetAll
    [string]$WingetExcludePattern = 'Omnissa|VMware|Horizon|App ?Volumes|Dynamic Environment|FSLogix|Microsoft\.Office|Microsoft 365 Apps|Aplikacje Microsoft 365|Microsoft\.VisualStudio\.20|Visual Studio (Community|Professional|Enterprise|Build Tools)|Visual Studio Installer|Microsoft\.Edge|Microsoft Edge|Microsoft\.AppInstaller|DesktopAppInstaller',
    # Additional winget ids to skip (exact match)
    [string[]]$WingetExcludeIds = @(),
    # MSIX/Store apps - winget would update them for the current account only, not in the image
    [string[]]$WingetStoreIds = @('Microsoft.Teams', 'Microsoft.Outlook', 'Microsoft.WindowsTerminal', 'Microsoft.365Copilot'),

    # New Teams - provisioned version updated by teamsbootstrapper -p
    [switch]$SkipTeams,
    [string]$TeamsBootstrapperPath,

    # --- Seal ---
    [switch]$Cleanup,
    [switch]$Force,
    # Only report the detected additional updaters, do not block them
    [switch]$NoBlockDetected,
    # What counts as an updater (task/service name or path)
    [string]$UpdaterDetectPattern = 'update|updater|upgrade|maintenanceservice|\\gup\.exe',
    # What NOT to block despite a match (antivirus, VDI components)
    [string]$DetectExcludePattern = 'Omnissa|VMware|Horizon|App ?Volumes|FSLogix|Dynamic Environment|Trend ?Micro|Defender|Sophos|CrowdStrike|Sentinel|ESET|Symantec|McAfee|Kaspersky|Bitdefender|VDI-ImageMaint',
    [switch]$Shutdown,

    # --- Seal / Unlock / Status / Inventory ---
    [switch]$AsSystem,

    # --- Generalize (image build) ---
    # Confirms that a VM snapshot from before Generalize exists (a failed Sysprep can be irreversible)
    [switch]$SnapshotConfirmed,
    # Osot = OSOT -g (recommended by Omnissa); Sysprep = sysprep.exe directly (when OSOT is missing)
    [ValidateSet('Osot', 'Sysprep')]
    [string]$GeneralizeEngine = 'Osot',
    # Built-in administrator password for OOBE/AutoLogon (without it: interactive prompt)
    [securestring]$AdminPassword,
    # Remove ALL AppX packages installed for an account but not provisioned (except MSTeams)
    [switch]$RemoveUnprovisionedAppx,

    # --- Configure ---
    # Console list instead of the Out-GridView window (e.g. Server Core, remote session)
    [switch]$NoGui
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Modules\VDI-ImageMaint\VDI-ImageMaint.psd1') -Force

# All parameters (given and default values) go to the module; only the given ones are forwarded to
# the resume task and the SYSTEM task
$common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable',
    'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm')
$all = @{}
foreach ($p in $MyInvocation.MyCommand.Parameters.Keys) {
    if ($common -contains $p) { continue }
    $all[$p] = Get-Variable -Name $p -ValueOnly
}
$bound = @{}
foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = $PSBoundParameters[$k] }

$rc = @(Invoke-VdiImageMaint -Parameters $all -BoundParameters $bound -EntryScript $PSCommandPath)
exit ([int]$rc[-1])
