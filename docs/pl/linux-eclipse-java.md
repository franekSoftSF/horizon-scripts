# Eclipse + Java na pulpicie Debian (Horizon Instant Clone)

Komponent: `linux/apps/eclipse-java.sh` (samodzielny, idempotentny, komunikaty EN/PL).
Środowisko: Debian 12/13 amd64, MATE + LightDM, Horizon Linux Agent, Instant Clone,
logowanie AD (SSSD), katalogi domowe na **NFSv4 z `sec=krb5*`** (autofs).

## Co instaluje

| Element | Gdzie | Uwagi |
|---|---|---|
| JDK (domyślnie **Temurin 25 LTS**) | `/usr/lib/jvm/...`, `/etc/profile.d/vdi-java.sh` | repozytorium Adoptium albo Debian `openjdk-N-jdk`; ustawiane jako domyślne (`java`, `javac`, `jshell`) |
| Eclipse IDE for Java (domyślnie **2026-09**) | `/opt/vdi-apps/eclipse-java-2026-09`, dowiązanie `/opt/vdi-apps/eclipse` | wspólna instalacja tylko do odczytu, sprawdzana suma SHA-512, poprzednia wersja zostaje do wycofania |
| Program uruchamiający | `/opt/vdi-apps/bin/vdi-eclipse` | sprawdza, czy katalog NFS jest zapisywalny i czy jest bilet Kerberos; jeśli nie – okno z komunikatem EN/PL |
| Menu MATE | `/usr/share/applications/vdi-eclipse.desktop` | **Aplikacje > Programowanie**; opcjonalne dodatkowe podmenu (`MENU_SUBMENU`) |
| Ikona na pulpicie (opcja) | `/etc/xdg/autostart/vdi-eclipse-user.desktop` | tworzona **przy logowaniu, przez samego użytkownika**, jednorazowo (usunięcie jest respektowane) |

## Dlaczego tak (NFS + Kerberos + Instant Clone)

- **root nie może pisać do katalogów domowych** (`sec=krb5*`: root nie ma biletu użytkownika), a `/etc/skel`
  nie jest kopiowany na NFS. Dlatego w obrazie nic nie jest przygotowywane per użytkownik: skróty w menu są
  systemowe, ikonę na pulpicie tworzy sesja użytkownika przy logowaniu.
- **Instalacja tylko do odczytu**: studenci nie zaktualizują ani nie zepsują Eclipse innym; Eclipse zapisuje
  swoją konfigurację w `~/.eclipse`, a workspace w `~/eclipse-workspace` – oba na NFS, więc przetrwają
  usunięcie klona po wylogowaniu. Sprawdzanie aktualizacji jest wyłączone; nowy Eclipse przychodzi z kolejnym obrazem.
- **Brak `/root/.eclipse` w obrazie**: kroki bez GUI (`-initialize`, instalacja wtyczek) działają z tymczasowym `HOME`.
- **Eclipse 2026-09 do uruchomienia wymaga Javy 25** – odczytywane z `-Dosgi.requiredJavaVersion` w `eclipse.ini`.
  Jeśli JDK z zajęć jest co najmniej tej wersji, Eclipse działa na nim i jest ono domyślnym JRE nowych projektów.
  Jeśli zajęcia wymagają starszego JDK (np. 21), Eclipse działa na wbudowanym JRE, JDK z zajęć jest wykrywane
  w `/usr/lib/jvm`, a poziom kompilatora domyślnie ustawiany na wersję z zajęć.
- **Blokady workspace**: NFSv4 ma blokady w protokole, więc zostaje domyślne zachowanie Equinox. Klon usunięty bez
  zamknięcia Eclipse zwalnia blokadę po wygaśnięciu dzierżawy NFSv4 (ok. 90 s) – kto zaloguje się natychmiast
  ponownie, może przez chwilę zobaczyć „workspace in use”. `ECLIPSE_OSGI_LOCKING=none` tylko gdy serwer NFS nie ma działających blokad.
- **Czas życia biletu**: gdy bilet Kerberos wygaśnie, NFS przestaje działać i Eclipse nie zapisze plików. SSSD odnawia
  bilety (`krb5_renew_interval`, odnawialne 7 dni – krok `domain`); sprawdź, czy polityka biletów w AD pozwala na odnawianie.
  Program uruchamiający ostrzega, gdy przy starcie nie ma biletu.

## Istniejące i nowe pulpity

Instant clone nie zmienia się pojedynczo – klony powstają ze snapshotu złotego obrazu:

1. Na złotym obrazie: `vdi-imagemaint.sh unlock` (jeśli zapieczętowany) → `apps` (albo bezpośrednio
   `sudo linux/apps/eclipse-java.sh`) → test jako **użytkownik domenowy** → `check` → `seal` → wyłączenie.
2. vCenter: snapshot.
3. Horizon: **istniejące pule** – *Push Image* na nowy snapshot (użytkownicy dostają zmiany przy następnym logowaniu/odświeżeniu);
   **nowe pule** – wybierz ten snapshot przy tworzeniu puli.

Katalogi domowe na NFS nie wymagają migracji: skrót w menu jest w obrazie, ikona na pulpicie (opcja) pojawi się przy
następnym logowaniu, stare ustawienia Eclipse zostają w `~/.eclipse` (nowa wersja dostaje własny folder).

Działa też na złotych obrazach zbudowanych bez VDI-ImageMaint – skrypt wymaga tylko Debiana i MATE.

## Konfiguracja

Skopiuj `linux/apps/eclipse-java.conf.example` do `linux/apps/eclipse-java.conf`. Najważniejsze ustawienia:
`JAVA_SOURCE`, `JAVA_VERSION`, `ECLIPSE_RELEASE`, `ECLIPSE_PACKAGE`, `ECLIPSE_P2_REPOS` / `ECLIPSE_P2_FEATURES`
(dodatkowe wtyczki), `MENU_SUBMENU` / `MENU_SUBMENU_PL`, `DESKTOP_ICON`. Wartości domyślne są na początku skryptu.

Budowa bez internetu: umieść `eclipse-java-2026-09-R-linux-gtk-x86_64.tar.gz` i plik `.sha512` z
<https://download.eclipse.org/technology/epp/downloads/release/2026-09/R/> w `linux/apps/Apps/`.
JDK nadal wymaga repozytorium apt Adoptium lub Debiana (albo lokalnego mirrora).

## Polecenia

```bash
sudo ./eclipse-java.sh               # instalacja / aktualizacja (= --install)
sudo ./eclipse-java.sh --status      # co jest zainstalowane, kod 1 gdy niekompletne
sudo ./eclipse-java.sh --remove      # usuwa Eclipse + menu; --purge-java usuwa też JDK
```

Log: `/var/log/vdi-imagemaint/apps-eclipse-java-RRRRMMDD.log`, stan: `/var/lib/vdi-imagemaint/apps-eclipse-java.state`.

## Poza zakresem / do sprawdzenia na VM

- Logowanie prawdziwego użytkownika AD na klonie (montowanie NFS, odnawianie biletu w długiej sesji) – wymaga środowiska klienta.
- Interfejs Eclipse jest po angielsku (polskie tłumaczenia Babel są niekompletne).
- Limit (quota) na NFS: workspace z cache Maven/Gradle (`~/.m2`, `~/.gradle`) szybko rośnie.
