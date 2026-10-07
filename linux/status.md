# Status – VDI-ImageMaint dla Linuksa

_Aktualizacja: 2026-10-07_ · wersja **0.6.0** · Debian 12 + MATE · Horizon 2506 Instant Clone

## Zrobione
- [x] Szkielet: `vdi-imagemaint.sh` (menu + tryby), `lib/common.sh` (konfiguracja, i18n EN/PL, log, śledzenie zmian w JSON)
- [x] Profile `university` / `business`, `conf/defaults.conf` + lokalny `vdi-imagemaint.conf`
- [x] `prepare`: pakiety, MATE + LightDM, locale, klawiatura, strefa, NTP z AD, open-vm-tools, opcjonalnie Edge
- [x] `nfs`: autofs, NFSv4 sec=krb5p, idmapd, fragment SSSD (homedir + FILE ccache)
- [x] `agent`: instalacja z `Horizon/`, OfflineJoinDomain=sssd, RunOnceScript, SSO
- [x] `optimize` (odwracalny), `collab` (pyta o każde ustawienie, link UAG), `apps` – uruchamia `apps/*.sh`; **Eclipse + Java 1.0.0** gotowy (osobna sesja, [opis](../docs/pl/linux-eclipse-java.md), test w kontenerze debian:12, bez VM)
- [x] `seal`: blokada pakietów (apt/dpkg/PackageKit), brak okienek dla użytkowników, sprzątanie, klucze SSH; `unlock`; `update --then-seal`; `check` (L01–L17)
- [x] `domain` (SSSD, krb5, realm join, sudo dla grup AD) – przywrócony: wymagany pod offline join oraz True SSO + logowanie kartą
- [x] True SSO / karta: pcscd, OpenSC, krb5-pkinit, CA z `certs/` → SSSD, `pam_cert_auth`, `pkinit_anchors`, parametry agenta `-T`/`-m`
- [x] `fido`: eksperymentalny test przekierowania FIDO2 w sesji na klonie (`fido2-token -L`)

- [x] 0.2.0: kontrola wersji (kroki pomijane przy tej samej wersji i konfiguracji), wersja/upgrade agenta, zależności z dokumentacji,
      USB 3.0 (VHCI + DKMS), FIDO2 przez USB, dźwięk (pulseaudio-utils, -a), tryb `recording`, `update` aktualizuje agentów,
      SSSD/True SSO/karta zgodnie z dokumentacją 2606 (PDF od użytkownika)

- [x] 0.3.0: tryb `adopt` dla istniejących obrazów (wykrycie, podgląd diff, przejęte kroki, wersja agenta bez reinstalacji,
      zachowanie winbind/RunOnceScript); `get-vdi-imagemaint.sh` – instalacja/aktualizacja z GitHuba z zachowaniem plików lokalnych

- [x] 0.3.1: `adopt` sam tworzy `vdi-imagemaint.conf` z wykrytych ustawień (pyta tylko o profil); istniejąca konfiguracja → `.detected` + lista różnic

- [x] 0.3.2: po pierwszym teście na VM (przejęty obraz): tryb `usb` (sam sterownik VHCI), L20 jako ostrzeżenie przy zainstalowanym agencie,
      L23 rozpoznaje wartości przykładowe, menu nie zgłasza wyników check jako błędu kroku

- [x] 0.4.0: automatyczna aktualizacja narzędzia z GitHuba przy każdym uruchomieniu (AUTO_UPGRADE, --no-upgrade, tryb self-update), odświeżanie skryptu klona

- [x] 0.4.1: instalatory także w `/install` (HORIZON_EXTRA_DIRS) i jako rozpakowane katalogi; VHCI z rozpakowanego katalogu, wykrycie nałożonej łatki;
      adopt proponuje wersję agenta z nazwy instalatora

- [x] 0.4.2: VM – łatka agenta 2506 nie pasowała do ręcznie rozpakowanego /install/vhci-hcd-1.15 → kolejne źródło / czyste pobranie, dry-run, wynik patch w logu

- [x] 0.5.0: VM – po wyłączeniu obrazu Kerberos/SSSD przestaje działać → brak automatycznej zmiany hasła komputera, rotacja w `update`,
      SSSD czeka na czas, skrypt klona synchronizuje czas, odnawianie biletów, check L24 `adcli testjoin`

- [x] 0.5.1: po awarii na VM (brak logowania) – Kerberos z domeny z sssd.conf (nigdy przykładowej), sssctl config-check + restart SSSD z automatycznym
      wycofaniem, czekanie na czas tylko przy timesyncd, adopt pyta; użytkownik przywrócił snapshot i przechodzi proces od nowa

