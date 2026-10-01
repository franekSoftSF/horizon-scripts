# Paths, update-blocking definitions and module state.
# The entry script (VDI-ImageMaint.ps1) copies its parameters into module scope in Invoke-VdiImageMaint,
# so functions read $InstallDir, $WingetAll, ... exactly as in the single-file version.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Module-scope configuration read by the other Private files')]
param()

$script:ToolVersion = '2.0.0'

$BaseDir        = Join-Path $env:ProgramData 'VDI-ImageMaint'
$LogDir         = Join-Path $BaseDir 'Logs'
$StateFile      = Join-Path $BaseDir 'seal-state.json'
$BuildDir       = Join-Path $BaseDir 'Build'
$UnattendPath   = Join-Path $BuildDir 'unattend.xml'
$BuildStateFile = Join-Path $BaseDir 'build-state.json'
$WinlogonKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$ResumeTaskName = 'VDI-ImageMaint-Resume'
$DefaultManifestFile = Join-Path $script:ModuleRoot 'Templates\packages.default.json'

# Thrown after a reboot has been scheduled: the entry point stops without an error (replaces 'exit 0' in functions)
$script:RestartSignal = 'VDI-ImageMaint:RestartScheduled'

# Services disabled by Seal (Default = start type used by Unlock when no seal state exists)
$ServiceDefs = @(
    @{ Name = 'wuauserv';           Default = 3 }
    @{ Name = 'UsoSvc';             Default = 2 }
    @{ Name = 'WaaSMedicSvc';       Default = 3 }
    @{ Name = 'edgeupdate';         Default = 2 }
    @{ Name = 'edgeupdatem';        Default = 3 }
    @{ Name = 'MozillaMaintenance'; Default = 3 }
    # Google Chrome - new GoogleUpdater (versioned names) and legacy Google Update
    @{ Name = 'GoogleUpdaterService*';         Default = 2 }
    @{ Name = 'GoogleUpdaterInternalService*'; Default = 2 }
    @{ Name = 'gupdate';                       Default = 2 }
    @{ Name = 'gupdatem';                      Default = 3 }
    # Adobe Acrobat / Reader
    @{ Name = 'AdobeARMservice';               Default = 2 }
)

# HKLM policies set by Seal
$PolicyDefs = @(
    # Windows Update
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU';            Name = 'NoAutoUpdate';                 Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';               Name = 'SetDisableUXWUAccess';         Value = 1 }
    # Microsoft Store
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore';                        Name = 'AutoDownload';                 Value = 2 }
    # Microsoft 365 Apps (Click-to-Run)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate';     Name = 'EnableAutomaticUpdates';       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate';     Name = 'HideEnableDisableUpdates';     Value = 1 }
    # Microsoft Edge (EdgeUpdate policies apply to domain/MDM machines - the services are disabled anyway)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate';                          Name = 'UpdateDefault';                Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate';                          Name = 'AutoUpdateCheckPeriodMinutes'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate';                          Name = 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'; Value = 0 }
    # Google Chrome (like Edge: policies apply to domain/MDM - services and tasks are disabled independently)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Google\Update';                                 Name = 'UpdateDefault';                Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Google\Update';                                 Name = 'AutoUpdateCheckPeriodMinutes'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Google\Update';                                 Name = 'Update{8A69D345-D564-463C-AFF1-A69D9E530F96}'; Value = 0 }
    # New Microsoft Teams on VDI
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Teams';                                        Name = 'disableAutoUpdate';            Value = 1 }
    # Mozilla Firefox
    @{ Path = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox';                               Name = 'DisableAppUpdate';             Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox';                               Name = 'BackgroundAppUpdate';          Value = 0 }
    # Visual Studio Code
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode';                              Name = 'UpdateMode';                   Value = 'none'; Type = 'String' }
    # Visual Studio 2022
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\Setup';                  Name = 'BackgroundDownloadDisabled';   Value = 1 }
    # Adobe Acrobat Reader (classic 32-bit and the unified 64-bit build, which uses the Acrobat path)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown';       Name = 'bUpdater';                     Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown';        Name = 'bUpdater';                     Value = 0 }
)

# Scheduled tasks (full path, wildcards)
$TaskPatterns = @(
    '\Microsoft\Windows\WindowsUpdate\*'
    '\Microsoft\Windows\UpdateOrchestrator\*'
    '\Microsoft\Windows\WaaSMedic\*'
    '\Microsoft\Windows\InstallService\ScanForUpdates*'
    '\Microsoft\Office\Office Automatic Updates*'
    '\Microsoft\Office\Office Feature Updates*'
    '\MicrosoftEdgeUpdateTask*'
    '\GoogleUpdateTask*'
    '\GoogleSystem\GoogleUpdater\*'
    '\GoogleUpdaterTask*'
    '\Microsoft\VisualStudio\Updates\*'
    '\Mozilla\Firefox Background Update*'
    '\OneDrive*Update*'
    '*K-Lite*'
    '\Adobe Acrobat Update Task*'
)

# Updater executables renamed to *.disabled
$FileDefs = @(
    (Join-Path $env:ProgramFiles 'Notepad++\updater\GUP.exe')
    (Join-Path ${env:ProgramFiles(x86)} 'Notepad++\updater\GUP.exe')
)

