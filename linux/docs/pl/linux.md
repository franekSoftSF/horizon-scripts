# VDI-ImageMaint dla Linuksa (Debian 12, MATE, Instant Clone)

Narzędzie do obrazu wzorcowego **Debian 12 (bookworm) + MATE** dla **Omnissa Horizon 2506 Instant Clone**.
Obraz wzorcowy ma SSSD, a agent Horizon dołącza każdy klon do domeny (offline join). Opcjonalnie działa
logowanie przez True SSO lub kartę, jest też eksperymentalny test przekierowania FIDO2. Katalogi domowe
są na NFSv4 z Kerberosem. Cykl jest ten sam co w wersji Windows: **budowa → Update → Optimize → Seal**,
cofany przez **Unlock**. Profile: `university` i `business`. Komunikaty są po angielsku i po polsku.

**Pierwszy raz?** Zacznij od instrukcji krok po kroku: [tutorial.md](tutorial.md) (English: [../tutorial.md](../tutorial.md)).

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

Najprościej: `sudo ./vdi-imagemaint.sh setup` pyta o ustawienia i po kolei wykonuje kroki poniżej (po agencie restart i ponownie `setup`). Ręcznie:

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

Pełna procedura (nowa stacja, istniejący obraz, co miesiąc) jest zawsze pod adresem
https://github.com/franekSoftSF/horizon-scripts/releases/latest.

```bash
curl -fsSL https://github.com/franekSoftSF/horizon-scripts/releases/latest/download/get-vdi-imagemaint.sh | sudo bash
```

Świeży Debian 12 ma `wget`, ale nie ma `curl`; skrypt instalacyjny sam doinstaluje curl, więc działa też:

```bash
wget -qO- https://github.com/franekSoftSF/horizon-scripts/releases/latest/download/get-vdi-imagemaint.sh | sudo bash
```

Jeśli brakuje też `sudo` (przy instalacji ustawiono hasło roota), wykonaj jako root (`su -`):
`apt-get update && apt-get install -y curl ca-certificates sudo`.

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
| SSSD sam zmienia hasło konta komputera co 30 dni. Snapshot z keytabem starszym niż hasło w AD jest wtedy odrzucany. | `ad_maximum_machine_account_password_age = 0` w `/etc/sssd/conf.d/60-vdi-imagemaint-kerberos.conf`. Domyślnie hasło nie jest zmieniane wcale (`MACHINE_PASSWORD_ROTATION="off"`), więc każdy snapshot pozostaje ważny; AD nie wymusza zmiany haseł komputerów. Przy `"update"` zmienia je tryb `update` (`adcli update`), ale starsze snapshoty mają wtedy nieaktualny keytab. |
| (0.5.0–0.7.2) SSSD czekał na zegar, a skrypt klona synchronizował czas i restartował SSSD. | **Usunięte w 0.8.0**: psuło logowanie domenowe na klonach Instant Clone, bo podczas dostosowania SSSD należy do ClonePrep Horizon. `kerberos` i `seal` usuwają pozostałości; `check` L25 zgłasza je jako błąd. |
| Bilety użytkowników wygasają w długich sesjach i katalogi NFS krb5 przestają działać. | Odnawialne bilety (7 dni), odnawiane przez SSSD co 60 minut. |

`check` L24 wykonuje `adcli testjoin` i blokuje `seal`, gdy AD nie akceptuje już keytabu. Naprawa: przywróć
snapshot z keytabem akceptowanym przez AD albo dołącz ponownie (najpierw kopia `/etc/sssd/sssd.conf`, bo `realm join`
zapisuje własny), potem nowy snapshot. Ustawienia używają domeny z `sssd.conf` (nigdy wartości przykładowej). Po zapisie
narzędzie uruchamia `sssctl config-check` i restartuje SSSD; jeśli coś się nie powiedzie, wszystko jest wycofywane. Jeśli kiedykolwiek zmienisz hasło konta komputera (`MACHINE_PASSWORD_ROTATION="update"`),
snapshoty sprzed zmiany mają nieaktualny keytab: logowanie domenowe na obrazie wzorcowym tam nie działa (klonów to nie dotyczy –
każdy dostaje od Horizon własne konto). Domyślnie hasło nie jest zmieniane (`"off"`), więc wszystkie snapshoty pozostają zgodne z AD. Na klonach `runonce.log` pokazuje wpisy keytabu; narzędzie nie dotyka tam SSSD ani zegara.

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
- **Które aplikacje:** `COURSES_APPS="geany jupyter qtcreator code.desktop octave jmol larch vdi-demeter gnumeric texmaker texstudio texdoctk"`.
  Wpis kończący się na `.desktop` to dokładna nazwa pliku; każdy inny to fragment nazwy pliku, bez rozróżniania
  wielkości liter. Eclipse jest dodawany, gdy jest zainstalowany. Niezainstalowane aplikacje są pomijane.
