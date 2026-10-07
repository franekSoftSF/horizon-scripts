# VDI-ImageMaint dla Linuksa (Debian 12, MATE, Instant Clone)

Narzędzie do obrazu wzorcowego **Debian 12 (bookworm) + MATE** dla **Omnissa Horizon 2506 Instant Clone**.
Obraz wzorcowy ma SSSD, a agent Horizon dołącza każdy klon do domeny (offline join). Opcjonalnie działa
logowanie przez True SSO lub kartę, jest też eksperymentalny test przekierowania FIDO2. Katalogi domowe
są na NFSv4 z Kerberosem. Cykl jest ten sam co w wersji Windows: **budowa → Update → Optimize → Seal**,
cofany przez **Unlock**. Profile: `university` i `business`. Komunikaty są po angielsku i po polsku.

## Układ

Katalog `linux/` w repozytorium to kompletny `/opt/vdi-imagemaint` na VM.

| Ścieżka | Do czego |
|---|---|
| `vdi-imagemaint.sh` | punkt wejścia (bez argumentów = menu) |
| `vdi-imagemaint.conf.example` | skopiuj do `vdi-imagemaint.conf` (poza gitem) i dostosuj |
| `conf/defaults.conf`, `conf/profile-*.conf` | wszystkie ustawienia z wartościami domyślnymi oraz domyślne wartości profili |
| `lib/*.sh` | jeden plik na tryb + `common.sh` (konfiguracja, i18n, log, śledzenie zmian) |
| `lang/en-US.sh`, `lang/pl-PL.sh` | tabele komunikatów (główny jest angielski) |
| `files/runonce.sh` | skrypt uruchamiany na każdym klonie (`/usr/local/sbin/vdi-imagemaint-runonce.sh`) |
| `certs/` | certyfikaty CA (PEM) do True SSO / logowania kartą (poza gitem) |
| `apps/*.sh` | opcjonalne instalatory aplikacji, uruchamia je tryb `apps` – np. [Eclipse + Java](../../../docs/pl/linux-eclipse-java.md) |
| `Horizon/` | `Omnissa-horizonagent-linux-x86_64-*.tar.gz`, `Horizon.Recording.Linux.Agent-*.tar.gz`, `vhci-hcd-1.15.tar.gz` (poza gitem) |

Na VM logi są w `/var/log/vdi-imagemaint/`, a stan w `/var/lib/vdi-imagemaint/`. Każda sekcja (`build`,
`optimize`, `seal`) ma własny plik `<sekcja>-state.json`, a oryginał każdego zmienianego pliku jest
zapisywany jeden raz.

## Budowa (raz na obraz)

```bash
sudo cp -r linux /opt/vdi-imagemaint && cd /opt/vdi-imagemaint
sudo cp vdi-imagemaint.conf.example vdi-imagemaint.conf && sudo nano vdi-imagemaint.conf
sudo ./vdi-imagemaint.sh prepare     # pakiety, sesja MATE + GDM, locale, czas (NTP = AD)
sudo ./vdi-imagemaint.sh domain      # krb5, SSSD, realm join (pyta o hasło), True SSO / karta
sudo ./vdi-imagemaint.sh nfs         # autofs + NFSv4 sec=krb5p, idmapd, fragment SSSD
sudo ./vdi-imagemaint.sh agent       # agent Horizon, OfflineJoinDomain=sssd, RunOnceScript
sudo reboot
sudo ./vdi-imagemaint.sh recording   # Horizon Recording Agent (opcjonalnie, pyta o hasło)
sudo ./vdi-imagemaint.sh apps        # apps/*.sh --install (Eclipse ...)
sudo ./vdi-imagemaint.sh optimize
sudo ./vdi-imagemaint.sh collab      # pyta o każde ustawienie Session Collaboration
sudo ./vdi-imagemaint.sh seal        # najpierw check, potem wyłączenie -> snapshot
```

## Co miesiąc

