# Eclipse IDE i Java na Instant Clone (FSLogix + przekierowanie folderów DEM)

> Wersja angielska: [../eclipse-java.md](../eclipse-java.md).
> Pozycje oznaczone **(sprawdź)** trzeba przetestować na puli testowej, zanim trafią do klientów.

## 1. Założenia

| Co | Gdzie | Dlaczego |
|---|---|---|
| Eclipse Temurin JDK 21 LTS | Obraz, `C:\Program Files\Eclipse Adoptium\jdk-21` (stały `INSTALLDIR`) | Ustawia `JAVA_HOME`, `PATH` i `.jar`. Stały folder nie zmienia ścieżki przy comiesięcznej aktualizacji MSI, więc Installed JREs, skrypty i `JAVA_HOME` dalej działają |
| Eclipse Temurin JDK 25 LTS | Obraz, `C:\Program Files\Eclipse Adoptium\jdk-25` | Tylko drugie JDK, bez `JAVA_HOME`/`PATH` |
| Eclipse IDE for Java Developers | Obraz, `C:\Program Files\Eclipse\java`, tylko do odczytu dla użytkowników | Instalacja współdzielona. IDE działa na dołączonym JRE JustJ, bo Eclipse 2026-09 wymaga Java 25 do startu |
| Workspace `%USERPROFILE%\eclipse-workspace` | Kontener profilu FSLogix | Kontener działa jak dysk lokalny, więc `.lock`, indeksy JDT i obserwowanie plików działają |
| `%USERPROFILE%\.eclipse` (konfiguracja i wtyczki użytkownika), `.m2`, `.gradle`, `.p2` | Kontener profilu FSLogix | Zostają między sesjami i klonami |
| Dokumenty, Pulpit (opcjonalnie Obrazy, Pobrane) | Przekierowanie folderów DEM na `\\fs01\Home$\%USERNAME%\...` | Wymiana plików, prace zaliczeniowe, kopie zapasowe na serwerze plików |
| Kod źródłowy | Git (GitLab / GitHub / Azure DevOps) | Historia i kopia zapasowa. Nie polegaj na samym kontenerze |

