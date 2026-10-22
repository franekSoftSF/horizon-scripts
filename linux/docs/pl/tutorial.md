# Krok po kroku: obraz wzorcowy Linux dla Horizon z VDI-ImageMaint

Proste instrukcje, po kolei. Wersja angielska: [../tutorial.md](../tutorial.md).
Szczegóły każdego kroku: [linux.md](linux.md).

Wszystko wpisujesz **na maszynie wzorcowej**, z **konsoli vSphere**, zalogowany na **lokalne**
konto administratora (np. `sysadmin`) — nie na konto domenowe. Jego `sudo` działa nawet wtedy,
gdy domena nie działa.

Dwie drogi:

* **Droga A — obraz, który już masz** (w domenie, z agentem): kroki 1–3, potem A1–A9.
* **Droga B — nowy obraz** ze świeżego Debiana 12 lub 13: kroki 1–3, potem B1–B10.

Potem dla obu: krok 4 (zaplombowanie i publikacja) i krok 5 (co miesiąc).

**(S)** = **przed** tym krokiem zrób snapshot maszyny w vCenter, a po nim zaloguj się raz kontem
domenowym w nowej sesji. Jeśli logowanie nie działa, wróć do snapshotu.

---

## Gdzie co wrzucić

| Co | Gdzie na maszynie | Do czego |
|---|---|---|
| Agent Horizon `Omnissa-horizonagent-linux-x86_64-*.tar.gz` (Omnissa Customer Connect) | `/opt/vdi-imagemaint/Horizon/` | `agent` — Debian 13 wymaga **2606 lub nowszego** |
| Agent nagrywania `Horizon.Recording.Linux.Agent-*.tar.gz` (opcjonalnie) | `/opt/vdi-imagemaint/Horizon/` | `recording` |
| VS Code `code_*.deb` (opcjonalnie) | `/opt/vdi-imagemaint/Horizon/` | `courses` |
| Źródła sterownika USB 3.0 `vhci-hcd-1.15.tar.gz` | `/opt/vdi-imagemaint/Horizon/` — **pobierane samo** | `usb`, `agent` |
| Certyfikaty CA (PEM): główne CA i CA wystawiające certyfikaty logowania | `/opt/vdi-imagemaint/certs/` | True SSO / karta (`domain`) |
| Ustawienia | `/opt/vdi-imagemaint/vdi-imagemaint.conf` (zapisuje je `adopt` albo kopiujesz z przykładu) | wszystko |
| Logi, diagnoza | `/var/log/vdi-imagemaint/` | sprawdzenie, co się stało |

Na obrazach przygotowanych ręcznie narzędzie znajdzie archiwum agenta także w `/install`.

Jak wgrać pliki na maszynę: WinSCP z komputera do `/tmp`, potem
`sudo cp /tmp/<plik> /opt/vdi-imagemaint/Horizon/` — albo pendrive, albo ISO z datastore.

---

## 1. Tylko świeży Debian: curl i sudo

Jeśli brakuje `sudo` albo `curl`, zaloguj się jako root (`su -`) i wpisz:

```bash
apt-get update && apt-get install -y curl ca-certificates sudo
```

## 2. Zainstaluj narzędzie

Jedno polecenie (wystarczy `wget`):

```bash
wget -qO- https://github.com/franekSoftSF/horizon-scripts/releases/latest/download/get-vdi-imagemaint.sh | sudo bash
```

Instaluje do `/opt/vdi-imagemaint`, zakłada `Horizon/` i `certs/` i pobiera źródła sterownika USB.
Od teraz narzędzie samo aktualizuje się z GitHuba przy każdym uruchomieniu.

## 3. Skopiuj pliki

Skopiuj archiwum agenta (i opcjonalne) do `/opt/vdi-imagemaint/Horizon/`, a przy True SSO lub kartach
certyfikaty CA do `/opt/vdi-imagemaint/certs/` — zobacz tabelę wyżej. Potem:

```bash
cd /opt/vdi-imagemaint
```

---

## Droga A — obraz, który już masz

**A1. Niech narzędzie pozna obraz.** Odczytuje, co jest zainstalowane, i samo zapisuje
`vdi-imagemaint.conf`. W systemie nic się nie zmienia.

```bash
sudo ./vdi-imagemaint.sh adopt
```

**A2. Sprawdzenie.** Oczekiwane 0 ERR. Linie WARN mówią, co można poprawić.

```bash
sudo ./vdi-imagemaint.sh check
```

**A3. (S) Aktualizacja pakietów i agentów.** Restart, jeśli narzędzie poprosi.

```bash
sudo ./vdi-imagemaint.sh update
```

**A4. (S) Katalogi NFS montowane przy pierwszym dostępie** (tylko gdy katalogi domowe są z udziału NFS
w fstab). Potem `sudo reboot` i test logowania domenowego.

```bash
sudo ./vdi-imagemaint.sh nfsmount
```

**A5. (S) Sterownik USB 3.0 / FIDO2.** Potem `sudo reboot`.

```bash
sudo ./vdi-imagemaint.sh usb
```

**A6. (S) Zabezpieczenie Kerberos** (hasło komputera ważne w każdym snapshocie). Potem `sudo reboot`
i test logowania domenowego.

```bash
sudo ./vdi-imagemaint.sh kerberos
```

**A7. (S) True SSO / karta** (tylko jeśli ich używasz). Otwórz ustawienia:

```bash
sudo nano vdi-imagemaint.conf
```

i ustaw (nazwy Twoich plików w `certs/`; adresy CRL poda zespół PKI):

