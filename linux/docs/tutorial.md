# Step by step: a Linux golden image for Horizon with VDI-ImageMaint

Plain instructions, in order. Polish version: [pl/tutorial.md](pl/tutorial.md).
Details behind every step: [linux.md](linux.md).

You type everything **in the golden VM**, from the **vSphere console**, logged in as the **local**
admin account (for example `sysadmin`) — not as a domain user. Its `sudo` keeps working even when
the domain does not.

Two ways:

* **Path A — an image you already have** (joined to the domain, agent installed): steps 1–3, then A1–A9.
* **Path B — a new image** from a fresh Debian 12 or 13: steps 1–3, then B1 (guided setup).

Then for both: step 4 (seal and publish) and step 5 (every month).

**(S)** = take a vCenter snapshot of the VM **before** this step, and after it log in once with a
domain account in a new session. If that logon fails, go back to the snapshot.

---

## Where every file goes

| What | Where on the VM | Needed for |
|---|---|---|
| Horizon Linux Agent `Omnissa-horizonagent-linux-x86_64-*.tar.gz` (Omnissa Customer Connect) | `/opt/vdi-imagemaint/Horizon/` | `agent` — Debian 13 needs **2606 or newer** |
| Horizon Recording Agent `Horizon.Recording.Linux.Agent-*.tar.gz` (optional) | `/opt/vdi-imagemaint/Horizon/` | `recording` |
| VS Code `code_*.deb` (optional) | `/opt/vdi-imagemaint/Horizon/` | `courses` |
| USB 3.0 driver source `vhci-hcd-1.15.tar.gz` | `/opt/vdi-imagemaint/Horizon/` — **downloaded for you** | `usb`, `agent` |
| CA certificates (PEM): root CA and issuing CA of the logon certificates | `/opt/vdi-imagemaint/certs/` | True SSO / smart card (`domain`) |
| Settings | `/opt/vdi-imagemaint/vdi-imagemaint.conf` (written by `adopt`, or copied from the example) | everything |
| Logs, diagnostics | `/var/log/vdi-imagemaint/` | reading what happened |

On images prepared by hand, the tool also finds the agent archive in `/install`.

How to get files onto the VM: WinSCP from your PC to `/tmp`, then
`sudo cp /tmp/<file> /opt/vdi-imagemaint/Horizon/` — or a USB stick, or a datastore ISO.

---

## 1. Fresh Debian only: curl and sudo

If `sudo` or `curl` is missing, log in as root (`su -`) and run:

```bash
apt-get update && apt-get install -y curl ca-certificates sudo
```

## 2. Install the tool

One command (works with `wget` only):

```bash
wget -qO- https://github.com/franekSoftSF/horizon-scripts/releases/latest/download/get-vdi-imagemaint.sh | sudo bash
```

It installs to `/opt/vdi-imagemaint`, creates `Horizon/` and `certs/`, and downloads the USB driver
source. From now on the tool updates itself from GitHub every time it starts.

## 3. Copy the files

Copy the agent archive (and the optional ones) to `/opt/vdi-imagemaint/Horizon/` and, for True SSO
or smart cards, the CA certificates to `/opt/vdi-imagemaint/certs/` — see the table above. Then:

```bash
cd /opt/vdi-imagemaint
```

---

## Path A — an image you already have

**A1. Let the tool learn the image.** It reads what is there and writes `vdi-imagemaint.conf` for you.
Nothing on the system is changed.

```bash
sudo ./vdi-imagemaint.sh adopt
```

**A2. Check.** Expect 0 ERR. WARN lines say what could be better.

```bash
sudo ./vdi-imagemaint.sh check
```

**A3. (S) Update packages and agents.** Reboot if it asks.

```bash
sudo ./vdi-imagemaint.sh update
```

**A4. (S) NFS homes mounted on first access** (only if homes come from an NFS share in fstab). Then
`sudo reboot` and test a domain logon.

```bash
sudo ./vdi-imagemaint.sh nfsmount
```

**A5. (S) USB 3.0 / FIDO2 driver.** Then `sudo reboot`.

```bash
sudo ./vdi-imagemaint.sh usb
```

**A6. (S) Kerberos safety** (the machine password stays valid in every snapshot). Then `sudo reboot`
and test a domain logon.

```bash
sudo ./vdi-imagemaint.sh kerberos
```

**A7. (S) True SSO / smart card** (only if you use them). Open the settings:

```bash
sudo nano vdi-imagemaint.conf
```

and set (names of your files in `certs/`; ask your PKI team for the CRL addresses):

