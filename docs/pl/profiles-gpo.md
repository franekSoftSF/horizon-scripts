# Profile, OneDrive, GPO, DEM i FSLogix – zalecane ustawienia

> English version: [../profiles-gpo.md](../profiles-gpo.md).
> Części dotyczące OSOT i FSLogix z tabeli poniżej ustawia `-Mode Configure`. Ustawienia GPO i DEM trafiają
> do domeny, **nie** do obrazu. Pozycje oznaczone **(do weryfikacji)** trzeba sprawdzić na puli testowej,
> zanim wdrożysz je u klientów.

## 1. Profile obrazu

| Obszar | Uczelnia | Firma | Grafik / projektant (vGPU) |
|---|---|---|---|
| Efekty wizualne OSOT | `balanced` | `balanced` | `quality` + akceleracja GPU zostaje w Office/Edge/Adobe |
| Pozycje OSOT „Hardware Acceleration” (7) | zaznaczone (renderowanie programowe) | zaznaczone | **odznaczone** |
| Pamięć miniatur, zbieranie danych pióra | wyłączone | wyłączone | **zostają** (przeglądanie obrazów, tablety graficzne) |
| Powiadomienia aplikacji (połączenia i czat Teams) | zostają (domyślnie w kreatorze) | zostają | zostają |
| OneDrive | zależnie od klienta | **dla całej maszyny + KFM** | dla całej maszyny + KFM |
| FSLogix `SizeInMBs` | 30 000 | 50 000 | 100 000 |
| FSLogix `RoamIdentity` | – | tak | tak |
| Dodatkowe wykluczenia FSLogix | – | – | pamięć podręczna multimediów Adobe |
| Licencja Microsoft 365 (produkt ODT) | `O365ProPlusRetail` (A3/A5) | `O365ProPlusRetail` (E3/E5) lub `O365BusinessRetail` (tylko Business Premium) | jak dla Firmy |
| Propozycje winget | przeglądarki, 7-Zip, Reader, VLC, VC++ | to samo | + Inkscape, Blender, Krita |

### Grafik / projektant – poza OSOT
- **vGPU**: profil NVIDIA vGPU dobrany do aplikacji (np. 2–4 GB pamięci ramki dla 2D/Adobe, więcej dla 3D).
  Sterownik NVIDIA i token licencji instalujesz **przed** Generalize, tak jak VMware Tools.
- **Blast (GPO Horizon)**: *Max Frame Rate* podnieś do 60 i włącz *High Color Accuracy* (H.264 4:4:4) albo HEVC
  do pracy z wiernymi kolorami. To zwiększa zużycie łącza, więc stosuj to tylko w puli graficznej. **(do weryfikacji z urządzeniami klienckimi)**
- **Zarządzanie kolorem**: profile ICC monitorów są na urządzeniu klienckim. Horizon przesyła obraz, nie profil ICC. **(do weryfikacji)**
- **Tablety graficzne (Wacom itp.)**: przekierowanie USB albo obsługa pióra w Horizon, zależnie od modelu. **(do weryfikacji)**
- **Adobe Creative Cloud**: pakiet budujesz w Adobe Admin Console. Named User Licensing dla pracowników,
  Shared Device Licensing dla laboratoriów studenckich. Sprawdź aktualne stanowisko Adobe wobec nietrwałego VDI. **(do weryfikacji)**
- **Dyski robocze i pamięć podręczna**: dyski robocze i pamięć podręczną multimediów Photoshop/Premiere kieruj na lokalny
  dysk nietrwały, nie do kontenera FSLogix. Pamięć podręczną multimediów Adobe kreator wyklucza z kontenera.
- **Czcionki**: instaluj w obrazie dla całej maszyny. Czcionki per użytkownik trafiałyby do każdego kontenera.

## 2. OneDrive, który nie rozjeżdża się na nietrwałym VDI

Typowe powody, dla których OneDrive „się rozjeżdża” na Instant Clone, i sposób naprawy każdego z nich:

