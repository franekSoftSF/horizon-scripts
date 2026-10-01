# Status – VDI-ImageMaint dla Linuksa

_Aktualizacja: 2026-10-01_ · wersja **0.1.0** · Debian 12 + MATE · Horizon 2506 Instant Clone

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

## Jak testowano (bez VM)
- Kontener `debian:12` (Docker): 25/25 testów (`tests/run-tests.sh`), shellcheck 0 uwag
- Integracja w kontenerze: po seal `apt install`/`apt update`/`dpkg -i` odrzucone (kody 100/100/2) z komunikatem PL,
  `dpkg -l` działa; po unlock instalacja działa, pliki blokady usunięte
- `collab -y` i interaktywnie (odrzuca `http://`, przyjmuje `https://`) na atrapie `/etc/omnissa`
- `domain` z True SSO: baza CA SSSD, `pam_cert_auth`, `certificate_verification`, `pkinit_anchors`; zły PEM → kod 1
- `fido` bez klucza: instaluje fido2-tools, zgłasza brak urządzenia
- `help`, `status`, `check` (PL), nieznany tryb/opcja → kod 2
- **Nie testowano na VM**: prepare, nfs, agent, optimize (systemd, dconf, polkit), seal z wyłączeniem, RunOnce na klonie

## Do weryfikacji na VM / w dokumentacji Omnissa
1. Klucze `viewagent-custom.conf` i `config` dla agenta 2506 (`OfflineJoinDomain`, `RunOnceScript*`, `CollaborationEnable`,
   `collaboration.serverUrl/enableEmail/enableControlPassing/maxCollabors`) oraz katalog `/etc/omnissa` vs `/etc/vmware`
2. Parametry `install_viewagent.sh` (domyślnie tylko `-A yes`)
3. `realm join` + nasz sssd.conf a ClonePrep z OfflineJoinDomain=sssd na klonie (konto komputera, keytab, dyndns)
4. Montowanie NFS krb5p na klonie po logowaniu SSO (bilet w FILE:/tmp, rpc.gssd)
5. True SSO na Linuksie: czy agent 2506 wymaga dodatkowych ustawień poza SSSD/PKINIT (Enrollment Server, szablon certyfikatu)
6. Przekierowanie FIDO2 w agencie Linux 2506 (przełącznik instalatora, polityka w kliencie)
7. Reguła polkit „power” – czy MATE ukrywa przyciski wyłączenia

## Plan
1. Test na VM: budowa od ISO → seal → pula Instant Clone → logowanie, NFS, collaboration przez UAG
2. Poprawki po teście, wersja 0.2.0
3. Raport HTML cyklu (jak w Windows), ewentualnie Ubuntu jako drugi system
