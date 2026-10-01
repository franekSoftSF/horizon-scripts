# Status projektu VDI-ImageMaint

_Aktualizacja: 2026-10-01_ · VDI-ImageMaint **2.0.0 (w trakcie)** · Set-FSLogixConfig **1.1.0** · Test-SysprepReadiness **0.1**

## Układ repozytorium
- `windows/` – narzędzie Windows, `linux/` – narzędzie Linux (osobna praca)
- `windows/install/` = kompletny `C:\install` (skrypty, manifest, katalog winget, XML Office, OSOT JSON; binaria poza git)
- `windows/docs/` (EN) + `windows/docs/pl/` (PL): skąd pobrać instalatory (`downloads.md`), cykl życia obrazu (`image-lifecycle.md`)
- `windows/CHANGELOG.md`, `status.md`, `status.json`, `CLAUDE.md`

## Zrobione
- [x] Git (`main`), commit bazowy 1.7.3, `.gitattributes` (CRLF), `.gitignore` (bez binariów), `.editorconfig`
- [x] Poprawki **B1–B7** oraz S2, S3, S5, S9 (szczegóły w CHANGELOG 1.8.0)
- [x] **Generalize → PostGeneralize**: skrypt sam uruchamia Sysprep (OSOT `-g`), po OOBE loguje się automatycznie
      (unattend: AutoLogon + FirstLogonCommands) i kontynuuje: agenty z restartami → wyłączenie AutoLogon → Seal → Finalize
- [x] **Configure** – kreator krok po kroku (profil, Office, FSLogix, App Volumes, ustawienia regionalne, OSOT, winget w oknie wyboru)
- [x] Aplikacje winget z manifestu instalowane dla całej maszyny; Seal blokuje też aktualizacje Adobe Reader
- [x] `Office\Configuration_x64.xml`: Updates=FALSE, FORCEAPPSHUTDOWN=TRUE, Display=None; `Uninstall.xml` = Remove All
- [x] `START.cmd` (dwuklik) → menu PL/EN z krokami po kolei; `Update -ThenSeal` = cykl miesięczny jednym krokiem
- [x] Profil **Grafik** (OSOT quality + GPU, FSLogix 100 GB) i OneDrive dla całej maszyny; `docs/profiles-gpo.md` (GPO, DEM, FSLogix)
- [x] **Java / Eclipse**: Temurin JDK 21 + 25 (MSI, stały `INSTALLDIR`) i Eclipse IDE (`Scripts\Install-Eclipse.ps1` 1.0, EN/PL) jako
      pakiety `TemurinJDK21` / `TemurinJDK25` / `EclipseJava`; `-Mode Download` je pobiera; `docs/eclipse-java.md` (+pl):
      workspace w kontenerze FSLogix, Dokumenty/Pulpit przez przekierowanie folderów DEM na UNC.
      Test lokalny instalatora na prawdziwym ZIP 2026-09 i prawdziwe pobieranie; **nie testowano na VM**
      (wykrywanie JDK przy starcie Eclipse, `user.home` przy przekierowaniu DEM)
- [x] **Configure: krok 3/8 Java/Eclipse** (kreator ma teraz 8 kroków): wybór JDK, pakiet java/jee, workspace bez pytania,
      -Xmx, opcjonalne wykluczenie cache Maven/Gradle z FSLogix; test kreatora na kopii `install/` (-NoGui) + 4 testy Pester

- [x] **Przygotowanie do Windows 11 26H2 i agenta Horizon** (2026-10-01): tabela wydań 24H2/25H2/26H2/26H1 ze wsparciem
      Horizon Agent (KB 78714), OSOT i końcem wsparcia; Update pomija aktualizacje funkcji, dopóki `Windows.TargetRelease`
      nie wskaże wydania; readiness: 26H2 WARN, 26H1 FAIL, vTPM (C21). Horizon Agent: `VDM_VC_MANAGED_AGENT=1` +
      `ADDLOCAL` z Core/NGVC wg profilu (wcześniej brakowało obu), walidacja parametrów. **Nie testowano na VM.**

- [x] **Instalacja nowego obrazu** (2026-10-01): `Scripts\New-BuildMedia.ps1` (menu B) tworzy `VDI-Build.iso` z `autounattend.xml`:
      instalacja Windows bez pytań prosto do trybu audytu (bez vTPM, bez szyfrowania, bez auto-aktualizacji Store), kopiuje
      `C:\install` i otwiera menu. ISO testowane lokalnie (zapis w PS 5.1 i pwsh 7, montowanie: UDF, komplet plików);
      **instalacja na VM nie była jeszcze testowana**.

## Jak testowano (bez VM)
- Parser PS 5.1: 0 błędów we wszystkich skryptach; PSScriptAnalyzer: tylko puste bloki catch (celowe)
- Testy funkcji w izolacji (PS 5.1): unattend.xml (poprawny XML, wszystkie fazy, hasła w formacie WSIM),
  przekazywanie parametrów do SYSTEM (B5), pakiety ps1 z apostrofami i tablicami (B2), filtr SystemComponent (B1)