Włącz obraz wzorcowy i uruchom `sudo ./vdi-imagemaint.sh update --then-seal`. Narzędzie odblokuje obraz,
wykona `apt full-upgrade` i zamknie go ponownie. Jeśli nowe jądro wymaga restartu, uruchom VM ponownie,
a potem wykonaj `seal`.

## Pobieranie z GitHuba

```bash
curl -fsSL https://raw.githubusercontent.com/franekSoftSF/horizon-scripts/main/linux/get-vdi-imagemaint.sh | sudo bash
```

`get-vdi-imagemaint.sh`:
- znajduje najnowsze wydanie `linux-v*` (w repozytorium są też wydania Windows);
- pobiera je i sprawdza sumę SHA-256;
- instaluje w `/opt/vdi-imagemaint`.

To samo polecenie aktualizuje narzędzie. Wymieniane są tylko pliki narzędzia; `vdi-imagemaint.conf`,
`Horizon/`, `certs/` i `apps/*.conf` zostają bez zmian. Opcje: `--version 0.3.0`, `--dir <ścieżka>`, `--lang pl-PL`.

### Automatyczna aktualizacja

Przy każdym uruchomieniu narzędzie sprawdza na GitHubie, czy jest nowsze wydanie `linux-v*`. Jeśli tak,
instaluje je w miejscu (z kontrolą SHA-256 i zachowaniem plików lokalnych) i uruchamia to samo polecenie
ponownie w nowej wersji. Odświeża też zainstalowany skrypt klona. Gdy GitHub jest niedostępny, narzędzie
działa dalej na zainstalowanej wersji.

- `AUTO_UPGRADE="yes"` (domyślnie), `"ask"` albo `"no"` w `vdi-imagemaint.conf`;
- `--no-upgrade` pomija aktualizację w jednym uruchomieniu;
- `self-update` sprawdza GitHub od razu, także przy `AUTO_UPGRADE="no"`.

## Istniejący obraz wzorcowy (tryb `adopt`)

Jeśli obraz był budowany bez tego narzędzia, zacznij od `adopt`:

```bash
sudo ./vdi-imagemaint.sh adopt
```

Nie trzeba wcześniej kopiować ani edytować `vdi-imagemaint.conf.example`: `adopt` sam tworzy
`vdi-imagemaint.conf` z tego, co znajdzie na obrazie. Pyta tylko o profil (university lub business). Plik obejmuje
locale, strefę czasową, klawiaturę, domenę AD i workgroup, nazwy i mapowanie ID w SSSD, serwer NFS, eksport i `sec=`
z fstab lub autofs, SSO, USB, kartę, True SSO, Collaboration i Recording. Jeśli `vdi-imagemaint.conf` już istnieje,
zostaje bez zmian: wykryte wartości trafiają do `vdi-imagemaint.conf.detected`, a różnice są wypisane.

1. **Wykrywa** obecny stan:
   - sesje pulpitu i menedżer logowania;
   - sposób dołączenia do domeny (SSSD lub winbind/Samba) i keytab maszyny;
   - montowanie katalogów domowych (fstab, autofs lub lokalne);
   - agenta Horizon: jego konfigurację, `OfflineJoinDomain`, `RunOnceScript` i składniki USB.
2. **Pokazuje podgląd** tego, co zmieniłyby `prepare`, `domain`, `nfs` i konfiguracja agenta: `diff` każdego
   pliku z zamaskowanymi hasłami. Nic nie jest zapisywane.
3. **Pyta**, które kroki zachować. Zachowany krok dostaje oznaczenie *adopted*: `prepare`/`domain`/`nfs`
   nie wykonają się na nim ponownie, także po aktualizacji narzędzia, chyba że użyjesz `--force`.
   `-y` zachowuje wszystkie wykryte kroki.
4. **Zapisuje wersję agenta** bez reinstalacji. Omnissa nie dokumentuje pliku z wersją, więc narzędzie pyta
   o wersję (YYMM-y.y.y-build) albo bierze ją z `ADOPT_AGENT_VERSION`. Pyta też, czy agent był instalowany
   z opcjami obecnej konfiguracji. Jeśli nie, następne uruchomienie `agent` z tą samą wersją raz uruchomi
   instalator z opcjami z konfiguracji.