- **Najpierw doinstalowywane są brakujące aplikacje** (`COURSES_INSTALL="yes"`): pakiety Debiana z
  `COURSES_PACKAGES` (Geany, Jupyter Notebook, Qt Creator, Octave, Jmol, Larch/Larix z Ifeffit i Feff do XAS, Gnumeric, Texmaker, TeXstudio) oraz
  VS Code z pliku `code_*.deb` w `Horizon/` lub `/install`. Na zamkniętym obrazie nic nie jest instalowane.
- **Demeter (Athena, Artemis, Hephaestus, Atoms)** - pakiet `libdemeter-perl`, **tylko Debian 13** (w Debianie 12 go nie ma,
  zgłaszany jako niedostępny). Jest w `contrib` i potrzebuje dwóch modułów Perla z `non-free`, więc `courses` dopisuje
  komponenty z `COURSES_APT_COMPONENTS="contrib non-free"` do źródeł apt Debiana (śledzone, `courses --revert` przywraca
  źródła). Pakiet nie ma wpisów w menu: `courses` tworzy `vdi-demeter-*.desktop` (Zajęcia > Edukacja). Ustawienia
  użytkownika trafiają do `~/.horae` w katalogu domowym. Wpisy uruchamiają Demeter z `DEMETER_FORCE_IFEFFIT=1`: bez tego
  najpierw próbuje backendu Larch, czeka na niego kilka sekund, a ekran powitalny pokazuje „nie odpowiada”.
  Także z Ifeffit interfejs ładuje się ponad 5 s za ekranem powitalnym, który nie odpowiada, więc `courses` wydłuża
  wszystkim limit GNOME dla „nie odpowiada” (`COURSES_ALIVE_TIMEOUT_MS="30000"`, dconf `org.gnome.mutter
  check-alive-timeout`; `""` zostawia domyślne 5000).
- `get-vdi-imagemaint.sh` zakłada katalogi `Horizon/` i `certs/` i pobiera źródła USB VHCI. Instalatory Omnissa
  wymagają logowania w Customer Connect i kopiuje się je ręcznie.
- `courses --revert` usuwa folder.

### Brak katalogów domowych NFS po starcie (tryb `nfsmount`)

Na VM udział NFS `sec=krb5` z `/etc/fstab` czasem nie montował się przy starcie systemu. Sieć, DNS, `rpc-gssd` albo
poświadczenie Kerberos maszyny nie były jeszcze gotowe, a próba nie była ponawiana. Logowanie działało, ale katalogu
domowego brakowało do ręcznego `mount`. `nfsmount` dopisuje do wpisów NFS w fstab
`_netdev,x-systemd.automount,x-systemd.mount-timeout=30`, więc udział montuje się przy pierwszym wejściu do katalogu.
Nowy fstab jest sprawdzany przez `findmnt --verify`. Oryginał jest zachowany, a `nfsmount --revert` go przywraca.
`check` L26 ostrzega o niezamontowanych udziałach NFS z fstab.

### Debian 13 i NFS na jednym udziale

- **Debian 13 (trixie)** jest wspierany obok Debiana 12. Wszystkie pakiety używane przez narzędzie są w Debianie 13 pod
  tymi samymi nazwami; jądro to 6.12. Agent Horizon: dokumentacja Omnissa wymienia Debian 13 od wydania **2606**. `agent`
  odrzuca starsze archiwum na Debianie 13 (chyba że `--force`), a `check` L27 ostrzega.
