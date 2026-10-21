# Oprogramowanie XAS (Demeter, Larch / Larix) na Instant Clone

> English version: [../demeter.md](../demeter.md)

Dwa pakiety dla zajęć z XAS / EXAFS, ten sam zestaw co na obrazie Linux (`libdemeter-perl`, `python3-xraylarch` /
Larix, ifeffit, feff):

| Pakiet | Programy | Skrypt | Folder |
|---|---|---|---|
| `Demeter` | Athena, Artemis, Hephaestus, Atoms (Perl, Ifeffit, Feff) | `Scripts\Install-Demeter.ps1` | `C:\DemeterPerl` |
| `Larch` | Larix (GUI XANES / EXAFS, Feff), przeglądarki XRF / XRFMap / XRD1D, Larch CLI, Jupyter Lab (Python) | `Scripts\Install-Larch.ps1` | `C:\xraylarch` |

Oba oryginalne instalatory są **per-user**; oba skrypty robią z nich instalację dla wszystkich według tego samego
wzorca: stały folder bez spacji, Użytkownicy tylko odczyt + wykonanie, launchery `<folder>\vdi\*.cmd` ustawiające
środowisko dla procesu, grupa w menu Start dla wszystkich, test działania i wpis odinstalowania uruchamiający kopię
skryptu z `<folder>\vdi`. Wcześniejsze kopie per-user w dowolnym lokalnym profilu są usuwane ich deinstalatorem.

## Demeter