5. **Zachowuje dotychczasowe dołączenie do domeny i skrypt klona**:
   - Przy dołączeniu przez winbind/Sambę `OfflineJoinDomain` zostaje bez zmian.
   - Istniejący `RunOnceScript` (np. ponowne dołączenie przez `net ads join`) jest wywoływany przez
     `/etc/vdi-imagemaint/runonce.local`, przed restartem SSSD/NFS.
   - `check` akceptuje przejęty pulpit, sposób dołączenia i katalogi domowe.

Jeśli `check` zgłasza L21 (brak sterownika USB VHCI) na przejętym obrazie, uruchom `sudo ./vdi-imagemaint.sh usb`: zbuduje sterownik z łatką z zainstalowanego agenta albo z archiwum agenta w `Horizon/`, bez reinstalacji agenta.

Po `adopt` używaj `check`, potem `agent` (aktualizacja), `recording`, `apps`, `optimize`, `collab` i `seal` jak zwykle.
Dokumentacja zaleca budowę obrazu ze świeżej instalacji, nigdy z klona.

## Logowanie nie działa po wyłączeniu obrazu (Kerberos / SSSD)

Objaw: obraz wzorcowy był przez jakiś czas wyłączony albo wrócono do snapshotu i logowanie przestaje działać.
Wynika to z działania SSSD i Kerberosa z AD; dokumentacja Omnissa tego nie opisuje.

| Przyczyna | Co robi narzędzie (tryb `kerberos`, wykonywany też przez `domain` i `adopt`) |
|---|---|
| SSSD sam zmienia hasło konta komputera co 30 dni. AD akceptuje tylko bieżące i poprzednie hasło, więc starszy snapshot lub keytab jest odrzucany. | `ad_maximum_machine_account_password_age = 0` w `/etc/sssd/conf.d/60-vdi-imagemaint-kerberos.conf`. `update` zmienia hasło świadomie (`adcli update`, gdy starsze niż `MACHINE_PASSWORD_DAYS`=25) tuż przed nowym snapshotem. |
| SSSD startuje przed synchronizacją zegara, a Kerberos nie działa przy różnicy powyżej 5 minut. | `sssd.service` czeka na `time-sync.target` (`systemd-time-wait-sync`, najwyżej 90 s). Skrypt klona synchronizuje czas przed restartem SSSD i NFS. |
| Bilety użytkowników wygasają w długich sesjach i katalogi NFS krb5 przestają działać. | Odnawialne bilety (7 dni), odnawiane przez SSSD co 60 minut. |

`check` L24 wykonuje `adcli testjoin` i blokuje `seal`, gdy AD nie akceptuje już keytabu. Naprawa: przywróć
snapshot z keytabem akceptowanym przez AD albo dołącz ponownie (najpierw kopia `/etc/sssd/sssd.conf`, bo `realm join`
zapisuje własny), potem nowy snapshot. Ustawienia używają domeny z `sssd.conf` (nigdy wartości przykładowej). Po zapisie
narzędzie uruchamia `sssctl config-check` i restartuje SSSD; jeśli coś się nie powiedzie, wszystko jest wycofywane.
SSSD czeka na zegar tylko wtedy, gdy synchronizuje go `systemd-timesyncd`. Nie wracaj do snapshotów
starszych niż jedna zmiana hasła. Na klonach `runonce.log` pokazuje synchronizację czasu i wpisy keytabu.

## Wersje i ponowne uruchomienia

- Każdy krok budowy (`prepare`, `domain`, `nfs`) jest zapisywany w `build-state.json` razem z wersją
  narzędzia, czasem i odciskiem konfiguracji. Ponowne uruchomienie przy tej samej wersji narzędzia i
  niezmienionej konfiguracji jest pomijane. `--force` wykonuje krok jeszcze raz.
- `status` pokazuje wykonane kroki, wersję i opcje agenta, sterownik VHCI i Recording.

