# Cykl życia złotego obrazu – Budowa (z Generalize) i Day-2 (Update → Optimize → Finalize → Seal)

> English version: [../image-lifecycle.md](../image-lifecycle.md)
> Źródła: Omnissa TechZone *Manually creating optimized Windows images for Horizon VMs*,
> dokumentacja Omnissa *OSOT Command Line Operations*, Omnissa KB 77253 *Troubleshooting Windows Sysprep Failures*.

## 1. Dwie fazy, jedna zasada

| Faza | Kiedy | Generalize (Sysprep) | Wynik |
|---|---|---|---|
| **Budowa** | Nowy obraz oraz każde **wydanie funkcji** Windows (24H2 → 25H2) | **Tak, obowiązkowo, dokładnie raz** | Czysta, uogólniona maszyna wzorcowa z agentami |
| **Day-2** | Comiesięczne poprawki, aktualizacje aplikacji | **Nie** | Ta sama maszyna, zaktualizowana, ponownie zoptymalizowana i sfinalizowana |

Dlaczego w Day-2 nie powtarzamy Generalize:
- Kolejność według Omnissa: **Optimize → Generalize → instalacja agentów Horizon → Finalize**. Gdy agenty są już
  zainstalowane, ponowne Generalize wychodzi poza wspieraną kolejność. Agenty, App Volumes i DEM instaluje się na uogólnionym systemie.
- Każde Generalize zużywa licznik rearm (licencjonowanie), wyrzuca maszynę z domeny i od nowa przechodzi OOBE.
- Pule Instant Clone domyślnie używają **ClonePrep**, który daje klonom SID obrazu wzorcowego. Dlatego sam obraz
  trzeba uogólnić raz. Sysprep na każdym klonie jest opcjonalny.
- Wytyczne Omnissa dla Day-2: włącz ponownie Windows Update → aktualizuj → **ponownie Optimize i Finalize**.

**Nowe wydanie funkcji: budujesz od nowa, nie aktualizujesz in-place.** Obraz podniesiony in-place to częste
źródło problemów z Sysprep i OOBE, a pozostałości starego systemu trafiają do każdego klona.

## 2. Faza budowy krok po kroku