# Known update mechanisms - used by Inventory to rate the blocking. Order matters (first name match wins).
# The scriptblocks run in module scope when Inventory evaluates them, so T returns the current language.
$UpdaterCatalog = @(
    @{ Match = 'Mozilla Firefox'; Check = {
        New-Status -How (T 'upd.firefox') -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'DisableAppUpdate' 1),
            (Test-SvcDisabled 'MozillaMaintenance'),
            (Test-TasksDisabled '\Mozilla\Firefox Background Update*')) } }
    @{ Match = 'Mozilla Maintenance'; Check = {
        New-Status -How (T 'upd.mozmaint') -Checks @((Test-SvcDisabled 'MozillaMaintenance')) } }
    @{ Match = 'Notepad\+\+'; Check = {
        New-Status -How 'updater\GUP.exe -> .disabled' -Checks @(($FileDefs | ForEach-Object { -not (Test-Path $_) })) } }
    @{ Match = 'Google Chrome'; Check = {
        New-Status -How (T 'upd.chrome') -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Google\Update' 'UpdateDefault' 0),
            (Test-SvcDisabled 'GoogleUpdater*'), (Test-SvcDisabled 'gupdate*'),
            (Test-TasksDisabled '\GoogleSystem\GoogleUpdater\*'), (Test-TasksDisabled '\GoogleUpdate*')) } }
    @{ Match = 'Microsoft Edge'; Check = {
        New-Status -How (T 'upd.edge') -Checks @(
            (Test-SvcDisabled 'edgeupdate*'), (Test-TasksDisabled '\MicrosoftEdgeUpdateTask*')) } }
    @{ Match = 'Visual Studio Code'; Check = {
        New-Status -How (T 'upd.vscode') -Checks @((Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode' 'UpdateMode' 'none')) } }
    @{ Match = 'Visual Studio (Community|Professional|Enterprise|Installer|Build Tools)'; Check = {
        New-Status -How (T 'upd.vs') -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\Setup' 'BackgroundDownloadDisabled' 1),
            (Test-TasksDisabled '\Microsoft\VisualStudio\Updates\*')) } }
    @{ Match = 'Microsoft 365|Aplikacje Microsoft 365|Microsoft Office'; Check = {
        New-Status -How (T 'upd.office') -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' 'EnableAutomaticUpdates' 0),
            (Test-TasksDisabled '\Microsoft\Office\Office Automatic Updates*')) } }
    @{ Match = 'Teams'; Check = {
        New-Status -How 'HKLM\SOFTWARE\Microsoft\Teams disableAutoUpdate=1' -Checks @((Test-Policy 'HKLM:\SOFTWARE\Microsoft\Teams' 'disableAutoUpdate' 1)) } }
    @{ Match = 'OneDrive'; Check = {
        New-Status -How (T 'upd.onedrive') -Checks @((Test-TasksDisabled '\OneDrive*Update*')) } }
    @{ Match = 'Adobe Acrobat'; Check = {
        New-Status -How (T 'upd.adobe') -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown' 'bUpdater' 0),
            (Test-SvcDisabled 'AdobeARMservice'), (Test-TasksDisabled '\Adobe Acrobat Update Task*')) } }
    @{ Match = 'K-Lite'; Check = {
        New-Status -How (T 'upd.klite') -Checks @((Test-TasksDisabled '*K-Lite*')) } }
    @{ Match = 'Omnissa|VMware|FSLogix|Horizon|App Volumes|Dynamic Environment'; Check = {
        New-NoUpdater (T 'upd.vdi') } }
    @{ Match = 'Visual C\+\+|ODBC|SQL Server|CLR Types|Web Deploy|IIS|Windows SDK|Software Development Kit|^vs_|\.NET|Desktop Runtime|7-Zip|Remote Desktop|WinRT'; Check = {
        New-NoUpdater (T 'upd.none') } }
)

# System mechanisms (separate report rows)
$SystemUpdaters = @(
    @{ Key = 'upd.sys.wu'; Check = {
        New-Status -How (T 'upd.wu') -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1),
            (Test-SvcDisabled 'wuauserv'), (Test-SvcDisabled 'UsoSvc'), (Test-SvcDisabled 'WaaSMedicSvc'),
            (Test-TasksDisabled '\Microsoft\Windows\WindowsUpdate\*'), (Test-TasksDisabled '\Microsoft\Windows\UpdateOrchestrator\*')) } }
    @{ Key = 'upd.sys.store'; Check = {
        New-Status -How 'WindowsStore AutoDownload=2' -Checks @((Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2)) } }
)

# VDI infrastructure components - reported, updated only by enabled manifest packages
$InfraPattern = 'VMware Tools|Horizon Agent|Dynamic Environment Manager|App Volumes|FSLogix'

# ---------- module state ----------
$script:TaskCache        = @()
$script:SvcNames         = @()
$script:WingetExe        = $null
$script:WingetExit       = 0
$script:HotfixCache      = $null
$script:ProvCache        = $null
$script:OfficeHandled    = $false
$script:PackageRunResult = ''
$script:BoundParams      = @{}
$script:OsotExit         = $null
$script:BuildFinalize    = $false   # PostGeneralize: Finalize with Osot.FinalizeBuild
$script:ForceInstallIds  = @()      # PostGeneralize: packages installed despite Enabled=false / RequireInstalled
$script:SealDone         = $false   # Update -ThenSeal: Seal done (condition for -Shutdown)
$script:SealIssues       = 0
$script:EntryScript      = ''       # path of VDI-ImageMaint.ps1 (resume, SYSTEM task, FirstLogonCommands)
$isSystem                = $false