## Agent Horizon: zależności, USB 3.0, dźwięk, aktualizacja

Źródło: „Desktops and Applications in Omnissa Horizon 8” (PDF w wersji 2606 od użytkownika) oraz strony
Horizon 8 2506. Wersje Debiana: 12.10 i 11.11 dla 2506 (KB 87277); 12.13 i 13.3 dla 2606.

- **Zależności** (instalowane przed agentem):
  - `gnome-shell-extension-appindicator` i `libnss3-tools`. Bez nich instalator agenta się zatrzymuje.
  - `pulseaudio-utils` do dźwięku (wejście i wyjście) w Debianie 12.x.
  - `open-vm-tools` i `krb5-user`.
- **Przełączniki instalatora** wynikają z ustawień: `-A yes -M yes`, `-a` (mikrofon, `AUDIO_IN_ENABLE`),
  `-U` (USB, `USB_ENABLE`), `-T` (True SSO) i `-m` (karta). Inne udokumentowane przełączniki wpisz w
  `HORIZON_AGENT_EXTRA_ARGS`, np. `--webcam`.
- **USB 3.0 / VHCI** zgodnie z kolejnością z dokumentacji dla archiwum tar.gz: rozpakowanie archiwum
  agenta, instalacja sterownika VHCI, potem agent z `-U yes`. Kroki:
  - Źródła VHCI (`vhci-hcd-1.15.tar.gz`) pochodzą z `Horizon/`; jeśli ich tam nie ma, narzędzie pobiera
    je z SourceForge, z adresu podanego w dokumentacji.
  - Narzędzie nakłada łatkę `resources/vhci/patch/vhci.patch` z archiwum agenta.
  - Kopia `hcd.h` wymagana dla Debiana jest wykonywana jako skrypt `PRE_BUILD` w DKMS.
  - DKMS razem z `linux-headers-amd64` przebudowuje sterownik dla każdego nowego jądra zainstalowanego
    przez `update`. Dokumentacja wymaga przebudowy po każdej zmianie jądra.
  - Przy włączonym Secure Boot moduły trzeba podpisać i zarejestrować klucz MOK. Narzędzie tylko ostrzega.
- **FIDO2** działa przez przekierowanie USB (KB 6001193). `FIDO_ENABLE` wymusza USB, a `FIDO_VIDPID`
  ustawia `viewusb.IncludeVidPid` w `/etc/omnissa/config`.
- **Wersja i aktualizacja**: wersja jest odczytywana z nazwy archiwum `...-YYMM-y.y.y-build.tar.gz`
  i zapisywana po instalacji (Omnissa nie dokumentuje pliku z wersją). Zachowanie:
  - Ta sama wersja i te same opcje: instalator nie jest uruchamiany.
  - Ta sama wersja, inne opcje: instalator uruchamia się ponownie z nowymi opcjami.
  - Nowsze archiwum: aktualizacja. Zgodnie z dokumentacją instalator dostaje ponownie wszystkie opcje
    funkcji, bo archiwum tar.gz ich nie zachowuje. BlastServer nie może działać. Potem wymagany jest
    restart, na który czekają `check` i `seal`.
  - Starsze archiwum: odmowa, chyba że użyjesz `--force`.
  - `update` sam aktualizuje agenta i Recording, gdy w `Horizon/` są nowsze archiwa (`UPDATE_AGENTS`).

## Horizon Recording (tryb `recording`)

Recording Agent wymaga Horizon 8 2306 lub nowszego, wcześniej zainstalowanego agenta Horizon i otwartego
portu 9443 na serwerze. Narzędzie:
- uruchamia `install.sh -u https://<serwer>:9443 -n <użytkownik> -p <hasło> -t` z archiwum
  `Horizon.Recording.Linux.Agent-x.x.x.x.tar.gz`. `-t` jest wymagane dla Instant Clone; `-s <odcisk>` jest opcjonalne;
- pyta o hasło albo bierze je z `VDI_REC_PASSWORD`. Hasło nigdy nie jest zapisywane, a w logu jest maskowane;
- kontroluje wersję tak samo jak przy agencie: ta sama wersja jest pomijana, nowsza oznacza aktualizację
  (potem restart), starsza jest odrzucana;
