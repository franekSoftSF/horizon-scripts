# Horizon Scripts – VDI-ImageMaint

> English version: [README.md](README.md).

Narzędzia do utrzymania złotego obrazu (golden image) dla pulpitów **Omnissa Horizon Instant Clone**:

| Narzędzie | Platforma | Folder |
|---|---|---|
| **VDI-ImageMaint dla Windows** (moduł PowerShell 2.0) | Windows 11 Enterprise/Education, Horizon 2506+, FSLogix, DEM, App Volumes, Microsoft 365 Apps, nowe Teams | [`windows/`](windows/) |
| **VDI-ImageMaint dla Linuksa** (Bash) | Debian 12 + MATE, Horizon Linux Agent, SSSD, True SSO / karta inteligentna, NFSv4 + Kerberos | [`linux/`](linux/) |

Oba narzędzia działają w tym samym cyklu – **Update → Optimize → Seal**, z możliwością cofnięcia przez
**Unlock** – i komunikują się z administratorem **po polsku lub po angielsku**.

> Stan: kod jest sprawdzony statycznie i pokryty testami offline (Pester 5 w Windows PowerShell 5.1 i
> PowerShell 7, PSScriptAnalyzer; testy Bash w kontenerze `debian:12`, shellcheck). Pełny cykl wymaga jeszcze
> testu na prawdziwej maszynie Horizon. Aktualny stan: [`status.md`](status.md).

---

## Po co ten projekt

Pula Instant Clone jest tak dobra, jak jej złoty obraz. Każdy klon powstaje z tego samego snapshotu i jest
usuwany po wylogowaniu, więc każdy błąd w obrazie powiela się na setki pulpitów:

- **Oczekujący restart, trwająca aktualizacja albo niedoinstalowana aplikacja** w snapshocie → każdy klon
  powtarza to przy logowaniu (wolne logowanie, skoki CPU, niedziałające aplikacje).
- **Oprogramowanie, które samo się aktualizuje** (Office, Teams, przeglądarki, Adobe, Java), robi to w każdym
  klonie i traci wynik po wylogowaniu – zmarnowane CPU, dysk i sieć, a na każdym pulpicie inna wersja.
- **Pominięte optymalizacje** (OSOT, usługi, zadania harmonogramu) i **niewyczyszczone cache/logi** powiększają
  obraz i spowalniają logowanie.
- **Agenty infrastruktury** (VMware Tools, Horizon Agent, DEM, App Volumes, FSLogix) muszą pasować do wersji
  backendu i być instalowane we właściwej kolejności, z właściwymi funkcjami.
- **Ręczne łatanie co miesiąc** jest wolne, podatne na błędy i za każdym razem inne – zwłaszcza gdy zależy od
  notatek jednego administratora.

VDI-ImageMaint zamienia to w **powtarzalną, logowaną i odwracalną procedurę**:

1. **Update** – Windows Update, Microsoft 365 Apps, nowe Teams, Edge, aplikacje winget i pakiety z manifestu
   (`packages.json`), z automatycznymi restartami i wznawianiem.
2. **Optimize** – Omnissa OS Optimization Tool (OSOT) z szablonem dobranym do profilu, uruchamiany jako
   administrator (nigdy jako SYSTEM), aby ustawienia HKCU trafiły do Default User.
3. **Seal** – wyłącza wszystkie mechanizmy samoaktualizacji, zatrzymuje usługi, czyści cache, logi i dzienniki
   zdarzeń, sprawdza, czy nie czeka restart, i zapisuje każdą zmianę w `seal-state.json`.
4. **Unlock** – czyta `seal-state.json` i cofa dokładnie to, co zmienił Seal, więc kolejne okno serwisowe
   zaczyna się od czystego, zapisywalnego obrazu.

Dwie fazy są celowo rozdzielone (zob. [`windows/docs/pl/image-lifecycle.md`](windows/docs/pl/image-lifecycle.md)):

- **Build** – raz na wydanie funkcji Windows: instalacja z ISO, agenty infrastruktury, Generalize (Sysprep),
  potem pierwszy Update/Optimize/Seal.
- **Day-2** – co miesiąc: Unlock → Update → Optimize → Seal, **bez** Generalize, potem nowy snapshot i
  *Push Image* w Horizon.

### Zasady projektu

- **Idempotentność** – dwukrotne uruchomienie kroku daje ten sam wynik; każdy krok można wznowić po restarcie.
- **Odwracalność** – każda zmiana Seal jest zapisana i cofana przez Unlock.
- **Świadomość Instant Clone** – bez zerowania/kompaktowania dysku w OSOT Finalize, bez oczekującego restartu
  przy Seal, optymalizacja mediów Teams na miejscu, FSLogix wyklucza tylko foldery zalecane przez Microsoft.
- **Sterowanie manifestem** – aplikacje są opisane w `packages.json` (polecenie instalacji, wykrywanie, źródło
  wersji, akcja przy Seal) i sprawdzane przez `-Mode Validate` (JSON Schema z podpowiedziami w edytorze).