| Przyczyna | Rozwiązanie |
|---|---|
| OneDrive zainstalowany **per użytkownik** (domyślnie w Windows): na każdym nowym klonie instaluje się i synchronizuje od nowa | Instalacja **dla całej maszyny**: `OneDriveSetup.exe /allusers` (pakiet `OneDrive` w `packages.json`, włącza go kreator). Co miesiąc wgraj aktualny `OneDriveSetup.exe` do `Apps\` |
| OSOT usuwa OneDrive (`Remove OneDriveSync`) | Kreator odznacza te pozycje OSOT, gdy odpowiesz, że OneDrive ma zostać |
| Pamięć podręczna OneDrive poza kontenerem profilu albo z niego wykluczona | FSLogix **Profile Container** trzyma `%LocalAppData%\Microsoft\OneDrive` w VHDX. **Nie** wykluczaj tego folderu (wykluczone jest tylko `OneDrive\logs`) |
| **Known Folder Move i przekierowanie folderów jednocześnie** (GPO albo DEM) | Wybierz **jedno**. Z OneDrive: tylko KFM, bez GPO *Folder Redirection* i bez przekierowania folderów w DEM dla Pulpitu, Dokumentów i Obrazów |
| Kontener zapełnia się pobranymi plikami | Pliki na żądanie + odwadnianie przez Storage Sense (polityki poniżej). Rozmiar kontenera dobierasz do pamięci podręcznej, nie do całego OneDrive |
| Pytanie o logowanie na każdym klonie | Ciche logowanie (`SilentAccountConfig`) przy hybrydowym dołączeniu do Entra / SSO. FSLogix `RoamIdentity=1` trzyma tokeny Entra ID w kontenerze **(do weryfikacji na Instant Clone dołączonych hybrydowo)** |
| Stara wersja OneDrive w obrazie | Seal blokuje aktualizator OneDrive na klonach, więc `OneDriveSetup.exe` odświeżasz w każdym cyklu miesięcznym |

### Polityki OneDrive (Komputer, ADMX OneDrive – `HKLM\SOFTWARE\Policies\Microsoft\OneDrive`)
| Polityka | Wartość |
|---|---|
| Silently sign in users to the OneDrive sync app with their Windows credentials (`SilentAccountConfig`) | Włączona |
| Use OneDrive Files On-Demand (`FilesOnDemandEnabled`) | Włączona |
| Silently move Windows known folders to OneDrive (`KFMSilentOptIn`) | Włączona, identyfikator dzierżawy; Pulpit, Dokumenty, Obrazy |
| Prevent users from moving their Windows known folders back to their PC (`KFMBlockOptOut`) | Włączona |
| Prevent users from syncing personal OneDrive accounts (`DisablePersonalSync`) | Włączona (Firma) |
| Allow syncing OneDrive accounts for only specific organizations (`AllowTenantList`) | Identyfikator dzierżawy (Firma) |

Storage Sense (Komputer, *System > Storage Sense*): *Allow Storage Sense* = Włączona,
*Configure Storage Sense Cloud Content dehydration threshold* = np. 14 dni.

## 3. GPO – propozycja

### Komputer (OU puli VDI, przetwarzanie sprzężenia zwrotnego = Merge)
| Obszar | Ustawienie | Wartość |
|---|---|---|
| Windows | Turn off Microsoft consumer experiences | Włączone |
| Windows | Show first sign-in animation | Wyłączone |
| Windows | Configure Logon Script Delay | Włączone, 0 minut |
| Windows | Always wait for the network at computer startup and logon | Zostaw **nieskonfigurowane**, chyba że używasz instalacji oprogramowania przez GPO albo przekierowania folderów |
| Windows Update | (nic) – aktualizacje robisz tylko w obrazie wzorcowym (Seal je blokuje) | – |
| Horizon Agent (ADMX Omnissa) | Enable Media Optimization for Microsoft Teams | Włączone |
| Horizon Blast | Max Frame Rate | 30 (biuro), 60 (pula graficzna) |
| Horizon Blast | High Color Accuracy / HEVC | tylko pula graficzna **(do weryfikacji)** |
| Horizon | Przekierowanie schowka, dysków klienta, USB | Przez DEM Horizon Smart Policies (osobno dla puli i lokalizacji) |
| FSLogix (ADMX) | Ustawienia Profile Container | **Albo** GPO, **albo** `Set-FSLogixConfig.ps1` w obrazie – nie jedno i drugie. GPO wygrywa i łatwiej je zmienić bez nowego obrazu |
| Microsoft Edge | Startup boost (`StartupBoostEnabled`) | Wyłączone |
| Microsoft Edge | Continue running background apps when Edge is closed (`BackgroundModeEnabled`) | Wyłączone |
| Microsoft Edge | Hide the first-run experience (`HideFirstRunExperience`) | Włączone |
| Microsoft Edge | Sleeping tabs (`SleepingTabsEnabled`) | Włączone |
| Microsoft 365 Apps | Aktualizacje automatyczne | Wyłączone (także w XML ODT i przez Seal) |
| Outlook | Okres synchronizacji trybu buforowanego Exchange | 1 miesiąc (Uczelnia), 3 miesiące (Firma). Plik OST zostaje w kontenerze FSLogix |
| Teams | nic więcej dla nowego Teams na Horizon poza Media Optimization powyżej | – |

### Użytkownik
| Obszar | Ustawienie | Wartość |
|---|---|---|
| Office | Wyłączenie okien pierwszego uruchomienia i prywatności | Włączone |
| OneDrive | (wszystko w części Komputer) | – |
| Start / pasek zadań | Układ przypiętych elementów | przez DEM albo plik XML układu, nie przez skrypty GPO per użytkownik |

## 4. DEM (Dynamic Environment Manager) – jak podzielić pracę z FSLogix

Zasada: **FSLogix trzyma cały profil, DEM tylko konfiguruje.** Podwójny roaming (kontener FSLogix i personalizacja
DEM tej samej aplikacji) to najczęstszy powód, dla którego ustawienia się rozjeżdżają.

| Używaj DEM do | **Nie** używaj DEM do (przy FSLogix Profile Container) |
|---|---|
| Horizon Smart Policies: schowek, USB, dyski klienta, drukowanie, przepustowość – osobno dla puli i lokalizacji klienta | Personalizacji aplikacji, których dane są już w kontenerze (Office, Teams, przeglądarki, OneDrive) |
| Mapowania dysków, drukarek, zmiennych środowiskowych, skrótów, skojarzeń plików | Przekierowania Pulpitu, Dokumentów i Obrazów, gdy włączony jest OneDrive KFM |
| Zestawów warunków (pula, grupa AD, zakres IP klienta) – np. brak pamięci USB w pulach studenckich | Roamingu pamięci podręcznych z `AppData\Local` |
| Blokowania aplikacji (laboratoria), podnoszenia uprawnień dla wybranych instalatorów | |

ADMX DEM: *Run FlexEngine as Group Policy Extension* = Włączone. Udział konfiguracji na DFS blisko pul,
udział archiwów profili tylko wtedy, gdy cokolwiek personalizujesz.

## 5. FSLogix – według profilu

Wspólne dla wszystkich (ustawia `Set-FSLogixConfig.ps1`):
- dynamiczny VHDX, `DeleteLocalProfileWhenVHDShouldApply=1`, `FlipFlopProfileDirectoryName=1`,
  `PreventLoginWithFailure=1`, `PreventLoginWithTempProfile=1`, wykluczenia pamięci podręcznych w `redirections.xml`,
- wykluczenia antywirusa dla VHD(X), procesów FSLogix i folderów Horizon/App Volumes/DEM.

| | Uczelnia | Firma | Grafik |
|---|---|---|---|
| `SizeInMBs` | 30 000 | 50 000 | 100 000 |
| Grupa z kontenerem | studenci + pracownicy | pracownicy | graficy |
| Wykluczeni | administratorzy obrazu | administratorzy obrazu | administratorzy obrazu |
| `RoamIdentity` | opcjonalnie | 1 | 1 |
| Udział | SMB z ciągłą dostępnością, wykluczenia AV na serwerze plików | to samo | to samo, na szybszej pamięci masowej (duże VHDX i pliki) |
| Cloud Cache | tylko przy wielu lokalizacjach | tylko przy wielu lokalizacjach | niezalecane (duże kontenery) |