- nie usuwa podczas seal tokenu parowania `/etc/omnissa/horizonrecording/pairingdata.json`.

## Folder „Zajęcia” (tryb `courses`)

`courses` przenosi aplikacje do zajęć do jednego folderu `COURSES_FOLDER_NAME` (domyślnie „Courses”, po polsku
„Zajęcia”). `apps` uruchamia go na końcu, a `update` go odświeża.

- **GNOME:** jeden płaski folder w siatce aplikacji (foldery GNOME nie mogą być zagnieżdżone), ustawiony dla wszystkich użytkowników przez systemową bazę dconf.
  Aplikacje z folderu znikają z głównej siatki. Przy `COURSES_LOCK="yes"` (domyślnie dla uczelni) użytkownicy
  nie mogą usunąć folderu.
- **MATE:** podmenu w menu Aplikacje (to samo `VDI-Apps`, którego używa komponent Eclipse), a w nim zwykłe
  podkategorie: Courses > Programowanie (Geany, Jupyter, Qt Creator, VS Code, Eclipse), Edukacja (Octave, Jmol),
  Biuro (Gnumeric, Texmaker, TeXstudio), Grafika, Inne. Każda aplikacja zachowuje grupę, którą miała w menu MATE. Aplikacje są
  przenoszone przez kopie wpisów w `/usr/local/share/applications`; pliki pakietów nie są zmieniane.
- **Które aplikacje:** `COURSES_APPS="geany jupyter qtcreator code.desktop octave jmol gnumeric texmaker texstudio texdoctk"`.
  Wpis kończący się na `.desktop` to dokładna nazwa pliku; każdy inny to fragment nazwy pliku, bez rozróżniania
  wielkości liter. Eclipse jest dodawany, gdy jest zainstalowany. Niezainstalowane aplikacje są pomijane.
- `courses --revert` usuwa folder.

## Co zmieniają tryby

- **domain**: zapisuje `krb5.conf`, `sssd.conf` i `smb.conf` i dołącza obraz wzorcowy przez `realm join`
  (adcli). Nadaje sudo grupom AD. Przy `OfflineJoinDomain=sssd` agent Horizon tworzy potem konto
  komputera i keytab dla każdego klona. Bilety są w `FILE:/tmp/krb5cc_%U`, bo rpc.gssd nie czyta KCM.
  - **True SSO / karta** (`TRUESSO_ENABLE`, `SMARTCARD_ENABLE`): instaluje pcscd, OpenSC i krb5-pkinit
    i zapisuje łańcuch CA z `certs/` do `/etc/sssd/pki/sssd_auth_ca_db.pem`. Ustawia `pam_cert_auth`
    i dodaje `pkinit_anchors` do krb5.conf, więc logowanie certyfikatem też daje bilet TGT i NFS krb5p
    działa. Agent jest instalowany z `-T yes` / `-m yes`.
  - **FIDO2** (`FIDO_ENABLE`, eksperymentalnie): `fido2-tools` jest instalowane przed seal. Uruchom
    `fido` w sesji Horizon na klonie, z kluczem włożonym do klienta. Tryb pokaże urządzenia FIDO2
    widoczne w pulpicie.
- **optimize** (cofnięcie: `optimize --revert`):
  - Wyłącza zbędne usługi, np. bluetooth, ModemManager, avahi, plocate, fwupd, anacron i exim4.
    Maskuje uśpienie i hibernację.
  - Ustawia MATE przez dconf: bez kompozycji i animacji, jednolite tło, bez oszczędzania energii.
    W Caja na NFS wyłącza miniatury, podglądy i liczniki elementów. Wyłącza dźwięki zdarzeń.
  - LightDM (tylko gdy to on jest menedżerem logowania): ukrywa listę użytkowników i wyłącza konto gościa. Obrazy z SSO
    Horizon używają GDM: SSO loguje przez usługę PAM `gdm-hzncred` i uruchamia MATE (`SSODesktopType=UseMATE`).
  - System: journald w RAM, strojenie sysctl, harmonogram I/O `none` oraz opcjonalnie `/tmp` w RAM.
  - polkit: użytkownik nie może wyłączyć, zrestartować ani uśpić klona.
