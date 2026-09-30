#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Obsługa złotego obrazu VDI (Windows 11, Omnissa Horizon Instant Clone):
    aktualizacja aplikacji, a następnie blokada automatycznych aktualizacji przed publikacją.

.DESCRIPTION
    Tryby pracy (-Mode):
      Status     - raport: usługi, zadania harmonogramu, polityki, oczekujący restart, stan "pieczęci"
      WingetList - podgląd (dry-run): co winget chce zaktualizować i co zostanie pominięte
      Init       - tworzy strukturę C:\install (Patches, Office, FSLogix, Horizon, OSOT, Apps, Scripts),
                   manifest packages.json i README
      Discover   - buduje manifest dla bieżącego obrazu: pliki z C:\install bez wpisu są dopasowywane
                   do zainstalowanych aplikacji; warianty x86 trafiają do Ignore; wynik w
                   packages.discovered.json (z -Apply: bezpośrednio do packages.json + kopia .bak)
      Optimize   - OSOT: optymalizacja obrazu wg sekcji "Osot" manifestu (+ raport analizy)
      Finalize   - OSOT: finalizacja (-f) wg sekcji "Osot" manifestu
      PackageList- plan instalacji pakietów z manifestu packages.json (dry-run, nic nie instaluje)
      Packages   - instalacja pakietów z manifestu (bez Windows Update / winget)
      Inventory  - zrzut pakietów (Win32, MSIX provisioned, winget export) ze statusem blokady
                   autoaktualizacji -> %ProgramData%\VDI-ImageMaint\Inventory\<data>\ (CSV dla Excela + JSON)
      Unlock     - przywraca stan sprzed Seal (odblokowuje mechanizmy aktualizacji)
      Update     - Unlock + OSOT (włączenie Windows/Office Update) + FSLogix z paczki w C:\install
                + aktualizacja: Defender, Microsoft 365 (ODT: setup.exe /download + /configure Configure.xml,
                a gdy brak ODT - klient C2R), Visual Studio, Edge, Teams (MSIX),
                aplikacje przez winget, na końcu Windows Update (może wymagać restartu)
                Domyślnie winget aktualizuje listę -WingetIds; z -WingetAll aktualizuje wszystko,
                co winget wykryje, POZA pakietami pasującymi do -WingetExcludePattern / -WingetExcludeIds
                (komponenty VDI, Office, Visual Studio, Edge, App Installer - mają własne ścieżki aktualizacji)
      Seal    - OSOT Optimize (szablon / plik wyborów + opcje wspólne, -windowsupdate/-officeupdate disable),
                następnie blokuje automatyczne aktualizacje: Windows Update / UsoSvc / WaaSMedic, Store,
                Microsoft 365 C2R, Edge, Chrome (GoogleUpdater), Teams, Firefox (+ Mozilla Maintenance), VS Code, Visual Studio,
                Notepad++ (GUP), OneDrive, K-Lite; dodatkowo WYKRYWA i blokuje inne aktualizatory
                (zadania/usługi firm trzecich z "update/updater" w nazwie lub ścieżce, poza AV i VDI);
                opcjonalnie czyści obraz (-Cleanup); wykonuje Inventory; na końcu OSOT Finalize
      Generalize - BUDOWA obrazu (raz na wydanie Windows, w trybie audytu): naprawa znanych blokerów Sysprep
                (szyfrowanie, polityka Store, Copilot/BingSearch), kontrola Test-SysprepReadiness.ps1,
                wygenerowany unattend.xml (AutoLogon + FirstLogonCommands), OSOT -g (Sysprep), restart.
                Wymaga -SnapshotConfirmed. Po OOBE automatycznie uruchamia się PostGeneralize
      PostGeneralize - (uruchamiane automatycznie po OOBE) usunięcie Copilot/BingSearch, instalacja agentów
                z Build.PostGeneralizePackages (restarty + wznowienie), wyłączenie AutoLogon, Seal (jako SYSTEM)
                z Finalize wg Osot.FinalizeBuild

    Katalog instalacyjny (-InstallDir, domyślnie C:\install):
      packages.json                   manifest pakietów (tworzony przy pierwszym uruchomieniu)
      *OS*Optimization*Tool*.exe      OSOT - używana jest najnowsza wersja z katalogu
      setup.exe + Configure.xml       pakiet "Office365" (ODT /download + /configure)
      FSLogix*.zip                    pakiety "FSLogix", "FSLogixRuleEditor" (tylko aktualizacja)
      Patches\*.msu, *.cab, *.msp     poprawki (DISM / msiexec /p), pomijane gdy KB już zainstalowany
      Apps\, Scripts\                 własne pakiety MSI/EXE/MSIX/PS1 opisane w manifeście
      Horizon / DEM / App Volumes / VMware Tools - wpisy w manifeście, domyślnie Enabled=false

    Manifest - pola pakietu:
      Id, Name, Enabled, Order, Type (exe|msi|msp|msu|cab|odt|appx|ps1), File (wzorzec, może zawierać
      podfolder), Archive (zip do rozpakowania), Recurse, PreferPath/ExcludePath (regex), FileInfoMatch,
      Multiple (wszystkie pasujące pliki), Version (gdy nie da się odczytać z pliku), Arguments
      (zmienne {File} {Dir} {Log} {InstallDir} + sekcja Variables), Detect {Type: Uninstall|Hotfix|
      File|Appx|Registry|Always, Name/Path/Value}, RequireInstalled (tylko aktualizacja), SuccessCodes,
      RebootCodes, RebootAfter (restart przed kolejnymi pakietami), StopProcesses, StopServices,
      PreScript, PostScript, StopOnError
    Manifest - sekcja "Ignore": lista regex (ścieżka względna do C:\install) plików, które nie są pakietami

    Seal zapisuje oryginalny stan do %ProgramData%\VDI-ImageMaint\seal-state.json,
    dzięki czemu Unlock przywraca dokładnie to, co zostało zmienione.

    Komponenty infrastruktury VDI (VMware Tools, Horizon Agent, DEM, App Volumes Agent, FSLogix)
    NIE są aktualizowane - ich wersje muszą być zgodne z backendem (Connection Server / App Volumes Manager).

.EXAMPLE
    # 0. Plan pakietów z C:\install i podgląd winget (nic nie instalują)
    .\VDI-ImageMaint.ps1 -Mode PackageList
    .\VDI-ImageMaint.ps1 -Mode WingetList -WingetAll

    # 1. Aktualizacja - po restarcie powtarzaj, aż Windows Update nie znajdzie nic nowego
    .\VDI-ImageMaint.ps1 -Mode Update -WingetAll

    # 1b. Jak wyżej, ale z automatycznym restartem i wznowieniem po zalogowaniu (max 5 rund)
    .\VDI-ImageMaint.ps1 -Mode Update -WingetAll -AutoReboot

    # Tylko wybrane pakiety z manifestu
    .\VDI-ImageMaint.ps1 -Mode Packages -PackageIds FSLogix,WindowsPatches

    # Wykluczenie dodatkowych pakietów
    .\VDI-ImageMaint.ps1 -Mode Update -WingetAll -WingetExcludeIds 'Microsoft.WebDeploy','Microsoft.SQLServer.2019.LocalDB'

    # 2. Blokada aktualizacji + czyszczenie + wyłączenie VM przed snapshotem
    .\VDI-ImageMaint.ps1 -Mode Seal -Cleanup -AsSystem -Shutdown

    # 2b. Seal z innym szablonem OSOT i pełną finalizacją (nadpisuje sekcję "Osot" manifestu)
    .\VDI-ImageMaint.ps1 -Mode Seal -AsSystem -OsotTemplate 'Omnissa Templates\Windows 10, 11 and Server 2022, 2025' -OsotFinalize all -Shutdown

    # Pierwsze uruchomienie: struktura katalogów + manifest dopasowany do obrazu
    .\VDI-ImageMaint.ps1 -Mode Init
    .\VDI-ImageMaint.ps1 -Mode Discover            # propozycja -> packages.discovered.json
    .\VDI-ImageMaint.ps1 -Mode Discover -Apply     # zapis do packages.json

    # Kontrola
    .\VDI-ImageMaint.ps1 -Mode Status
    .\VDI-ImageMaint.ps1 -Mode Inventory

    # BUDOWA: po Optimize + restarcie, w trybie audytu, po zrobieniu snapshotu "pre-generalize"
    .\VDI-ImageMaint.ps1 -Mode Generalize -SnapshotConfirmed -Shutdown
    #   -> Sysprep -> OOBE -> AutoLogon -> PostGeneralize (agenty, restarty) -> Seal -> wyłączenie VM

.NOTES
    Wersja 1.8.0 (Generalize/PostGeneralize, poprawki B1-B7). Logi: %ProgramData%\VDI-ImageMaint\Logs
    -AsSystem zalecane dla Seal/Unlock: część usług i zadań (WaaSMedicSvc, UpdateOrchestrator)
    jest chroniona i administrator nie może ich zmienić.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Init', 'Discover', 'Status', 'Inventory', 'WingetList', 'PackageList', 'Packages', 'Optimize', 'Finalize', 'Unlock', 'Update', 'Seal', 'Generalize', 'PostGeneralize')]
    [string]$Mode,

    # --- Katalog z paczkami ---
    [string]$InstallDir = 'C:\install',

    # --- OSOT (Omnissa OS Optimization Tool) ---
    [switch]$SkipOsot,
    [string]$OsotPath,                 # wymuszenie konkretnego exe (domyślnie najnowszy z -InstallDir)
    # Domyślne ustawienia OSOT są w sekcji "Osot" pliku packages.json; parametry poniżej je nadpisują
    [switch]$OsotOptimize,             # wymuś optymalizację w Seal
    [switch]$OsotSkipOptimize,         # Seal bez optymalizacji (tylko wyłączenie Windows/Office Update)
    [string]$OsotTemplate,             # np. 'Omnissa Templates\Windows 10, 11 and Server 2022, 2025'
    [string]$OsotLevel,                # np. 'recommended'; puste = domyślny wybór szablonu
    [string]$OsotFinalize,             # np. 'all' lub '0 1 3 4 10'; 'none' = bez finalizacji
    [string[]]$OsotExtraArgs = @(),    # dodatkowe opcje wspólne OSOT, np. '-onedrive','disable'

    # --- Platforma pakietów ---
    [string]$Manifest,                 # domyślnie <InstallDir>\packages.json (tworzony automatycznie)
    [switch]$SkipPackages,             # Update bez pakietów z manifestu
    [string[]]$PackageIds,             # ogranicz do wybranych Id z manifestu
    [switch]$Apply,                    # Discover: zapisz wynik do packages.json (z kopią zapasową)
    [switch]$AutoReboot,               # restart + automatyczne wznowienie po zalogowaniu
    [int]$MaxRounds = 5,               # limit restartów przy -AutoReboot
    [int]$ResumeRound = 0,             # (wewnętrzne) numer rundy po wznowieniu

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
    # Aktualizuj wszystko, co wykryje winget (z wykluczeniami poniżej) zamiast listy -WingetIds
    [switch]$WingetAll,
    # Uwzględnij pakiety z nieznaną wersją (mogą być reinstalowane przy każdym uruchomieniu)
    [switch]$WingetIncludeUnknown,
    # Regex dopasowywany do nazwy LUB identyfikatora - takie pakiety są pomijane przy -WingetAll
    [string]$WingetExcludePattern = 'Omnissa|VMware|Horizon|App ?Volumes|Dynamic Environment|FSLogix|Microsoft\.Office|Microsoft 365 Apps|Aplikacje Microsoft 365|Microsoft\.VisualStudio\.20|Visual Studio (Community|Professional|Enterprise|Build Tools)|Visual Studio Installer|Microsoft\.Edge|Microsoft Edge|Microsoft\.AppInstaller|DesktopAppInstaller',
    # Dodatkowe identyfikatory winget do pominięcia (dokładne dopasowanie)
    [string[]]$WingetExcludeIds = @(),
    # Aplikacje MSIX/Store - winget zaktualizowałby je tylko dla bieżącego konta, nie w obrazie
    [string[]]$WingetStoreIds = @('Microsoft.Teams', 'Microsoft.Outlook', 'Microsoft.WindowsTerminal', 'Microsoft.365Copilot'),

    # Nowy Teams - aktualizacja wersji zaprowizjonowanej przez teamsbootstrapper -p
    [switch]$SkipTeams,
    [string]$TeamsBootstrapperPath,

    # --- Seal ---
    [switch]$Cleanup,
    [switch]$Force,
    # Tylko raportuj wykryte dodatkowe aktualizatory, nie blokuj ich
    [switch]$NoBlockDetected,
    # Co uznajemy za aktualizator (nazwa/ścieżka zadania lub usługi)
    [string]$UpdaterDetectPattern = 'update|updater|upgrade|maintenanceservice|\\gup\.exe',
    # Czego NIE blokować mimo dopasowania (antywirusy, komponenty VDI)
    [string]$DetectExcludePattern = 'Omnissa|VMware|Horizon|App ?Volumes|FSLogix|Dynamic Environment|Trend ?Micro|Defender|Sophos|CrowdStrike|Sentinel|ESET|Symantec|McAfee|Kaspersky|Bitdefender|VDI-ImageMaint',
    [switch]$Shutdown,

    # --- Seal / Unlock / Status ---
    [switch]$AsSystem,

    # --- Generalize (budowa obrazu) ---
    # Potwierdzenie, że istnieje snapshot VM sprzed Generalize (nieudany Sysprep bywa nieodwracalny)
    [switch]$SnapshotConfirmed,
    # Osot = OSOT -g (zalecane przez Omnissa); Sysprep = bezpośrednio sysprep.exe (gdy brak OSOT)
    [ValidateSet('Osot', 'Sysprep')]
    [string]$GeneralizeEngine = 'Osot',
    # Hasło wbudowanego Administratora dla OOBE/AutoLogon (bez parametru - pytanie interaktywne)
    [securestring]$AdminPassword,
    # Usuń WSZYSTKIE pakiety AppX zainstalowane dla konta, a niezaprowizjonowane (poza MSTeams)
    [switch]$RemoveUnprovisionedAppx
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# =====================================================================
#  KONFIGURACJA
# =====================================================================
$BaseDir   = Join-Path $env:ProgramData 'VDI-ImageMaint'
$LogDir    = Join-Path $BaseDir 'Logs'
$StateFile = Join-Path $BaseDir 'seal-state.json'

# Usługi wyłączane przy Seal (Default = typ startu używany przy Unlock bez zapisu stanu)
$ServiceDefs = @(
    @{ Name = 'wuauserv';           Default = 3 }
    @{ Name = 'UsoSvc';             Default = 2 }
    @{ Name = 'WaaSMedicSvc';       Default = 3 }
    @{ Name = 'edgeupdate';         Default = 2 }
    @{ Name = 'edgeupdatem';        Default = 3 }
    @{ Name = 'MozillaMaintenance'; Default = 3 }
    # Google Chrome - nowy GoogleUpdater (nazwy z numerem wersji) i stary Google Update
    @{ Name = 'GoogleUpdaterService*';         Default = 2 }
    @{ Name = 'GoogleUpdaterInternalService*'; Default = 2 }
    @{ Name = 'gupdate';                       Default = 2 }
    @{ Name = 'gupdatem';                      Default = 3 }
)

# Polityki (HKLM) ustawiane przy Seal
$PolicyDefs = @(
    # Windows Update
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU';            Name = 'NoAutoUpdate';                 Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';               Name = 'SetDisableUXWUAccess';         Value = 1 }
    # Microsoft Store
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore';                        Name = 'AutoDownload';                 Value = 2 }
    # Microsoft 365 Apps (Click-to-Run)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate';     Name = 'EnableAutomaticUpdates';       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate';     Name = 'HideEnableDisableUpdates';     Value = 1 }
    # Microsoft Edge (polityki EdgeUpdate działają na maszynach w domenie / MDM - usługi i tak są wyłączane)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate';                          Name = 'UpdateDefault';                Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate';                          Name = 'AutoUpdateCheckPeriodMinutes'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate';                          Name = 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'; Value = 0 }
    # Google Chrome (jak Edge: polityki działają w domenie / MDM - usługi i zadania są wyłączane niezależnie)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Google\Update';                              Name = 'UpdateDefault';                Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Google\Update';                              Name = 'AutoUpdateCheckPeriodMinutes'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Google\Update';                              Name = 'Update{8A69D345-D564-463C-AFF1-A69D9E530F96}'; Value = 0 }
    # Nowy Microsoft Teams na VDI
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Teams';                                       Name = 'disableAutoUpdate';            Value = 1 }
    # Mozilla Firefox
    @{ Path = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox';                               Name = 'DisableAppUpdate';             Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox';                               Name = 'BackgroundAppUpdate';          Value = 0 }
    # Visual Studio Code
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode';                              Name = 'UpdateMode';                   Value = 'none'; Type = 'String' }
    # Visual Studio 2022
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\Setup';                  Name = 'BackgroundDownloadDisabled';   Value = 1 }
)

# Zadania harmonogramu (pełna ścieżka, wildcard)
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
)

# Pliki aktualizatorów zmieniane na *.disabled
$FileDefs = @(
    (Join-Path $env:ProgramFiles 'Notepad++\updater\GUP.exe')
    (Join-Path ${env:ProgramFiles(x86)} 'Notepad++\updater\GUP.exe')
)