| # | Krok | Narzędzie / polecenie | Dlaczego to ważne w 24H2 / 25H2 |
|---|---|---|---|
| 1 | VM: Windows 11 64-bit, UEFI + Secure Boot, **bez vTPM**, VMXNET3, PVSCSI (sterowniki wbudowane od 22H2), bez stacji dyskietek i portów szeregowych | vSphere | Złoty obraz nie może mieć vTPM: Horizon dodaje unikalny vTPM do każdego klona (Omnissa KB 85960). Bez vTPM nie ma też automatycznego szyfrowania urządzenia (krok 4) |
| 2 | Instalacja z czystego ISO **bez pytań, prosto do trybu audytu**: CD 1 = ISO Windows, CD 2 = `VDI-Build.iso` (§2a). Ręcznie: na pierwszym ekranie OOBE naciśnij **Ctrl+Shift+F3** | `Scripts\New-BuildMedia.ps1` (menu **B**) | OSOT Generalize **wymaga trybu audytu**. Nie twórz kont i nie loguj się kontem Microsoft |
| 3 | W trybie audytu okno Sysprep zamykasz przy każdym logowaniu (Anuluj) | – | Tryb audytu przetrwa restarty |
| 4 | **Od razu zatrzymaj szyfrowanie urządzenia i BitLocker**: `PreventDeviceEncryption=1`, usługa BDESVC wyłączona, dysk C: w pełni odszyfrowany | sprawdza to `Test-SysprepReadiness.ps1` | Nowe kompilacje Win11 same włączają szyfrowanie, a Sysprep przy wyjściu z trybu audytu kończy się wtedy błędem. OSOT 2606+ robi to w Optimize, starsze wersje nie |
| 5 | **Zablokuj aktualizacje Store dla bieżącego konta**: polityka `WindowsStore\AutoDownload=2`, nie otwieraj Store | polityka | Aplikacja Store zaktualizowana tylko dla Administratora wywraca Sysprep z błędem `0x80073cf2` |
| 6 | VMware Tools → restart | `packages.json` VMwareTools | – |
| 7 | Windows Update, aż nic nie oczekuje, potem restart | `-Mode Update` | Sysprep odmawia przy oczekującym restarcie: `0x36b7 … updates that require a reboot` |
| 8 | Aplikacje: M365 (ODT), nowy Teams **zaprowizjonowany** (`teamsbootstrapper -p`), FSLogix, aplikacje klienta | `-Mode Packages` | MSIX **zaprowizjonowane** przechodzą przez Sysprep. MSIX zarejestrowane **tylko dla bieżącego konta** nie przechodzą |
| 9 | **OSOT Optimize** (JSON profilu + opcje wspólne) → restart | `-Mode Optimize` | Usuwa zbędne zaprowizjonowane aplikacje Store. Przy `-storeapp remove-all` zawsze dodawaj `--exclude MSTeams` |
| 10 | **Kontrola gotowości – wszystko musi być PASS** | `Scripts\Test-SysprepReadiness.ps1` (uruchamiany automatycznie w `-Mode Generalize`) | Wyłapuje znane blokery *przed* Sysprep |
| 11 | **Snapshot „pre-generalize”** | vSphere | Nieudany Sysprep często zostawia maszynę, która nie startuje. Ten snapshot to punkt powrotu |
| 12 | **OSOT Generalize** (`-g <unattend.xml>`), restart → OOBE z pliku odpowiedzi | `-Mode Generalize` | OSOT nie łączy Generalize i Finalize w jednym uruchomieniu, między nimi musi być restart |
| 13 | Po pierwszym logowaniu odczekaj 1–2 min (prowizjonowanie AppX), potem usuń Copilot i BingSearch zainstalowane dla bieżącego konta | `Get-AppxPackage -AllUsers Microsoft.Copilot \| Remove-AppxPackage -AllUsers` (to samo dla `Microsoft.BingSearch`) | Nowe kompilacje instalują je dla bieżącego konta w trakcie OOBE, co psuje później pule z personalizacją przez Sysprep |
| 14 | Horizon Agent (**Instant Clone** + **Media Optimization for Microsoft Teams**), DEM, App Volumes Agent → restart | `packages.json` | Agenty instalujesz **po** Generalize |
| 15 | **OSOT Finalize** (zestaw dla pierwszej budowy, patrz §4) | `-Mode Finalize` | – |
| 16 | **Seal** → wyłączenie → snapshot → Push Image | `-Mode Seal -AsSystem -Shutdown` | – |

