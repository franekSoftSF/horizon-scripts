# XAS software (Demeter, Larch / Larix) on Instant Clone

> Polish version: [pl/demeter.md](pl/demeter.md)

Two packages for XAS / EXAFS courses, the same set as the Linux image (`libdemeter-perl`, `python3-xraylarch` /
Larix, ifeffit, feff):

| Package | Programs | Script | Folder |
|---|---|---|---|
| `Demeter` | Athena, Artemis, Hephaestus, Atoms (Perl, Ifeffit, Feff) | `Scripts\Install-Demeter.ps1` | `C:\DemeterPerl` |
| `Larch` | Larix (XANES / EXAFS GUI, Feff), XRF / XRFMap / XRD1D viewers, Larch CLI, Jupyter Lab (Python) | `Scripts\Install-Larch.ps1` | `C:\xraylarch` |

Both upstream installers are **per-user**; both scripts turn them into all-users installs with the same pattern:
fixed folder without spaces, Users read + execute only, launchers `<folder>\vdi\*.cmd` that set the environment per
process, an all-users Start menu group, a smoke test and an Uninstall entry that runs a copy of the script in
`<folder>\vdi`. Earlier per-user copies in any local profile are removed with their own uninstaller.

## Demeter

Demeter (<https://bruceravel.github.io/demeter/>) is the XAS data processing / EXAFS analysis suite built on a
bundled Strawberry Perl.

### Why the plain installer fails on VDI

`Demeter_<ver>_with_Strawberry_Perl_(64).exe` (Inno Setup, `PrivilegesRequired=lowest`,
[strawberry.iss](https://github.com/bruceravel/demeter/blob/master/win/inno/strawberry.iss)) is a **per-user** installer:

| What | Official installer | Effect on a golden image |
|---|---|---|
| Folder | `%APPDATA%\DemeterPerl` of the installing account | other users cannot reach it |
| `PATH` (perl\bin, perl\site\bin, c\bin) and `PGPLOT_DIR` | `HKCU\SYSTEM\CurrentControlSet\Control\Session Manager\Environment` – a key Windows never reads | `dathena.bat` finds no `perl.exe` / PGPLOT → the programs fail to start |
| Start menu | the installing account's group | nobody else sees the shortcuts |
| `.pl` / `.prj` / `.fpj` associations | written to the `HKCU` **root** (not `Software\Classes`) | never worked |

So "installed fine, but the programs do not start for users" is expected.

### What `Scripts\Install-Demeter.ps1` 1.1 does

0. Removes earlier per-user copies (Uninstall entry of this account, `%APPDATA%\DemeterPerl` of every local profile)
   with their `unins000.exe` (waits for the copy of the uninstaller that Inno Setup starts from `%TEMP%`) and that
   profile's Start menu group.
1. Installs silently into **`C:\DemeterPerl`** (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /TASKS="" /DIR=... /LOG=...`).
   The path must not contain spaces (Strawberry Perl). The installer's `[Run]` step `relocation.pl.bat` has no
   `postinstall` flag, so it runs in silent mode too and rewrites the Perl paths; step 5 checks it. An existing
   install with the same AppId (also ours) is uninstalled by the installer itself before an upgrade.
2. Cleans the per-user leftovers of the installing account (the PATH / `PGPLOT_DIR` values above and the then empty
   `HKCU\SYSTEM\...` keys, `HKCU\Environment`, the broken HKCU root keys, its Start menu group / desktop icons) and
   hides the installer's own Uninstall entry.
3. Permissions: Users read + execute, Administrators / SYSTEM full (subfolders of `C:\` otherwise give
   Authenticated Users Modify). A sample of the existing files is checked; if one is still writable for users the
   tree is reset to inherited permissions (`icacls <folder>\* /reset /T`).
4. Launchers `C:\DemeterPerl\vdi\Athena.cmd`, `Artemis.cmd`, `Hephaestus.cmd`, `Stand-alone-Atoms.cmd` set `PATH`
   (Demeter first) and `PGPLOT_DIR` per process and create `%APPDATA%\demeter` (logs, stash – in the FSLogix
   container). Start menu group **Demeter** for all users. Machine `PATH` is not touched unless `-AddToPath`
   (Strawberry's `c\bin` contains gcc and DLLs that can break other software).
5. `-Associate`: `.prj` → Athena, `.fpj` → Artemis in `HKLM\SOFTWARE\Classes`; `.prj` is skipped when another
   program owns it (ArcGIS / QGIS projection files).
6. Smoke test `perl.exe -MConfig -MDemeter` (Demeter version + Perl prefix below `C:\DemeterPerl` = relocation done),
   Uninstall entry *Demeter (Athena, Artemis, Hephaestus)* with the version.

Idempotent: the same version is not reinstalled, steps 0 and 2–6 are re-applied. `-WhatIf` and `-Uninstall` work;
it runs as an administrator or as SYSTEM (`-AsSystem`). Log: `C:\ProgramData\VDI-ImageMaint\Logs\Demeter_<date>.log`,
installer log `DemeterSetup_<date>.log`.

### Use

1. Put the 64-bit installer into `C:\install\Apps\Demeter\` (or enable `Demeter` in `C:\install\downloads.json`).
2. Package `Demeter` in `packages.json` (`Enabled: true`) → `-Mode Update` / `Install`, or directly:

   ```powershell
   C:\install\Scripts\Install-Demeter.ps1 -Associate
   ```

3. Test on a clone as an **ordinary user** (not the installing account): Athena, Artemis, Hephaestus from the
   Start menu, open a project, Feff run in Artemis. Then Seal + Push Image.

### Notes

- Demeter 0.9.26 (2018) is the last Windows release; no updater. The installer is not code-signed.
- User settings and logs live in `%APPDATA%\demeter` (FSLogix container) – nothing to exclude.
- The Perl launcher keeps a minimized console window open while the program runs – expected.

## Larch / Larix

Larch (<https://xraypy.github.io/xraylarch/>) is the Python XAS / XRF analysis library; **Larix** is its XANES /
EXAFS GUI (the successor of Athena / Artemis, Feff 6 and 8 built in).

### The official installer

`xraylarch-<YYYY-MM>-Windows-x86_64.exe` (~500 MB, from
<https://millenia.cars.aps.anl.gov/xraylarch/downloads/>) is a conda
[constructor](https://github.com/xraypy/xraylarch/tree/master/installers/conda_constructor) (NSIS) installer:

| What | Official installer (interactive) | Effect on a golden image |
|---|---|---|
| Folder | `C:\Users\<name>\xraylarch` or `%LOCALAPPDATA%\xraylarch` (domain) | other users cannot reach it |
| Larch itself | not in the installer: its post-install script runs `pip install "xraylarch[larix]"` from PyPI | needs internet at install time |
| Shortcuts | `larch -m` (pyshortcuts): Desktop folder `Larch` + Start menu of the installing account | nobody else sees them |
| Updates | "Update Larch" shortcut / `larch -u` = pip into the install folder | must stay an admin task |

The constructor's documented [command-line options](https://conda.github.io/constructor/cli-options/) do allow a
silent all-users install, which is what the script uses.

### What `Scripts\Install-Larch.ps1` 1.0 does

0. Removes earlier per-user copies (`Uninstall-xraylarch.exe` in `<profile>\xraylarch` or
   `<profile>\AppData\Local\xraylarch` of every local profile: `/S _?=<folder>`, then the folder) and that profile's
   `Desktop\Larch` / Start menu `Larch` folders.
1. Installs the conda base environment silently for all users into **`C:\xraylarch`** (no spaces – Larch requirement):

   ```text
   xraylarch-2026-03-Windows-x86_64.exe /S /InstallationType=AllUsers /AddToPath=0 /RegisterPython=0
       /NoShortcuts=1 /NoScripts=1 /KeepPkgCache=0 /D=C:\xraylarch
   ```

   `/D=` is last and unquoted (NSIS). `/NoScripts=1` skips the post-install script, so no pip run without a log and
   no icons on the installing account's desktop. A newer installer (release in the file name) replaces the folder –
   conda installers do not upgrade in place.
2. `python.exe -m pip install --no-cache-dir "xraylarch[larix]"` with the conda environment, log `LarchPip_<date>.log`;
   only after an install, with `-Upgrade` (newest xraylarch from PyPI between installer releases) or when
   `import larch` fails. `-Requirement 'xraylarch[larix]==2026.3.1'` pins a version. **Needs HTTPS to `pypi.org` and
   `files.pythonhosted.org`** (also from SYSTEM if `-AsSystem` is used – check the proxy).
3. Removes `Desktop\Larch` / Start menu `Larch` of the installing account (older installers without `/NoScripts`)
   and hides the constructor's own Uninstall entry.
4. Permissions as for Demeter: Users read + execute – users cannot pip-install into the shared environment.
5. Launchers `C:\xraylarch\vdi\*.cmd` set `PATH` like `conda activate` (`<folder>`, `Library\mingw-w64\bin`,
   `Library\usr\bin`, `Library\bin`, `Scripts`, `bin`), `CONDA_PREFIX`, `PYTHONNOUSERSITE=1` (a user's own
   `pip --user` packages cannot break the GUIs) and start in `%USERPROFILE%`. Start menu group **Larch** for all
   users: Larix, XRF Viewer, XRFMap Viewer, XRD1D Viewer, Sitka, Jupyter Lab, Larch CLI (those whose `Scripts\*.exe`
   exist). The upstream "Update Larch" shortcut is left out on purpose.
6. Smoke test `python -c "import larch, wx"`, Uninstall entry *Larch / Larix (xraylarch)* with the xraylarch version
   (value `InstallerRelease` = installer release, used for idempotence).

Idempotent, `-WhatIf`, `-Uninstall`, administrator or SYSTEM – as Demeter. Logs:
`C:\ProgramData\VDI-ImageMaint\Logs\Larch_<date>.log`, `LarchSetup_<date>.log`, `LarchPip_<date>.log`.

### Use

1. Put the installer into `C:\install\Apps\Larch\` (or enable `Larch` in `C:\install\downloads.json` – it reads the
   newest release from the download folder listing).
2. Package `Larch` in `packages.json` (`Enabled: true`) → `-Mode Update` / `Install`, or directly:

   ```powershell
   C:\install\Scripts\Install-Larch.ps1            # -Upgrade = newest xraylarch from PyPI
   ```

3. Test on a clone as an **ordinary user**: Larix from the Start menu, read a data file, run Feff; XRF Viewer. Then
   Seal + Push Image.

### Notes and limitations

- Per-user data lands in the FSLogix container: `%USERPROFILE%\.larch` (settings, history, Feff runs),
  `%USERPROFILE%\.matplotlib` (font cache – the first start per user is slower), `%APPDATA%\jupyter`. Nothing is
  written into `C:\xraylarch` at run time.
- Larix checks PyPI for a newer version at start and may offer an update – users cannot apply it (read-only folder);
  update the image with `-Upgrade` or a new installer instead.
- The installer is not Authenticode-signed (not verified – the download entry has no `Signer`); download only from
  the official folder above.
- The option set (`/NoScripts`, `/NoShortcuts`, `/KeepPkgCache`) comes from current constructor versions; an older
  installer ignores unknown options – then its post-install script runs as well (pip + icons of this account), which
  steps 2 and 3 tolerate / clean up.
