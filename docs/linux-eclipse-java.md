# Eclipse + Java on a Debian Horizon Instant Clone desktop

Component: `linux/apps/eclipse-java.sh` (standalone, idempotent, EN/PL messages).
Target: Debian 12/13 amd64, MATE + LightDM, Horizon Linux Agent, Instant Clone,
AD (SSSD) login, home directories on **NFSv4 with `sec=krb5*`** (autofs).

## What it does

| Part | Where | Notes |
|---|---|---|
| JDK (default **Temurin 25 LTS**) | `/usr/lib/jvm/...`, `/etc/profile.d/vdi-java.sh` | Adoptium apt repo or Debian `openjdk-N-jdk`; set as system default (`java`, `javac`, `jshell`) |
| Eclipse IDE for Java (default **2026-09**) | `/opt/vdi-apps/eclipse-java-2026-09`, symlink `/opt/vdi-apps/eclipse` | read-only shared install, SHA-512 checked, previous release kept for rollback |
| Launcher | `/opt/vdi-apps/bin/vdi-eclipse` | checks the NFS home is writable and a Kerberos ticket exists, shows an EN/PL dialog otherwise |
| MATE menu | `/usr/share/applications/vdi-eclipse.desktop` | **Applications > Programming**; optional extra submenu (`MENU_SUBMENU`) |
| Desktop icon (optional) | `/etc/xdg/autostart/vdi-eclipse-user.desktop` | created **at login, as the user**, once (deleting it is respected) |

## Why it is built this way (NFS + Kerberos + Instant Clone)

- **root cannot write to the users' homes** (`sec=krb5*`: root has no user ticket) and `/etc/skel`
  is never copied to NFS homes. So nothing per-user is prepared on the image: menu entries are
  system-wide, the desktop icon is made by the user's own session at login.
- **Read-only install**: users cannot update Eclipse or break it for others; Eclipse writes its
  per-user configuration to `~/.eclipse` and the workspace to `~/eclipse-workspace` – both on NFS,
  so they survive the clone being deleted at logoff. Update checks are switched off
  (`vdi-plugin_customization.ini`); a new Eclipse comes with the next golden image.
- **No `/root/.eclipse` in the image**: headless steps (`-initialize`, plugin installation) run with a
  throw-away `HOME`.
- **Eclipse needs Java 25 to run (2026-09)** – read from `-Dosgi.requiredJavaVersion` in the release's
  `eclipse.ini`. If the course JDK is at least that, Eclipse runs on it and it is the default JRE for new
  projects. If the course uses an older JDK (e.g. 21), Eclipse runs on its bundled JRE, the course JDK is
  detected from `/usr/lib/jvm` and the compiler level defaults to the course version.
- **Workspace locks**: NFSv4 has locking in the protocol, so the Equinox default is kept. A clone that
  is destroyed without closing Eclipse releases its lock when the NFSv4 lease expires (≈90 s): a user who
  logs on again immediately can briefly see "workspace in use". Use `ECLIPSE_OSGI_LOCKING=none` only if
  the NFS server has no working locks.
- **Ticket lifetime**: when the Kerberos ticket expires, NFS access stops and Eclipse cannot save.
  SSSD renews tickets (`krb5_renew_interval`, renewable 7 days, set by the `domain` step); check that
  the AD ticket policy allows renewal. The launcher warns if there is no ticket at start.

## Existing and new desktops

Instant clones are never changed one by one – they are forked from the golden image snapshot:

1. On the golden image: `vdi-imagemaint.sh unlock` (if sealed) → `apps` (or run
   `sudo linux/apps/eclipse-java.sh` directly) → test as a **domain user** → `check` → `seal` → power off.
2. vCenter: take a snapshot.
3. Horizon: **existing pools** – *Push Image* to the new snapshot (users get it at their next logon/refresh);
   **new pools** – choose this snapshot when creating the pool.

Users' NFS homes need no migration: the menu entry is in the image, the optional desktop icon is created
at their next login, older Eclipse settings stay in `~/.eclipse` (a new release gets its own folder).

Golden images that were built without VDI-ImageMaint work as well – the script only needs Debian and MATE.

## Configuration

Copy `linux/apps/eclipse-java.conf.example` to `linux/apps/eclipse-java.conf`. The main settings:
`JAVA_SOURCE`, `JAVA_VERSION`, `ECLIPSE_RELEASE`, `ECLIPSE_PACKAGE`, `ECLIPSE_P2_REPOS` /
`ECLIPSE_P2_FEATURES` (extra plugins), `MENU_SUBMENU`, `DESKTOP_ICON`. All defaults are at the top of the script.

Offline image build: put `eclipse-java-2026-09-R-linux-gtk-x86_64.tar.gz` and its `.sha512` from
<https://download.eclipse.org/technology/epp/downloads/release/2026-09/R/> into `linux/apps/Apps/`.
The JDK still needs the Adoptium or Debian apt repository (or a local mirror).

## Commands

```bash
sudo ./eclipse-java.sh               # install / update (same as --install)
sudo ./eclipse-java.sh --status      # what is installed, exit 1 if incomplete
sudo ./eclipse-java.sh --remove      # remove Eclipse + menu; --purge-java also removes the JDK
```

Log: `/var/log/vdi-imagemaint/apps-eclipse-java-YYYYMMDD.log`, state: `/var/lib/vdi-imagemaint/apps-eclipse-java.state`.

## Not covered / to check on the VM

- Login of a real AD user on a clone (NFS mount, ticket renewal over a long session) – needs the customer environment.
- Eclipse UI language is English (Babel Polish translations are incomplete).
- NFS quota: a workspace with Maven/Gradle caches (`~/.m2`, `~/.gradle`) grows quickly.