# Katalog znanych mechanizmów aktualizacji - używany przez Inventory do oceny blokady.
# Kolejność ma znaczenie (pierwsze dopasowanie nazwy wygrywa).
$UpdaterCatalog = @(
    @{ Match = 'Mozilla Firefox'; Check = {
        New-Status -How 'DisableAppUpdate + MozillaMaintenance + zadanie Background Update' -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'DisableAppUpdate' 1),
            (Test-SvcDisabled 'MozillaMaintenance'),
            (Test-TasksDisabled '\Mozilla\Firefox Background Update*')) } }
    @{ Match = 'Mozilla Maintenance'; Check = {
        New-Status -How 'usługa MozillaMaintenance' -Checks @((Test-SvcDisabled 'MozillaMaintenance')) } }
    @{ Match = 'Notepad\+\+'; Check = {
        New-Status -How 'updater\GUP.exe -> .disabled' -Checks @(($FileDefs | ForEach-Object { -not (Test-Path $_) })) } }
    @{ Match = 'Google Chrome'; Check = {
        New-Status -How 'polityka Google\Update + usługi GoogleUpdater/gupdate + zadania' -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Google\Update' 'UpdateDefault' 0),
            (Test-SvcDisabled 'GoogleUpdater*'), (Test-SvcDisabled 'gupdate*'),
            (Test-TasksDisabled '\GoogleSystem\GoogleUpdater\*'), (Test-TasksDisabled '\GoogleUpdate*')) } }
    @{ Match = 'Microsoft Edge'; Check = {
        New-Status -How 'usługi edgeupdate + zadania MicrosoftEdgeUpdateTask' -Checks @(
            (Test-SvcDisabled 'edgeupdate*'), (Test-TasksDisabled '\MicrosoftEdgeUpdateTask*')) } }
    @{ Match = 'Visual Studio Code'; Check = {
        New-Status -How 'polityka VSCode UpdateMode=none' -Checks @((Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode' 'UpdateMode' 'none')) } }
    @{ Match = 'Visual Studio (Community|Professional|Enterprise|Installer|Build Tools)'; Check = {
        New-Status -How 'BackgroundDownloadDisabled + zadania VisualStudio\Updates' -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\Setup' 'BackgroundDownloadDisabled' 1),
            (Test-TasksDisabled '\Microsoft\VisualStudio\Updates\*')) } }
    @{ Match = 'Microsoft 365|Aplikacje Microsoft 365|Microsoft Office'; Check = {
        New-Status -How 'officeupdate EnableAutomaticUpdates=0 + zadania Office Automatic Updates' -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' 'EnableAutomaticUpdates' 0),
            (Test-TasksDisabled '\Microsoft\Office\Office Automatic Updates*')) } }
    @{ Match = 'Teams'; Check = {
        New-Status -How 'HKLM\SOFTWARE\Microsoft\Teams disableAutoUpdate=1' -Checks @((Test-Policy 'HKLM:\SOFTWARE\Microsoft\Teams' 'disableAutoUpdate' 1)) } }
    @{ Match = 'OneDrive'; Check = {
        New-Status -How 'zadania OneDrive Update' -Checks @((Test-TasksDisabled '\OneDrive*Update*')) } }
    @{ Match = 'K-Lite'; Check = {
        New-Status -How 'zadania K-Lite (sprawdzanie aktualizacji w Codec Tweak Tool wyłącz ręcznie)' -Checks @((Test-TasksDisabled '*K-Lite*')) } }
    @{ Match = 'Omnissa|VMware|FSLogix|Horizon|App Volumes|Dynamic Environment'; Check = {
        New-NoUpdater 'aktualizacja ręczna, zgodnie z wersją backendu VDI' } }
    @{ Match = 'Visual C\+\+|ODBC|SQL Server|CLR Types|Web Deploy|IIS|Windows SDK|Software Development Kit|^vs_|\.NET|Desktop Runtime|7-Zip|Remote Desktop|WinRT'; Check = {
        New-NoUpdater 'brak własnego aktualizatora (Windows Update / winget / ręcznie)' } }
)

# Mechanizmy systemowe (osobne wiersze w raporcie)
$SystemUpdaters = @(
    @{ Name = 'Windows Update'; Check = {
        New-Status -How 'NoAutoUpdate + wuauserv/UsoSvc/WaaSMedicSvc + zadania WindowsUpdate/UpdateOrchestrator' -Checks @(
            (Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1),
            (Test-SvcDisabled 'wuauserv'), (Test-SvcDisabled 'UsoSvc'), (Test-SvcDisabled 'WaaSMedicSvc'),
            (Test-TasksDisabled '\Microsoft\Windows\WindowsUpdate\*'), (Test-TasksDisabled '\Microsoft\Windows\UpdateOrchestrator\*')) } }
    @{ Name = 'Microsoft Store (aktualizacje aplikacji MSIX)'; Check = {
        New-Status -How 'WindowsStore AutoDownload=2' -Checks @((Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2)) } }
)

$script:TaskCache = @()
$script:SvcNames  = @()

# Komponenty VDI - tylko raport, bez aktualizacji
$InfraPattern = 'VMware Tools|Horizon Agent|Dynamic Environment Manager|App Volumes|FSLogix'

# =====================================================================
#  POMOCNICZE
# =====================================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'STEP')][string]$Level = 'INFO'
    )
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERR = 'Red'; STEP = 'Cyan' }[$Level]
    if ($Level -eq 'STEP') { Write-Host '' }
    Write-Host ('[{0}] [{1,-4}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $color
}

function Get-RegValue {
    # Bez wyjątków przy braku klucza/wartości (PS 5.1 zapisuje przechwycone wyjątki do transkrypcji)
    param([string]$Path, [string]$Name)
    if (-not $Path) { return $null }   # Get-Item -LiteralPath '' rzuca błąd wiązania (nie wycisza go SilentlyContinue)
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    return $key.GetValue($Name, $null)
}

function Test-PendingReboot {
    $r = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $r += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $r += 'WindowsUpdate' }
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $r += 'PendingFileRename' }
    return $r
}

function Resolve-ServiceDefs {
    # Rozwija wzorce (np. GoogleUpdaterService*) do faktycznie istniejących usług
    $all = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
    foreach ($d in $ServiceDefs) {
        if ($d.Name -match '[\*\?]') {
            foreach ($n in @($all | Where-Object { $_ -like $d.Name })) { @{ Name = $n; Default = $d.Default } }
        } elseif ($all -contains $d.Name) {
            $d
        }
    }
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($Object.PSObject.Properties[$Name]) { return [string]$Object.$Name } else { return '' }
}

function Get-InstalledApps {
    $hives = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             Arch = 'x64' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Arch = 'x86' }
    )
    foreach ($h in $hives) {
        Get-ItemProperty -Path $h.Path -ErrorAction SilentlyContinue |
            # Get-Prop zwraca string: SystemComponent=0 daje '0', które jest "prawdą" - porównanie z '1'
            Where-Object { (Get-Prop $_ 'DisplayName') -and (Get-Prop $_ 'SystemComponent') -ne '1' -and -not (Get-Prop $_ 'ParentKeyName') } |
            ForEach-Object {
                [pscustomobject]@{
                    Name            = Get-Prop $_ 'DisplayName'
                    Version         = Get-Prop $_ 'DisplayVersion'
                    Publisher       = Get-Prop $_ 'Publisher'
                    InstallDate     = Get-Prop $_ 'InstallDate'
                    InstallLocation = Get-Prop $_ 'InstallLocation'
                    Arch            = $h.Arch
                }
            }
    }
}

function Show-AppDiff {
    param($Before, $After)
    $b = @{}; foreach ($x in $Before) { $b[$x.Name] = $x.Version }
    $a = @{}; foreach ($x in $After)  { $a[$x.Name] = $x.Version }
    $changes = @()
    foreach ($k in $a.Keys) {
        if (-not $b.ContainsKey($k))  { $changes += [pscustomobject]@{ Aplikacja = $k; Przed = '(nowa)'; Po = $a[$k] } }
        elseif ($b[$k] -ne $a[$k])    { $changes += [pscustomobject]@{ Aplikacja = $k; Przed = $b[$k];    Po = $a[$k] } }
    }
    foreach ($k in $b.Keys) {
        if (-not $a.ContainsKey($k))  { $changes += [pscustomobject]@{ Aplikacja = $k; Przed = $b[$k]; Po = '(usunięta)' } }
    }
    Write-Log 'Zmiany w zainstalowanych aplikacjach' STEP
    if ($changes.Count -eq 0) { Write-Log 'Brak zmian w wersjach aplikacji'; return }
    $changes | Sort-Object Aplikacja | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
}

function Get-MatchingTasks {
    $seen = @{}
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $full = $t.TaskPath + $t.TaskName
        foreach ($p in $TaskPatterns) {
            if ($full -like $p -and -not $seen.ContainsKey($full)) { $seen[$full] = $true; $t; break }
        }
    }
}

# =====================================================================
#  WINGET
# =====================================================================
$script:WingetExe  = $null
$script:WingetExit = 0

function Find-WingetExe {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object { try { [version](($_.Directory.Name -split '_')[1]) } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if ($p) { return $p.FullName }
    return $null
}

function Initialize-Winget {
    if ($script:WingetExe) { return $true }
    $exe = Find-WingetExe
    if (-not $exe) {
        # App Installer bywa zainstalowany, ale niezarejestrowany dla bieżącego konta (częste na obrazach VDI)
        Write-Log 'winget nie znaleziony - próba rejestracji App Installer dla bieżącego konta' WARN
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
            Start-Sleep -Seconds 3
            $exe = Find-WingetExe
        } catch { Write-Log "Rejestracja nieudana: $($_.Exception.Message)" WARN }
    }
    if (-not $exe) {
        Write-Log 'winget niedostępny. Zainstaluj "App Installer" (Microsoft.DesktopAppInstaller) - OSOT/LTSC często go usuwa.' ERR
        return $false
    }
    $script:WingetExe = $exe
    $ver = (Invoke-Winget -Arguments @('--version') | Select-Object -Last 1)
    Write-Log "winget $ver ($exe)" OK
    [void](Invoke-Winget -Arguments @('source', 'update', '--disable-interactivity'))
    if ($script:WingetExit -ne 0) { Write-Log "winget source update: kod $($script:WingetExit)" WARN }
    return $true
}

function Invoke-Winget {
    param([string[]]$Arguments)
    # PS 5.1: stderr natywnego exe przy 2>&1 + EAP=Stop daje błąd kończący - lokalnie Continue
    $ErrorActionPreference = 'Continue'
    $prevEnc = $null
    try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try {
        $out = @(& $script:WingetExe @Arguments 2>&1 | ForEach-Object {
            # usuń animację postępu (\r, backspace) - zostaw ostatni stan linii
            (("$_" -split "`r")[-1]) -replace "[\x08]", ''
        })
        $script:WingetExit = $LASTEXITCODE
    } finally {
        if ($prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
    }
    return $out
}

function Get-WingetColumn {
    param([string]$Line, [int[]]$Cols, [int]$Index)
    $start = $Cols[$Index]
    if ($start -ge $Line.Length) { return '' }
    $end = if ($Index + 1 -lt $Cols.Count) { [Math]::Min($Cols[$Index + 1], $Line.Length) } else { $Line.Length }
    return $Line.Substring($start, $end - $start).Trim()
}

function Get-WingetUpgrades {
    # Parsowanie tabeli 'winget upgrade' po pozycjach kolumn (działa niezależnie od języka nagłówków)
    $args2 = @('upgrade', '--accept-source-agreements', '--disable-interactivity')
    if ($WingetIncludeUnknown) { $args2 += '--include-unknown' }
    $lines = Invoke-Winget -Arguments $args2

    $sep = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*-{10,}\s*$') { $sep = $i; break } }
    if ($sep -lt 1) { return @() }   # brak tabeli = brak aktualizacji

    $header = $lines[$sep - 1]
    $cols = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
    if ($cols.Count -lt 4) { Write-Log "Nie rozpoznano nagłówka winget: '$header'" WARN; return @() }

    $pkgs = @()
    for ($i = $sep + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($l) -or $l.Length -le $cols[3]) { break }   # koniec tabeli / stopka
        $pkg = [pscustomobject]@{
            Name      = Get-WingetColumn $l $cols 0
            Id        = Get-WingetColumn $l $cols 1
            Version   = Get-WingetColumn $l $cols 2
            Available = Get-WingetColumn $l $cols 3
            Source    = $(if ($cols.Count -ge 5) { Get-WingetColumn $l $cols 4 } else { '' })
            Action    = 'aktualizuj'
            Reason    = ''
        }
        if (-not $pkg.Id) { continue }
        if ($pkg.Id -match '…|\.\.\.$') {
            $pkg.Action = 'pomiń'; $pkg.Reason = 'obcięty identyfikator'
        } elseif ($WingetStoreIds -contains $pkg.Id) {
            $pkg.Action = 'pomiń'; $pkg.Reason = 'MSIX/Store - winget tylko dla bieżącego konta'
            if ($pkg.Id -eq 'Microsoft.Teams') { $pkg.Reason = 'MSIX - aktualizacja przez teamsbootstrapper' }
        } elseif ($WingetExcludeIds -contains $pkg.Id) {
            $pkg.Action = 'pomiń'; $pkg.Reason = 'WingetExcludeIds'
        } elseif ($pkg.Name -match $WingetExcludePattern -or $pkg.Id -match $WingetExcludePattern) {
            $pkg.Action = 'pomiń'; $pkg.Reason = 'wykluczenie (VDI / własny mechanizm)'
        }
        $pkgs += $pkg
    }
    return $pkgs
}

function Show-WingetList {
    Write-Log 'WINGET - podgląd dostępnych aktualizacji (dry-run)' STEP
    if (-not (Initialize-Winget)) { return }
    if ($WingetAll) {
        $pkgs = @(Get-WingetUpgrades)
        if ($pkgs.Count -eq 0) { Write-Log 'Brak dostępnych aktualizacji winget' OK; return }
        $pkgs | Select-Object Name, Id, Version, Available, Action, Reason |
            Format-Table -AutoSize | Out-String -Width 250 | Write-Host
        $n = @($pkgs | Where-Object { $_.Action -eq 'aktualizuj' }).Count
        Write-Log "Do aktualizacji: $n, pominięte: $($pkgs.Count - $n)"
    } else {
        $pkgs = @(Get-WingetUpgrades)
        $rows = foreach ($id in $WingetIds) {
            $hit = $pkgs | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            [pscustomobject]@{
                Id        = $id
                Version   = $(if ($hit) { $hit.Version } else { '' })
                Available = $(if ($hit) { $hit.Available } else { '(aktualna lub niezainstalowana)' })
            }
        }
        $rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
        Write-Log 'Tryb listy -WingetIds. Dodaj -WingetAll, aby zobaczyć wszystkie pakiety.'
    }
}

# =====================================================================
#  ZAPIS STANU (Seal <-> Unlock)
# =====================================================================
function New-SealState {
    [ordered]@{
        Created  = (Get-Date).ToString('s')
        Computer = $env:COMPUTERNAME
        Sealed   = $false   # false = tylko stan bazowy sprzed OSOT (Seal niedokończony)
        Services = @()
        Tasks    = @()
        Registry = @()
        Files    = @()
    }
}

function Get-SealState {
    if (-not (Test-Path $StateFile)) { return $null }
    $j = Get-Content -Path $StateFile -Raw | ConvertFrom-Json
    $s = New-SealState
    $s.Created  = $j.Created
    $s.Computer = $j.Computer
    $s.Sealed   = [bool](Get-PV $j 'Sealed' $true)   # pliki sprzed 1.8.0 nie mają pola = zapieczętowane
    foreach ($k in 'Services', 'Tasks', 'Registry', 'Files') { $s[$k] = @(Get-PV $j $k @() | Where-Object { $_ }) }
    return $s
}

# ---------- stan bazowy (B4) ----------
# Zapisywany PRZED OSOT: OSOT -windowsupdate disable sam wyłącza usługi i ustawia polityki, więc gdyby stan
# był zapisywany dopiero po OSOT, Unlock "przywróciłby" wyłączone usługi. Rekordy nigdy nie są nadpisywane.
function Add-PolicyBaseline {
    param($Def, $State)
    if (@($State.Registry | Where-Object { $_.Path -eq $Def.Path -and $_.Name -eq $Def.Name }).Count) { return }
    $rec = [pscustomobject]@{ Path = $Def.Path; Name = $Def.Name; Existed = $false; OldValue = $null; OldKind = $null }
    $key = Get-Item -LiteralPath $Def.Path -ErrorAction SilentlyContinue
    if ($key -and ($key.GetValueNames() -contains $Def.Name)) {
        $rec.Existed  = $true
        $rec.OldValue = $key.GetValue($Def.Name, $null, 'DoNotExpandEnvironmentNames')
        $rec.OldKind  = $key.GetValueKind($Def.Name).ToString()
    }
    $State.Registry += $rec
}

function Add-ServiceBaseline {
    param([string]$Name, $State)
    $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $reg)) { return }
    if (@($State.Services | Where-Object { $_.Name -eq $Name }).Count) { return }
    $State.Services += [pscustomobject]@{ Name = $Name; Start = [int](Get-RegValue $reg 'Start') }
}

function Add-TaskBaseline {
    param($Task, $State)
    $full = $Task.TaskPath + $Task.TaskName
    if (@($State.Tasks | Where-Object { $_.FullName -eq $full }).Count) { return }
    $State.Tasks += [pscustomobject]@{
        TaskPath = $Task.TaskPath; TaskName = $Task.TaskName; FullName = $full
        WasEnabled = ($Task.State -ne 'Disabled')
    }
}

function Save-SealBaseline {
    $state = Get-SealState
    if (-not $state) { $state = New-SealState }
    foreach ($p in $PolicyDefs) { Add-PolicyBaseline -Def $p -State $state }
    foreach ($s in @(Resolve-ServiceDefs)) { Add-ServiceBaseline -Name $s.Name -State $state }
    foreach ($t in @(Get-MatchingTasks)) { Add-TaskBaseline -Task $t -State $state }
    Save-SealState -State $state
    Write-Log "Stan bazowy sprzed OSOT zapisany: $StateFile"
}

function Save-SealState {
    param($State)
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8
}

# =====================================================================
#  SEAL - elementy
# =====================================================================
function Set-PolicyValue {
    param($Def, $State)
    Add-PolicyBaseline -Def $Def -State $State
    if (-not (Test-Path $Def.Path)) { New-Item -Path $Def.Path -Force | Out-Null }
    $type = if ($Def.ContainsKey('Type')) { $Def.Type } else { 'DWord' }
    New-ItemProperty -Path $Def.Path -Name $Def.Name -Value $Def.Value -PropertyType $type -Force | Out-Null
    Write-Log ("Polityka: {0}\{1} = {2}" -f ($Def.Path -replace '^HKLM:\\SOFTWARE\\Policies\\', ''), $Def.Name, $Def.Value) OK
}

function Disable-UpdateService {
    param($Def, $State)
    $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Def.Name)"
    if (-not (Test-Path $reg)) { Write-Log "Usługa $($Def.Name) nie istnieje - pomijam"; return }
    $cur = [int](Get-RegValue $reg 'Start')
    Add-ServiceBaseline -Name $Def.Name -State $State
    try {
        Set-ItemProperty -Path $reg -Name Start -Value 4 -ErrorAction Stop
        Write-Log "Usługa $($Def.Name): Disabled (było Start=$cur)" OK
    } catch {
        Write-Log "Usługa $($Def.Name): brak uprawnień do zmiany (chroniona) - uruchom z -AsSystem" WARN
        $script:SealIssues++
    }
    try { Stop-Service -Name $Def.Name -Force -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { Write-Log "Usługa $($Def.Name): nie udało się zatrzymać ($($_.Exception.Message))" WARN }
}

function Disable-OneTask {
    param($Task, $State)
    $full = $Task.TaskPath + $Task.TaskName
    Add-TaskBaseline -Task $Task -State $State
    if ($Task.State -eq 'Disabled') { return }
    try {
        Disable-ScheduledTask -TaskPath $Task.TaskPath -TaskName $Task.TaskName -ErrorAction Stop | Out-Null
        Write-Log "Zadanie wyłączone: $full" OK
    } catch {
        Write-Log "Zadanie chronione, nie wyłączono: $full (użyj -AsSystem)" WARN
        $script:SealIssues++
    }
}

function Disable-UpdateTasks {
    param($State)
    foreach ($t in @(Get-MatchingTasks)) { Disable-OneTask -Task $t -State $State }
}