Demeter (<https://bruceravel.github.io/demeter/>) to pakiet do obróbki danych XAS / analizy EXAFS działający na
dołączonym Strawberry Perl.

### Dlaczego zwykły instalator nie działa na VDI

`Demeter_<wersja>_with_Strawberry_Perl_(64).exe` (Inno Setup, `PrivilegesRequired=lowest`,
[strawberry.iss](https://github.com/bruceravel/demeter/blob/master/win/inno/strawberry.iss)) to instalator **per-user**:

| Co | Oficjalny instalator | Skutek na złotym obrazie |
|---|---|---|
| Folder | `%APPDATA%\DemeterPerl` konta instalującego | inni użytkownicy go nie widzą |
| `PATH` (perl\bin, perl\site\bin, c\bin) i `PGPLOT_DIR` | `HKCU\SYSTEM\CurrentControlSet\Control\Session Manager\Environment` – klucz, którego Windows nigdy nie czyta | `dathena.bat` nie znajduje `perl.exe` / PGPLOT → programy się nie uruchamiają |
| Menu Start | grupa konta instalującego | nikt inny nie widzi skrótów |
| Skojarzenia `.pl` / `.prj` / `.fpj` | zapisane w **korzeniu** `HKCU` (nie `Software\Classes`) | nigdy nie działały |

Czyli „instalacja przeszła, ale u użytkowników programy się nie uruchamiają” to spodziewany efekt.

### Co robi `Scripts\Install-Demeter.ps1` 1.1

0. Usuwa wcześniejsze kopie per-user (wpis odinstalowania tego konta, `%APPDATA%\DemeterPerl` każdego lokalnego
   profilu) ich `unins000.exe` (czeka na kopię deinstalatora, którą Inno Setup uruchamia z `%TEMP%`) razem z grupą
   menu Start tego profilu.
1. Instaluje cicho do **`C:\DemeterPerl`** (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /TASKS="" /DIR=... /LOG=...`).
   Ścieżka bez spacji (wymóg Strawberry Perl). Krok `[Run]` instalatora `relocation.pl.bat` nie ma flagi
   `postinstall`, więc wykonuje się także w trybie cichym i przepisuje ścieżki Perla; krok 5 to sprawdza. Istniejącą
   instalację z tym samym AppId (także naszą) instalator sam odinstalowuje przed aktualizacją.
2. Sprząta pozostałości per-user konta instalującego (wartości PATH / `PGPLOT_DIR` z tabeli i puste potem klucze
   `HKCU\SYSTEM\...`, `HKCU\Environment`, błędne klucze w korzeniu HKCU, jego grupa w menu Start / ikony na
   pulpicie) i ukrywa własny wpis odinstalowania instalatora.
3. Uprawnienia: Użytkownicy odczyt + wykonanie, Administratorzy / SYSTEM pełne (podfoldery `C:\` dają domyślnie
   Użytkownikom uwierzytelnionym Modyfikację). Sprawdzana jest próbka istniejących plików; jeśli któryś nadal jest
   zapisywalny dla użytkowników, drzewo dostaje dziedziczone uprawnienia (`icacls <folder>\* /reset /T`).
4. Launchery `C:\DemeterPerl\vdi\Athena.cmd`, `Artemis.cmd`, `Hephaestus.cmd`, `Stand-alone-Atoms.cmd` ustawiają
   `PATH` (Demeter na początku) i `PGPLOT_DIR` dla procesu i tworzą `%APPDATA%\demeter` (logi, stash – w kontenerze
   FSLogix). Grupa **Demeter** w menu Start dla wszystkich. `PATH` maszyny bez zmian, chyba że `-AddToPath`
   (`c\bin` ze Strawberry zawiera gcc i DLL-e, które potrafią zepsuć inne programy).
5. `-Associate`: `.prj` → Athena, `.fpj` → Artemis w `HKLM\SOFTWARE\Classes`; `.prj` pominięte, jeśli należy już do
   innego programu (pliki projekcji ArcGIS / QGIS).
6. Test `perl.exe -MConfig -MDemeter` (wersja Demeter + prefiks Perla w `C:\DemeterPerl` = relokacja wykonana),
   wpis odinstalowania *Demeter (Athena, Artemis, Hephaestus)* z wersją.

Idempotentny: ta sama wersja nie jest instalowana ponownie, kroki 0 i 2–6 są stosowane od nowa. Działa `-WhatIf` i
`-Uninstall`; działa jako administrator albo SYSTEM (`-AsSystem`). Log:
`C:\ProgramData\VDI-ImageMaint\Logs\Demeter_<data>.log`, log instalatora `DemeterSetup_<data>.log`.

### Użycie

1. Instalator 64-bit do `C:\install\Apps\Demeter\` (albo włącz `Demeter` w `C:\install\downloads.json`).
2. Pakiet `Demeter` w `packages.json` (`Enabled: true`) → `-Mode Update` / `Install`, albo bezpośrednio:

   ```powershell
   C:\install\Scripts\Install-Demeter.ps1 -Associate
   ```

3. Test na klonie jako **zwykły użytkownik** (nie konto instalujące): Athena, Artemis, Hephaestus z menu Start,
   otwarcie projektu, przebieg Feff w Artemis. Potem Seal + Push Image.

### Uwagi

- Demeter 0.9.26 (2018) to ostatnie wydanie dla Windows; brak aktualizatora. Instalator nie jest podpisany.
- Ustawienia i logi użytkownika są w `%APPDATA%\demeter` (kontener FSLogix) – nic do wykluczania.
- Launcher Perla trzyma zminimalizowane okno konsoli, dopóki program działa – to normalne.

## Larch / Larix

Larch (<https://xraypy.github.io/xraylarch/>) to biblioteka Pythona do analizy XAS / XRF; **Larix** to jej GUI do
XANES / EXAFS (następca Athena / Artemis, z wbudowanym Feff 6 i 8).

### Oficjalny instalator

`xraylarch-<RRRR-MM>-Windows-x86_64.exe` (~500 MB, z <https://millenia.cars.aps.anl.gov/xraylarch/downloads/>) to
instalator conda [constructor](https://github.com/xraypy/xraylarch/tree/master/installers/conda_constructor) (NSIS):

| Co | Oficjalny instalator (interaktywnie) | Skutek na złotym obrazie |
|---|---|---|
| Folder | `C:\Users\<nazwa>\xraylarch` albo `%LOCALAPPDATA%\xraylarch` (domena) | inni użytkownicy go nie widzą |
| Sam Larch | nie ma go w instalatorze: skrypt poinstalacyjny robi `pip install "xraylarch[larix]"` z PyPI | potrzebny internet podczas instalacji |
| Skróty | `larch -m` (pyshortcuts): folder `Larch` na pulpicie + menu Start konta instalującego | nikt inny ich nie widzi |
| Aktualizacje | skrót „Update Larch” / `larch -u` = pip do folderu instalacji | musi zostać zadaniem administratora |

Udokumentowane [opcje wiersza poleceń](https://conda.github.io/constructor/cli-options/) constructora pozwalają na
cichą instalację dla wszystkich – z tego korzysta skrypt.

### Co robi `Scripts\Install-Larch.ps1` 1.0

0. Usuwa wcześniejsze kopie per-user (`Uninstall-xraylarch.exe` w `<profil>\xraylarch` albo
   `<profil>\AppData\Local\xraylarch` każdego lokalnego profilu: `/S _?=<folder>`, potem folder) i foldery
   `Desktop\Larch` / `Larch` w menu Start tego profilu.
1. Instaluje cicho środowisko bazowe conda dla wszystkich do **`C:\xraylarch`** (bez spacji – wymóg Larch):

   ```text
   xraylarch-2026-03-Windows-x86_64.exe /S /InstallationType=AllUsers /AddToPath=0 /RegisterPython=0
       /NoShortcuts=1 /NoScripts=1 /KeepPkgCache=0 /D=C:\xraylarch
   ```

   `/D=` na końcu i bez cudzysłowów (NSIS). `/NoScripts=1` pomija skrypt poinstalacyjny: żadnego pip bez logu ani
   ikon na pulpicie konta instalującego. Nowszy instalator (wydanie w nazwie pliku) zastępuje folder – instalatory
   conda nie aktualizują w miejscu.
2. `python.exe -m pip install --no-cache-dir "xraylarch[larix]"` w środowisku conda, log `LarchPip_<data>.log`;
   tylko po instalacji, z `-Upgrade` (najnowszy xraylarch z PyPI między wydaniami instalatora) albo gdy
   `import larch` się nie udaje. `-Requirement 'xraylarch[larix]==2026.3.1'` przypina wersję. **Wymaga HTTPS do
   `pypi.org` i `files.pythonhosted.org`** (także z konta SYSTEM przy `-AsSystem` – sprawdź proxy).
3. Usuwa `Desktop\Larch` / `Larch` w menu Start konta instalującego (starsze instalatory bez `/NoScripts`) i ukrywa
   własny wpis odinstalowania constructora.
4. Uprawnienia jak przy Demeter: Użytkownicy odczyt + wykonanie – użytkownicy nie doinstalują nic pipem do
   wspólnego środowiska.
5. Launchery `C:\xraylarch\vdi\*.cmd` ustawiają `PATH` jak `conda activate` (`<folder>`, `Library\mingw-w64\bin`,
   `Library\usr\bin`, `Library\bin`, `Scripts`, `bin`), `CONDA_PREFIX`, `PYTHONNOUSERSITE=1` (własne pakiety
   `pip --user` nie zepsują programów) i startują w `%USERPROFILE%`. Grupa **Larch** w menu Start dla wszystkich:
   Larix, XRF Viewer, XRFMap Viewer, XRD1D Viewer, Sitka, Jupyter Lab, Larch CLI (te, których `Scripts\*.exe`
   istnieją). Skrót „Update Larch” z oryginału jest celowo pominięty.
6. Test `python -c "import larch, wx"`, wpis odinstalowania *Larch / Larix (xraylarch)* z wersją xraylarch
   (wartość `InstallerRelease` = wydanie instalatora, do idempotencji).

Idempotentny, `-WhatIf`, `-Uninstall`, administrator albo SYSTEM – jak Demeter. Logi:
`C:\ProgramData\VDI-ImageMaint\Logs\Larch_<data>.log`, `LarchSetup_<data>.log`, `LarchPip_<data>.log`.

### Użycie

1. Instalator do `C:\install\Apps\Larch\` (albo włącz `Larch` w `C:\install\downloads.json` – najnowsze wydanie
   czytane jest z listingu folderu pobierania).
2. Pakiet `Larch` w `packages.json` (`Enabled: true`) → `-Mode Update` / `Install`, albo bezpośrednio:

   ```powershell
   C:\install\Scripts\Install-Larch.ps1            # -Upgrade = najnowszy xraylarch z PyPI
   ```

3. Test na klonie jako **zwykły użytkownik**: Larix z menu Start, wczytanie pliku danych, przebieg Feff; XRF
   Viewer. Potem Seal + Push Image.

### Uwagi i ograniczenia

- Dane użytkownika trafiają do kontenera FSLogix: `%USERPROFILE%\.larch` (ustawienia, historia, przebiegi Feff),
  `%USERPROFILE%\.matplotlib` (cache czcionek – pierwsze uruchomienie u użytkownika jest wolniejsze),
  `%APPDATA%\jupyter`. W czasie pracy nic nie jest zapisywane do `C:\xraylarch`.
- Larix przy starcie sprawdza w PyPI nowszą wersję i może zaproponować aktualizację – użytkownik jej nie wykona
  (folder tylko do odczytu); aktualizuj obraz przez `-Upgrade` albo nowy instalator.
- Instalator nie jest podpisany Authenticode (nie sprawdzone – wpis pobierania nie ma `Signer`); pobieraj tylko z
  oficjalnego folderu podanego wyżej.
- Zestaw opcji (`/NoScripts`, `/NoShortcuts`, `/KeepPkgCache`) pochodzi z obecnych wersji constructora; starszy
  instalator ignoruje nieznane opcje – wtedy wykona też swój skrypt poinstalacyjny (pip + ikony tego konta), co
  kroki 2 i 3 tolerują / sprzątają.
