# Pobieranie – co wgrać do `C:\install` i skąd to wziąć

Instalatorów **nie trzymamy** w git (`.gitignore`). Pobierasz je sam i sprawdzasz podpis cyfrowy:
`Get-AuthenticodeSignature <plik>` ma zwrócić `Valid`, a wydawcą ma być Microsoft, Omnissa albo Broadcom.
Potem kopiujesz plik do folderu z tabeli.

> English version: [../downloads.md](../downloads.md)

## Windows i poprawki

| Element | Folder | Źródło | Uwagi |
|---|---|---|---|
| ISO Windows 11 Enterprise (24H2 / 25H2) | – (budowa VM) | Microsoft 365 admin center → licencje zbiorcze albo subskrypcja Visual Studio | Każde wydanie funkcji budujesz z czystego ISO. Obrazu wzorcowego **nie** podnosisz in-place (patrz image-lifecycle.md) |
| Aktualizacje zbiorcze (MSU) | `Patches\` | <https://www.catalog.update.microsoft.com> | 24H2/25H2 używają aktualizacji **checkpoint**: MSU checkpoint i najnowszy CU trzymasz w jednym folderze |
| Poprawki aplikacji (MSP) | `Patches\` | Producent | Włączasz je w `packages.json` świadomie (wpis `PatchesMsp`) |

## OS Optimization Tool (OSOT)

| Element | Folder | Źródło | Uwagi |
|---|---|---|---|
| Omnissa Horizon OS Optimization Tool (`OmnissaHorizonOSOptimizationTool-x86_64-*.exe`) | `OSOT\` | Omnissa Customer Connect → Downloads → Horizon → *OS Optimization Tool*; dokumentacja: <https://docs.omnissa.com/Optimizing-Images-for-Horizon/OptimizingImagesforHorizon> | **Minimum 2603 dla Windows 11 25H2**, **zalecane 2606+**: wyłącza szyfrowanie urządzenia i BitLocker, najczęstszą przyczynę błędów Sysprep na nowych kompilacjach |
| `Optimize.json` (wybory) | `OSOT\` | Eksport z GUI OSOT: Optimize → *Export Selections* | Osobny plik na profil (uczelnia / firma) |
| `LGPO.exe` | `OSOT\` (kopiowany do `System32` na czas Finalize) | Microsoft Security Compliance Toolkit: <https://www.microsoft.com/en-us/download/details.aspx?id=55319> (`LGPO.zip`) | Potrzebny w kroku Finalize **8** (lokalne zasady grupy) |
| `sdelete64.exe` | `OSOT\` | Sysinternals: <https://learn.microsoft.com/en-us/sysinternals/downloads/sdelete> | Krok Finalize **7** (zerowanie wolnego miejsca). **Tylko przy pierwszej budowie**, nigdy w cyklu Day-2 na Instant Clone |

## Komponenty Omnissa / VMware (wersje muszą pasować do backendu)

| Element | Folder | Źródło | Uwagi |
|---|---|---|---|
| VMware Tools x64 | `Horizon\` | <https://packages.vmware.com/tools/releases/latest/windows/x64/> | Instalujesz jako pierwsze, przed wszystkim innym |
| Omnissa Horizon Agent (`Omnissa-Horizon-Agent-x86_64-*.exe`) | `Horizon\` | Omnissa Customer Connect → Horizon 8 → wersja zgodna z backendem (2506) | Instalujesz **po Generalize**. Zostaw funkcje *Instant Clone* i *Media Optimization for Microsoft Teams* |
| Agent Dynamic Environment Manager (`Omnissa Dynamic Environment Manager*x64.msi`) | `Horizon\` | Omnissa Customer Connect → DEM | Po Horizon Agent |
| App Volumes Agent | `Horizon\` | Omnissa Customer Connect → App Volumes (wersja zgodna z Managerem) | Ostatni z agentów. Potrzebuje adresu Managera (`Variables` w `packages.json`) |
| Pakiet GPO Horizon (ADMX) | – (SYSVOL domeny) | Omnissa Customer Connect → Horizon 8 → *GPO Bundle* | Potrzebny do polityk optymalizacji Teams i Blast |

## Microsoft 365, Teams, FSLogix, Edge

| Element | Folder | Źródło | Uwagi |
|---|---|---|---|
| Office Deployment Tool (`setup.exe`) | `Office\` | <https://www.microsoft.com/en-us/download/details.aspx?id=49117> | XML z <https://config.office.com>: `SharedComputerLicensing=1`, `Updates Enabled="FALSE"`, `FORCEAPPSHUTDOWN=TRUE`, `Display Level="None"` |
| Bootstrapper nowego Teams (`teamsbootstrapper.exe`) | `Teams\` | <https://go.microsoft.com/fwlink/?linkid=2243204> | Instalacja dla wszystkich użytkowników: `teamsbootstrapper.exe -p` (online) lub `-p -o <msix>` (offline) |
| MSIX nowego Teams x64 (`MSTeams-x64.msix`) | `Teams\` | <https://go.microsoft.com/fwlink/?linkid=2196106> | Do instalacji offline. Wytyczne VDI: <https://learn.microsoft.com/en-us/microsoftteams/new-teams-vdi-requirements-deploy> |
| FSLogix (`FSLogix_<wersja>.zip`) | `FSLogix\` | <https://aka.ms/fslogix_download>, informacje o wydaniach: <https://learn.microsoft.com/en-us/fslogix/overview-release-notes> | Nie rozpakowuj, narzędzie zrobi to samo |
| Microsoft Edge for Business (MSI x64) | `Apps\` | <https://www.microsoft.com/edge/business/download> | Tylko gdy Edge instalujesz lub naprawiasz offline |
| App Installer / winget | – | <https://aka.ms/getwinget> | OSOT i LTSC często go usuwają, a jest potrzebny w `-Mode Update` |

## Opcjonalne

| Element | Źródło | Uwagi |
|---|---|---|
| Windows ADK – Windows System Image Manager | <https://learn.microsoft.com/windows-hardware/get-started/adk-install> | Tylko do edycji i walidacji własnego `unattend.xml` |
| VMware PowerCLI | PowerShell Gallery (`Install-Module VMware.PowerCLI`) | Punkt 5 roadmapy (snapshot + Push Image) |