- Kreator Configure przeszedł całość na kopii `install/` dla profili Firma i Grafik (tryb konsolowy `-NoGui`)
- `START.cmd` → menu (bez UAC, wejście przekierowane) i menu PS w obu językach, łącznie z blokadą Generalize bez snapshotu
- `Set-FSLogixConfig.ps1 -WhatIf`: kod 0, bez zmian w rejestrze (B3)
- **Nie testowano na VM**: Generalize/PostGeneralize (Sysprep, OOBE, AutoLogon), okno Out-GridView, instalacje winget,
  C09/C10 w Test-SysprepReadiness (wymaga admina)

## Decyzje do podjęcia
1. ~~**Licencja i języki Office**~~ ✔ – gotowe szablony w `windows/install/Office/Templates` (ProPlus i Business Shared × PL, EN, DE, FR, PL+EN); wybór w kreatorze.
   Dawny opis: **Licencja Office**: w `Configuration_x64.xml` jest `O365BusinessRetail` (Microsoft 365 Apps for business).
   Uczelnia (A3/A5) zwykle potrzebuje `O365ProPlusRetail`. SCA z `O365BusinessRetail` działa tylko z Business Premium.
2. ~~**Języki Office**~~ ✔ (szablony + presety w kreatorze). Dawny opis: obecnie `pl-pl` + `en-gb` (pełne pakiety). Kreator proponuje jeden język + opcjonalnie tylko ProofingTools.
   Uruchom `-Mode Configure` albo podaj wybór.
3. **Teams**: w `Optimize.json` zaznaczone „Turn off notifications from apps and other senders” (synchronizowane do Default User)
   → brak powiadomień Teams o czacie/połączeniach. Kreator odznacza je, jeśli wybierzesz zachowanie powiadomień.
4. **OneDrive**: `Optimize.json` usuwa OneDrive („Remove OneDriveSync”). Dla Firmy (Known Folder Move) kreator to odznacza.
5. „Let Windows apps run in the background” (zaznaczone) – do sprawdzenia na klonie, czy nie blokuje Teams w tle.
6. **Wersja Horizon a wydanie Windows**: Horizon **2506 nie wspiera 25H2** (KB 78714) – obraz produkcyjny na 2506 = **24H2**
   (Ent/Edu do 2027-10-12; Pro tylko do 2026-10-13). 25H2 wymaga agenta i Connection Servera 2512+ (2512.1/2603/2606).
   **26H2** (GA 2026-09-29, kompilacja 26300) nie jest jeszcze wspierany przez Horizon ani OSOT → tylko pula pilotażowa.
   Decyzja: kiedy aktualizować backend Horizon i na które wydanie Windows budować obraz produkcyjny.

## Otwarte problemy
| # | Ważność | Problem |
|---|---|---|
| S1 | średnia | Brak kontroli ACL `C:\install` (PreScript, OSOT, zadanie SYSTEM) – eskalacja uprawnień przy zapisie przez użytkowników |
| S4 | średnia | Wyszukiwanie WU bez `BrowseOnly=0`; wynik `Download()` niesprawdzany |
| S7 | średnia | `Get-NormalizedName` usuwa lata (VC++ 2013/2015) |
| S8 | średnia | MSU checkpoint (24H2+) instalowane pojedynczo |
| S10 | niska | Dry-run rozpakowuje ZIP-y; brak odświeżania rozpakowanej kopii |
| S11 | niska | Pomoc skryptu częściowo nieaktualna (np. „FSLogix nie jest aktualizowany”) |
| – | średnia | Parametry cichej instalacji Horizon Agent ustawione wg dokumentacji Omnissa 2603 (`VDM_VC_MANAGED_AGENT=1`, ADDLOCAL Core+NGVC) – do sprawdzenia na VM (Teams Media Optimized, Instant Clone) |

## Plan
1. ~~Git~~ ✔ · 2. ~~B1–B7~~ ✔ · 2a. ~~Generalize/PostGeneralize~~ ✔ · 2b. ~~Configure + winget~~ ✔
3. **Test na VM** (budowa od ISO: tryb audytu → Update → Optimize → Generalize → PostGeneralize) i poprawki po teście
4. ~~Moduł + i18n~~ ✔ (2026-10-01: `install/Modules/VDI-ImageMaint`, 407 komunikatów EN/PL, `-Language`); ~~`-Mode Download`~~ ✔ (7 pakietów, test z prawdziwym pobieraniem); ~~tłumaczenie Set-FSLogixConfig~~ ✔
5. ~~Pester~~ ✔ (60 testów, PS 5.1 + pwsh 7, PSScriptAnalyzer bez uwag); ~~walidacja manifestu~~ ✔ (`-Mode Validate`, schemat JSON); ~~szablony XML Office~~ ✔ (10 wariantów) (`-Mode Validate`, JSON Schema)
6. ~~Komponenty Horizon (ADDLOCAL, kolejność)~~ ✔ (restarty – test na VM), kontrola jakości klona (Teams Media Optimized, FSLogix, logowanie)
7. Raport HTML cyklu, vCenter/Horizon (snapshot, Push Image)
8. **Linux (Debian/Ubuntu)** – po zakończeniu narzędzia Windows
