<!-- Release notes template: every linux-v* release carries the complete procedure (users read it in the VDI browser,
     there is no clipboard). Replace {{VERSION}} and {{CHANGES}}. Stable links: releases/latest and
     releases/latest/download/get-vdi-imagemaint.sh. -->
VDI-ImageMaint for Linux **{{VERSION}}** – golden-image tool for **Debian 12** (MATE session, GDM, Horizon SSO) on **Omnissa Horizon 8 Instant Clone**.

## 0. Fresh Debian: curl and sudo

A fresh Debian 12 has `wget` but no `curl`. If you set a root password during the installation, `sudo` is missing
too. Then run as root (`su -`):

```bash
apt-get update && apt-get install -y curl ca-certificates sudo
```

Shortest way: one command installs everything below (works with wget alone, curl is added automatically):

```bash
wget -qO- https://github.com/franekSoftSF/horizon-scripts/releases/latest/download/get-vdi-imagemaint.sh | sudo bash
```

## 1. Download and install by hand (golden image)

```bash
cd /tmp
curl -fsSLO https://github.com/franekSoftSF/horizon-scripts/releases/download/linux-v{{VERSION}}/vdi-imagemaint-linux-{{VERSION}}.tar.gz
curl -fsSLO https://github.com/franekSoftSF/horizon-scripts/releases/download/linux-v{{VERSION}}/vdi-imagemaint-linux-{{VERSION}}.tar.gz.sha256
sha256sum -c vdi-imagemaint-linux-{{VERSION}}.tar.gz.sha256
sudo tar -xzf vdi-imagemaint-linux-{{VERSION}}.tar.gz -C /opt
sudo mkdir -p /opt/vdi-imagemaint/Horizon /opt/vdi-imagemaint/certs
cd /opt/vdi-imagemaint
```

Copy into `/opt/vdi-imagemaint/Horizon/`:
- `Omnissa-horizonagent-linux-x86_64-*.tar.gz` (Customer Connect);
- optionally `Horizon.Recording.Linux.Agent-*.tar.gz` and `code_*.deb` (VS Code).

On images prepared by hand, the tool also looks in `/install`.

From now on, the tool upgrades itself from GitHub at every start.

## 2a. EXISTING golden image (already in the domain, agent installed)

Take a vCenter snapshot before every step marked (S). After those steps, test a domain logon in a **new** session.

```bash
sudo ./vdi-imagemaint.sh adopt          # detects the image, creates vdi-imagemaint.conf, shows a diff, keeps your setup
sudo ./vdi-imagemaint.sh check          # 0 ERR expected
sudo ./vdi-imagemaint.sh usb            # (S) USB 3.0 / FIDO2 driver (VHCI), then: sudo reboot
sudo ./vdi-imagemaint.sh kerberos       # (S) machine password / time sync safety, then: sudo reboot + logon test
sudo ./vdi-imagemaint.sh courses        # installs course apps, "Courses" folder in the MATE menu
sudo ./vdi-imagemaint.sh optimize       # VDI tuning (undo: optimize --revert)
sudo ./vdi-imagemaint.sh collab         # Session Collaboration, asks for the UAG link
sudo ./vdi-imagemaint.sh check
sudo ./vdi-imagemaint.sh seal           # (S) last step, powers off -> snapshot -> Push Image
```

## 2b. NEW golden image (fresh Debian 12)

```bash
sudo cp vdi-imagemaint.conf.example vdi-imagemaint.conf
sudo nano vdi-imagemaint.conf           # AD domain, join account, NFS, ...
sudo ./vdi-imagemaint.sh prepare        # packages, MATE + GDM, locale, time
sudo ./vdi-imagemaint.sh domain         # SSSD, realm join (asks for the password)
sudo ./vdi-imagemaint.sh nfs            # NFSv4 + Kerberos homes
sudo ./vdi-imagemaint.sh agent          # Horizon agent + USB driver, then: sudo reboot
sudo ./vdi-imagemaint.sh apps           # Eclipse + course apps + "Courses" folder
sudo ./vdi-imagemaint.sh optimize
sudo ./vdi-imagemaint.sh collab
sudo ./vdi-imagemaint.sh check
sudo ./vdi-imagemaint.sh seal
```

## 3. Every month

```bash
sudo /opt/vdi-imagemaint/vdi-imagemaint.sh update --then-seal
```

Reboot when the tool asks for it, then run `seal`. After that, take a snapshot and run Push Image.

## When something is wrong

```bash
sudo /opt/vdi-imagemaint/vdi-imagemaint.sh diag     # read-only, saved to /var/log/vdi-imagemaint/diag-*.txt
sudo /opt/vdi-imagemaint/vdi-imagemaint.sh status
sudo /opt/vdi-imagemaint/vdi-imagemaint.sh unlock   # reverse a seal
```

Logs are in `/var/log/vdi-imagemaint/`. Running `sudo ./vdi-imagemaint.sh` without a mode opens the menu.

## New in {{VERSION}}
{{CHANGES}}

---

## PL – całość krok po kroku

**0. Świeży Debian:** nie ma `curl` (jest `wget`). Jeśli przy instalacji ustawiono hasło roota, nie ma też `sudo`.
Wtedy jako root (`su -`): `apt-get update && apt-get install -y curl ca-certificates sudo`. Najkrócej, bez `curl`:
`wget -qO- https://github.com/franekSoftSF/horizon-scripts/releases/latest/download/get-vdi-imagemaint.sh | sudo bash`

**1. Pobranie i instalacja** – polecenia z punktu 1 powyżej. Potem skopiuj archiwum agenta Horizon do `/opt/vdi-imagemaint/Horizon/`. Na obrazach przygotowanych ręcznie narzędzie szuka też w `/install`.

**2a. Istniejący obraz.** Przed krokami oznaczonymi (S) zrób snapshot. Po tych krokach przetestuj logowanie domenowe w nowej sesji. Kolejność:
1. `adopt` – rozpoznaje obraz i sam tworzy konfigurację.
2. `check`
3. `usb`, potem restart.
4. `kerberos`, potem restart i test logowania.
5. `courses` – aplikacje do zajęć i folder Zajęcia.
6. `optimize`
7. `collab` – pyta o link UAG.
8. `check`
9. `seal`, potem snapshot i Push Image.

**2b. Nowy obraz.** Skopiuj `vdi-imagemaint.conf.example` do `vdi-imagemaint.conf` i uzupełnij. Kolejność:
1. `prepare`
2. `domain`
3. `nfs`
4. `agent`, potem restart.
5. `apps`
6. `optimize`
7. `collab`
8. `check`
9. `seal`

**3. Co miesiąc:** `sudo /opt/vdi-imagemaint/vdi-imagemaint.sh update --then-seal`.

**Problem:** `diag` – diagnoza tylko do odczytu, zapisywana do pliku.