- **seal** (cofnięcie: `unlock`):
  - Wykonuje `check`, wyłącza timery apt i unattended-upgrades oraz maskuje PackageKit.
  - Czyści cache, logi, bilety Kerberos i dzierżawy DHCP. Cache SSSD jest celowo zachowywany: jego usuwanie psuło logowanie, gdy SSSD tuż po restarcie nie mógł połączyć się z kontrolerem domeny. Usuwa klucze hosta SSH; skrypt
    RunOnce tworzy nowe na każdym klonie.
  - **Blokuje zmiany pakietów dla wszystkich aż do unlock**: dpkg `pre-invoke` i apt
    `Update::Pre-Invoke` odrzucają `apt update`, `apt install` i `dpkg -i`. Zapytania o pakiety
    nadal działają.
  - **Ukrywa okienka przed użytkownikami**: polkit odmawia akcji PackageKit i apt bez pytania o hasło
    i zezwala na colord, więc nie pojawia się okno „wymagane uwierzytelnienie”. Wyłącza powiadomienia
    housekeeping MATE i powiadomienia sieci oraz zrzuty pamięci.
- **collab** pyta o każdą wartość; `-y` bierze wartości domyślne z konfiguracji. Do
  `viewagent-custom.conf` zapisuje `CollaborationEnable`, a do pliku `config` agenta
  `collaboration.serverUrl` (link w zaproszeniach, np. adres UAG), `enableEmail`, `enableControlPassing`
  i `maxCollabors`.

## Aplikacje (tryb `apps`)

`apps` uruchamia każdy `apps/*.sh --install --yes` i zatrzymuje się na pierwszym błędzie. Każdy instalator
ma własny stan i log w `/var/lib/vdi-imagemaint/` i `/var/log/vdi-imagemaint/`. Na zamkniętym obrazie
instalator odmawia pracy, więc `apps` uruchamiaj przed `seal`.

- **Eclipse + Java** (`apps/eclipse-java.sh`, v1.0.0): Eclipse 2026-09 wymaga do działania Javy 25,
  dlatego domyślny JDK to Temurin 25 z repozytorium Adoptium. Pliki trafiają do `/opt/vdi-apps/`.
  Szczegóły: [docs/pl/linux-eclipse-java.md](../../../docs/pl/linux-eclipse-java.md).

## Ograniczenia

- **Teams**: agent Linux nie ma Media Optimization for Teams. Profil `business` instaluje Edge, więc
  Teams działa jako aplikacja webowa.
- **FIDO2**: do sprawdzenia, czy agent Linux 2506 przekierowuje urządzenia FIDO2 (tryb `fido`).
  Ewentualny przełącznik instalatora wpisz w `HORIZON_AGENT_ARGS_FIDO`.
- **GPO**: ADSys jest tylko dla Ubuntu (większość funkcji wymaga Ubuntu Pro) i nie ma go w Debianie 12.
  `samba-gpupdate` wymaga konta maszyny Samba/winbind, którego offline join z SSSD nie tworzy.
  Uprawnienia do logowania daje SSSD `ad_gpo_access_control`, a ustawienia – to narzędzie.
- Przełączniki instalatora (`-T`, `-m`) i nazwy kluczy agenta (`OfflineJoinDomain`, `RunOnceScript`, `CollaborationEnable`, `collaboration.*`)
  pochodzą z dokumentacji Horizon Linux Agent. Sprawdź je dla wdrażanej wersji agenta.
- Klony Instant Clone powstają przez fork, a nie przez uruchomienie systemu. Wszystko, co ma się różnić
  między klonami, należy do `files/runonce.sh` albo `/etc/vdi-imagemaint/runonce.local`. Wszystkie klony
  mają ten sam `/etc/machine-id`.