```bash
TRUESSO_ENABLE="yes"
SMARTCARD_ENABLE="no"
CERT_CA_FILES="root-ca.pem issuing-ca.pem"
CERT_REVOCATION="crl"
CERT_CRL_URLS="http://pki.example.edu/CertEnroll/Root.crl http://pki.example.edu/CertEnroll/Issuing.crl"
```

Potem:

```bash
sudo ./vdi-imagemaint.sh domain
sudo ./vdi-imagemaint.sh check
```

Na przejętym obrazie to dodaje **tylko** osobny plik SSSD dla certyfikatów; Twój `sssd.conf` się nie
zmienia. Linie L18 i L28–L31 w `check` muszą być OK. Jeśli nie wiesz, jakie sprawdzanie unieważnień
wybrać: `none` zawsze działa dla True SSO; `crl` sprawdza też unieważnione karty.

**A8. Aplikacje do zajęć, przyspieszenie, współdzielenie sesji.**

```bash
sudo ./vdi-imagemaint.sh courses
sudo ./vdi-imagemaint.sh optimize
sudo ./vdi-imagemaint.sh collab
```

`collab` pyta o każde ustawienie, w tym o link UAG.

**A9. Jeszcze jedno sprawdzenie.**

```bash
sudo ./vdi-imagemaint.sh check
```

Przejdź do **kroku 4**.

---

## Droga B — nowy obraz

**B1. Ustawienia.**

```bash
sudo cp vdi-imagemaint.conf.example vdi-imagemaint.conf
sudo nano vdi-imagemaint.conf
```

Uzupełnij co najmniej: `AD_DOMAIN`, `AD_JOIN_USER` (konto, które może dodawać komputery do domeny),
`AD_COMPUTER_OU`, `AD_ACCESS_GROUPS`, `AD_SUDO_GROUPS`, `NFS_SERVER`, `NFS_EXPORT`. Dla jednego udziału
NFS jak na obecnych obrazach: `NFS_MODE="fstab"`, `NFS_MOUNTPOINT="/home/STUDENT"`,
`HOME_ROOT="/home/STUDENT"`, `NFS_SEC="krb5"`. Dla True SSO / karty także linie z A7.

**B2. System bazowy** (pakiety, pulpit MATE, język, czas).

```bash
sudo ./vdi-imagemaint.sh prepare
```

**B3. Domena** (SSSD, dołączenie — pyta o hasło konta `AD_JOIN_USER`; logowanie certyfikatem, jeśli włączone).

```bash
sudo ./vdi-imagemaint.sh domain
```

**B4. Katalogi domowe NFS.**

```bash
sudo ./vdi-imagemaint.sh nfs
```

**B5. Agent Horizon** i sterownik USB. Potem `sudo reboot`.

```bash
sudo ./vdi-imagemaint.sh agent
```

**B6. Nagrywanie** (opcjonalnie, pyta o hasło).

```bash
sudo ./vdi-imagemaint.sh recording
```

**B7. Aplikacje** (Eclipse, aplikacje do zajęć, folder „Zajęcia”).

```bash
sudo ./vdi-imagemaint.sh apps
sudo ./vdi-imagemaint.sh courses
```

**B8. Przyspieszenie.**

```bash
sudo ./vdi-imagemaint.sh optimize
```

**B9. Współdzielenie sesji** (pyta o link UAG).

```bash
sudo ./vdi-imagemaint.sh collab
```

**B10. Sprawdzenie.** Oczekiwane 0 ERR.

```bash
sudo ./vdi-imagemaint.sh check
```

---

## 4. Zaplombowanie i publikacja (obie drogi)

**(S)** Seal: sprawdza obraz, blokuje instalowanie pakietów, ukrywa użytkownikom „Wyłącz” i
„Uruchom ponownie” i wyłącza maszynę.

```bash
sudo ./vdi-imagemaint.sh seal
```

Potem w vCenter: snapshot. W Horizon: **Push Image** tego snapshotu — **najpierw na pulę testową**.
Zaloguj się na klon przez Connection Server kontem domenowym (i przez True SSO lub kartą, jeśli ich
używasz). Sprawdź katalog domowy i bilet:

```bash
ls ~
klist
```

Bilet w `klist` oznacza, że Kerberos (a przy True SSO także PKINIT) działa.

Jeśli klony nie startują albo nikt nie może się zalogować: w ustawieniach puli włącz *Stop
provisioning on error*, zaloguj się na zepsuty klon lokalnym administratorem i uruchom:

```bash
sudo /opt/vdi-imagemaint/vdi-imagemaint.sh diag
```

Raport jest w `/var/log/vdi-imagemaint/diag-*.txt`.

## 5. Co miesiąc

Włącz maszynę wzorcową, potem:

```bash
sudo /opt/vdi-imagemaint/vdi-imagemaint.sh update --then-seal
```

Jeśli poprosi o restart: `sudo reboot`, potem `sudo /opt/vdi-imagemaint/vdi-imagemaint.sh seal`.
Snapshot, Push Image (najpierw pula testowa).

---

## Przydatne zawsze

| Polecenie | Co robi |
|---|---|
| `sudo ./vdi-imagemaint.sh` | menu (nie trzeba pamiętać nazw trybów) |
| `sudo ./vdi-imagemaint.sh status` | wersja, co zostało zrobione, czy obraz jest zaplombowany |
| `sudo ./vdi-imagemaint.sh unlock` | cofa seal (żeby coś zainstalować lub zmienić) |
| `sudo ./vdi-imagemaint.sh optimize --revert` | cofa przyspieszenie |
| `sudo ./vdi-imagemaint.sh diag` | diagnoza tylko do odczytu, zapis do pliku |
| `sudo ./vdi-imagemaint.sh --lang pl-PL check` | komunikaty po polsku |