```bash
TRUESSO_ENABLE="yes"
SMARTCARD_ENABLE="no"
CERT_CA_FILES="root-ca.pem issuing-ca.pem"
CERT_REVOCATION="crl"
CERT_CRL_URLS="http://pki.example.edu/CertEnroll/Root.crl http://pki.example.edu/CertEnroll/Issuing.crl"
```

Then:

```bash
sudo ./vdi-imagemaint.sh domain
sudo ./vdi-imagemaint.sh check
```

On an adopted image this adds **only** a separate SSSD file for certificates; your `sssd.conf` is
not changed. Lines L18 and L28–L31 of `check` must be OK. If you are unsure which revocation to
choose: `none` always works for True SSO; `crl` also checks revoked smart cards.

**A8. Course apps, tuning, Session Collaboration.**

```bash
sudo ./vdi-imagemaint.sh courses
sudo ./vdi-imagemaint.sh optimize
sudo ./vdi-imagemaint.sh collab
```

`collab` asks for each setting, including the UAG link.

**A9. Check once more.**

```bash
sudo ./vdi-imagemaint.sh check
```

Go to **step 4**.

---

## Path B — a new image

**Do not run `adopt` here.** It is for images built without this tool. On a fresh
Debian it now notices that and offers the guided setup instead.

**B1. Guided setup.** It asks for the settings, saves them, then offers every step in
order (prepare → domain → nfs → agent → reboot → recording → apps → courses → optimize →
collab → check):

```bash
sudo ./vdi-imagemaint.sh setup
```

* Every question shows the current value in `[brackets]`; **Enter** keeps it, `-` clears
  an optional one. Have ready: AD domain, the account that may join computers, the NFS server
  and export, and, for True SSO, the CA files in `certs/`.
* Before each step it asks **"Run step … now?"**. Answer `n` to skip that step (it is offered
  again next time); `Ctrl+C` stops.
* `domain` asks for the password of the join account.
* After `agent` it asks to **reboot**. After the reboot run `setup` again: finished steps are
  skipped, it continues with the next one.
* If the agent archive is not in `Horizon/` yet, setup stops there and says where to put it.

When it says *All steps done*, test a domain logon and go to **step 4**.

**Manual alternative** (the same steps one by one):

```bash
sudo ./vdi-imagemaint.sh prepare
sudo ./vdi-imagemaint.sh domain
sudo ./vdi-imagemaint.sh nfs
sudo ./vdi-imagemaint.sh agent      # then: sudo reboot
sudo ./vdi-imagemaint.sh recording  # optional
sudo ./vdi-imagemaint.sh apps
sudo ./vdi-imagemaint.sh courses
sudo ./vdi-imagemaint.sh optimize
sudo ./vdi-imagemaint.sh collab
sudo ./vdi-imagemaint.sh check
```

The settings for the manual way are in `vdi-imagemaint.conf`; copy `vdi-imagemaint.conf.example`
to it and fill in at least `AD_DOMAIN`, `AD_JOIN_USER`, the `NFS_*` lines and, for True SSO, the
lines from A7.

---

## 4. Seal and publish (both paths)

**(S)** Seal: it checks the image, locks package installs, hides shut down and restart from users,
and powers the VM off.

```bash
sudo ./vdi-imagemaint.sh seal
```

Then in vCenter: take a snapshot. In Horizon: **Push Image** of that snapshot — to a **test pool
first**. Log in to a clone through the Connection Server with a domain account (and with True SSO
or a card if you use them). Check that the home directory is there:

```bash
ls ~
klist
```

`klist` showing a ticket means Kerberos (and for True SSO: PKINIT) works.

If the clones do not start or nobody can log in: in the pool settings turn on *Stop provisioning
on error*, log in to the broken clone with the local admin and run:

```bash
sudo /opt/vdi-imagemaint/vdi-imagemaint.sh diag
```

The report is saved in `/var/log/vdi-imagemaint/diag-*.txt`.

## 5. Every month

Power on the golden VM, then:

```bash
sudo /opt/vdi-imagemaint/vdi-imagemaint.sh update --then-seal
```

If it asks for a reboot: `sudo reboot`, then `sudo /opt/vdi-imagemaint/vdi-imagemaint.sh seal`.
Snapshot, Push Image (test pool first).

---

## Useful at any time

| Command | What it does |
|---|---|
| `sudo ./vdi-imagemaint.sh` | menu (no need to remember mode names) |
| `sudo ./vdi-imagemaint.sh status` | version, what has been done, sealed or not |
| `sudo ./vdi-imagemaint.sh unlock` | undo a seal (to install or change something) |
| `sudo ./vdi-imagemaint.sh optimize --revert` | undo the tuning |
| `sudo ./vdi-imagemaint.sh diag` | read-only diagnosis, saved to a file |
| `sudo ./vdi-imagemaint.sh --lang pl-PL check` | messages in Polish |
