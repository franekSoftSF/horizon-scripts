# Status projektu VDI-ImageMaint

_Aktualizacja: 2026-09-30_ · wersja kodu: VDI-ImageMaint.ps1 **1.7.3**, Set-FSLogixConfig.ps1 **1.0**

## Gdzie jesteśmy
- [x] Przegląd obu skryptów (odczyt całości, ręczna analiza logiki)
- [x] Parser: **0 błędów** w PS 5.1 i pwsh 7.6; kodowanie OK (UTF-8 BOM, CRLF)
- [x] PSScriptAnalyzer 1.25: 132 uwagi, prawie wyłącznie kosmetyczne (szczegóły niżej)
- [x] Potwierdzone na próbach: B1, B2, B3 (skrypty testowe w scratchpadzie)
- [x] Repozytorium git (`main`), commit bazowy 1.7.3 bez zmian w kodzie, `.gitattributes` (CRLF), `.gitignore` (bez binariów), `.editorconfig`
- [x] Struktura `install/` = `C:\install` (Patches, Office, FSLogix, Horizon, OSOT, Teams, Apps, Scripts) z opisami README EN/PL
- [x] `docs/downloads.md` + `docs/pl/downloads.md` – skąd pobrać każdy instalator
- [x] `docs/image-lifecycle.md` + PL – Budowa (z Generalize) i Day-2, OSOT pod szybki start, profile Uczelnia/Firma, Teams
- [x] `tools/Test-SysprepReadiness.ps1` v0.1 – 20 kontroli przed Generalize (EN/PL, tylko odczyt).
      Parser PS 5.1 OK, PSSA OK; uruchomiony próbnie bez admina na Win11 25H2. **C09/C10 (AppX) do sprawdzenia na VM jako admin**
- [ ] Brak w repo: `packages.json`, `OSOT\Optimize.json`, `Office\Configuration_x64.xml` – potrzebne do B2, walidacji manifestu
      i do sprawdzenia, czy `-storeapp` w Optimize.json nie usuwa MSTeams
- [ ] Poprawki B1–B7 w kodzie – jeszcze niezrobione

## Ustalenia OSOT / Generalize (źródła: Omnissa docs, TechZone, KB 77253)
- Generalize **wymaga trybu audytu**, nie da się go połączyć z Finalize w jednym uruchomieniu, a po nim trzeba zrestartować
- Kolejność Omnissa: Optimize → **Generalize** → agenty Horizon/DEM/AV → Finalize; w Day-2 **bez** Generalize (Optimize + Finalize ponownie)
- Najczęstsze przyczyny błędów Sysprep w 24H2/25H2: szyfrowanie urządzenia / BitLocker, AppX zainstalowane dla konta,
  ale niezaprowizjonowane (0x80073cf2), aktualizacje Store dla konta, oczekujący restart (0x36b7), Copilot i BingSearch po OOBE
- OSOT: **min. 2603 dla 25H2**, **2606+** sam wyłącza szyfrowanie urządzenia i BitLocker
- Do sprawdzenia: `-notification disable` a powiadomienia Teams (profil Firma); Finalize 6 (czyszczenie profilu domyślnego)

## Problemy wg ważności

### Wysoka
| # | Plik:linia | Problem | Skutek |
|---|---|---|---|
| B1 | VDI-ImageMaint.ps1:367 | `Get-Prop` zwraca string, więc `-not '0'` = False: aplikacje z **SystemComponent=0** (albo ParentKeyName) są pomijane | Brakujące pozycje w Inventory, Discover i Show-AppDiff; detekcja `Uninstall` nie znajduje aplikacji, więc pakiet z RequireInstalled jest pomijany **(potwierdzone)** |
| B2 | VDI-ImageMaint.ps1:1486 | Typ `ps1` uruchamiany przez `powershell -File`: apostrofy w Arguments zostają w wartości, tablic nie da się przekazać | FSLogixConfig z `-VHDLocations '\\srv\p$'` dostaje ścieżkę z apostrofami, a test UNC nie przechodzi **(potwierdzone)** |
| B3 | Set-FSLogixConfig.ps1:71,171,363 | Z `-WhatIf` nie startuje ani New-Item, ani Start-Transcript, a `Stop-Transcript` w finally rzuca błąd | Tryb podglądu kończy się błędem, exit 1 **(potwierdzone)** |
| B4 | VDI-ImageMaint.ps1:715 | Seal najpierw uruchamia OSOT (`-windowsupdate disable`), a **dopiero potem** zapisuje stan usług | seal-state.json zapisuje już wyłączone usługi, więc samo `-Mode Unlock` nie włącza Windows Update (w trybie Update ratuje to OSOT EnableUpdates) – do potwierdzenia na VM |
| B5 | VDI-ImageMaint.ps1:2166 | `Invoke-AsSystem` przekazuje tylko -Mode, -Cleanup i -Force | Proces SYSTEM traci `-NoBlockDetected`, `-InstallDir`, `-Manifest`, `-SkipOsot` i wzorce wykrywania, np. blokuje aktualizatory, choć użytkownik chciał tylko raportu |
| B6 | VDI-ImageMaint.ps1:2204 | Z -AsSystem OSOT Optimize rusza w procesie nadrzędnym **przed** sprawdzeniem oczekującego restartu (to sprawdzenie robi proces SYSTEM) | Obraz jest optymalizowany, a potem Seal odmawia – stan przejściowy |
| B7 | VDI-ImageMaint.ps1:1991 | Update wywołuje Unlock z konta admina (a -AsSystem jest dla Update zabroniony), więc WaaSMedicSvc i UsoSvc bywają niemożliwe do przywrócenia | Windows Update może nie działać po Seal z -AsSystem |