Gdy Sysprep się nie powiedzie, przeczytaj `C:\Windows\System32\Sysprep\Panther\setuperr.log` i `setupact.log`.
Gdy nie powiedzie się klon, przeczytaj `C:\Windows\Panther\` i `C:\Windows\Panther\UnattendGC\`.
`Test-SysprepReadiness.ps1` wypisuje ostatnie błędy z tych logów.

### 2a. Instalacja nowego obrazu bez pytań (`New-BuildMedia.ps1`)

> W pełni automatycznie z vCenter (utworzenie VM, wysłanie ISO, start, wydanie do puli) oraz alternatywa OSDCloud: [vcenter-osdcloud.md](vcenter-osdcloud.md).

Uruchom na swoim komputerze, na którym przygotowano `C:\install` (po Configure i Download) - menu **B** albo:

```
.\Scripts\New-BuildMedia.ps1 -Edition Enterprise -UILanguage pl-PL
```

Skrypt zapisuje `VDI-Build.iso` (UDF, wbudowany IMAPI2, bez Windows ADK) z `autounattend.xml`, plikiem znacznika
i całym folderem `install\`. Instalator Windows znajduje plik odpowiedzi na drugim napędzie CD/DVD:

| Faza | Co się dzieje |
|---|---|
| windowsPE | język, dysk 0 czyszczony: EFI 260 MB + MSR 16 MB + Windows (bez partycji odzyskiwania), edycja po nazwie + ogólny klucz klienta KMS (GVLK), bez Dynamic Update, pominięte sprawdzanie TPM (bez vTPM, KB 85960) |
| specialize | nazwa komputera i strefa czasowa (z `packages.json` Build), `PreventDeviceEncryption=1`, wyłączone automatyczne aktualizacje Store |
| oobeSystem | bez ekranów OOBE: **tryb audytu** (wbudowany Administrator, bez hasła) |
| auditUser | `install\` kopiowany do `C:\install`, potem otwiera się menu (`-AutoStart Menu`) albo startuje Update (`-AutoStart Update`) |

- `-UILanguage` **musi być zgodny z ISO Windows** (ISO pl-PL → `pl-PL`). Klawiatura i ustawienia regionalne pochodzą z kroku 5 kreatora.
- `-Edition` Enterprise / Education / Pro / ProEducation; `-ImageName`, gdy nazwa w `install.wim` jest inna
  (`dism /Get-WimInfo /WimFile:D:\sources\install.wim`). Aktywacja później przez KMS / aktywację w Active Directory albo MAK.
- `-WithVtpm`, gdy VM ma vTPM w czasie budowy (bez obejścia TPM) - usuń vTPM przed utworzeniem puli.
- `-ScriptsOnly` pomija instalatory (mniejsze ISO); `-XmlOnly` zapisuje tylko `autounattend.xml`.
- Na nośniku nie ma żadnego hasła. Hasło lokalnego Administratora po Generalize podajesz w `-Mode Generalize`.
- Gdy instalator się zatrzyma: zły język albo nazwa edycji (sprawdź dwie opcje powyżej). Log: `X:\Windows\Panther\setupact.log`
  (Shift+F10 w instalatorze), log kopiowania `C:\Windows\Temp\vdi-build-copy.log`.

## 3. Cykl Day-2 (co miesiąc)

```
Unlock → Update (pakiety, M365, Teams -p, winget, Windows Update, restarty) →
OSOT Optimize (ponownie – aktualizacje włączają usługi i zadania z powrotem) → OSOT Finalize (zestaw Day-2) →
Seal -AsSystem -Shutdown → snapshot → Push Image
```
Tu nie ma Generalize. Pomijasz też zerowanie wolnego miejsca (Finalize 7) i Compact (2).

### Raport cyklu (HTML)

Każdy przebieg, który coś zmienia (Update, Packages, Optimize, Finalize, Seal, Generalize, PostGeneralize, Unlock), zapisuje się w
`%ProgramData%\VDI-ImageMaint\cycle.json`, także przez restarty i procesy SYSTEM. Seal, który kończy cykl, zapisuje
`%ProgramData%\VDI-ImageMaint\Reports\VDI-ImageMaint_<komputer>_<cykl>.html`. `-Mode Report` (menu **H**) zapisuje go
w dowolnej chwili. To jedna samodzielna strona: bez internetu, z jasnym i ciemnym motywem, do wydruku. Przykład: [report-example.html](../report-example.html).

Raport zawiera:
- status (OK / ostrzeżenia / błędy), Windows przed → po i koniec wsparcia, wsparcie Horizon Agent;
- błędy i ostrzeżenia ze wszystkich przebiegów;
- aplikacje zmienione w cyklu (nowe / zaktualizowane / usunięte);
- aktualizacje Windows i pakiety z wynikami;
- wersje komponentów VDI (VMware Tools, Horizon Agent, DEM, App Volumes, FSLogix, Microsoft 365, Teams);
- stan Seal (polityki, usługi, aktywne zadania aktualizacji) i każdy przebieg z pełnym logiem.

## 4. Ustawienia OSOT pod szybki start i logowanie (Instant Clone)

Instant Clone startuje przez rozwidlenie działającej maszyny nadrzędnej. „Szybki start” oznacza więc trzy rzeczy:
szybki ClonePrep, krótkie pierwsze logowanie i brak pracy w tle na klonie zaraz po jego utworzeniu.

| Dźwignia | Ustawienie | Efekt |
|---|---|---|
| Prekompilacja .NET | Finalize **0** (NGEN) po każdej aktualizacji .NET | Klony nie kompilują .NET w tle. Bez tego Windows kompiluje przy bezczynności i potrafi zająć cały rdzeń nawet na godzinę na każdym klonie |
| Magazyn składników | Finalize **1** (czyszczenie DISM) po aktualizacjach | Mniejszy obraz, mniej I/O |
| Czyszczenie dysku / dzienniki zdarzeń | Finalize **3**, **4** | Mniejsza delta, czyste dzienniki na każdym klonie |
| SysMain (Superfetch) | Finalize **5** | Bez sensu na klonach nietrwałych, kosztuje I/O przy starcie |
| Zasady lokalne | Finalize **8** (wymaga `LGPO.exe`) | Ustawienia OSOT jako lokalne GPO |
| Zaprowizjonowane aplikacje Store | `-storeapp remove-all --exclude <lista, w tym MSTeams>` | Każda zaprowizjonowana aplikacja rejestruje się przy pierwszym logowaniu. Mniej aplikacji to szybsze pierwsze logowanie |
| Zadania konserwacji | Szablon OSOT (domyślny) + Seal VDI-ImageMaint | Brak zadań konserwacji, defragmentacji i aktualizacji na klonach |
| Aktualizacje Windows / Office / Store | `-windowsupdate disable -officeupdate disable` + Seal | Brak burzy aktualizacji po Push Image |
| Compact | Finalize **2** – **wyłączone** | Koszt CPU przy dekompresji, zero zysku na Instant Clone |
| Zerowanie wolnego miejsca | Finalize **7** – tylko przy pierwszej budowie i tylko przy eksporcie do dysku thin | – |
| Profil domyślny | Finalize **6** – **do sprawdzenia** na klonie testowym, zanim włączymy u klientów | Czyści profil domyślny; trzeba sprawdzić wpływ na synchronizację HKCU→Default User w OSOT |

Obecny Finalize w `packages.json`: `0 1 3 4 5 6 8`. Propozycja: Budowa `0 1 3 4 5 8 9 10 11` (+7 przy eksporcie),
Day-2 `0 1 3 4 5 8 10 11`. Krok 6 dodajemy dopiero, gdy klon testowy go potwierdzi.

## 5. Profile: Uczelnia i Firma (opcje wspólne OSOT)

| Opcja | Uczelnia | Firma | Uwagi |
|---|---|---|---|
| `-visualeffect` | `balanced` | `balanced` (`quality` + `enablehardwareacceleration` przy vGPU) | W `balanced` zostają wygładzanie czcionek i cienie ikon |
| `-storeapp` | `remove-all --exclude Calculator Photos ScreenSketch StickyNotes MSTeams` | `remove-all --exclude Calculator Photos ScreenSketch MSTeams` | **Nigdy nie usuwaj MSTeams** |
| `-notification` | `disable` | **`enable`, dopóki nie sprawdzimy** | Trzeba sprawdzić, czy powiadomienia o połączeniach i czacie Teams nadal się pokazują, gdy OSOT wyłączy powiadomienia |
| `-onedrive` | zależnie od klienta | `enable` (Known Folder Move) | – |
| `-windowsSearch` | `searchboxasicon` | `searchboxasicon` | Wyszukiwanie w menu Start musi działać, sprawdzamy to na klonie |
| `-antivirus`, `-securitycenter`, `-firewall`, `-smartscreen` | domyślne (włączone) | domyślne (włączone) | Firma: Defender for Endpoint w trybie VDI |
| `-hvci` | disable (domyślnie) | zgodnie z polityką bezpieczeństwa | – |

## 6. Microsoft Teams na Horizon – co musi mieć obraz

- Nowy Teams **zaprowizjonowany** (`teamsbootstrapper -p`), `HKLM\SOFTWARE\Microsoft\Teams\disableAutoUpdate=1` (ustawia Seal).
- Funkcja Horizon Agent **Media Optimization for Microsoft Teams** zainstalowana. Polityka GPO *Enable Media Optimization
  for Microsoft Teams* pochodzi z pakietu GPO Horizon.
- FSLogix wyklucza tylko foldery Teams zalecane przez Microsoft (patrz Set-FSLogixConfig.ps1).
- OSOT `-storeapp … --exclude MSTeams`.
- Kontrola na klonie (punkt 7 roadmapy): Teams zgłasza *Omnissa/VMware Media Optimized*, połączenia i udostępnianie
  ekranu są przekierowane na klienta, powiadomienia się pokazują.

## 7. Wydania Windows i wsparcie Horizon (24H2, 25H2, 26H2)

Stan na 2026-10-01. Źródła: Microsoft *Windows 11 release information*, Omnissa KB 78714 (systemy wspierane przez
Horizon Agent), Omnissa *Supported Windows versions for the OSOT components*. Ta sama tabela jest w
`Modules\VDI-ImageMaint\Private\Windows.ps1` (`$WindowsReleases`). Aktualizuj ją przy każdym nowym wydaniu.

| Wydanie | Kompilacja | Horizon Agent (KB 78714) | OSOT | Wsparcie Ent/Edu | Wsparcie Pro |
|---|---|---|---|---|---|
| 24H2 | 26100 | 2406+ (także 2312.2/2312.3 ESB); **2506 obsługuje najwyżej 24H2** | 2503+ | 2027-10-12 | **2026-10-13** |
| 25H2 | 26200 | **2512+** (2512, 2512.1, 2603, 2606); Horizon **2506 nie wspiera 25H2** | 2603+ (zalecane 2606+) | 2028-10-10 | 2027-10-12 |
| 26H2 | 26300 | **jeszcze nie ma na liście** (KB 78714 z 2026-09-29) | jeszcze nie ma | 2029-10-09 | 2028-10-10 |
| 26H1 | 28000 | nie dla VDI (tylko nowe urządzenia, nieoferowane istniejącym) | – | – | – |

Co to oznacza:
- **Backend Horizon 2506**: obrazy produkcyjne zostają na **24H2** (Enterprise/Education do 2027-10-12).
  Przed 25H2 lub 26H2 zaktualizuj Connection Servery i agenta (2512.1 / 2603 / 2606). Sprawdź macierz zgodności Omnissa.
- **26H2 to pakiet umożliwiający** (KB5121794) na 24H2/25H2: ta sama gałąź serwisowa i ta sama miesięczna
  aktualizacja zbiorcza (np. KB5124010 dla 26100/26200/26300). Obraz 26H2 można zrobić na dwa sposoby:
  1. **Czysta budowa z ISO 26H2** (zalecane dla produkcji, z Generalize – sekcja 2).
  2. **Pakiet umożliwiający na istniejącym obrazie 25H2** (jeden restart, bez Generalize, dobre dla puli pilotażowej):
     ustaw `"Windows": { "TargetRelease": "26H2" }` w `packages.json` i uruchom Update na **kopii** złotego obrazu
     albo skopiuj plik `.msu` KB5121794 do `Patches\`.
- Narzędzie chroni obraz przed przypadkową zmianą wydania: `-Mode Update` **pomija aktualizacje funkcji i pakiety
  umożliwiające**, dopóki `Windows.TargetRelease` nie wskaże wydania. Z ustawionym celem zapisuje politykę Windows Update
  `TargetReleaseVersion`/`TargetReleaseVersionInfo`, żeby nic nowszego nie było oferowane.
- `-Mode Status`, `Update` i plan pakietów pokazują wydanie, koniec wsparcia i to, czy instalator Horizon Agent je wspiera.
  `Test-SysprepReadiness.ps1` ostrzega przy 26H2 (C01, C17), zatrzymuje przy 26H1 i ostrzega, gdy złoty obraz ma
  vTPM (C21, KB 85960).

### Cicha instalacja Horizon Agent (packages.json)

```
/s /v"/qn VDM_VC_MANAGED_AGENT=1 ADDLOCAL={HorizonAgentFeatures} {HorizonAgentOptions} REBOOT=ReallySuppress /l*v {Log}"
```

- `VDM_VC_MANAGED_AGENT=1` jest **wymagany** (pulpit zarządzany przez vCenter).
- Przy liście funkcji `ADDLOCAL` musi zawierać **Core**. **NGVC** (Instant Clone Agent) **nie** instaluje się domyślnie
  przy cichej instalacji. Bez niego obrazu nie da się użyć w Instant Clone. Core zawiera już Blast, PCoIP,
  **Media Optimization for Microsoft Teams**, HTML5 MMR i Browser Redirection.
- Domyślne zestawy dla profili (`-Mode Configure` krok 4, `Variables.HorizonAgentFeatures`):

| Profil | ADDLOCAL |
|---|---|
| Uczelnia | `Core,NGVC,RTAV,ClientDriveRedirection,HznVaudio,BlastUDP,PrintRedir,HelpDesk,USB` |
| Firma | jak Uczelnia + `ScannerRedirection` |
| Grafika | jak Uczelnia (USB dla tabletów i myszy 3D) |

- W razie potrzeby dodaj `SmartCard`, `SerialPortRedirection`, `GEOREDIR` lub `PerfTracker`. `V4V` usunięto w 2412.
- `Variables.HorizonAgentOptions` to dodatkowe właściwości MSI, np. `URL_FILTERING_ENABLED=1`, `ENABLE_UNC_REDIRECTION=1`,
  `RDP_CHOICE=0`. Nigdy nie wpisuj haseł do manifestu.
- `-Mode Validate` sprawdza powyższe właściwości i zgłasza nieznane nazwy funkcji.
- Kolejność agentów: VMware Tools → Horizon Agent → DEM → App Volumes Agent (Order 10–13), wszystkie po Generalize.