- **`NFS_MODE="fstab"`**: jeden udział NFS (`NFS_SERVER:NFS_EXPORT`) trafia do `/etc/fstab` na `NFS_MOUNTPOINT` z opcjami
  `_netdev,x-systemd.automount,x-systemd.mount-timeout=30` (montowanie przy pierwszym dostępie); katalogi domowe to
  `HOME_ROOT/<login>` (SSSD `override_homedir`). Tak jest na obecnych obrazach (np. `/home/STUDENT`). `NFS_MODE="autofs"`
  montuje zamiast tego osobny eksport na użytkownika.

## Logowanie certyfikatem: True SSO i karta

Włącz w `vdi-imagemaint.conf`, wrzuć certyfikaty CA (PEM) do `certs/`, uruchom `domain`:

```bash
TRUESSO_ENABLE="yes"                 # Horizon True SSO (certyfikaty z Enrollment Server)
SMARTCARD_ENABLE="no"                # przekierowanie karty z klienta
CERT_CA_FILES="root-ca.pem issuing-ca.pem"   # w /opt/vdi-imagemaint/certs/
CERT_REVOCATION="crl"                # ocsp | soft_ocsp | crl | none
CERT_CRL_URLS="http://pki.example.edu/CertEnroll/Root.crl http://pki.example.edu/CertEnroll/Issuing.crl"
```

```bash
sudo ./vdi-imagemaint.sh domain
sudo ./vdi-imagemaint.sh check       # L18, L28-L31
```

Agent jest instalowany z `-T yes` (True SSO) / `-m yes` (karta) przez tryb `agent`.

**Gdzie to trafia.** Wszystko, co dotyczy certyfikatów, jest w osobnym pliku SSSD:
`/etc/sssd/conf.d/50-vdi-imagemaint-certlogon.conf`. `sssd.conf` nie jest do tego przepisywany, więc na
obrazie **przejętym** (`adopt`) tryb `domain` dodaje tylko ten plik (oraz pakiety i pakiet CA), a resztę
SSSD zostawia w spokoju. SSSD 2.8 (Debian 12) i 2.10 (Debian 13) czytają `[pam]`, `[certmap]` i
`local_auth_policy` z `conf.d` (sprawdzone w kontenerach). Po zapisie narzędzie uruchamia
`sssctl config-check` i restartuje SSSD; jeśli coś się nie uda, plik wraca do poprzedniej postaci.

**Co jest w środku i dlaczego** (wnioski zmierzone na prawdziwym hoście w projekcie sssd-smartcard):

| Ustawienie | Dlaczego |
|---|---|
| `[pam] pam_cert_auth = True`, `pam_p11_allowed_services = +gdm-hzncred` | Horizon SSO i True SSO logują przez usługę PAM `gdm-hzncred`. |
| `[certmap/<domena>/truesso]` `matchrule = <ISSUER>^<CA wystawiające>$<EKU>msScLogin` | Tylko certyfikaty z **tego** CA, wystawione do logowania kartą. CA wystawiające jest wybierane z `CERT_CA_FILES` samo, jeśli jest jedno; przy kilku ustaw `TRUESSO_ISSUER_CA` / `SMARTCARD_ISSUER_CA` na plik (`none` = bez przypięcia). Części reguły są sklejone: `&&` w środku sprawia, że SSSD pomija całą regułę. |
| `maprule = (\|(userPrincipalName={subject_principal})(sAMAccountName={subject_principal.short_name}))` | `userPrincipalName` to atrybut AD (starsze instrukcje podają `userPrincipal`, który niczego nie znajduje). Bez `domains =`, więc działają też inne sufiksy UPN (user@example.edu w ad.example.edu). |
| `local_auth_policy = enable:smartcard` (tylko SSSD >= 2.9.3, czyli Debian 13) | Bez tego dostawca AD czyta i sprawdza certyfikat, **a potem pyta o hasło**. Debian 12 nie zna tej opcji i jej nie potrzebuje. |
| `certificate_verification` z `CERT_REVOCATION` | Zobacz niżej. |