- [x] 0.5.2: przyczyna awarii (wskazana przez użytkownika): seal usuwał cache SSSD → po restarcie brak logowania. Usunięte z seal, skryptu klona
      i rotacji hasła (sss_cache -E tylko przy dołączaniu do domeny); test regresji

- [x] 0.5.3: VM – check zawieszał się na L24 (`adcli testjoin`) → limit 30 s, bez wejścia z terminala, przekroczenie = ostrzeżenie; L07 pokazuje domenę z sssd.conf

- [x] 0.5.4: L24 przez `kinit -k` (adcli tylko jako uzupełnienie), tryb `diag` (diagnoza tylko do odczytu, zapis do pliku – VDI bez schowka)

- [x] 0.6.0: tryb `courses` – folder „Courses/Zajęcia” (GNOME: folder w siatce aplikacji przez dconf; MATE: podmenu) dla Octave, Gnumeric,
      Qt Creator, VS Code, Texmaker, TeXstudio, texdoctk i Eclipse

## Jak testowano (bez VM)
- Kontener `debian:12` (Docker): 29/29 testów (`tests/run-tests.sh`), shellcheck 0 uwag
- Integracja w kontenerze: po seal `apt install`/`apt update`/`dpkg -i` odrzucone (kody 100/100/2) z komunikatem PL,
  `dpkg -l` działa; po unlock instalacja działa, pliki blokady usunięte
- `collab -y` i interaktywnie (odrzuca `http://`, przyjmuje `https://`) na atrapie `/etc/omnissa`
- `domain` z True SSO: baza CA SSSD, `pam_cert_auth`, `certificate_verification`, `pkinit_anchors`; zły PEM → kod 1
- `fido` bez klucza: instaluje fido2-tools, zgłasza brak urządzenia
- Agent na sztucznych archiwach: instalacja → pominięcie → upgrade → odmowa starszej wersji → blokada przy działającym BlastServer
- `adopt -y` na symulowanym obrazie (gdm3/GNOME, winbind, NFS w fstab, agent z OfflineJoinDomain=samba i RunOnceScript):
  podgląd nic nie zapisuje, kroki przejęte i pomijane, samba zachowane, RunOnceScript podpięty
- `get-vdi-imagemaint.sh` z GitHuba (wydanie 0.2.0 i „najnowsze”): suma OK, konfiguracja i Horizon/ zachowane
- `help`, `status`, `check` (PL), nieznany tryb/opcja → kod 2
- **Nie testowano na VM**: prepare, nfs, agent, optimize (systemd, dconf, polkit), seal z wyłączeniem, RunOnce na klonie

## Do weryfikacji na VM / w dokumentacji Omnissa
1. Klucze `viewagent-custom.conf` i `config` dla agenta 2506 (`OfflineJoinDomain`, `RunOnceScript*`, `CollaborationEnable`,
   `collaboration.serverUrl/enableEmail/enableControlPassing/maxCollabors`) oraz katalog `/etc/omnissa` vs `/etc/vmware`
2. Budowa VHCI przez DKMS z PRE_BUILD (hcd.h) na prawdziwym jądrze Debiana 12; Secure Boot (podpis MOK) – tylko ostrzeżenie
8. `gnome-shell-extension-appindicator` w MATE (wymagany przez instalator agenta, ciągnie gnome-shell)
9. Recording: rejestracja z `-t` na obrazie i działanie na klonach
3. `realm join` + nasz sssd.conf a ClonePrep z OfflineJoinDomain=sssd na klonie (konto komputera, keytab, dyndns)
4. Montowanie NFS krb5p na klonie po logowaniu SSO (bilet w FILE:/tmp, rpc.gssd)
5. True SSO na Linuksie: czy agent 2506 wymaga dodatkowych ustawień poza SSSD/PKINIT (Enrollment Server, szablon certyfikatu)
6. Przekierowanie FIDO2 w agencie Linux 2506 (przełącznik instalatora, polityka w kliencie)
7. Reguła polkit „power” – czy MATE ukrywa przyciski wyłączenia

## Plan
1. Test na VM: budowa od ISO → seal → pula Instant Clone → logowanie, NFS, collaboration przez UAG
2. Poprawki po teście, wersja 0.2.0
3. Raport HTML cyklu (jak w Windows), ewentualnie Ubuntu jako drugi system