### Dlaczego workspace nie leży w przekierowanych Dokumentach (UNC)
- `.metadata\.lock` idzie przez SMB. Po rozłączonej sesji na innym klonie użytkownik widzi „Workspace in use or cannot be created”.
- Build tworzy tysiące małych plików (indeks JDT, `bin\`, `target\`). Każda operacja na pliku czeka na odpowiedź SMB, więc build i indeksowanie są wolne.
- Powiadomienia o zmianach plików przez SMB są zawodne. Eclipse pracuje wtedy na nieaktualnych zasobach i ciągle trzeba wciskać F5 (Refresh).

Projekty mogą dalej leżeć w przekierowanych Dokumentach. Wtedy dodaje się je przez **File → Import → Existing Projects into
Workspace** z zaznaczonym *Copy projects into workspace*. Lepszy wybór to Git.

## 2. Obraz (manifest `packages.json`)

| Id | Order | Typ | Plik (`C:\install\...`) | Co robi |
|---|---|---|---|---|
| `TemurinJDK21` | 60 | msi | `Apps\Java\OpenJDK21U-jdk_x64_windows_hotspot_*.msi` | `ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome INSTALLDIR=...\jdk-21` |
| `TemurinJDK25` | 61 | msi | `Apps\Java\OpenJDK25U-jdk_x64_windows_hotspot_*.msi` | `ADDLOCAL=FeatureMain INSTALLDIR=...\jdk-25` |
| `EclipseJava` | 62 | ps1 | `Scripts\Install-Eclipse.ps1` + `Apps\Eclipse\eclipse-java-<RRRR-MM>-R-win32-x86_64.zip` | Rozpakowuje i konfiguruje Eclipse (niżej) |

Pliki: `-Mode Download` (START.cmd opcja 2) pobiera wszystkie trzy (API Adoptium, bieżące wydanie EPP z
`release.xml`; sprawdza podpisy plików MSI i `eclipse.exe`). Można też pobrać je ręcznie, patrz
[downloads.md](downloads.md).

`Install-Eclipse.ps1` (działa też samodzielnie, obsługuje `-WhatIf`, komunikaty EN/PL):
1. Bierze najnowszy ZIP z `Apps\Eclipse` i porównuje jego wydanie z wpisem odinstalowania (`DisplayVersion` = `2026.09`).
   Nowe wydanie zastępuje folder. Gdy wydanie jest już zainstalowane, skrypt tylko ponownie stosuje konfigurację,
   co trwa około 1 s. Dlatego manifest używa `Detect: Always`.
2. W `eclipse.ini` ustawia domyślny workspace `@user.home/eclipse-workspace` i `-Declipse.pluginCustomization`.
   Opcjonalnie ustawia też `-data` (`-ForceWorkspace`: bez pytania o workspace, dla laboratoriów),
   `-Xmx` (`-MaxHeapMB`) i `-vm` (`-Vm`, tylko JDK >= `osgi.requiredJavaVersion`). Oryginał zostaje jako `eclipse.ini.orig`.
3. W `plugin_customization.ini` wyłącza automatyczne sprawdzanie aktualizacji (`p2.ui.sdk.scheduler`) oraz zadania
   startowe i rejestrator preferencji Oomph. Wyłącza też pobieranie indeksów Maven i włącza **wykrywanie JDK przy starcie**
   (`org.eclipse.jdt.launching/detectVMsAtStartup`). Eclipse sam znajduje wtedy JDK w `%ProgramFiles%\Eclipse Adoptium`
   i pokazuje je w Installed JREs i środowiskach wykonawczych **(sprawdź przy pierwszym logowaniu)**.
4. Dodaje skrót w menu Start dla wszystkich i wpis odinstalowania (`-Uninstall` usuwa wszystko).

**`-Mode Configure`, krok 3/8** ustawia to wszystko: JDK (21 + 25 / 21 / 25; pierwsze dostaje `JAVA_HOME`), pakiet Eclipse
(java / jee), workspace bez pytania (domyślnie tak dla profilu Uczelnia), `-Xmx` oraz opcjonalne wykluczenie cache
Maven/Gradle z FSLogix (dołączane do `-ExtraExcludes` w `FSLogixConfig`). Starsze manifesty dostają trzy pakiety z szablonu.

Opcje do `Arguments` w manifeście: `-Package jee` (Enterprise Java and Web), `-ForceWorkspace`, `-MaxHeapMB 3072`,
`-AllowUserUpdates` (niezalecane).

### Cykl aktualizacji
- **JDK** (Adoptium wydaje poprawki co kwartał): nowe MSI wrzuć do `Apps\Java` albo uruchom `-Mode Download`. MSI
  aktualizuje się w miejscu, do tego samego folderu.
- **Eclipse** (wydania w marcu, czerwcu, wrześniu i grudniu): nowy ZIP wrzuć do `Apps\Eclipse` albo uruchom `-Mode Download`.
  Skrypt zastępuje `C:\Program Files\Eclipse\java`. Każde nowe wydanie dostaje w kontenerze własny
  `%USERPROFILE%\.eclipse\<id>_<wersja>`. Stary zostaje (kilka MB). Wtyczki, które użytkownicy zainstalowali sami, trzeba zainstalować ponownie.
- **Seal**: Eclipse i Temurin nie mają usługi ani zadania aktualizacji. Sprawdzanie aktualizacji jest wyłączone w
  konfiguracji, a folder instalacji jest tylko do odczytu. Seal nie potrzebuje nic dodatkowego.

## 3. FSLogix

- `redirections.xml` nie wymaga zmian. **Nie** wykluczaj `eclipse-workspace` ani `.eclipse`.
- Rozmiar kontenera: cache Maven/Gradle rośnie do setek MB, czasem kilku GB. 30 GB (Uczelnia) zwykle wystarcza. Sprawdź po semestrze.
- Opcjonalnie, tylko przy bliskim mirrorze Maven (Nexus/Artifactory): wyklucz cache. Pobierają się wtedy od nowa w
  każdej sesji:
  `Set-FSLogixConfig.ps1 -VHDLocations '\\fs01\Profiles$' -ExtraExcludes '.m2\repository','.gradle\caches'`
- Przekierowane Dokumenty/Pulpit nie są w kontenerze (DEM kieruje je na UNC). Nie dodawaj ich do wykluczeń.

## 4. DEM – przekierowanie folderów na UNC

DEM Management Console → **User Environment → Folder Redirection** (warunek: pula Java albo grupa AD):

| Folder | Cel |
|---|---|
| Documents | `\\fs01\Home$\%USERNAME%\Documents` |
| Desktop | `\\fs01\Home$\%USERNAME%\Desktop` |
| Pictures, Downloads (opcjonalnie) | `\\fs01\Home$\%USERNAME%\Pictures`, `...\Downloads` |

- Przekierowuj **tylko** te foldery. Nigdy nie przekierowuj `AppData` ani całego profilu: `user.home` musi zostać
  `C:\Users\<użytkownik>`, czyli w kontenerze.
- Wyłącz Pliki offline (CSC) na puli. GPO Komputer: *Sieć → Pliki trybu offline → Zezwalaj na używanie funkcji Pliki trybu offline lub nie zezwalaj* = **Wyłączone**.
  Inaczej Windows trzyma lokalną kopię na klonie, który i tak zostanie usunięty.
- Uprawnienia udziału jak przy zwykłym przekierowaniu folderów. Udział: Authenticated Users – Pełna kontrola. NTFS na katalogu głównym:
  *Users – Tworzenie folderów / dołączanie danych* (tylko ten folder), *CREATOR OWNER – Pełna kontrola* (tylko podfoldery i pliki),
  administratorzy Pełna kontrola. Folder użytkownika niech tworzy DEM albo załóż go razem z kontem **(sprawdź, czy DEM tworzy folder docelowy)**.
- **Nie** używaj jednocześnie OneDrive Known Folder Move (patrz [profiles-gpo.md](profiles-gpo.md), sekcja 2).
- Bez personalizacji DEM (plik konfiguracji Flex) dla Eclipse. FSLogix już trzyma `.eclipse` i workspace, a
  podwójny roaming tych samych danych psuje ustawienia.
- Przydatne w DEM: mapowanie dysku `H:` → `\\fs01\Home$\%USERNAME%` (okna Import i Open), schowek przez Horizon Smart Policies.

## 5. Sprawdzenie na klonie testowym

1. Pierwsze logowanie: Eclipse startuje bez pytania o aktualizacje i bez kreatora Oomph. Okno wyboru workspace proponuje
   `C:\Users\<użytkownik>\eclipse-workspace` (albo okna nie ma przy `-ForceWorkspace`).
2. *Window → Preferences → Java → Installed JREs* pokazuje `jdk-21` i `jdk-25` z `C:\Program Files\Eclipse Adoptium`.
   *Execution Environments* przypisuje JavaSE-21 → jdk-21 i JavaSE-25 → jdk-25 **(sprawdź)**.
3. Nowy projekt Java (JavaSE-21) buduje się i uruchamia. Projekt Maven: `.m2` powstaje w `C:\Users\<użytkownik>`.
4. Wylogowanie, potem logowanie na inny klon: workspace, preferencje i projekty są na miejscu, bez „Workspace in use”.
5. *Help → About → Installation Details → Configuration*: `user.home=C:\Users\<użytkownik>` (nie UNC) **(sprawdź z włączonym przekierowaniem DEM)**.
6. `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`: Personal i Desktop wskazują `\\fs01\Home$\...`.
7. `javac -version` w nowej konsoli pokazuje 21 (PATH/JAVA_HOME z MSI JDK 21).
8. Rozmiar VHDX po buildzie Maven (udział FSLogix) w porównaniu z `SizeInMBs`.