**Unieważnienia (`CERT_REVOCATION`)** — wybierz świadomie; zły wybór blokuje wszystkich:

| Wartość | Co się dzieje |
|---|---|
| `ocsp` (domyślnie) | Domyślnie w SSSD: OCSP, jeśli certyfikat wskazuje serwer. Jeśli klony go nie widzą, logowanie certyfikatem **nie działa**. |
| `soft_ocsp` | OCSP, ale niedostępny serwer nie blokuje logowania. |
| `crl` | Listy CRL z `CERT_CRL_URLS`. **Każde** CA w pakiecie (główne i wystawiające) potrzebuje aktualnej CRL, inaczej żaden certyfikat nie przejdzie. Komplet jest pobierany raz (musi się udać), potem co godzinę przez `vdi-imagemaint-crl.timer` — na obrazie wzorcowym **i na każdym klonie**. Niepełny, źle podpisany lub przeterminowany komplet nigdy nie zastępuje działającego pliku. |
| `none` | Bez sprawdzania (`no_ocsp`). W porządku dla certyfikatów True SSO, które żyją minuty lub godziny. |

`SSSD_CERT_VERIFICATION` dalej działa dla ekspertów i ma pierwszeństwo przed `CERT_REVOCATION`.

**Bilet Kerberos po logowaniu certyfikatem (katalogi NFS krb5).** TGT po logowaniu certyfikatem daje
tylko PKINIT: `krb5-pkinit` i `pkinit_anchors` w `krb5.conf` (tryb `domain` zapisuje je na budowanym
obrazie; na przejętym `check` L31 powie, czego brakuje). Bez tego logowanie działa, ale katalog NFS
sec=krb5 zostaje zamknięty. Certyfikat KDC ze starego szablonu *Domain Controller* wymaga jeszcze
`pkinit_eku_checking = kpServerAuth` i `pkinit_kdc_hostname` (`KRB5_KDC`).

**Karty na Debianie 12 / 13.** Debian 13 ma profil PAM `sss-smart-card-optional` i narzędzie go włącza
(hasło nadal działa). Debian 12 go nie ma: narzędzie wypisuje linię do ręcznego dopisania w
`/etc/pam.d/common-auth`.

**Kontrole.** L18 podstawa (pakiet CA, `pam_cert_auth`, pcscd dla kart), L28 reguła przypięta do CA
wystawiającego, L29 `local_auth_policy` (Debian 13), L30 CRL ważna i timer włączony, L31 PKINIT. `diag`
ma sekcję *certificate logon*. Wyłączenie obu opcji i ponowne `domain` usuwa plik i timer.

**Test na klonie** (bez schowka): zaloguj się przez Connection Server z True SSO, potem `klist` (bilet
TGT = PKINIT działa) i `ls ~` (katalog NFS). Jeśli zamiast tego pyta o hasło, uruchom na klonie
`sudo ./vdi-imagemaint.sh diag`.

## Co zmieniają tryby

- **domain**: zapisuje `krb5.conf`, `sssd.conf` i `smb.conf` i dołącza obraz wzorcowy przez `realm join`
  (adcli). Nadaje sudo grupom AD. Przy `OfflineJoinDomain=sssd` agent Horizon tworzy potem konto
  komputera i keytab dla każdego klona. Bilety są w `FILE:/tmp/krb5cc_%U`, bo rpc.gssd nie czyta KCM.
  - **True SSO / karta** (`TRUESSO_ENABLE`, `SMARTCARD_ENABLE`): łańcuch CA z `certs/` do
    `/etc/sssd/pki/sssd_auth_ca_db.pem`, `pkinit_anchors` w krb5.conf i plik SSSD
    `conf.d/50-vdi-imagemaint-certlogon.conf` - zobacz *Logowanie certyfikatem* wyżej.
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
  - **Użytkownicy widzą tylko „Wyloguj”** (`SEAL_HIDE_POWER`): reguła polkit odmawia wyłączenia, restartu, uśpienia
    i hibernacji wszystkim spoza grupy `sudo`, więc MATE, okno wylogowania i ekran logowania GDM je ukrywają; klony
    Instant Clone i tak są usuwane po wylogowaniu.
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