function Find-UnmanagedUpdaters {
    # Aktywne zadania i usługi firm trzecich wyglądające na aktualizatory, nieobjęte stałą konfiguracją
    $found = @()
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if ($t.State -eq 'Disabled') { continue }
        $full = $t.TaskPath + $t.TaskName
        if ($full -like '\Microsoft\Windows\*') { continue }
        if (@($TaskPatterns | Where-Object { $full -like $_ }).Count) { continue }
        $exec = @($t.Actions | ForEach-Object {
            if ($_.PSObject.Properties['Execute'] -and $_.Execute) { ("{0} {1}" -f $_.Execute, $_.Arguments).Trim() }
        }) -join ' | '
        $text = "$full $exec"
        if ($text -notmatch $UpdaterDetectPattern -or $text -match $DetectExcludePattern) { continue }
        $found += [pscustomobject]@{ Type = 'Zadanie'; Name = $full; Detail = $exec; Task = $t }
    }
    $managed = @(Resolve-ServiceDefs | ForEach-Object { $_.Name })
    foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
        if ($svc.StartMode -eq 'Disabled' -or $managed -contains $svc.Name) { continue }
        $path = [string]$svc.PathName
        if ($path -match '\\Windows\\') { continue }   # usługi systemowe
        $text = "$($svc.Name) $($svc.DisplayName) $path"
        if ($text -notmatch $UpdaterDetectPattern -or $text -match $DetectExcludePattern) { continue }
        $found += [pscustomobject]@{ Type = 'Usługa'; Name = $svc.Name; Detail = $path; Task = $null }
    }
    return $found
}

function Disable-DetectedUpdaters {
    param($State)
    $found = @(Find-UnmanagedUpdaters)
    if ($found.Count -eq 0) { Write-Log 'Nie wykryto dodatkowych aktualizatorów' OK; return }
    foreach ($f in $found) {
        if ($NoBlockDetected) { Write-Log "Wykryto (NIE zablokowano, -NoBlockDetected): [$($f.Type)] $($f.Name) -> $($f.Detail)" WARN; continue }
        Write-Log "Wykryto: [$($f.Type)] $($f.Name) -> $($f.Detail)"
        if ($f.Type -eq 'Zadanie') { Disable-OneTask -Task $f.Task -State $State }
        else { Disable-UpdateService -Def @{ Name = $f.Name; Default = 3 } -State $State }
    }
}

function Disable-UpdaterFiles {
    param($State)
    foreach ($f in $FileDefs) {
        if (-not (Test-Path $f)) { continue }
        $dst = "$f.disabled"
        if (Test-Path $dst) { Remove-Item $dst -Force }
        Rename-Item -Path $f -NewName (Split-Path $dst -Leaf) -Force
        if (@($State.Files | Where-Object { $_.Path -eq $f }).Count -eq 0) {
            $State.Files += [pscustomobject]@{ Path = $f }
        }
        Write-Log "Aktualizator wyłączony: $f" OK
    }
}

function Invoke-ImageCleanup {
    Write-Log 'Czyszczenie obrazu' STEP
    Stop-Service -Name wuauserv, BITS -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log 'SoftwareDistribution\Download wyczyszczony' OK
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; Write-Log 'Cache Delivery Optimization wyczyszczony' OK }
    catch { Write-Log 'Cache Delivery Optimization - pominięto' }
    Remove-Item "$env:ProgramFiles\Microsoft Office\Updates\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log 'Katalogi TEMP wyczyszczone' OK
    Write-Log 'DISM /StartComponentCleanup (może potrwać kilka-kilkanaście minut)...'
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
    Write-Log "DISM zakończony, kod: $LASTEXITCODE" $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' })
}

function Assert-SealPreconditions {
    # B6: sprawdzane PRZED OSOT (także w procesie nadrzędnym -AsSystem), żeby nie optymalizować obrazu,
    # którego Seal i tak zostanie odrzucony
    $pending = @(Test-PendingReboot)
    $hard = @($pending | Where-Object { $_ -ne 'PendingFileRename' })
    if ($hard.Count -gt 0 -and -not $Force) {
        throw "Oczekuje restart ($($hard -join ', ')). Zrestartuj VM przed Seal - inaczej operacje wykonają się na każdym klonie. (-Force pomija sprawdzenie)"
    }
    if ($pending.Count -gt 0) { Write-Log "Uwaga: oczekujący restart ($($pending -join ', '))" WARN }
}

function Invoke-Seal {
    Write-Log 'SEAL - blokada automatycznych aktualizacji' STEP
    Assert-SealPreconditions
    if (-not $SkipOsot -and -not $isSystem) { Save-SealBaseline; Invoke-OsotSealPre }

    $state = Get-SealState
    if ($state -and $state.Sealed) { Write-Log "Obraz był już zapieczętowany ($($state.Created)) - uzupełniam brakujące elementy" }
    elseif ($state) { Write-Log "Stan bazowy z $($state.Created) - kontynuuję Seal" }
    else            { $state = New-SealState }

    $script:SealIssues = 0
    try {
        Write-Log 'Polityki' STEP
        foreach ($p in $PolicyDefs)  { Set-PolicyValue -Def $p -State $state }
        Write-Log 'Usługi' STEP
        foreach ($s in @(Resolve-ServiceDefs)) { Disable-UpdateService -Def $s -State $state }
        Write-Log 'Zadania harmonogramu' STEP
        Disable-UpdateTasks -State $state
        Write-Log 'Aktualizatory aplikacji' STEP
        Disable-UpdaterFiles -State $state
        Write-Log 'Wykrywanie innych mechanizmów aktualizacji' STEP
        Disable-DetectedUpdaters -State $state
        $state.Sealed = $true
    } finally {
        Save-SealState -State $state
        Write-Log "Zapis stanu: $StateFile"
    }

    if ($Cleanup) { Invoke-ImageCleanup }
    Show-Status
    Invoke-Inventory
    if (-not $SkipOsot -and -not $isSystem) { Invoke-OsotFinalize }

    if ($script:SealIssues -gt 0) {
        Write-Log "Seal zakończony z $($script:SealIssues) ostrzeżeniami - uruchom ponownie z -AsSystem" WARN
    } else {
        Write-Log 'Seal zakończony poprawnie' OK
    }
    Write-Log 'Dalej: wyłącz VM -> snapshot -> Horizon Console: Push Image (Instant Clone)' STEP
}

# =====================================================================
#  UNLOCK
# =====================================================================
function Invoke-Unlock {
    Write-Log 'UNLOCK - odblokowanie mechanizmów aktualizacji' STEP
    $state  = Get-SealState
    $issues = 0

    if (-not $state) {
        Write-Log 'Brak zapisu stanu Seal - przywracam tylko wartości ustawione przez to narzędzie' WARN
        foreach ($p in $PolicyDefs) {
            if ((Get-RegValue $p.Path $p.Name) -eq $p.Value) {
                Remove-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction SilentlyContinue
                Write-Log "Polityka usunięta: $($p.Name)" OK
            }
        }
        foreach ($s in @(Resolve-ServiceDefs)) {
            $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
            if ((Test-Path $reg) -and (Get-RegValue $reg 'Start') -eq 4) {
                try { Set-ItemProperty -Path $reg -Name Start -Value $s.Default -ErrorAction Stop; Write-Log "Usługa $($s.Name): Start=$($s.Default)" OK }
                catch { Write-Log "Usługa $($s.Name): brak uprawnień (-AsSystem)" WARN }
            }
        }
        foreach ($f in $FileDefs) {
            if ((Test-Path "$f.disabled") -and -not (Test-Path $f)) { Rename-Item "$f.disabled" -NewName (Split-Path $f -Leaf); Write-Log "Przywrócono: $f" OK }
        }
        Write-Log 'Zadania harmonogramu pozostawiono bez zmian (brak informacji o stanie pierwotnym)' WARN
        return 0
    }

    foreach ($r in $state.Registry) {
        try {
            if ($r.Existed) {
                if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
                New-ItemProperty -Path $r.Path -Name $r.Name -Value $r.OldValue -PropertyType $r.OldKind -Force | Out-Null
            } else {
                Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
            }
            Write-Log "Polityka przywrócona: $($r.Name)" OK
        } catch { Write-Log "Polityka $($r.Name): $($_.Exception.Message)" WARN; $issues++ }
    }
    foreach ($s in $state.Services) {
        $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
        if (-not (Test-Path $reg)) { continue }
        try { Set-ItemProperty -Path $reg -Name Start -Value ([int]$s.Start) -ErrorAction Stop; Write-Log "Usługa $($s.Name): Start=$($s.Start)" OK }
        catch { Write-Log "Usługa $($s.Name): brak uprawnień (-AsSystem)" WARN; $issues++ }
    }
    foreach ($t in $state.Tasks) {
        if (-not $t.WasEnabled) { continue }
        try { Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null; Write-Log "Zadanie włączone: $($t.FullName)" OK }
        catch {
            if (Get-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction SilentlyContinue) {
                Write-Log "Zadanie $($t.FullName): nie włączono (-AsSystem)" WARN; $issues++
            }
        }
    }
    foreach ($f in $state.Files) {
        if ((Test-Path "$($f.Path).disabled") -and -not (Test-Path $f.Path)) {
            Rename-Item "$($f.Path).disabled" -NewName (Split-Path $f.Path -Leaf); Write-Log "Przywrócono: $($f.Path)" OK
        }
    }

    if ($issues -eq 0) { Remove-Item $StateFile -Force; Write-Log 'Stan przywrócony w całości, zapis Seal usunięty' OK }
    else { Write-Log "Przywrócono z $issues problemami - zapis stanu zachowany, uruchom Unlock z -AsSystem" WARN }
    return $issues
}

# =====================================================================
#  UPDATE - elementy
# =====================================================================
# =====================================================================
#  PACZKI Z KATALOGU INSTALACYJNEGO
# =====================================================================
function ConvertTo-Version {
    # Odporne na człony > Int32 (np. Horizon 8.16.0.16560454767) - takie człony są pomijane;
    # wynik zawsze ma 4 człony, żeby 8.16.0 == 8.16.0.0
    param([string]$Text)
    $m = [regex]::Match([string]$Text, '\d+(\.\d+){1,3}')
    if (-not $m.Success) { return $null }
    $nums = @()
    foreach ($part in $m.Value.Split('.')) {
        $n = 0L
        if ([long]::TryParse($part, [ref]$n) -and $n -le [int]::MaxValue) { $nums += [int]$n } else { break }
    }
    if ($nums.Count -lt 2) { return $null }
    while ($nums.Count -lt 4) { $nums += 0 }
    return (New-Object System.Version -ArgumentList $nums[0], $nums[1], $nums[2], $nums[3])
}

function Get-MsiProperty {
    param([string]$Path, [string]$Property)
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($Path, 0))
        $v  = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$Property'"))
        [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)
        $r  = $v.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $v, $null)
        if (-not $r) { return $null }
        $val = $r.GetType().InvokeMember('StringData', 'GetProperty', $null, $r, 1)
        [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
        return $val
    } catch { return $null }
}

function Get-MsiVersion { param([string]$Path) return (Get-MsiProperty $Path 'ProductVersion') }

function Get-FileVersionText {
    param($File)
    if ($File.Extension -eq '.msi') { return (Get-MsiVersion $File.FullName) }
    if ($File.Extension -match '^\.(msix|msixbundle|appx|appxbundle|msu|cab|zip|ps1|xml)$') {
        $v = ConvertTo-Version ($File.BaseName -replace '^[^_]*_', '')
        if ($v) { return $v.ToString() } else { return '' }
    }
    # EXE: pierwsza wartość, z której da się odczytać wersję (ProductVersion bywa np. "2506")
    $vi = $File.VersionInfo
    foreach ($cand in @($vi.ProductVersion, $vi.FileVersion, $File.BaseName)) {
        if ($cand -and (ConvertTo-Version $cand)) { return [string]$cand }
    }
    return [string]$vi.ProductVersion
}

# ---------- OSOT ----------
function Find-Osot {
    if ($OsotPath) {
        if (Test-Path $OsotPath) { return (Get-Item $OsotPath) }
        Write-Log "OSOT: nie znaleziono $OsotPath" WARN; return $null
    }
    if (-not (Test-Path $InstallDir)) { return $null }
    Get-ChildItem -Path $InstallDir -Recurse -File -Include '*OS*Optimization*Tool*.exe', '*OSOT*.exe' -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { ConvertTo-Version $_.VersionInfo.FileVersion }; Descending = $true },
                    @{ Expression = { $_.LastWriteTime }; Descending = $true } |
        Select-Object -First 1
}