### Średnia
| # | Miejsce | Problem |
|---|---|---|
| S1 | cały C:\install | Bezpieczeństwo: PreScript/PostScript z manifestu, OSOT wyszukiwany wzorcem, zadanie SYSTEM uruchamiające `C:\install\*.ps1` – jeśli użytkownicy mają prawo zapisu do C:\install, to eskalacja uprawnień. Potrzebna kontrola ACL w Seal/Validate |
| S2 | :1887 | Pobrany `teamsbootstrapper.exe` jest uruchamiany bez sprawdzenia podpisu Authenticode |
| S3 | :1779, :2235 | `Stop-Transcript` w finally bez try (wznowienie po restarcie, -WhatIf) |
| S4 | :1966 | Wyszukiwanie WU bez `BrowseOnly=0` – mogą wejść opcjonalne aktualizacje „Preview” (do weryfikacji); wynik `Download()` nie jest sprawdzany |
| S5 | :1419 | Detect `Registry`/`File` bez Path: `Get-Item -LiteralPath ''` rzuca błąd wiązania (tego nie wycisza SilentlyContinue) |
| S6 | :1364 i in. | `[bool]"false"` = True – wartości tekstowe w manifeście są interpretowane błędnie (rozwiąże to JSON Schema / Validate) |
| S7 | :1588 | `Get-NormalizedName` usuwa lata, więc VC++ 2013 i 2015 dają tę samą nazwę – ryzyko błędnego dopasowania w Discover |
| S8 | :1484 | MSU z Patches instalowane pojedynczo wg nazwy pliku; w Win11 24H2+ poprawki checkpoint wymagają kolejności lub `/PackagePath:<folder>` |
| S9 | Set-FSLogixConfig:255 | Gdy `Get-LocalGroupMember` zawiedzie (osierocone SID), Everyone po cichu zostaje w Include List |
| S10 | :1264 | PackageList (dry-run) rozpakowuje ZIP-y do TEMP; rozpakowana kopia nie jest odświeżana po podmianie ZIP-a o tej samej nazwie |
| S11 | nagłówek, :982 | Rozjazd dokumentacji i kodu: pomoc mówi, że FSLogix „NIE jest aktualizowany”; domyślny manifest w kodzie (performance, osot-selections.json, `-f 0 1 3 4 10`) różni się od faktycznego (balanced, Optimize.json, `0 1 3 4 5 6 8`) |

### Niska / styl (PSScriptAnalyzer)
- 79× PSAvoidUsingPositionalParameters (Get-PV, Test-Policy, Set-Reg) – do wyłączenia w ustawieniach dla helperów wewnętrznych
- 17× PSUseSingularNouns, 16× PSUseShouldProcessForStateChangingFunctions – do decyzji w ramach modułu
- 8× puste catch – dodać komentarz albo `Write-Verbose`
- 8× Write-Host – celowe (kolory + transkrypcja), do wyłączenia w ustawieniach
- `[xml]$check` nieużywane (Set-FSLogixConfig:231); `Set-Reg` używa `$PSCmdlet` ze skryptu (działa, ale jest kruche)
- Obiekty COM (WindowsInstaller) nie są zwalniane; `Test-PendingReboot` pomija część źródeł

## Plan (zatwierdzony 2026-09-30)
1. ~~Git + punkt odniesienia~~ ✔ (CHANGELOG razem z 1.7.4)
2. **Poprawki B1–B7, S3, S5** w obecnym pliku – mały diff do sprawdzenia na VM → 1.7.4
2a. **OSOT + Generalize w VDI-ImageMaint**: `-Mode Generalize` (kontrola gotowości → przypomnienie o snapshocie → OSOT `-g` →
    wznowienie po OOBE → usunięcie Copilot/BingSearch), osobne zestawy Finalize dla Budowy i Day-2, sekcja `Osot.Profiles`
    (Uczelnia/Firma) w manifeście z zachowaniem zgodności wstecz, zawsze `--exclude MSTeams`
3. **Moduł + i18n** (jeden krok, żeby nie tłumaczyć dwa razy):
   `src/VDI-ImageMaint/{psd1,psm1,Private,Public,en-US,pl-PL}`, cienki `VDI-ImageMaint.ps1` z tym samym `param()`,
   komunikaty w `Import-LocalizedData` (EN domyślnie, PL przez `-Language pl` lub kulturę UI).
   Pułapki: `$PSCommandPath` w module wskazuje psm1, `exit` w funkcjach, StrictMode w psm1
4. **Pester**: ConvertTo-Version, Get-NormalizedName, Expand-PkgString, parsowanie tabeli winget (wydzielone
   do czystej `ConvertFrom-WingetTable`), Get-PackagePlan i Resolve-OdtConfig na TestDrive; oba języki = te same klucze
5. **Profile Uczelnia / Firma** (roadmapa pkt 8) + weryfikacja optymalizacji Teams (roadmapa pkt 4 i 7)
6. Build: jeden plik do wdrożenia w C:\install (opcjonalnie) + PSScriptAnalyzerSettings.psd1
7. **Linux (Debian/Ubuntu)** – po zakończeniu narzędzia Windows: optymalizacja obrazu Horizon Linux Agent (osobny etap)

## Otwarte pytania
- Czy przesłać `packages.json`, `Optimize.json` i `Configuration_x64.xml` do repo?
- i18n: wybór języka przez parametr `-Language`, czy automatycznie z kultury systemu?
- Wdrożenie na VM: folder modułu obok skryptu czy jeden scalony plik?