- **Dwujęzyczność** – angielski to główny język kodu, logów i dokumentacji; każdy komunikat dla użytkownika
  istnieje też po polsku (`-Language auto|en|pl`).
- **Nic poufnego w gicie** – instalatory, ISO, certyfikaty i lokalna konfiguracja są poza repozytorium
  (skąd pobrać każdy plik: `windows/docs/pl/downloads.md`).

---

## Przypadek 1 – Uczelnia (studenci i pracownicy, wspólne pracownie)

**Sytuacja.** Uczelnia utrzymuje jedną lub kilka pul Instant Clone dla pracowni komputerowych, biblioteki i
dostępu zdalnego. Tysiące studentów loguje się na wspólne pulpity; sesje są krótkie i rozłożone w ciągu dnia,
ze szczytami na początku zajęć. Obrazy muszą zawierać oprogramowanie dydaktyczne (Java/Eclipse, IDE, statystyka,
pakiet biurowy, przeglądarki) i są przebudowywane między semestrami. Dział IT jest mały i często korzysta z
pomocy studentów.

**Jakie problemy rozwiązuje VDI-ImageMaint**

- **Burze logowań** na początku zajęć – szablon OSOT `balanced`, usunięte aplikacje ze Sklepu (poza
  Kalkulatorem, Zdjęciami, Wycinanie, Karteczkami i Teams), wyłączone samoaktualizacje, nic oczekującego
  w snapshocie.
- **Wielu użytkowników, mało miejsca** – kontenery FSLogix po 30 GB na użytkownika, foldery cache wykluczone
  przez `redirections.xml`, lokalny profil usuwany po wylogowaniu.
- **Oprogramowanie dydaktyczne zmieniające się co semestr** – aplikacje są w manifeście; `-Mode Download`
  pobiera instalatory, `-Mode Validate` sprawdza manifest przed oknem serwisowym.
  Przykład: Temurin JDK 21/25 i Eclipse IDE instalowane dla całej maszyny, z workspace w kontenerze FSLogix
  (zob. [`windows/docs/pl/eclipse-java.md`](windows/docs/pl/eclipse-java.md)).
- **Licencje** – Microsoft 365 Apps for enterprise (`O365ProPlusRetail`, A3/A5) z aktywacją na komputerze
  współdzielonym (Shared Computer Activation); gotowe szablony wdrożenia Office dla języków (PL, EN, DE, FR, PL+EN).
- **Pracownie linuksowe** – narzędzie Linux buduje pulpity Debian 12 + MATE dołączone do Active Directory przez
  SSSD, z katalogami domowymi NFSv4 z Kerberos, opcjonalnym logowaniem kartą / True SSO oraz Eclipse + Java do
  zajęć z programowania. `seal` blokuje instalację pakietów i ukrywa okienka aktualizacji, więc studenci nie
  zmienią obrazu.
- **Przekazywanie pracy między osobami** – jedno menu (`START.cmd` w Windows, `vdi-imagemaint.sh` bez
  argumentów w Linuksie) prowadzi przez kroki po kolei, po polsku lub angielsku, a każde uruchomienie jest
  logowane.

## Przypadek 2 – Klienci korporacyjni (pracownicy biurowi, intensywne użycie Teams)

**Sytuacja.** Firma udostępnia pulpity pracownikom biurowym, którzy spędzają dzień w Microsoft Teams, Outlooku,
OneDrive/SharePoint i aplikacjach biznesowych. Użytkownicy oczekują tego samego co na laptopie: pliki, podpisy
i ustawienia Teams są zawsze z nimi, rozmowy i udostępnianie ekranu działają płynnie, a zasady bezpieczeństwa
są egzekwowane.

**Jakie problemy rozwiązuje VDI-ImageMaint**

- **Teams w VDI** – nowe Teams zainstalowane dla całej maszyny (`teamsbootstrapper -p`), automatyczna
  aktualizacja wyłączona w zapieczętowanym obrazie, Horizon Agent z funkcją *Media Optimization for Microsoft
  Teams*, OSOT nigdy nie usuwa aplikacji Teams, powiadomienia zostają włączone do czasu weryfikacji na klonie.
- **Dane i tożsamość użytkownika** – OneDrive dla całej maszyny z Known Folder Move, kontenery FSLogix po 50 GB
  z `RoamIdentity`, DEM dla ustawień aplikacji i przekierowania folderów (zalecany podział GPO/DEM/FSLogix:
  [`windows/docs/pl/profiles-gpo.md`](windows/docs/pl/profiles-gpo.md)).
- **Bezpieczeństwo i zgodność** – antywirus, zapora, SmartScreen i Centrum zabezpieczeń pozostają włączone
  (Defender for Endpoint w trybie VDI), wykluczenia antywirusowe dla FSLogix/Horizon/App Volumes/DEM, kontrola
  gotowości do Sysprep (tylko odczyt) przed Generalize oraz log każdej zmiany na potrzeby audytu.