function Invoke-Osot {
    param([string[]]$Arguments, [string]$Label)
    $script:OsotExit = $null   # kod wyjścia ostatniego uruchomienia ($null = nie uruchomiono)
    if ($SkipOsot) { return }
    if ($isSystem) { Write-Log "OSOT ($Label) uruchamiany jest z konta administratora, nie w kontekście SYSTEM"; return }
    $exe = Find-Osot
    if (-not $exe) { Write-Log "OSOT nie znaleziony w $InstallDir - pomijam ($Label)" WARN; return }
    $argLine = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
    $log = Join-Path $LogDir ('OSOT_{0}_{1}.log' -f $Label, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Write-Log ("OSOT {0} [{1}]: {2}" -f $exe.VersionInfo.FileVersion, $Label, $argLine) STEP
    Write-Log "Plik: $($exe.FullName)"
    $p = Start-Process -FilePath $exe.FullName -ArgumentList $argLine -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $script:OsotExit = $p.ExitCode
    Write-Log "OSOT [$Label] kod: $($p.ExitCode), log: $log" $(if ($p.ExitCode -eq 0) { 'OK' } else { 'WARN' })
}

function Invoke-OsotEnableUpdates {
    # -o no-item = bez optymalizacji pozycji szablonu, tylko opcje wspólne
    Invoke-Osot -Label 'EnableUpdates' -Arguments @('-o', 'no-item', '-SyncHkcuToHku', 'disable',
        '-windowsupdate', 'enable', '-officeupdate', 'enable', '-v')
}

function Get-OsotConfig {
    # Konfiguracja OSOT: sekcja "Osot" manifestu + nadpisania z parametrów
    $m = $null
    $mp = Get-ManifestPath
    if (Test-Path $mp) { try { $m = Get-Content -Path $mp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $o = Get-PV $m 'Osot'
    $cfg = [ordered]@{
        Optimize      = [bool](Get-PV $o 'Optimize' $true)
        Template      = [string](Get-PV $o 'Template' '')
        Level         = [string](Get-PV $o 'Level' '')
        SettingsFile  = [string](Get-PV $o 'SettingsFile' '')
        CommonOptions = @(Get-PV $o 'CommonOptions' @('-visualeffect', 'performance', '-notification', 'disable', '-storeapp', 'keep-all'))
        Finalize      = [string](Get-PV $o 'Finalize' '0 1 3 4 10')
        Report        = [bool](Get-PV $o 'Report' $true)
    }
    # Budowa obrazu (PostGeneralize) może mieć pełniejszy zestaw Finalize niż cykl Day-2
    if ($script:BuildFinalize) { $cfg.Finalize = [string](Get-PV $o 'FinalizeBuild' $cfg.Finalize) }
    if ($OsotOptimize)     { $cfg.Optimize = $true }
    if ($OsotSkipOptimize) { $cfg.Optimize = $false }
    if ($OsotTemplate)     { $cfg.Template = $OsotTemplate }
    if ($OsotLevel)        { $cfg.Level = $OsotLevel }
    if ($OsotExtraArgs)    { $cfg.CommonOptions = @($cfg.CommonOptions) + @($OsotExtraArgs) }
    if ($OsotFinalize)     { $cfg.Finalize = $(if ($OsotFinalize -eq 'none') { '' } else { $OsotFinalize }) }
    return $cfg
}

function Get-OsotOptimizeArgs {
    param($Cfg)
    $a = @('-o')
    if ($Cfg.Level)    { $a += $Cfg.Level }
    if ($Cfg.Template) { $a += @('-t', $Cfg.Template) }
    if ($Cfg.SettingsFile) {
        $sf = if ([IO.Path]::IsPathRooted($Cfg.SettingsFile)) { $Cfg.SettingsFile } else { Join-Path $InstallDir $Cfg.SettingsFile }
        if (Test-Path $sf) { $a += @('-applyoptimization', $sf) }
        else { Write-Log "OSOT: brak pliku wyborów $sf - używam wyborów z szablonu" }
    }
    $a += @($Cfg.CommonOptions)
    if ($Cfg.Report) {
        $a += @('-r', (Join-Path $LogDir ('OSOT_Report_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))))
    }
    return $a
}

function Show-OsotConfig {
    $o = Find-Osot
    if ($o) { Write-Log "OSOT: $($o.FullName) (wersja $($o.VersionInfo.FileVersion))" OK } else { Write-Log "OSOT: brak w $InstallDir" WARN }
    $c = Get-OsotConfig
    Write-Log ("OSOT w Seal: optymalizacja={0} | szablon={1} | poziom={2} | wybory={3}" -f $c.Optimize,
        $(if ($c.Template) { $c.Template } else { 'domyślny' }), $(if ($c.Level) { $c.Level } else { 'domyślny' }),
        $(if ($c.SettingsFile) { $c.SettingsFile } else { '-' }))
    Write-Log ("OSOT opcje wspólne: {0} -windowsupdate disable -officeupdate disable" -f (@($c.CommonOptions) -join ' '))
    Write-Log ("OSOT Finalize: {0}" -f $(if ($c.Finalize) { "-f $($c.Finalize)" } else { 'wyłączony' }))
}

function Invoke-OsotSealPre {
    # Optymalizacja obrazu (lub samo wyłączenie aktualizacji, gdy Optimize=false)
    $cfg = Get-OsotConfig
    if ($cfg.Optimize) { $a = @(Get-OsotOptimizeArgs $cfg) }
    else { $a = @('-o', 'no-item', '-SyncHkcuToHku', 'disable') }
    $a += @('-windowsupdate', 'disable', '-officeupdate', 'disable', '-v')
    Invoke-Osot -Label $(if ($cfg.Optimize) { 'Optimize' } else { 'DisableUpdates' }) -Arguments $a
}

function Invoke-OsotFinalize {
    $cfg = Get-OsotConfig
    if (-not $cfg.Finalize) { Write-Log 'OSOT Finalize wyłączony (Finalize pusty lub -OsotFinalize none)'; return }
    Invoke-Osot -Label 'Finalize' -Arguments (@('-f') + @($cfg.Finalize -split '\s+' | Where-Object { $_ }) + @('-v'))
}

# =====================================================================
#  PLATFORMA PAKIETÓW (manifest packages.json)
# =====================================================================
$ResumeTaskName = 'VDI-ImageMaint-Resume'
$script:HotfixCache      = $null
$script:ProvCache        = $null
$script:OfficeHandled    = $false
$script:PackageRunResult = ''
$script:BoundParams      = @{}
$script:OsotExit         = $null
$script:BuildFinalize    = $false   # PostGeneralize: Finalize wg Osot.FinalizeBuild
$script:ForceInstallIds  = @()      # PostGeneralize: pakiety instalowane mimo Enabled=false / RequireInstalled

$DefaultManifestJson = @'
{
  "_opis": "Manifest VDI-ImageMaint. Wszystko w C:\\install: skrypt, ten plik, OSOT i paczki (podfoldery dowolne - wyszukiwanie rekurencyjne). Enabled=false = pakiet tylko raportowany. Kolejność wg Order.",
  "Variables": {
    "AppVolumesManager": "appvolumes.domena.local",
    "AppVolumesPort": "443"
  },
  "Osot": {
    "_opis": "Seal: optymalizacja (-o) z wyłączeniem Windows/Office Update, na końcu Finalize (-f). SettingsFile = eksport 'Export Selections' z GUI OSOT (opcjonalny).",
    "Optimize": true,
    "Template": "",
    "Level": "",
    "SettingsFile": "OSOT\\osot-selections.json",
    "CommonOptions": [
      "-visualeffect",
      "performance",
      "-notification",
      "disable",
      "-storeapp",
      "keep-all"
    ],
    "Finalize": "0 1 3 4 10",
    "FinalizeBuild": "0 1 3 4 5 8 10 11",
    "Report": true
  },
  "Build": {
    "_opis": "Budowa obrazu (-Mode Generalize -> PostGeneralize). Puste pole = bieżące ustawienie systemu. UILanguage musi być zainstalowanym językiem.",
    "TimeZone": "",
    "InputLocale": "",
    "SystemLocale": "",
    "UserLocale": "",
    "UILanguage": "",
    "ComputerName": "",
    "SkipRearm": false,
    "PersistAllDeviceInstalls": true,
    "AutoLogonCount": 10,
    "PostGeneralizePackages": ["VMwareTools", "HorizonAgent", "DEM", "AppVolumesAgent"],
    "RemoveUserAppx": ["Microsoft.Copilot", "Microsoft.BingSearch"],
    "AppxSettleSeconds": 120
  },
  "Ignore": [],
  "Packages": [
    {
      "Id": "WindowsPatches",
      "Name": "Poprawki Windows (MSU z folderu Patches)",
      "Enabled": true,
      "Order": 5,
      "Type": "msu",
      "File": "Patches\\*.msu",
      "Multiple": true,
      "Detect": {
        "Type": "Hotfix"
      },
      "RebootAfter": true
    },
    {
      "Id": "WindowsPatchesCab",
      "Name": "Poprawki Windows (CAB z folderu Patches)",
      "Enabled": true,
      "Order": 6,
      "Type": "cab",
      "File": "Patches\\*.cab",
      "Multiple": true,
      "Detect": {
        "Type": "Hotfix"
      },
      "RebootAfter": true
    },
    {
      "Id": "VMwareTools",
      "Name": "VMware Tools",
      "Enabled": false,
      "Order": 10,
      "Type": "exe",
      "File": "VMware-tools-*.exe",
      "Arguments": "/S /v \"/qn REBOOT=R\"",
      "Detect": {
        "Type": "Uninstall",
        "Name": "^VMware Tools$"
      },
      "RequireInstalled": true,
      "RebootAfter": true
    },
    {
      "Id": "HorizonAgent",
      "Name": "Omnissa Horizon Agent",
      "Enabled": false,
      "Order": 11,
      "Type": "exe",
      "File": "*Horizon-Agent-x86_64*.exe",
      "Arguments": "/s /v\"/qn REBOOT=ReallySuppress\"",
      "Detect": {
        "Type": "Uninstall",
        "Name": "Horizon Agent$"
      },
      "RequireInstalled": true,
      "RebootAfter": true
    },
    {
      "Id": "DEM",
      "Name": "Omnissa Dynamic Environment Manager",
      "Enabled": false,
      "Order": 12,
      "Type": "msi",
      "File": "*Dynamic Environment Manager*x64*.msi",
      "Arguments": "ADDLOCAL=FlexEngine",
      "Detect": {
        "Type": "Uninstall",
        "Name": "Dynamic Environment Manager"
      },
      "RequireInstalled": true,
      "RebootAfter": true,
      "ExcludePath": "(?i)Optional Components"
    },
    {
      "Id": "AppVolumesAgent",
      "Name": "App Volumes Agent",
      "Enabled": false,
      "Order": 13,
      "Type": "msi",
      "File": "App Volumes Agent*.msi",
      "Arguments": "MANAGER_ADDR={AppVolumesManager} MANAGER_PORT={AppVolumesPort} EnforceSSLCertificateValidation=1 REBOOT=ReallySuppress",
      "Detect": {
        "Type": "Uninstall",
        "Name": "App Volumes Agent"
      },
      "RequireInstalled": true,
      "RebootAfter": true
    },
    {
      "Id": "FSLogix",
      "Name": "Microsoft FSLogix Apps",
      "Enabled": true,
      "Order": 20,
      "Type": "exe",
      "Archive": "*FSLogix*.zip",
      "File": "FSLogixAppsSetup.exe",
      "PreferPath": "\\\\x64\\\\",
      "Arguments": "/install /quiet /norestart /log \"{Log}\"",
      "Detect": {
        "Type": "Uninstall",
        "Name": "^Microsoft FSLogix Apps$"
      },
      "RequireInstalled": true
    },
    {
      "Id": "FSLogixRuleEditor",
      "Name": "Microsoft FSLogix Apps RuleEditor",
      "Enabled": true,
      "Order": 21,
      "Type": "exe",
      "Archive": "*FSLogix*.zip",
      "File": "FSLogixAppsRuleEditorSetup.exe",
      "PreferPath": "\\\\x64\\\\",
      "Arguments": "/install /quiet /norestart /log \"{Log}\"",
      "Detect": {
        "Type": "Uninstall",
        "Name": "^Microsoft FSLogix Apps RuleEditor"
      },
      "RequireInstalled": true
    },
    {
      "Id": "Office365",
      "Name": "Microsoft 365 Apps (Office Deployment Tool)",
      "Enabled": true,
      "Order": 30,
      "Type": "odt",
      "File": "setup.exe",
      "Recurse": true,
      "FileInfoMatch": "Office",
      "Config": "",
      "Detect": {
        "Type": "Always"
      }
    },
    {
      "Id": "PatchesMsp",
      "Name": "Poprawki MSP aplikacji (folder Patches)",
      "Enabled": false,
      "Order": 35,
      "Type": "msp",
      "File": "Patches\\*.msp",
      "Multiple": true,
      "SuccessCodes": [
        0,
        1642
      ],
      "Detect": {
        "Type": "Always"
      }
    },
    {
      "Id": "NewOutlook",
      "Name": "Nowy Outlook (MSIX provisioned, folder Apps)",
      "Enabled": false,
      "Order": 40,
      "Type": "appx",
      "File": "Apps\\Microsoft.OutlookForWindows*.msixbundle",
      "Detect": {
        "Type": "Appx",
        "Name": "Microsoft.OutlookForWindows"
      }
    },
    {
      "Id": "Przyklad-MSI",
      "Name": "Przykład: aplikacja MSI (folder Apps)",
      "Enabled": false,
      "Order": 50,
      "Type": "msi",
      "File": "Apps\\Aplikacja*.msi",
      "Arguments": "ALLUSERS=1",
      "Detect": {
        "Type": "Uninstall",
        "Name": "^Aplikacja"
      },
      "StopProcesses": [
        "aplikacja"
      ]
    },
    {
      "Id": "Przyklad-EXE",
      "Name": "Przykład: instalator EXE z własną detekcją pliku",
      "Enabled": false,
      "Order": 51,
      "Type": "exe",
      "File": "Apps\\Narzedzie*.exe",
      "Arguments": "/S",
      "Detect": {
        "Type": "File",
        "Path": "C:\\Program Files\\Narzedzie\\narzedzie.exe"
      }
    },
    {
      "Id": "Przyklad-PS1",
      "Name": "Przykład: skrypt konfiguracyjny obrazu (jednorazowy)",
      "Enabled": false,
      "Order": 90,
      "Type": "ps1",
      "File": "Scripts\\Konfiguracja-Obrazu.ps1",
      "Arguments": "-Wersja 1",
      "Detect": {
        "Type": "Registry",
        "Path": "HKLM:\\SOFTWARE\\EMS\\VDI-Image",
        "Name": "KonfiguracjaWersja",
        "Value": "1"
      }
    }
  ]
}
'@

function Get-PV {
    # Bezpieczny odczyt właściwości obiektu z JSON (StrictMode)
    param($Obj, [string]$Name, $Default = $null)
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) { return $Obj.$Name }
    return $Default
}

function Expand-PkgString {
    param([string]$Text, [hashtable]$Vars)
    foreach ($k in $Vars.Keys) { $Text = $Text.Replace('{' + $k + '}', [string]$Vars[$k]) }
    return $Text
}

function Get-ManifestPath {
    if ($Manifest) { if ([IO.Path]::IsPathRooted($Manifest)) { return $Manifest } else { return (Join-Path $InstallDir $Manifest) } }
    return (Join-Path $InstallDir 'packages.json')
}

function Get-PackageManifest {
    $path = Get-ManifestPath
    if (-not (Test-Path $path)) {
        if (-not (Test-Path $InstallDir)) { Write-Log "Brak katalogu $InstallDir" ERR; return $null }
        Write-Log "Brak manifestu $path - tworzę domyślny (komponenty Horizon wyłączone, do uzupełnienia)" WARN
        Set-Content -Path $path -Value $DefaultManifestJson -Encoding UTF8
    }
    try { return (Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-Log "Błąd składni JSON w ${path}: $($_.Exception.Message)" ERR; return $null }
}

function Find-PackageFiles {
    param([string]$Root, [string]$Pattern, [bool]$Recurse = $true)
    if (-not (Test-Path $Root)) { return }
    $leaf = Split-Path $Pattern -Leaf
    $sub  = Split-Path $Pattern -Parent
    $base = if ($sub) { Join-Path $Root $sub } else { $Root }
    if (-not (Test-Path $base)) { return }
    if ($Recurse) { Get-ChildItem -Path $base -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue }
    else          { Get-ChildItem -Path $base -File -Filter $leaf -ErrorAction SilentlyContinue }
}

function Resolve-PackageFiles {
    param($Pkg)
    $pattern = [string](Get-PV $Pkg 'File' '')
    if (-not $pattern) { return @() }
    $recurse = [bool](Get-PV $Pkg 'Recurse' $true)
    $roots = @($InstallDir)
    $archive = [string](Get-PV $Pkg 'Archive' '')
    if ($archive) {
        foreach ($z in @(Find-PackageFiles -Root $InstallDir -Pattern $archive)) {
            $dst = Join-Path $env:TEMP ('VDI-ImageMaint_' + $z.BaseName)
            if (-not (Test-Path $dst)) { Write-Log "Rozpakowuję $($z.Name)"; Expand-Archive -Path $z.FullName -DestinationPath $dst -Force }
            $roots += $dst
        }
    }
    $files = @(foreach ($r in $roots) { Find-PackageFiles -Root $r -Pattern $pattern -Recurse ($recurse -or $r -ne $InstallDir) })
    $prefer = [string](Get-PV $Pkg 'PreferPath' '')
    if ($prefer) { $pf = @($files | Where-Object { $_.FullName -match $prefer }); if ($pf.Count) { $files = $pf } }
    $excl = [string](Get-PV $Pkg 'ExcludePath' '')
    if ($excl) { $files = @($files | Where-Object { $_.FullName -notmatch $excl }) }
    $info = [string](Get-PV $Pkg 'FileInfoMatch' '')
    if ($info) { $files = @($files | Where-Object { "$($_.VersionInfo.ProductName) $($_.VersionInfo.FileDescription)" -match $info }) }
    return @($files | Sort-Object FullName -Unique)
}

function Get-KbFromName {
    param([string]$Name)
    if ($Name -match '(?i)(kb\d{6,8})') { return $Matches[1].ToUpper() }
    return $null
}

function Test-KbInstalled {
    param([string]$Kb)
    if ($null -eq $script:HotfixCache) {
        Write-Log 'Odczyt zainstalowanych poprawek (Get-HotFix + Get-WindowsPackage)...'
        $list = @(Get-HotFix -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.HotFixID })
        foreach ($wp in @(Get-WindowsPackage -Online -ErrorAction SilentlyContinue)) {
            if ($wp.PackageName -match '(?i)(KB\d{6,8})' -and $wp.PackageState -match 'Installed|InstallPending') { $list += $Matches[1].ToUpper() }
        }
        $script:HotfixCache = $list
    }
    return ($script:HotfixCache -contains $Kb)
}

function Get-ProvisionedVersion {
    param([string]$Name)
    if ($null -eq $script:ProvCache) { $script:ProvCache = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) }
    $p = $script:ProvCache | Where-Object { $_.DisplayName -eq $Name } | Select-Object -First 1
    if ($p) { return [string]$p.Version } else { return $null }
}

function Set-VersionAction {
    param($Plan, [string]$Current, [string]$New, [bool]$RequireInstalled)
    $Plan.Installed = $(if ($Current) { $Current } else { '(brak)' })
    $Plan.Package   = $New
    if (-not $Current) {
        if ($RequireInstalled) { $Plan.Action = 'pomiń'; $Plan.Reason = 'nie jest zainstalowany (RequireInstalled)' }
        else { $Plan.Action = 'instaluj'; $Plan.Reason = 'nowa instalacja' }
        return
    }
    $cv = ConvertTo-Version $Current; $nv = ConvertTo-Version $New
    if (-not $nv)             { $Plan.Action = 'pomiń';      $Plan.Reason = 'nie można odczytać wersji paczki (dodaj "Version" w manifeście)' }
    elseif ($cv -and $nv -le $cv) { $Plan.Action = 'aktualny' }
    else                      { $Plan.Action = 'aktualizuj' }
}

function Test-OdtInstallXml {
    # Konfiguracja instalacyjna ODT: ma <Add>, nie ma <Remove> (odrzuca np. Uninstall.xml)
    param([string]$Path)
    try {
        [xml]$x = Get-Content -Path $Path -Raw -ErrorAction Stop
        return ([bool]$x.SelectSingleNode('/Configuration/Add') -and -not $x.SelectSingleNode('/Configuration/Remove'))
    } catch { return $false }
}

function Resolve-OdtConfig {
    # 1) ścieżka bezwzględna z pola Config  2) plik o nazwie z Config obok setup.exe / w katalogu głównym / w podfolderach
    # 3) automatycznie: jedyny XML instalacyjny ODT obok setup.exe (przy kilku - preferowany z "x64" w nazwie)
    param($Pkg, $SetupFile)
    $cfg = [string](Get-PV $Pkg 'Config' '')
    if ($cfg) {
        if ([IO.Path]::IsPathRooted($cfg)) { if (Test-Path $cfg) { return $cfg } else { return $null } }
        foreach ($d in @($SetupFile.DirectoryName, $InstallDir)) {
            $c = Join-Path $d $cfg
            if (Test-Path $c) { return $c }
        }
        $hit = Get-ChildItem -Path $InstallDir -Recurse -File -Filter (Split-Path $cfg -Leaf) -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\Office\\Data\\' } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $xmls = @(Get-ChildItem -Path $SetupFile.DirectoryName -File -Filter '*.xml' -ErrorAction SilentlyContinue |
        Where-Object { Test-OdtInstallXml $_.FullName })
    if ($xmls.Count -gt 1) {
        $x64 = @($xmls | Where-Object { $_.Name -match '(?i)x64|64' })
        if ($x64.Count) { $xmls = $x64 }
    }
    if ($xmls.Count -ge 1) { return ($xmls | Sort-Object Name | Select-Object -First 1).FullName }
    return $null
}

function Get-PackagePlan {
    param($Pkg, $Installed)
    $id = [string](Get-PV $Pkg 'Id' '(bez Id)')
    $plan = [pscustomobject]@{
        Order = [int](Get-PV $Pkg 'Order' 100); Id = $id; Name = [string](Get-PV $Pkg 'Name' $id)
        Type = ([string](Get-PV $Pkg 'Type' 'exe')).ToLower(); Installed = ''; Package = ''
        Action = ''; Reason = ''; Files = @(); Pkg = $Pkg
    }
    $forced  = ($script:ForceInstallIds -contains $id)   # PostGeneralize: świeża instalacja agentów
    $enabled = [bool](Get-PV $Pkg 'Enabled' $true) -or $forced
    $files = @(Resolve-PackageFiles $Pkg)
    if ($files.Count -eq 0) {
        $plan.Action = 'brak pliku'; $plan.Reason = [string](Get-PV $Pkg 'File' '')
        if (-not $enabled) { $plan.Reason += ' (wyłączony)' }
        return $plan
    }
    if ($plan.Type -eq 'odt') {
        $withCfg = @($files | Where-Object { Resolve-OdtConfig $Pkg $_ })
        if ($withCfg.Count -eq 0) {
            $plan.Action = 'brak pliku'
            $plan.Reason = "brak XML konfiguracji ODT (<Add>) obok setup.exe ani pliku z pola Config"
            return $plan
        }
        $near = @($withCfg | Where-Object { (Split-Path (Resolve-OdtConfig $Pkg $_) -Parent) -eq $_.DirectoryName })
        $files = @($(if ($near.Count) { $near } else { $withCfg }))
    }
    if (-not [bool](Get-PV $Pkg 'Multiple' $false) -and $files.Count -gt 1) {
        $files = @($files | Sort-Object @{ Expression = { ConvertTo-Version (Get-FileVersionText $_) }; Descending = $true },
                                        @{ Expression = { $_.LastWriteTime }; Descending = $true } | Select-Object -First 1)
    }
    $pkgVersion = [string](Get-PV $Pkg 'Version' '')
    if (-not $pkgVersion) { $pkgVersion = [string](Get-FileVersionText $files[0]) }
    $req    = [bool](Get-PV $Pkg 'RequireInstalled' $false) -and -not $forced
    $detect = Get-PV $Pkg 'Detect'
    $dType  = [string](Get-PV $detect 'Type' 'Always')

    switch ($dType) {
        'Uninstall' {
            $rx  = [string](Get-PV $detect 'Name' '^$')
            $app = @($Installed | Where-Object { $_.Name -match $rx }) |
                Sort-Object @{ Expression = { ConvertTo-Version $_.Version }; Descending = $true } | Select-Object -First 1
            Set-VersionAction -Plan $plan -Current $(if ($app) { $app.Version } else { '' }) -New $pkgVersion -RequireInstalled $req
        }
        'Hotfix' {
            $todo = @(); $done = @()
            foreach ($f in $files) {
                $kb = Get-KbFromName $f.Name
                if ($kb -and (Test-KbInstalled $kb)) { $done += $kb } else { $todo += $f }
            }
            $files = $todo
            $plan.Installed = $(if ($done.Count) { $done -join ', ' } else { '-' })
            $plan.Package   = (@($todo | ForEach-Object { $k = Get-KbFromName $_.Name; if ($k) { $k } else { $_.Name } }) -join ', ')
            $plan.Action    = $(if ($todo.Count) { 'instaluj' } else { 'aktualny' })
        }
        'File' {
            $path = [string](Get-PV $detect 'Path' '')
            $cur  = if ($path -and (Test-Path $path)) { (Get-Item $path).VersionInfo.FileVersion } else { '' }
            Set-VersionAction -Plan $plan -Current $cur -New $pkgVersion -RequireInstalled $req
        }
        'Appx' {
            $cur = Get-ProvisionedVersion ([string](Get-PV $detect 'Name' ''))
            Set-VersionAction -Plan $plan -Current $cur -New $pkgVersion -RequireInstalled $req
        }
        'Registry' {
            $cur  = [string](Get-RegValue ([string](Get-PV $detect 'Path' '')) ([string](Get-PV $detect 'Name' '')))
            $want = [string](Get-PV $detect 'Value' '')
            $plan.Installed = $(if ($cur) { $cur } else { '(brak)' }); $plan.Package = $want
            $plan.Action = $(if ($cur -eq $want) { 'aktualny' } else { 'instaluj' })
        }
        default {
            $plan.Package = $pkgVersion; $plan.Action = 'instaluj'; $plan.Reason = 'uruchamiany zawsze'
        }
    }
    if ($plan.Type -eq 'odt') {
        $plan.Installed = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'VersionToReport')
        if (-not $plan.Installed) { $plan.Installed = '(brak)' }
        $plan.Package = 'wg kanału'
        $plan.Reason  = "ODT $pkgVersion, config: $(Resolve-OdtConfig $Pkg $files[0])"
    }
    $plan.Files = $files
    if (-not $enabled -and $plan.Action -in 'instaluj', 'aktualizuj') {
        $plan.Reason = "wyłączony w manifeście (byłoby: $($plan.Action))"; $plan.Action = 'pomiń'
    } elseif ($PackageIds -and $PackageIds -notcontains $id -and $plan.Action -in 'instaluj', 'aktualizuj') {
        $plan.Reason = "poza -PackageIds (byłoby: $($plan.Action))"; $plan.Action = 'pomiń'
    }
    return $plan
}

function Install-PlannedPackage {
    param($Plan, [hashtable]$Vars)
    $pkg = $Plan.Pkg
    $defaultOk = if ($Plan.Type -in 'msu', 'cab') { @(0, -2146498530, 2359302) } else { @(0) }   # 0x800F081E = nie dotyczy
    $okCodes     = @(Get-PV $pkg 'SuccessCodes' $defaultOk)
    $rebootCodes = @(Get-PV $pkg 'RebootCodes' @(3010, 1641))

    foreach ($pn in @(Get-PV $pkg 'StopProcesses' @())) { Get-Process -Name $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    foreach ($sn in @(Get-PV $pkg 'StopServices' @()))  { Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue }
    $pre = [string](Get-PV $pkg 'PreScript' '')
    if ($pre) { Write-Log "[$($Plan.Id)] PreScript"; & ([scriptblock]::Create($pre)) | Out-Null }

    $failed = $false; $reboot = $false
    foreach ($f in $Plan.Files) {
        $log = Join-Path $LogDir ('PKG_{0}_{1}_{2}.log' -f $Plan.Id, $f.BaseName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $v = $Vars.Clone(); $v['File'] = $f.FullName; $v['Dir'] = $f.DirectoryName; $v['Log'] = $log
        $argText = Expand-PkgString ([string](Get-PV $pkg 'Arguments' '')) $v
        $rc = $null; $exe = $null; $al = ''; $shown = $null

        if ($Plan.Type -eq 'odt') {
            $cfg = Resolve-OdtConfig $pkg $f
            if (-not $cfg) { Write-Log "[$($Plan.Id)] brak XML konfiguracji ODT obok $($f.FullName)" ERR; $failed = $true; break }
            Write-Log "[$($Plan.Id)] setup.exe: $($f.FullName) | config: $cfg"
            $ok = Update-OfficeOdt -Odt $f.FullName -Xml $cfg
            $script:OfficeHandled = $true
            $rc = $(if ($ok) { 0 } else { 1 })
        } elseif ($Plan.Type -eq 'appx') {
            try {
                $deps = @()
                $depDir = Join-Path $f.DirectoryName 'Dependencies'
                if (Test-Path $depDir) { $deps = @(Get-ChildItem $depDir -Recurse -File -Include '*.appx', '*.msix' | Where-Object { $_.FullName -notmatch '(?i)arm|x86' } | ForEach-Object { $_.FullName }) }
                Write-Log "[$($Plan.Id)] Add-AppxProvisionedPackage $($f.Name)"
                if ($deps.Count) { Add-AppxProvisionedPackage -Online -PackagePath $f.FullName -DependencyPackagePath $deps -SkipLicense -ErrorAction Stop | Out-Null }
                else             { Add-AppxProvisionedPackage -Online -PackagePath $f.FullName -SkipLicense -ErrorAction Stop | Out-Null }
                $rc = 0; $script:ProvCache = $null
            } catch { Write-Log "[$($Plan.Id)] $($_.Exception.Message)" ERR; $rc = 1 }
        } else {
            switch ($Plan.Type) {
                'exe' { $exe = $f.FullName; $al = $argText }
                'msi' { $exe = 'msiexec.exe'; $al = ("/i `"{0}`" /qn /norestart /l*v `"{1}`" {2}" -f $f.FullName, $log, $argText).Trim() }
                'msp' { $exe = 'msiexec.exe'; $al = ("/p `"{0}`" /qn /norestart /l*v `"{1}`" {2}" -f $f.FullName, $log, $argText).Trim() }
                'msu' { $exe = Join-Path $env:SystemRoot 'System32\dism.exe'; $al = "/Online /Add-Package /PackagePath:`"$($f.FullName)`" /Quiet /NoRestart /LogPath:`"$log`"" }
                'cab' { $exe = Join-Path $env:SystemRoot 'System32\dism.exe'; $al = "/Online /Add-Package /PackagePath:`"$($f.FullName)`" /Quiet /NoRestart /LogPath:`"$log`"" }
                'ps1' {
                    # B2: -EncodedCommand zamiast -File - Arguments mają składnię PowerShell (apostrofy, tablice 'a','b');
                    # dotychczasowe wpisy w cudzysłowach "..." działają tak samo
                    $exe = 'powershell.exe'
                    $cmdText = ("& '{0}' {1}; exit `$LASTEXITCODE" -f ($f.FullName -replace "'", "''"), $argText)
                    $al = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + (ConvertTo-EncodedCommand $cmdText)
                    $shown = "-Command $cmdText"
                }
                default { Write-Log "[$($Plan.Id)] nieznany typ '$($Plan.Type)'" ERR }
            }
            if (-not $exe) { $failed = $true; break }
            Write-Log "[$($Plan.Id)] $([IO.Path]::GetFileName($exe)) $(if ($shown) { $shown } else { $al })"
            $sp = @{ FilePath = $exe; Wait = $true; PassThru = $true; WorkingDirectory = $f.DirectoryName }
            if ($al) { $sp['ArgumentList'] = $al }
            try { $rc = (Start-Process @sp).ExitCode } catch { Write-Log "[$($Plan.Id)] $($_.Exception.Message)" ERR; $rc = -1 }
        }

        if ($rebootCodes -contains $rc) { $reboot = $true; Write-Log "[$($Plan.Id)] $($f.Name): OK, wymagany restart (kod $rc)" OK }
        elseif ($okCodes -contains $rc) { Write-Log "[$($Plan.Id)] $($f.Name): OK (kod $rc)" OK }
        else {
            Write-Log ("[{0}] {1}: BŁĄD kod {2} (0x{3:X8}), log: {4}" -f $Plan.Id, $f.Name, $rc, [int]$rc, $log) ERR
            $failed = $true
            if ([bool](Get-PV $pkg 'StopOnError' $true)) { break }
        }
    }

    $post = [string](Get-PV $pkg 'PostScript' '')
    if ($post -and -not $failed) { Write-Log "[$($Plan.Id)] PostScript"; & ([scriptblock]::Create($post)) | Out-Null }
    return [pscustomobject]@{ Failed = $failed; Reboot = $reboot }
}

function Invoke-PackagePlatform {
    param([switch]$DryRun)
    $script:PackageRunResult = 'done'
    Write-Log $(if ($DryRun) { 'PAKIETY - plan instalacji (dry-run)' } else { 'PAKIETY - instalacja z manifestu' }) STEP
    $m = Get-PackageManifest
    if (-not $m) { $script:PackageRunResult = 'error'; return }
    Write-Log "Manifest: $(Get-ManifestPath)"

    $vars = @{ InstallDir = $InstallDir }
    $mv = Get-PV $m 'Variables'
    if ($mv) { foreach ($pp in $mv.PSObject.Properties) { $vars[$pp.Name] = [string]$pp.Value } }

    $installed = @(Get-InstalledApps)
    $plans = @(@(foreach ($pkg in @(Get-PV $m 'Packages' @())) { Get-PackagePlan -Pkg $pkg -Installed $installed }) | Sort-Object Order, Id)
    $plans | Select-Object Order, Id, Type, Installed, Package, Action, Reason |
        Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
    Show-UnassignedFiles -ManifestObj $m
    if ($DryRun) { return }

    $todo = @($plans | Where-Object { $_.Action -in 'instaluj', 'aktualizuj' })
    if ($todo.Count -eq 0) { Write-Log 'Brak pakietów do instalacji' OK; return }
    $errors = 0
    foreach ($pl in $todo) {
        Write-Log ("[{0}] {1}: {2} -> {3}" -f $pl.Id, $pl.Name, $pl.Installed, $pl.Package) STEP
        $r = Install-PlannedPackage -Plan $pl -Vars $vars
        $script:HotfixCache = $null
        if ($r.Failed) { $errors++ }
        if ($r.Reboot -and [bool](Get-PV $pl.Pkg 'RebootAfter' $false)) {
            Write-Log "[$($pl.Id)] wymaga restartu przed kolejnymi pakietami" WARN
            $script:PackageRunResult = 'reboot'
            Request-RebootAndResume
            return
        }
    }
    Write-Log "Pakiety: zainstalowano $($todo.Count - $errors), błędy $errors" $(if ($errors) { 'WARN' } else { 'OK' })
}

function Get-RelativePath {
    param([string]$FullName)
    $root = $InstallDir.TrimEnd('\')
    if ($FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $FullName.Substring($root.Length + 1) }
    return $FullName
}

function Get-UnassignedFiles {
    param($ManifestObj)
    $assigned = @{}
    foreach ($pkg in @(Get-PV $ManifestObj 'Packages' @())) {
        foreach ($f in @(Resolve-PackageFiles $pkg)) { $assigned[$f.FullName] = $true }
        $arch = [string](Get-PV $pkg 'Archive' '')
        if ($arch) { foreach ($z in @(Find-PackageFiles -Root $InstallDir -Pattern $arch)) { $assigned[$z.FullName] = $true } }
    }
    foreach ($o in @(Get-ChildItem -Path $InstallDir -Recurse -File -Include '*OS*Optimization*Tool*.exe', '*OSOT*.exe' -ErrorAction SilentlyContinue)) { $assigned[$o.FullName] = $true }
    if ($PSCommandPath) { $assigned[$PSCommandPath] = $true }
    $ignore = @(Get-PV $ManifestObj 'Ignore' @())
    $exts = @('.exe', '.msi', '.msp', '.msu', '.cab', '.msix', '.msixbundle', '.appx', '.appxbundle', '.zip', '.ps1')
    Get-ChildItem -Path $InstallDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $rel = Get-RelativePath $_.FullName
        ($exts -contains $_.Extension.ToLower()) -and -not $assigned.ContainsKey($_.FullName) -and
        $_.FullName -notmatch '\\Office\\Data\\' -and                     # pliki pobrane przez ODT
        -not (@($ignore | Where-Object { $rel -match $_ }).Count)
    }
}

function Show-UnassignedFiles {
    param($ManifestObj)
    $un = @(Get-UnassignedFiles -ManifestObj $ManifestObj)
    if ($un.Count -eq 0) { Write-Log "Wszystkie paczki w $InstallDir mają wpis w manifeście (lub są na liście Ignore)" OK; return }
    Write-Log "Pliki w $InstallDir BEZ wpisu w manifeście (nie będą instalowane) - uruchom -Mode Discover:" WARN
    foreach ($f in $un) { Write-Log ("  {0}  [{1}]" -f (Get-RelativePath $f.FullName), (Get-FileVersionText $f)) }
}

# ---------- DISCOVER: budowa manifestu dla bieżącego środowiska ----------
function Get-NormalizedName {
    param([string]$Name)
    $n = $Name.ToLower()
    $n = $n -replace '\((x64|x86|64-bit|32-bit)[^)]*\)', ' '
    $n = $n -replace '\b(x64|x86|x86_64|amd64|win32|64-bit|32-bit)\b', ' '
    $n = $n -replace '\d+([._-]\d+)+', ' ' -replace '\b\d{4}\b', ' '
    $n = $n -replace '[^a-z0-9+ ]', ' ' -replace '\s+', ' '
    return $n.Trim()
}

function Get-PackageFileInfo {
    param($File)
    $ext = $File.Extension.ToLower()
    $type = switch -Regex ($ext) {
        '^\.(msix|msixbundle|appx|appxbundle)$' { 'appx' }
        '^\.(msi|msp|msu|cab|exe|ps1|zip)$'     { $ext.TrimStart('.') }
        default                                 { '' }
    }
    $name = ''
    if ($ext -eq '.msi') { $name = [string](Get-MsiProperty $File.FullName 'ProductName') }
    elseif ($ext -eq '.exe') { $name = [string]$File.VersionInfo.ProductName }
    if (-not $name) { $name = $File.BaseName }
    $arch = if ($File.Name -match '(?i)x86_64|x64|amd64|64-bit') { 'x64' } elseif ($File.Name -match '(?i)x86|win32|32-bit') { 'x86' } else { '' }
    [pscustomobject]@{ File = $File; Type = $type; Product = $name.Trim(); Norm = (Get-NormalizedName $name); Arch = $arch; Version = (Get-FileVersionText $File) }
}

function New-PackageId {
    param([string]$Name, [hashtable]$Used)
    $base = (Get-Culture).TextInfo.ToTitleCase((Get-NormalizedName $Name)) -replace '[^A-Za-z0-9]', ''
    if (-not $base) { $base = 'Pakiet' }
    if ($base.Length -gt 40) { $base = $base.Substring(0, 40) }
    $id = $base; $i = 2
    while ($Used.ContainsKey($id)) { $id = "$base$i"; $i++ }
    $Used[$id] = $true
    return $id
}

function Invoke-Discover {
    Write-Log 'DISCOVER - manifest dopasowany do bieżącego obrazu i zawartości C:\install' STEP
    $m = Get-PackageManifest
    if (-not $m) { return }
    $packages = New-Object System.Collections.ArrayList
    foreach ($x in @(Get-PV $m 'Packages' @())) { [void]$packages.Add($x) }
    $ignore = New-Object System.Collections.ArrayList
    foreach ($x in @(Get-PV $m 'Ignore' @())) { [void]$ignore.Add($x) }
    $used = @{}; foreach ($x in $packages) { $used[[string](Get-PV $x 'Id' '')] = $true }
    $order = 60
    foreach ($x in $packages) { $o = [int](Get-PV $x 'Order' 0); if ($o -ge $order -and $o -lt 90) { $order = $o + 1 } }

    $installed = @(Get-InstalledApps)
    $infos = @(Get-UnassignedFiles -ManifestObj $m | ForEach-Object { Get-PackageFileInfo $_ })
    if ($infos.Count -eq 0) { Write-Log 'Brak nowych plików do opisania - manifest jest kompletny' OK; return }

    $report = @()
    $patchDirs = @{}
    foreach ($i in $infos) {
        $rel = Get-RelativePath $i.File.FullName
        # 1) wariant x86, gdy obok jest x64 tego samego produktu -> Ignore
        if ($i.Arch -eq 'x86') {
            $twin = @($infos + @() | Where-Object { $_.Arch -eq 'x64' -and $_.Norm -eq $i.Norm -and $_.File.DirectoryName -eq $i.File.DirectoryName })
            $twinAssigned = @(Get-ChildItem -Path $i.File.DirectoryName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $i.File.Name -and $_.Extension -eq $i.File.Extension -and $_.Name -match '(?i)x64|x86_64|amd64' -and (Get-NormalizedName ([string](Get-MsiProperty $_.FullName 'ProductName'))) -eq $i.Norm })
            if ($twin.Count -or $twinAssigned.Count -or ($installed | Where-Object { (Get-NormalizedName $_.Name) -eq $i.Norm -and $_.Arch -eq 'x64' })) {
                [void]$ignore.Add('^' + [regex]::Escape($rel) + '$')
                $report += [pscustomobject]@{ Plik = $rel; Decyzja = 'Ignore'; Id = ''; Powod = 'wariant x86 (obraz x64)' }
                continue
            }
        }
        # 2) poprawki MSU/CAB/MSP poza folderem Patches -> wpis na cały folder
        if ($i.Type -in 'msu', 'cab', 'msp') {
            $dir = Split-Path $rel -Parent
            $key = "$dir|$($i.Type)"
            if ($patchDirs.ContainsKey($key)) { continue }
            $patchDirs[$key] = $true
            $id = New-PackageId ("Patches $dir $($i.Type)") $used
            $pat = $(if ($dir) { "$dir\*.$($i.Type)" } else { "*.$($i.Type)" })
            [void]$packages.Add([pscustomobject]([ordered]@{
                Id = $id; Name = "Poprawki $($i.Type.ToUpper()) z $(if ($dir) { $dir } else { 'katalogu głównego' })"; Enabled = $true; Order = 7
                Type = $i.Type; File = $pat; Recurse = $false; Multiple = $true
                Detect = [pscustomobject]@{ Type = $(if ($i.Type -eq 'msp') { 'Always' } else { 'Hotfix' }) }
                RebootAfter = ($i.Type -ne 'msp')
            }))
            $report += [pscustomobject]@{ Plik = $pat; Decyzja = 'nowy wpis (włączony)'; Id = $id; Powod = 'poprawki wg KB' }
            continue
        }
        if (-not $i.Type -or $i.Type -eq 'zip') {
            $report += [pscustomobject]@{ Plik = $rel; Decyzja = 'pominięty'; Id = ''; Powod = 'archiwum/nieznany typ - opisz ręcznie (pole Archive)' }
            continue
        }
        # 3) dopasowanie do zainstalowanej aplikacji
        $app = $installed | Where-Object {
            $n = Get-NormalizedName $_.Name
            $n -and ($n -eq $i.Norm -or ($n.Length -ge 8 -and $i.Norm.Length -ge 8 -and ($n.Contains($i.Norm) -or $i.Norm.Contains($n))))
        } | Select-Object -First 1
        $id = New-PackageId $i.Product $used
        $leaf = ($i.File.Name -replace '\d+([._-]\d+)+', '*' -replace '\b\d{4}\b', '*') -replace '\*(\s*\*)+', '*'
        $isInfra = $i.Product -match $InfraPattern
        $entry = [ordered]@{ Id = $id; Name = $i.Product; Enabled = $false; Order = $order; Type = $i.Type; File = $leaf }
        if ($i.Arch -eq 'x64') { $entry['PreferPath'] = '(?i)x64|x86_64|amd64' }
        if ($i.Type -eq 'exe') { $entry['Arguments'] = ''; $entry['_uwaga'] = 'uzupełnij parametry cichej instalacji, potem Enabled=true' }
        if ($i.Type -eq 'ps1') { $entry['Detect'] = [pscustomobject]@{ Type = 'Always' } }
        elseif ($i.Type -eq 'appx') { $entry['Detect'] = [pscustomobject]@{ Type = 'Appx'; Name = ($i.File.BaseName -split '_')[0] } }
        elseif ($app) {
            $rx = '^' + ([regex]::Escape($app.Name) -replace '\d+(\\\.\d+)+', '[\d.]+') + '$'
            $entry['Detect'] = [pscustomobject]@{ Type = 'Uninstall'; Name = $rx }
            $entry['RequireInstalled'] = $true
        } else {
            $entry['Detect'] = [pscustomobject]@{ Type = 'Uninstall'; Name = '^' + [regex]::Escape($i.Product) }
            $entry['RequireInstalled'] = $true
        }
        if ($app -and $i.Type -in 'msi', 'appx' -and -not $isInfra) { $entry['Enabled'] = $true }
        if ($isInfra) { $entry['RebootAfter'] = $true }
        $order++
        [void]$packages.Add([pscustomobject]$entry)
        $why = if ($app) { "zainstalowany: $($app.Name) $($app.Version)" } else { 'nie jest zainstalowany na obrazie' }
        if ($isInfra) { $why += ' | komponent VDI - włącz świadomie' }
        $report += [pscustomobject]@{ Plik = $rel; Decyzja = $(if ($entry['Enabled']) { 'nowy wpis (włączony)' } else { 'nowy wpis (wyłączony)' }); Id = $id; Powod = $why }
    }

    Write-Log 'Propozycje' STEP
    $report | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host

    $out = [ordered]@{}
    foreach ($pp in $m.PSObject.Properties) { if ($pp.Name -notin 'Packages', 'Ignore') { $out[$pp.Name] = $pp.Value } }
    $out['Ignore']   = @($ignore)
    $out['Packages'] = @($packages | Sort-Object { [int](Get-PV $_ 'Order' 100) })
    $json = [pscustomobject]$out | ConvertTo-Json -Depth 10
    $target = Get-ManifestPath
    if ($Apply) {
        $bak = "$target.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item -Path $target -Destination $bak -Force
        Set-Content -Path $target -Value $json -Encoding UTF8
        Write-Log "Manifest zaktualizowany: $target (kopia: $bak)" OK
    } else {
        $prop = [IO.Path]::ChangeExtension($target, '.discovered.json')
        Set-Content -Path $prop -Value $json -Encoding UTF8
        Write-Log "Propozycja zapisana: $prop" OK
        Write-Log 'Przejrzyj ją i zastosuj: -Mode Discover -Apply (kopia obecnego manifestu zostanie zachowana)'
    }
}

function Invoke-Init {
    Write-Log "INIT - struktura katalogu $InstallDir" STEP
    $dirs = [ordered]@{
        'Patches' = 'poprawki Windows *.msu / *.cab (wg KB) oraz poprawki aplikacji *.msp'
        'Office'  = 'Office Deployment Tool: setup.exe + Configure.xml (pobrane pliki trafią do Office\Data)'
        'FSLogix' = 'FSLogix_*.zip z oficjalnej paczki Microsoft'
        'Horizon' = 'VMware Tools, Horizon Agent, DEM, App Volumes Agent (wpisy w manifeście Enabled=false)'
        'OSOT'    = 'Omnissa OS Optimization Tool (*.exe) + osot-selections.json (Export Selections z GUI)'
        'Apps'    = 'własne aplikacje MSI/EXE/MSIX'
        'Scripts' = 'skrypty konfiguracyjne PS1'
    }
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    foreach ($d in $dirs.Keys) {
        $p = Join-Path $InstallDir $d
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null; Write-Log "Utworzono $p" OK }
        else { Write-Log "Istnieje  $p" }
    }
    [void](Get-PackageManifest)
    $lines = @("Struktura $InstallDir (VDI-ImageMaint)", '', 'VDI-ImageMaint.ps1   skrypt', 'packages.json        manifest pakietów + konfiguracja OSOT (sekcja "Osot")', '')
    foreach ($d in $dirs.Keys) { $lines += ('{0,-20} {1}' -f ($d + '\'), $dirs[$d]) }
    $lines += @('', 'Pliki mogą leżeć w dowolnym podfolderze - wyszukiwanie jest rekurencyjne.',
        'Pliki bez wpisu w manifeście pokazuje: .\VDI-ImageMaint.ps1 -Mode PackageList')
    Set-Content -Path (Join-Path $InstallDir 'README-struktura.txt') -Value $lines -Encoding UTF8
    Write-Log "Opis struktury: $(Join-Path $InstallDir 'README-struktura.txt')" OK
    Write-Log 'Istniejących plików nie przenoszę - mogą zostać w obecnych miejscach.'
}

# ---------- restart i wznowienie ----------
function ConvertTo-ArgumentText {
    # Parametry w składni PowerShell (dla -Command / -EncodedCommand, NIE dla -File - tam apostrofy zostają w wartości)
    param($Params, [string[]]$Exclude = @())
    $parts = @()
    foreach ($k in @($Params.Keys)) {
        if ($Exclude -contains $k) { continue }
        $v = $Params[$k]
        if ($v -is [securestring]) { continue }   # hasła nigdy nie trafiają do wiersza poleceń
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $parts += "-$k" }; continue }
        $vals = @(@($v) | ForEach-Object { "'" + ([string]$_ -replace "'", "''") + "'" })
        $parts += ("-$k " + ($vals -join ','))
    }
    return ($parts -join ' ')
}

function ConvertTo-EncodedCommand {
    param([string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))
}

function Get-ResumeCommand {
    $a = ConvertTo-ArgumentText -Params $script:BoundParams -Exclude @('ResumeRound')
    return ("& '{0}' {1} -ResumeRound {2}" -f ($PSCommandPath -replace "'", "''"), $a, ($ResumeRound + 1))
}

function Request-RebootAndResume {
    if (-not $AutoReboot) {
        Write-Log 'Zrestartuj VM i uruchom ponownie to samo polecenie - zainstalowane elementy zostaną pominięte (lub użyj -AutoReboot).' WARN
        return
    }
    if ($ResumeRound -ge $MaxRounds) { Write-Log "Osiągnięto limit $MaxRounds restartów (-MaxRounds) - przerwij i sprawdź logi" ERR; return }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $cmd  = Get-ResumeCommand
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand ' + (ConvertTo-EncodedCommand $cmd))
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Log "Wznowienie po zalogowaniu $user (runda $($ResumeRound + 1)/$MaxRounds): $cmd"
    Write-Log 'Restart za 20 s (Ctrl+C aby przerwać)...' WARN
    try { Stop-Transcript | Out-Null } catch { }
    Start-Sleep -Seconds 20
    Restart-Computer -Force
    exit 0
}

function Update-Defender {
    Write-Log 'Microsoft Defender - sygnatury' STEP
    try { Update-MpSignature -ErrorAction Stop; Write-Log 'Sygnatury zaktualizowane' OK }
    catch { Write-Log "Defender pominięty ($($_.Exception.Message))" }
}

function Test-OdtConfig {
    param([string]$Path)
    try { [xml]$x = Get-Content -Path $Path -Raw } catch { Write-Log "Configure.xml: błąd XML ($($_.Exception.Message))" ERR; return $false }
    $add = $x.SelectSingleNode('/Configuration/Add')
    if (-not $add) { Write-Log 'Configure.xml: brak elementu <Add>' ERR; return $false }
    $ver = $add.GetAttribute('Version')
    Write-Log ("Configure.xml: kanał={0}, SourcePath={1}, wersja={2}" -f $add.GetAttribute('Channel'), $add.GetAttribute('SourcePath'), $(if ($ver) { $ver } else { 'najnowsza w kanale' }))
    $upd = $x.SelectSingleNode('/Configuration/Updates')
    if ($upd -and $upd.GetAttribute('Enabled') -match '^true$') { Write-Log 'Configure.xml: <Updates Enabled="TRUE"> - na VDI zalecane FALSE' WARN }
    $scl = $x.SelectSingleNode("/Configuration/Property[@Name='SharedComputerLicensing']")
    if (-not $scl -or $scl.GetAttribute('Value') -ne '1') { Write-Log 'Configure.xml: brak SharedComputerLicensing=1 (wymagane na współdzielonym VDI)' WARN }
    $fas = $x.SelectSingleNode("/Configuration/Property[@Name='FORCEAPPSHUTDOWN']")
    if (-not $fas -or $fas.GetAttribute('Value') -notmatch '^true$') { Write-Log 'Configure.xml: brak FORCEAPPSHUTDOWN=TRUE - otwarte aplikacje Office mogą zablokować aktualizację' WARN }
    $disp = $x.SelectSingleNode('/Configuration/Display')
    if (-not $disp -or $disp.GetAttribute('Level') -ne 'None') { Write-Log 'Configure.xml: <Display Level="None"> zalecane dla instalacji bez okien' WARN }
    return $true
}

function Update-OfficeOdt {
    param([string]$Odt, [string]$Xml)
    $cfg = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $before = Get-RegValue $cfg 'VersionToReport'
    Write-Log "Office Deployment Tool: $Odt (wersja przed: $before)"
    if (-not (Test-OdtConfig $Xml)) { return $false }

    Write-Log 'ODT /download (pobieranie plików instalacyjnych)...'
    $p = Start-Process -FilePath $Odt -ArgumentList "/download `"$Xml`"" -WorkingDirectory (Split-Path $Odt) -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Log "ODT /download: kod $($p.ExitCode) (logi: %TEMP%\*.log)" ERR; return $false }
    Write-Log 'ODT /download zakończony' OK

    Write-Log 'ODT /configure (instalacja/aktualizacja)...'
    $p = Start-Process -FilePath $Odt -ArgumentList "/configure `"$Xml`"" -WorkingDirectory (Split-Path $Odt) -Wait -PassThru
    $after = Get-RegValue $cfg 'VersionToReport'
    if ($p.ExitCode -ne 0) { Write-Log "ODT /configure: kod $($p.ExitCode) (logi: %TEMP%\*.log)" ERR; return $false }
    if ($after -ne $before) { Write-Log "Microsoft 365: $before -> $after" OK }
    else { Write-Log "Microsoft 365: wersja bez zmian ($after) - aktualna dla kanału z Configure.xml" OK }
    return $true
}

function Update-Office {
    if ($script:OfficeHandled) { return }   # zaktualizowane przez pakiet ODT z manifestu
    Write-Log 'Microsoft 365 Apps (klient C2R - brak aktywnego pakietu ODT w manifeście)' STEP
    $c2r = Join-Path $env:CommonProgramFiles 'microsoft shared\ClickToRun\OfficeC2RClient.exe'
    if (-not (Test-Path $c2r)) { Write-Log 'Nie znaleziono Microsoft 365 C2R - pomijam'; return }
    $cfg = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $before = Get-RegValue $cfg 'VersionToReport'
    Write-Log "Wersja przed: $before (kanał: $(Get-RegValue $cfg 'CDNBaseUrl'))"
    Start-Process -FilePath $c2r -ArgumentList '/update user updatepromptuser=false forceappshutdown=true displaylevel=false' -Wait
    $deadline = (Get-Date).AddMinutes($OfficeWaitMinutes)
    do {
        Start-Sleep -Seconds 15
        $running = [bool](Get-Process -Name OfficeC2RClient -ErrorAction SilentlyContinue)
        $now = Get-RegValue $cfg 'VersionToReport'
    } while (($running -or $now -eq $before) -and (Get-Date) -lt $deadline)
    if ($now -ne $before) { Write-Log "Microsoft 365: $before -> $now" OK }
    else { Write-Log "Microsoft 365: bez zmiany wersji po $OfficeWaitMinutes min (aktualna lub aktualizacja w tle - sprawdź Status przed Seal)" WARN }
}

function Update-VisualStudio {
    Write-Log 'Visual Studio' STEP
    $inst    = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $vswhere = Join-Path $inst 'vswhere.exe'
    $setup   = Join-Path $inst 'setup.exe'
    if (-not ((Test-Path $vswhere) -and (Test-Path $setup))) { Write-Log 'Visual Studio Installer nie znaleziony - pomijam'; return }
    foreach ($p in @(& $vswhere -all -prerelease -property installationPath)) {
        if (-not $p) { continue }
        Write-Log "Aktualizacja: $p"
        $proc = Start-Process -FilePath $setup -ArgumentList @('update', '--installPath', "`"$p`"", '--quiet', '--norestart') -Wait -PassThru
        switch ($proc.ExitCode) {
            0       { Write-Log 'Visual Studio zaktualizowane' OK }
            3010    { Write-Log 'Visual Studio zaktualizowane - wymagany restart' WARN }
            default { Write-Log "Visual Studio: kod wyjścia $($proc.ExitCode) (logi: %TEMP%\dd_*.log)" WARN }
        }
    }
}

function Update-Edge {
    Write-Log 'Microsoft Edge' STEP
    $eu = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe'
    if (-not (Test-Path $eu)) { Write-Log 'EdgeUpdate nie znaleziony - pomijam'; return }
    Start-Process -FilePath $eu -ArgumentList '/ua /installsource scheduler' -Wait
    Write-Log 'Wywołano EdgeUpdate' OK
}

function Update-Teams {
    Write-Log 'Microsoft Teams (nowy, MSIX) - aktualizacja wersji zaprowizjonowanej' STEP
    $prov = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MSTeams' }) | Select-Object -First 1
    if (-not $prov) { Write-Log 'Nowy Teams nie jest zaprowizjonowany w obrazie - pomijam'; return }
    Write-Log "Wersja zaprowizjonowana przed: $($prov.Version)"

    $bs = $TeamsBootstrapperPath
    if (-not $bs) {
        # obok skryptu albo w C:\install (np. Teams\)
        $local = Join-Path (Split-Path $PSCommandPath) 'teamsbootstrapper.exe'
        if (Test-Path $local) { $bs = $local }
        elseif (Test-Path $InstallDir) {
            $hit = Get-ChildItem -Path $InstallDir -Recurse -File -Filter 'teamsbootstrapper.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $bs = $hit.FullName }
        }
    }
    if (-not $bs -or -not (Test-Path $bs)) {
        $bs = Join-Path $env:TEMP 'teamsbootstrapper.exe'
        Write-Log 'Pobieranie teamsbootstrapper.exe...'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409' -OutFile $bs -UseBasicParsing
        } catch { Write-Log "Nie udało się pobrać teamsbootstrapper: $($_.Exception.Message) (podaj -TeamsBootstrapperPath)" WARN; return }
    }
    # S2: uruchamiamy tylko plik z ważnym podpisem Microsoft
    $sig = Get-AuthenticodeSignature -FilePath $bs
    if ($sig.Status -ne 'Valid' -or [string]$sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        Write-Log "teamsbootstrapper: nieprawidłowy podpis ($($sig.Status)) - nie uruchamiam $bs" ERR
        return
    }

    $ErrorActionPreference = 'Continue'
    $out = & $bs -p 2>&1 | Out-String
    $rc  = $LASTEXITCODE
    Write-Log ("teamsbootstrapper -p: kod {0} {1}" -f $rc, ($out -replace '\s+', ' ').Trim())

    $after = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MSTeams' }) | Select-Object -First 1
    if ($after -and $after.Version -ne $prov.Version) { Write-Log "Teams: $($prov.Version) -> $($after.Version)" OK }
    elseif ($rc -eq 0) { Write-Log 'Teams: wersja zaprowizjonowana bez zmian (aktualna)' }
    else { Write-Log 'Teams: aktualizacja nieudana - sprawdź wynik powyżej' WARN }
}

function Update-WingetPackage {
    param([string]$Id, [string]$Label)
    $a = @('upgrade', '--id', $Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($WingetIncludeUnknown) { $a += '--include-unknown' }
    $out = Invoke-Winget -Arguments $a
    $rc = $script:WingetExit
    switch ($rc) {
        0           { Write-Log "${Label}: zaktualizowano" OK }
        -1978335189 { Write-Log "${Label}: wersja aktualna" }
        -1978335212 { Write-Log "${Label}: nie jest zainstalowany - pomijam" }
        default {
            Write-Log ("{0}: kod {1} (0x{2:X8})" -f $Label, $rc, $rc) WARN
            $out | Where-Object { "$_".Trim() } | Select-Object -Last 4 | ForEach-Object { Write-Log "    $_" }
        }
    }
    return $rc
}

function Update-WingetApps {
    Write-Log $(if ($WingetAll) { 'Aplikacje przez winget (wszystkie wykryte, z wykluczeniami)' } else { 'Aplikacje przez winget (lista -WingetIds)' }) STEP
    if (-not (Initialize-Winget)) { return }

    if (-not $WingetAll) {
        foreach ($id in $WingetIds) {
            if ($WingetExcludeIds -contains $id -or $WingetStoreIds -contains $id) { Write-Log "${id}: pominięty (WingetExcludeIds)"; continue }
            [void](Update-WingetPackage -Id $id -Label $id)
        }
        return
    }

    $pkgs = @(Get-WingetUpgrades)
    if ($pkgs.Count -eq 0) { Write-Log 'Brak dostępnych aktualizacji winget' OK; return }

    foreach ($p in @($pkgs | Where-Object { $_.Action -ne 'aktualizuj' })) {
        Write-Log ("Pominięto: {0} [{1}] - {2}" -f $p.Name, $p.Id, $p.Reason) WARN
    }
    $todo = @($pkgs | Where-Object { $_.Action -eq 'aktualizuj' })
    $ok = 0; $fail = 0
    foreach ($p in $todo) {
        Write-Log ("{0} [{1}] {2} -> {3}" -f $p.Name, $p.Id, $p.Version, $p.Available)
        $rc = Update-WingetPackage -Id $p.Id -Label $p.Id
        if ($rc -eq 0) { $ok++ } elseif ($rc -ne -1978335189) { $fail++ }
    }
    Write-Log "winget: zaktualizowano $ok, błędy $fail, pominięte $($pkgs.Count - $todo.Count)" $(if ($fail) { 'WARN' } else { 'OK' })

    # Kontrola: czy coś zostało (np. pakiet wymagał zamknięcia aplikacji)
    $left = @(Get-WingetUpgrades | Where-Object { $_.Action -eq 'aktualizuj' })
    if ($left.Count) { Write-Log "Nadal do aktualizacji: $(($left | ForEach-Object { $_.Id }) -join ', ')" WARN }
}

function Update-Windows {
    Write-Log 'Windows Update (wyszukiwanie może potrwać kilka minut)' STEP
    $wu = 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv'
    if ((Get-RegValue $wu 'Start') -eq 4) {
        Write-Log 'wuauserv nadal wyłączona (np. przez OSOT) - ustawiam Manual na czas aktualizacji' WARN
        try { Set-ItemProperty -Path $wu -Name Start -Value 3 -ErrorAction Stop } catch { Write-Log 'Nie można zmienić wuauserv' ERR; return }
    }
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'VDI-ImageMaint'
        $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    } catch { Write-Log "Windows Update: błąd wyszukiwania ($($_.Exception.Message))" ERR; return }

    if ($result.Updates.Count -eq 0) { Write-Log 'Brak nowych aktualizacji Windows' OK; return }

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $result.Updates) {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$coll.Add($u)
        Write-Log "  + $($u.Title)"
    }
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
    Write-Log 'Pobieranie...';  [void]$dl.Download()
    $ins = $session.CreateUpdateInstaller(); $ins.Updates = $coll
    Write-Log 'Instalacja...';  $r = $ins.Install()

    $codes = @{ 0 = 'NotStarted'; 1 = 'InProgress'; 2 = 'Succeeded'; 3 = 'SucceededWithErrors'; 4 = 'Failed'; 5 = 'Aborted' }
    for ($i = 0; $i -lt $coll.Count; $i++) {
        $ur = $r.GetUpdateResult($i)
        if ($ur.ResultCode -ne 2) { Write-Log ("  ! {0}: {1} (HResult 0x{2:X8})" -f $coll.Item($i).Title, $codes[[int]$ur.ResultCode], $ur.HResult) WARN }
    }
    Write-Log ("Windows Update: {0}, restart wymagany: {1}" -f $codes[[int]$r.ResultCode], $r.RebootRequired) $(if ($r.ResultCode -in 2, 3) { 'OK' } else { 'WARN' })
}

function Invoke-Update {
    $issues = Invoke-Unlock
    if ($issues -gt 0 -and -not $isSystem) {
        # B7: chronione usługi/zadania (WaaSMedicSvc, UsoSvc, UpdateOrchestrator) - Unlock ponownie jako SYSTEM
        Write-Log 'Część blokad jest chroniona - ponawiam Unlock w kontekście SYSTEM' WARN
        $rc = Invoke-AsSystem -TargetMode 'Unlock'
        if ($rc -ne 0) { Write-Log "Unlock jako SYSTEM: kod $rc - Windows Update może nie działać, sprawdź Status" WARN }
    }
    if (-not $SkipOsot) { Invoke-OsotEnableUpdates }
    $before = @(Get-InstalledApps)

    Write-Log 'Komponenty VDI (aktualizowane wyłącznie przez włączone pakiety manifestu)' STEP
    $before | Where-Object { $_.Name -match $InfraPattern } | Sort-Object Name |
        ForEach-Object { Write-Log ("{0,-55} {1}" -f $_.Name, $_.Version) }

    if (-not $SkipPackages) {
        Invoke-PackagePlatform
        if ($script:PackageRunResult -eq 'reboot') { return }
    }
    Update-Defender
    if (-not $SkipOffice)        { Update-Office }
    if (-not $SkipVisualStudio)  { Update-VisualStudio }
    if (-not $SkipEdge)          { Update-Edge }
    if (-not $SkipTeams)         { Update-Teams }
    if (-not $SkipWinget)        { Update-WingetApps }
    if (-not $SkipWindowsUpdate) { Update-Windows }

    Show-AppDiff -Before $before -After @(Get-InstalledApps)

    $pending = @(Test-PendingReboot)
    $hard = @($pending | Where-Object { $_ -ne 'PendingFileRename' })
    if ($hard.Count -gt 0 -and $AutoReboot) {
        Write-Log "Wymagany restart ($($hard -join ', ')) - kolejna runda Update po restarcie" WARN
        Request-RebootAndResume
    } elseif ($pending.Count -gt 0) {
        Write-Log "Wymagany restart ($($pending -join ', ')). Po restarcie uruchom ponownie -Mode Update, aż nie będzie nowych aktualizacji." WARN
    } else {
        Write-Log 'Brak oczekującego restartu. Następny krok: -Mode Seal [-Cleanup] -AsSystem -Shutdown' OK
    }
}

# =====================================================================
#  INVENTORY
# =====================================================================
function New-Status {
    param([object[]]$Checks, [string]$How)
    if (@($Checks | Where-Object { -not $_ }).Count -eq 0) { [pscustomobject]@{ Status = 'Zablokowana'; Detail = $How } }
    else { [pscustomobject]@{ Status = 'AKTYWNA'; Detail = "niepełna blokada: $How" } }
}
function New-NoUpdater { param([string]$How) [pscustomobject]@{ Status = 'Brak mechanizmu'; Detail = $How } }
function Test-Policy { param([string]$Path, [string]$Name, $Value) return ((Get-RegValue $Path $Name) -eq $Value) }
function Test-SvcDisabled {
    param([string]$Pattern)
    foreach ($n in @($script:SvcNames | Where-Object { $_ -like $Pattern })) {
        if ((Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$n" 'Start') -ne 4) { return $false }
    }
    return $true
}
function Test-TasksDisabled {
    param([string]$Pattern)
    return (@($script:TaskCache | Where-Object { ($_.TaskPath + $_.TaskName) -like $Pattern -and $_.State -ne 'Disabled' }).Count -eq 0)
}

function Get-AppUpdateStatus {
    param($App, $Detected)
    foreach ($c in $UpdaterCatalog) { if ($App.Name -match $c.Match) { return (& $c.Check) } }
    $loc = ([string]$App.InstallLocation).TrimEnd('\')
    if ($loc.Length -gt 3) {
        $hit = @($Detected | Where-Object { ([string]$_.Detail).IndexOf($loc, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($hit.Count) { return [pscustomobject]@{ Status = 'AKTYWNA'; Detail = 'wykryto: ' + (($hit | ForEach-Object { $_.Name }) -join ', ') } }
    }
    return [pscustomobject]@{ Status = 'Nie wykryto'; Detail = '' }
}

function Export-WingetPackages {
    param([string]$Dir)
    if (-not (Initialize-Winget)) { return }
    $f = Join-Path $Dir 'winget-export.json'
    [void](Invoke-Winget -Arguments @('export', '-o', $f, '--include-versions', '--accept-source-agreements', '--disable-interactivity'))
    if (Test-Path $f) { Write-Log "winget export: $f" OK } else { Write-Log "winget export nieudany (kod $($script:WingetExit))" WARN }
}

function Invoke-Inventory {
    Write-Log 'INVENTORY - zrzut pakietów i stanu blokady autoaktualizacji' STEP
    $dir = Join-Path $BaseDir ('Inventory\{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $script:TaskCache = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    $script:SvcNames  = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
    $detected = @(Find-UnmanagedUpdaters)

    $rows = @()
    foreach ($su in $SystemUpdaters) {
        $st = & $su.Check
        $rows += [pscustomobject]@{ Nazwa = $su.Name; Wersja = ''; Wydawca = 'Microsoft'; Typ = 'System'; Autoaktualizacja = $st.Status; Szczegoly = $st.Detail; Lokalizacja = '' }
    }
    foreach ($a in @(Get-InstalledApps | Sort-Object Name, Arch -Unique)) {
        $st = Get-AppUpdateStatus -App $a -Detected $detected
        $rows += [pscustomobject]@{ Nazwa = $a.Name; Wersja = $a.Version; Wydawca = $a.Publisher; Typ = "Win32 $($a.Arch)"; Autoaktualizacja = $st.Status; Szczegoly = $st.Detail; Lokalizacja = $a.InstallLocation }
    }
    $storeBlocked = Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2
    foreach ($px in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Sort-Object DisplayName)) {
        $ok = $storeBlocked
        $how = 'Store AutoDownload=2'
        if ($px.DisplayName -eq 'MSTeams') { $ok = $ok -and (Test-Policy 'HKLM:\SOFTWARE\Microsoft\Teams' 'disableAutoUpdate' 1); $how += ' + Teams disableAutoUpdate=1' }
        $rows += [pscustomobject]@{
            Nazwa = $px.DisplayName; Wersja = [string]$px.Version; Wydawca = ''; Typ = 'MSIX provisioned'
            Autoaktualizacja = $(if ($ok) { 'Zablokowana' } else { 'AKTYWNA' }); Szczegoly = $how; Lokalizacja = ''
        }
    }

    $csv = Join-Path $dir 'pakiety.csv'
    $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    $detected | Select-Object Type, Name, Detail | Export-Csv -Path (Join-Path $dir 'wykryte-aktualizatory.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    if (-not $isSystem) { Export-WingetPackages -Dir $dir }
    else { Write-Log 'winget export zostanie wykonany z konta administratora po zakończeniu zadania SYSTEM' }

    Write-Log 'Podsumowanie' STEP
    $rows | Group-Object Autoaktualizacja | Sort-Object Name | ForEach-Object { Write-Log ("{0,-16} {1}" -f $_.Name, $_.Count) }
    $act = @($rows | Where-Object { $_.Autoaktualizacja -eq 'AKTYWNA' })
    if ($act.Count) {
        Write-Log 'Pakiety z AKTYWNĄ autoaktualizacją:' WARN
        $act | Format-Table Nazwa, Wersja, Typ, Szczegoly -AutoSize | Out-String -Width 250 | Write-Host
    } else {
        Write-Log 'Wszystkie wykryte mechanizmy autoaktualizacji są zablokowane' OK
    }
    Write-Log "Raport: $csv" OK
}

# =====================================================================
#  STATUS
# =====================================================================
function Show-Status {
    Write-Log 'STATUS mechanizmów aktualizacji' STEP
    $startNames = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
    $rows = foreach ($s in @(Resolve-ServiceDefs)) {
        $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
        if (-not (Test-Path $reg)) { continue }
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        [pscustomobject]@{
            'Usługa' = $s.Name
            'Start'  = $startNames[[int](Get-RegValue $reg 'Start')]
            'Stan'   = $(if ($svc) { $svc.Status } else { '?' })
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    $rows = foreach ($p in $PolicyDefs) {
        $cur = Get-RegValue $p.Path $p.Name
        [pscustomobject]@{
            'Polityka' = $p.Name
            'Seal'     = $p.Value
            'Aktualna' = $(if ($null -eq $cur) { '<brak>' } else { $cur })
            'OK'       = $(if ($cur -eq $p.Value) { 'tak' } else { '-' })
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    $tasks  = @(Get-MatchingTasks)
    $active = @($tasks | Where-Object { $_.State -ne 'Disabled' })
    Write-Log ("Zadania aktualizacji: {0}, aktywne: {1}" -f $tasks.Count, $active.Count) $(if ($active.Count) { 'WARN' } else { 'OK' })
    foreach ($t in $active) { Write-Log "  aktywne: $($t.TaskPath)$($t.TaskName)" }

    foreach ($f in $FileDefs) {
        if (Test-Path $f)            { Write-Log "Aktualizator aktywny: $f" WARN }
        elseif (Test-Path "$f.disabled") { Write-Log "Aktualizator wyłączony: $f" OK }
    }

    $m365 = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'VersionToReport'
    if ($m365) { Write-Log "Microsoft 365 wersja: $m365" }

    $pending = @(Test-PendingReboot)
    if ($pending.Count) { Write-Log "Oczekujący restart: $($pending -join ', ')" WARN } else { Write-Log 'Brak oczekującego restartu' OK }

    $st = Get-SealState
    if ($st -and $st.Sealed) { Write-Log "Obraz ZAPIECZĘTOWANY (od $($st.Created))" OK }
    elseif ($st) { Write-Log "Zapisany tylko stan bazowy ($($st.Created)) - Seal niedokończony" WARN }
    else { Write-Log 'Obraz NIE jest zapieczętowany (brak zapisu stanu)' WARN }
}

# =====================================================================
#  GENERALIZE (budowa obrazu) - Sysprep i automatyczna kontynuacja po OOBE
# =====================================================================
# Kolejność Omnissa: Optimize -> Generalize -> agenty Horizon/DEM/App Volumes -> Finalize.
# Generalize wykonujemy RAZ na wydanie Windows (tryb audytu). Cykl Day-2 (Update/Seal) go nie powtarza.
# Kontynuacja: unattend.xml (AutoLogon + FirstLogonCommands) uruchamia -Mode PostGeneralize po OOBE;
# kolejne restarty (agenty) obsługuje zwykłe wznowienie AtLogOn (-AutoReboot).
$BuildDir       = Join-Path $BaseDir 'Build'
$UnattendPath   = Join-Path $BuildDir 'unattend.xml'
$BuildStateFile = Join-Path $BaseDir 'build-state.json'
$WinlogonKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Get-BuildConfig {
    # Sekcja "Build" manifestu (opcjonalna). Domyślne ustawienia regionalne = bieżące ustawienia systemu,
    # bo UILanguage MUSI być zainstalowanym językiem (inaczej OOBE się nie powiedzie).
    $m = $null
    $mp = Get-ManifestPath
    if (Test-Path $mp) { try { $m = Get-Content -Path $mp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $b = Get-PV $m 'Build'
    $culture = (Get-Culture).Name
    # pusty string w manifeście = wartość domyślna
    $str = { param($Name, $Default) $v = [string](Get-PV $b $Name ''); if ($v.Trim()) { $v.Trim() } else { $Default } }
    [ordered]@{
        TimeZone                 = & $str 'TimeZone' (Get-TimeZone).Id
        InputLocale              = & $str 'InputLocale' $culture
        SystemLocale             = & $str 'SystemLocale' (Get-WinSystemLocale).Name
        UILanguage               = & $str 'UILanguage' ([Globalization.CultureInfo]::InstalledUICulture.Name)
        UserLocale               = & $str 'UserLocale' $culture
        ComputerName             = & $str 'ComputerName' $env:COMPUTERNAME
        SkipRearm                = [bool](Get-PV $b 'SkipRearm' $false)
        PersistAllDeviceInstalls = [bool](Get-PV $b 'PersistAllDeviceInstalls' $true)
        SysprepVmMode            = [bool](Get-PV $b 'SysprepVmMode' $false)
        KeepBitLocker            = [bool](Get-PV $b 'KeepBitLocker' $false)
        AutoLogonCount           = [int](Get-PV $b 'AutoLogonCount' 10)
        PostGeneralizePackages   = @(Get-PV $b 'PostGeneralizePackages' @('VMwareTools', 'HorizonAgent', 'DEM', 'AppVolumesAgent'))
        RemoveUserAppx           = @(Get-PV $b 'RemoveUserAppx' @('Microsoft.Copilot', 'Microsoft.BingSearch'))
        AppxSettleSeconds        = [int](Get-PV $b 'AppxSettleSeconds' 120)
    }
}

function Set-BuildStage {
    param([string]$Stage)
    [pscustomobject]@{ Stage = $Stage; Updated = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME } |
        ConvertTo-Json | Set-Content -Path $BuildStateFile -Encoding UTF8
    Write-Log "Etap budowy: $Stage"
}

function Get-BuildStage {
    if (-not (Test-Path $BuildStateFile)) { return '' }
    try { return [string](Get-PV (Get-Content -Path $BuildStateFile -Raw | ConvertFrom-Json) 'Stage' '') } catch { return '' }
}

function Test-AuditMode {
    $state = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' 'ImageState')
    return ((Test-Path 'HKLM:\SYSTEM\Setup\Status\AuditBoot') -or $state -match 'RESEAL_TO_AUDIT|UNDEPLOYABLE')
}

function Get-BuiltinAdminName {
    # Nazwa konta RID 500 (bywa zmieniona lub zlokalizowana)
    $u = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
    if ($u) { return $u.Name } else { return 'Administrator' }
}

function Get-UnprovisionedAppx {
    # Pakiety zainstalowane dla konta, ale niezaprowizjonowane - główna przyczyna błędu Sysprep 0x80073cf2
    $prov = @{}
    foreach ($p in @(Get-AppxProvisionedPackage -Online)) { $prov[[string]$p.DisplayName] = $true }
    foreach ($a in @(Get-AppxPackage -AllUsers)) {
        if ((Get-PV $a 'IsFramework' $false) -or (Get-PV $a 'IsResourcePackage' $false) -or (Get-PV $a 'NonRemovable' $false)) { continue }
        if ([string](Get-PV $a 'SignatureKind' '') -eq 'System') { continue }
        if ($prov.ContainsKey([string]$a.Name)) { continue }
        $inst = @(@(Get-PV $a 'PackageUserInformation' @()) | Where-Object { [string]$_.InstallState -eq 'Installed' })
        if ($inst.Count) { $a }
    }
}

function Remove-UserAppx {
    param([string[]]$Names)
    foreach ($n in $Names) {
        foreach ($a in @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue)) {
            try { Remove-AppxPackage -Package $a.PackageFullName -AllUsers -ErrorAction Stop; Write-Log "AppX usunięty: $($a.PackageFullName)" OK }
            catch { Write-Log "AppX $($a.PackageFullName): $($_.Exception.Message)" WARN }
        }
    }
}

function Wait-VolumeDecrypted {
    # Szyfrowanie urządzenia (Win11 24H2/25H2 z vTPM) blokuje Sysprep przy wyjściu z trybu audytu
    param([int]$TimeoutMinutes = 180)
    $vol = $null
    try {
        $vol = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$($env:SystemDrive)'" -ErrorAction Stop
    } catch { return $true }   # brak BitLockera w systemie
    if (-not $vol) { return $true }
    $cs = Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus
    if ([int]$cs.ConversionStatus -eq 0) { return $true }
    Write-Log "Dysk $($env:SystemDrive) zaszyfrowany (status $($cs.ConversionStatus), $($cs.EncryptionPercentage)%) - odszyfrowuję (manage-bde -off)" WARN
    & manage-bde.exe -off $env:SystemDrive | Out-Null
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 30
        $cs = Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus
        Write-Log "  odszyfrowywanie: status $($cs.ConversionStatus), pozostało $($cs.EncryptionPercentage)%"
    } while ([int]$cs.ConversionStatus -ne 0 -and (Get-Date) -lt $deadline)
    return ([int]$cs.ConversionStatus -eq 0)
}

function Invoke-SysprepRemediation {
    param($Cfg)
    Write-Log 'Naprawa znanych blokerów Sysprep' STEP
    # Aktualizacje Store dla konta = pakiety nowsze niż zaprowizjonowane (0x80073cf2)
    $store = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    if ((Get-RegValue $store 'AutoDownload') -ne 2) {
        if (-not (Test-Path $store)) { New-Item -Path $store -Force | Out-Null }
        New-ItemProperty -Path $store -Name AutoDownload -Value 2 -PropertyType DWord -Force | Out-Null
        Write-Log 'Store AutoDownload=2' OK
    }
    if (-not $Cfg.KeepBitLocker) {
        $bl = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
        if (-not (Test-Path $bl)) { New-Item -Path $bl -Force | Out-Null }
        New-ItemProperty -Path $bl -Name PreventDeviceEncryption -Value 1 -PropertyType DWord -Force | Out-Null
        if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\BDESVC') {
            try { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\BDESVC' -Name Start -Value 4 -ErrorAction Stop } catch { Write-Log "BDESVC: $($_.Exception.Message)" WARN }
        }
        Write-Log 'PreventDeviceEncryption=1, BDESVC wyłączona' OK
        if (-not (Wait-VolumeDecrypted)) { throw "Dysk $($env:SystemDrive) nadal zaszyfrowany - Sysprep się nie powiedzie" }
    }
    Remove-UserAppx -Names $Cfg.RemoveUserAppx
    $left = @(Get-UnprovisionedAppx)
    foreach ($a in $left) {
        if ($a.Name -eq 'MSTeams') {
            Write-Log 'MSTeams zainstalowany tylko dla konta - zaprowizjonuj: teamsbootstrapper.exe -p (nie usuwam)' WARN
        } elseif ($RemoveUnprovisionedAppx) {
            Remove-UserAppx -Names @($a.Name)
        } else {
            Write-Log "AppX tylko dla konta: $($a.PackageFullName) (usuń lub użyj -RemoveUnprovisionedAppx)" WARN
        }
    }
}

function Invoke-ReadinessCheck {
    # tools\Test-SysprepReadiness.ps1 (obok skryptu, w C:\install lub w ..\tools repozytorium)
    $cands = @(
        (Join-Path (Split-Path $PSCommandPath) 'Test-SysprepReadiness.ps1'),
        (Join-Path (Split-Path (Split-Path $PSCommandPath)) 'tools\Test-SysprepReadiness.ps1')
    )
    $checker = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $checker -and (Test-Path $InstallDir)) {
        $hit = Get-ChildItem -Path $InstallDir -Recurse -File -Filter 'Test-SysprepReadiness.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $checker = $hit.FullName }
    }
    if (-not $checker) {
        if ($Force) { Write-Log 'Brak Test-SysprepReadiness.ps1 - kontynuuję bez kontroli (-Force)' WARN; return }
        throw 'Brak Test-SysprepReadiness.ps1 (skopiuj go do C:\install\Scripts). -Force pomija kontrolę.'
    }
    Write-Log "Kontrola gotowości: $checker" STEP
    $json = Join-Path $LogDir ('SysprepReadiness_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow -ArgumentList (
        '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallDir "{1}" -OutFile "{2}"' -f $checker, $InstallDir, $json)
    if (Test-Path $json) {
        $r = Get-Content -Path $json -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($x in @($r.Results | Where-Object { $_.Status -in 'FAIL', 'WARN' })) {
            Write-Log ("{0} {1}: {2}" -f $x.Id, $x.Check, $x.Detail) $(if ($x.Status -eq 'FAIL') { 'ERR' } else { 'WARN' })
        }
    }
    if ($p.ExitCode -ge 2) {
        if ($Force) { Write-Log 'Kontrola gotowości: FAIL - kontynuuję (-Force)' WARN }
        else { throw "Kontrola gotowości: FAIL (raport: $json). Usuń przyczyny i uruchom ponownie." }
    } else {
        Write-Log "Kontrola gotowości: kod $($p.ExitCode) (0 = OK, 1 = ostrzeżenia)" $(if ($p.ExitCode -eq 0) { 'OK' } else { 'WARN' })
    }
}

function New-UnattendXml {
    param($Cfg, [securestring]$Password, [string]$FirstLogonCommand)
    $esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    # Format "PlainText=false" z WSIM: Base64(UTF-16LE(hasło + nazwa pola)); Windows Setup usuwa hasła z kopii w Panther
    $admPwd   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain + 'AdministratorPassword'))
    $logonPwd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain + 'Password'))
    $plain = $null
    $admin = Get-BuiltinAdminName
    $c = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    $rearm = if ($Cfg.SkipRearm) { @"

    <component name="Microsoft-Windows-Security-SPP" $c>
      <SkipRearm>1</SkipRearm>
    </component>
"@ } else { '' }
    return @"
<?xml version="1.0" encoding="utf-8"?>
<!-- VDI-ImageMaint: Generalize ($(Get-Date -Format 'yyyy-MM-dd HH:mm')). Plik usuwany po OOBE. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="generalize">
    <component name="Microsoft-Windows-PnpSysprep" $c>
      <PersistAllDeviceInstalls>$(([string]$Cfg.PersistAllDeviceInstalls).ToLower())</PersistAllDeviceInstalls>
    </component>$rearm
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <ComputerName>$(& $esc $Cfg.ComputerName)</ComputerName>
      <TimeZone>$(& $esc $Cfg.TimeZone)</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" $c>
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>net user "$(& $esc $admin)" /active:yes</Path>
          <Description>Enable built-in administrator for AutoLogon</Description>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $c>
      <InputLocale>$(& $esc $Cfg.InputLocale)</InputLocale>
      <SystemLocale>$(& $esc $Cfg.SystemLocale)</SystemLocale>
      <UILanguage>$(& $esc $Cfg.UILanguage)</UILanguage>
      <UserLocale>$(& $esc $Cfg.UserLocale)</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$admPwd</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$(& $esc $admin)</Username>
        <LogonCount>$([int]$Cfg.AutoLogonCount)</LogonCount>
        <Password>
          <Value>$logonPwd</Value>
          <PlainText>false</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>$(& $esc $FirstLogonCommand)</CommandLine>
          <Description>VDI-ImageMaint PostGeneralize</Description>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
      <TimeZone>$(& $esc $Cfg.TimeZone)</TimeZone>
    </component>
  </settings>
</unattend>
"@
}

function Read-AdminPassword {
    if ($AdminPassword) { return $AdminPassword }
    $admin = Get-BuiltinAdminName
    for ($i = 0; $i -lt 3; $i++) {
        $p1 = Read-Host -AsSecureString "Hasło konta $admin po Generalize (AutoLogon do dokończenia budowy)"
        $p2 = Read-Host -AsSecureString 'Powtórz hasło'
        $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1); $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
        try {
            $same = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
            $empty = $p1.Length -eq 0
        } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2) }
        if ($same -and -not $empty) { return $p1 }
        Write-Log 'Hasła różne lub puste - spróbuj ponownie' WARN
    }
    throw 'Nie podano hasła administratora'
}

function Invoke-Generalize {
    Write-Log 'GENERALIZE - Sysprep obrazu wzorcowego (budowa, raz na wydanie Windows)' STEP
    if ($isSystem) { throw 'Generalize uruchamiaj z konta administratora (OSOT nie działa jako SYSTEM).' }
    if (-not (Test-AuditMode)) {
        if ($Force) { Write-Log 'System NIE jest w trybie audytu - kontynuuję (-Force)' WARN }
        else { throw 'System nie jest w trybie audytu (OSOT Generalize tego wymaga). Buduj z ISO: Ctrl+Shift+F3 na pierwszym ekranie OOBE. -Force pomija sprawdzenie.' }
    }
    if (-not $SnapshotConfirmed) {
        throw 'Zrób snapshot VM "pre-generalize" (nieudany Sysprep bywa nieodwracalny) i uruchom ponownie z -SnapshotConfirmed.'
    }
    $pending = @(Test-PendingReboot | Where-Object { $_ -ne 'PendingFileRename' })
    if ($pending.Count) { throw "Oczekuje restart ($($pending -join ', ')) - Sysprep kończy się błędem 0x36b7. Zrestartuj i uruchom ponownie." }
    if ($GeneralizeEngine -eq 'Osot' -and -not $SkipOsot -and -not (Find-Osot)) { throw "Brak OSOT w $InstallDir (albo użyj -GeneralizeEngine Sysprep)." }

    $cfg = Get-BuildConfig
    Write-Log ("Ustawienia OOBE: strefa={0}, UI={1}, system={2}, użytkownik={3}, klawiatura={4}, nazwa={5}" -f $cfg.TimeZone, $cfg.UILanguage,
        $cfg.SystemLocale, $cfg.UserLocale, $cfg.InputLocale, $cfg.ComputerName)
    Invoke-SysprepRemediation -Cfg $cfg
    Invoke-ReadinessCheck
    $admPass = Read-AdminPassword

    # Po OOBE: AutoLogon -> FirstLogonCommands -> PostGeneralize (limit 1024 znaków, dlatego -File)
    $cont = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode PostGeneralize -InstallDir "{1}"' -f $PSCommandPath, $InstallDir
    if ($Manifest) { $cont += ' -Manifest "{0}"' -f (Get-ManifestPath) }
    if ($Shutdown) { $cont += ' -Shutdown' }
    if ($cont.Length -gt 1000) { throw "Polecenie FirstLogonCommands za długie ($($cont.Length) znaków)" }

    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
    # Plik zawiera (zakodowane) hasło - dostęp tylko SYSTEM i Administratorzy
    & icacls.exe $BuildDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $xml = New-UnattendXml -Cfg $cfg -Password $admPass -FirstLogonCommand $cont
    [IO.File]::WriteAllText($UnattendPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
    [void][xml](Get-Content -Path $UnattendPath -Raw)   # walidacja składni XML
    Write-Log "unattend.xml: $UnattendPath" OK
    Set-BuildStage 'Generalizing'

    if ($GeneralizeEngine -eq 'Osot' -and -not $SkipOsot) {
        # -g bez -reboot: restart dopiero po potwierdzeniu, że Sysprep się udał
        Invoke-Osot -Label 'Generalize' -Arguments @('-g', $UnattendPath, '-v')
    } else {
        $sp = Join-Path $env:SystemRoot 'System32\Sysprep\sysprep.exe'
        $a = "/generalize /oobe /quit /unattend:`"$UnattendPath`""
        if ($cfg.SysprepVmMode) { $a += ' /mode:vm' }
        Write-Log "sysprep.exe $a" STEP
        [void](Start-Process -FilePath $sp -ArgumentList $a -Wait -PassThru)
    }
    # OSOT może uruchomić sysprep.exe asynchronicznie - czekamy na jego zakończenie
    $deadline = (Get-Date).AddMinutes(60)
    while ((Get-Process -Name sysprep -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }

    $state = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' 'ImageState')
    if ($state -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        $err = Join-Path $env:SystemRoot 'System32\Sysprep\Panther\setuperr.log'
        if (Test-Path $err) { Get-Content -Path $err -Tail 15 | ForEach-Object { Write-Log "  $_" ERR } }
        Set-BuildStage 'GeneralizeFailed'
        throw "Sysprep nie zakończył się poprawnie (ImageState=$state). Szczegóły: $err i setupact.log. Przywróć snapshot, jeśli VM nie startuje."
    }
    Set-BuildStage 'Generalized'
    Write-Log 'Sysprep zakończony poprawnie. Restart -> OOBE (unattend) -> AutoLogon -> PostGeneralize' OK
    Write-Log 'Restart za 15 s...' WARN
    try { Stop-Transcript | Out-Null } catch { }
    Start-Sleep -Seconds 15
    Restart-Computer -Force
    exit 0
}

function Disable-AutoLogon {
    Set-ItemProperty -Path $WinlogonKey -Name AutoAdminLogon -Value '0'
    foreach ($n in 'DefaultPassword', 'AutoLogonCount') { Remove-ItemProperty -Path $WinlogonKey -Name $n -ErrorAction SilentlyContinue }
    Write-Log 'AutoLogon wyłączony, hasło usunięte z Winlogon' OK
}

function Export-WingetToLastInventory {
    $last = Get-ChildItem -Path (Join-Path $BaseDir 'Inventory') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { Export-WingetPackages -Dir $last.FullName }
}

function Invoke-SealAsSystemFlow {
    # Seal z konta admina: baseline + OSOT Optimize (admin) -> blokady jako SYSTEM -> winget export -> OSOT Finalize (admin)
    Assert-SealPreconditions
    if (-not $SkipOsot) { Save-SealBaseline; Invoke-OsotSealPre }
    $rc = Invoke-AsSystem -TargetMode 'Seal'
    Export-WingetToLastInventory
    if ($rc -eq 0 -and -not $SkipOsot) { Invoke-OsotFinalize }
    return $rc
}

function Invoke-PostGeneralize {
    Write-Log 'POST-GENERALIZE - dokończenie budowy obrazu po OOBE' STEP
    # Hasło w unattend (zakodowane) - usuwamy kopię źródłową; Windows usuwa hasła z kopii w Panther
    if (Test-Path $BuildDir) { Remove-Item -Path $BuildDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Log "Usunięto $BuildDir" }
    $stage = Get-BuildStage
    if ($stage -notin 'Generalized', 'PostGeneralize') { Write-Log "Etap budowy: '$stage' (oczekiwano Generalized) - kontynuuję" WARN }
    Set-BuildStage 'PostGeneralize'
    $cfg = Get-BuildConfig

    # Kolejne rundy (restarty po agentach) wznawia zadanie AtLogOn; AutoLogon loguje administratora
    $script:AutoReboot = [System.Management.Automation.SwitchParameter]::Present
    $script:BoundParams['AutoReboot'] = [System.Management.Automation.SwitchParameter]::Present

    if ($ResumeRound -eq 0 -and $cfg.AppxSettleSeconds -gt 0) {
        Write-Log "Czekam $($cfg.AppxSettleSeconds) s na prowizjonowanie AppX po pierwszym logowaniu (zalecenie Omnissa)"
        Start-Sleep -Seconds $cfg.AppxSettleSeconds
    }
    Remove-UserAppx -Names $cfg.RemoveUserAppx

    Write-Log "Agenty po Generalize: $($cfg.PostGeneralizePackages -join ', ')" STEP
    $script:ForceInstallIds = @($cfg.PostGeneralizePackages)
    $script:PackageIds      = @($cfg.PostGeneralizePackages)
    Invoke-PackagePlatform          # przy RebootAfter: restart + wznowienie (exit)
    if ($script:PackageRunResult -eq 'error') { throw 'Błąd manifestu - przerwano budowę' }
    $script:ForceInstallIds = @()

    $pending = @(Test-PendingReboot | Where-Object { $_ -ne 'PendingFileRename' })
    if ($pending.Count) {
        Write-Log "Oczekuje restart ($($pending -join ', ')) przed Seal" WARN
        Request-RebootAndResume
        return
    }

    Disable-AutoLogon
    $script:BuildFinalize = $true
    $rc = Invoke-SealAsSystemFlow
    if ($rc -ne 0) { throw "Seal (SYSTEM) zakończony kodem $rc - sprawdź log Seal_*.log" }
    Set-BuildStage 'Done'
    Write-Log 'Budowa obrazu zakończona: Generalize -> agenty -> Seal -> Finalize' OK
    Write-Log 'Dalej: wyłącz VM -> snapshot -> Horizon Console: Push Image' STEP
}

# =====================================================================
#  URUCHOMIENIE JAKO SYSTEM
# =====================================================================
function Invoke-AsSystem {
    param([string]$TargetMode = $Mode)
    # B5: przekazujemy WSZYSTKIE parametry wywołania (np. -NoBlockDetected, -InstallDir, -Manifest, wzorce wykrywania),
    # poza tymi, które obsługuje proces nadrzędny
    $argText = ConvertTo-ArgumentText -Params $script:BoundParams -Exclude @('Mode', 'AsSystem', 'Shutdown', 'ResumeRound', 'AutoReboot', 'AdminPassword', 'SnapshotConfirmed')
    $cmd = "& '{0}' -Mode {1} {2}; exit `$LASTEXITCODE" -f ($PSCommandPath -replace "'", "''"), $TargetMode, $argText
    $taskName = 'VDI-ImageMaint-AsSystem'
    $start    = Get-Date

    Write-Log "SYSTEM: $cmd"
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + (ConvertTo-EncodedCommand $cmd))
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

    Write-Log "Uruchamiam $TargetMode jako SYSTEM..." STEP
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 3
    while ((Get-ScheduledTask -TaskName $taskName).State -in 'Running', 'Queued') { Start-Sleep -Seconds 3 }
    $rc = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

    $log = Get-ChildItem -Path $LogDir -Filter "$($TargetMode)_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $start } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) { Get-Content -Path $log.FullName | Write-Host; Write-Log "Log: $($log.FullName)" }
    return [int]$rc
}

# =====================================================================
#  MAIN
# =====================================================================
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
$script:BoundParams = $PSBoundParameters
if (-not $isSystem -and (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false   # jesteśmy we wznowieniu
}
$exitCode = 0

if ($AsSystem -and -not $isSystem) {
    if ($Mode -in 'Update', 'WingetList', 'Packages', 'PackageList', 'Optimize', 'Finalize', 'Init', 'Discover', 'Generalize', 'PostGeneralize') {
        throw "Tryb $Mode uruchamiaj jako administrator (OSOT i winget nie działają poprawnie w kontekście SYSTEM)."
    }
    try {
        # OSOT musi działać z konta administratora (synchronizacja HKCU -> Default User), nie jako SYSTEM
        if ($Mode -eq 'Seal') { $exitCode = Invoke-SealAsSystemFlow }
        else {
            $exitCode = Invoke-AsSystem
            if ($Mode -eq 'Inventory') { Export-WingetToLastInventory }
        }
    } catch {
        Write-Log $_.Exception.Message ERR
        $exitCode = 1
    }
} else {
    $log = Join-Path $LogDir ('{0}_{1}.log' -f $Mode, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Start-Transcript -Path $log -Force | Out-Null
    try {
        Write-Log "VDI-ImageMaint | tryb: $Mode | komputer: $env:COMPUTERNAME | konto: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        switch ($Mode) {
            'Status'     { Show-Status }
            'WingetList' { Show-WingetList }
            'PackageList' { Invoke-PackagePlatform -DryRun; Write-Log 'OSOT' STEP; Show-OsotConfig }
            'Init'       { Invoke-Init }
            'Discover'   { Invoke-Discover }
            'Optimize'   { Show-OsotConfig; Save-SealBaseline; Invoke-OsotSealPre }
            'Finalize'   { Invoke-OsotFinalize }
            'Packages'   { Invoke-PackagePlatform }
            'Inventory'  { Invoke-Inventory }
            'Unlock' {
                $issues = Invoke-Unlock
                Show-Status
                if ($issues -gt 0) { $exitCode = 1 }   # kod dla Invoke-AsSystem (B7)
            }
            'Update' { Invoke-Update }
            'Seal'   { Invoke-Seal }
            'Generalize'     { Invoke-Generalize }
            'PostGeneralize' { Invoke-PostGeneralize }
        }
    } catch {
        Write-Log $_.Exception.Message ERR
        $exitCode = 1
    } finally {
        # S3: transkrypcja mogła zostać już zatrzymana (restart z wznowieniem, Generalize)
        try { Stop-Transcript | Out-Null } catch { }
    }
}

if ($Shutdown -and ($Mode -in @('Seal', 'PostGeneralize')) -and $exitCode -eq 0 -and -not $isSystem) {
    Write-Log 'Wyłączanie VM za 15 s (Ctrl+C aby przerwać)...' WARN
    Start-Sleep -Seconds 15
    Stop-Computer -Force
}
exit $exitCode