- **Przewidywalne łatanie co miesiąc** – `Update -ThenSeal` wykonuje cały cykl Day-2 jednym krokiem, a wydanie
  funkcji Windows jest przypięte (`Windows.TargetRelease`), dopóki Horizon i OSOT nie wspierają kolejnego.
- **Licencje** – `O365ProPlusRetail` (E3/E5) lub `O365BusinessRetail` (tylko Business Premium), wybierane
  w kreatorze.
- **Graficy i zaawansowani użytkownicy** – opcjonalny profil *Grafik* dla pul z vGPU: OSOT `quality`
  z zachowaną akceleracją sprzętową, kontenery 100 GB, cache mediów Adobe wykluczony z profilu.

### Podsumowanie profili

| Ustawienie | Uczelnia | Firma | Grafik (vGPU) |
|---|---|---|---|
| Efekty wizualne OSOT | `balanced` | `balanced` | `quality` + akceleracja GPU |
| FSLogix `SizeInMBs` | 30 000 | 50 000 | 100 000 |
| FSLogix `RoamIdentity` | opcjonalnie | tak | tak |
| OneDrive | wg klienta | dla maszyny + KFM | dla maszyny + KFM |
| Microsoft 365 Apps | `O365ProPlusRetail` (A3/A5) | `O365ProPlusRetail` (E3/E5) lub `O365BusinessRetail` | jak Firma |

---

## Szybki start – Windows

1. Skopiuj [`windows/install/`](windows/install/) do `C:\install` na maszynie ze złotym obrazem i dołóż
   binaria (Office, FSLogix, Horizon Agent, OSOT, …) zgodnie z [`windows/docs/pl/downloads.md`](windows/docs/pl/downloads.md).
2. Kliknij dwukrotnie `C:\install\START.cmd` (menu po polsku lub angielsku) albo uruchom kroki bezpośrednio:

```powershell
.\VDI-ImageMaint.ps1 -Mode Configure -Language pl             # kreator: profil, Office, FSLogix, Java/Eclipse, OSOT, aplikacje
.\VDI-ImageMaint.ps1 -Mode Validate                           # sprawdzenie packages.json
.\VDI-ImageMaint.ps1 -Mode Download                           # pobranie instalatorów
.\VDI-ImageMaint.ps1 -Mode Update -AutoReboot -ThenSeal -Shutdown   # cykl miesięczny jednym krokiem
.\VDI-ImageMaint.ps1 -Mode Unlock                             # przed kolejnym oknem serwisowym
.\VDI-ImageMaint.ps1 -Mode Status -Language pl
```

Logi i stan: `C:\ProgramData\VDI-ImageMaint\`. Zmiany: [`windows/CHANGELOG.md`](windows/CHANGELOG.md).

## Szybki start – Linux

Skopiuj [`linux/`](linux/) do `/opt/vdi-imagemaint`, skopiuj `vdi-imagemaint.conf.example` do
`vdi-imagemaint.conf`, a potem uruchom `sudo ./vdi-imagemaint.sh`, aby otworzyć menu.
Szczegóły: [`linux/docs/pl/linux.md`](linux/docs/pl/linux.md).

## Testy

```powershell
.\windows\tests\Invoke-Tests.ps1     # Pester 5 (PS 5.1 + pwsh 7) i PSScriptAnalyzer
```

```bash
linux/tests/run-tests.sh             # testy offline (uruchamiane w kontenerze debian:12)
```

## Dokumentacja

| Temat | Polski | Angielski |
|---|---|---|
| Cykl życia obrazu (Build i Day-2, OSOT, Teams, wydania Windows) | [image-lifecycle.md](windows/docs/pl/image-lifecycle.md) | [en](windows/docs/image-lifecycle.md) |
| Profile, OneDrive, GPO, DEM, FSLogix | [profiles-gpo.md](windows/docs/pl/profiles-gpo.md) | [en](windows/docs/profiles-gpo.md) |
| Skąd pobrać instalatory | [downloads.md](windows/docs/pl/downloads.md) | [en](windows/docs/downloads.md) |
| Java / Eclipse w Windows | [eclipse-java.md](windows/docs/pl/eclipse-java.md) | [en](windows/docs/eclipse-java.md) |
| Narzędzie dla Linuksa | [linux.md](linux/docs/pl/linux.md) | [en](linux/docs/linux.md) |
| Java / Eclipse w Linuksie | [linux-eclipse-java.md](docs/pl/linux-eclipse-java.md) | [en](docs/linux-eclipse-java.md) |

## Licencja

[MIT](LICENSE) © 2026 Szymon Frankiewicz. Instalatory i narzędzia firm trzecich (Omnissa OSOT, Horizon Agent, FSLogix,
Microsoft 365 Apps, …) nie są częścią repozytorium i mają własne licencje.

## Zastrzeżenie

Omnissa Horizon, Microsoft 365, FSLogix i inne nazwy produktów należą do ich właścicieli. Projekt nie jest
powiązany z nimi ani przez nie wspierany. Każdą zmianę przetestuj na puli pilotażowej przed wdrożeniem
produkcyjnym.
