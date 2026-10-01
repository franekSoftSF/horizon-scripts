# Eclipse IDE and Java on Instant Clones (FSLogix + DEM folder redirection)

> Polish version: [pl/eclipse-java.md](pl/eclipse-java.md).
> Items marked **(verify)** must be tested on a test pool before customers get them.

## 1. Design

| What | Where | Why |
|---|---|---|
| Eclipse Temurin JDK 21 LTS | Image, `C:\Program Files\Eclipse Adoptium\jdk-21` (fixed `INSTALLDIR`) | Sets `JAVA_HOME`, `PATH` and `.jar`. The fixed folder keeps its path when the monthly MSI upgrades it, so Installed JREs, scripts and `JAVA_HOME` keep working |
| Eclipse Temurin JDK 25 LTS | Image, `C:\Program Files\Eclipse Adoptium\jdk-25` | Second JDK only, no `JAVA_HOME`/`PATH` |
| Eclipse IDE for Java Developers | Image, `C:\Program Files\Eclipse\java`, read-only for users | Shared install. The IDE runs on its bundled JustJ JRE, because Eclipse 2026-09 needs Java 25 to start |
| Workspace `%USERPROFILE%\eclipse-workspace` | FSLogix profile container | The container behaves like a local disk, so `.lock`, JDT indexes and file watching work |
| `%USERPROFILE%\.eclipse` (per-user configuration and plug-ins), `.m2`, `.gradle`, `.p2` | FSLogix profile container | Kept between sessions and clones |
| Documents, Desktop (optionally Pictures, Downloads) | DEM folder redirection to `\\fs01\Home$\%USERNAME%\...` | Exchanging files, coursework, backups on the file server |
| Source code | Git (GitLab / GitHub / Azure DevOps) | History and backup. Do not rely on the container alone |

### Why the workspace is not on the redirected Documents (UNC)
- The `.metadata\.lock` goes through SMB. After a disconnected session on another clone, users get "Workspace in use or cannot be created".
- A build creates thousands of small files (JDT index, `bin\`, `target\`). Every file operation pays the SMB round trip, so builds and indexing are slow.
- File change notifications over SMB are unreliable. Eclipse then works with stale resources and needs F5 (Refresh) all the time.

Users can still keep projects on the redirected Documents and bring them in with **File → Import → Existing Projects into
Workspace** with *Copy projects into workspace* selected. Git is the better choice.

## 2. Image (manifest `packages.json`)

| Id | Order | Type | File (`C:\install\...`) | What it does |
|---|---|---|---|---|
| `TemurinJDK21` | 60 | msi | `Apps\Java\OpenJDK21U-jdk_x64_windows_hotspot_*.msi` | `ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome INSTALLDIR=...\jdk-21` |
| `TemurinJDK25` | 61 | msi | `Apps\Java\OpenJDK25U-jdk_x64_windows_hotspot_*.msi` | `ADDLOCAL=FeatureMain INSTALLDIR=...\jdk-25` |
| `EclipseJava` | 62 | ps1 | `Scripts\Install-Eclipse.ps1` + `Apps\Eclipse\eclipse-java-<YYYY-MM>-R-win32-x86_64.zip` | Extracts and configures Eclipse (below) |

Files: `-Mode Download` (START.cmd option 2) fetches all three (Adoptium API, current EPP release from
`release.xml`; the signatures of the MSI files and of `eclipse.exe` are checked). Or download them by hand, see
[downloads.md](downloads.md).

`Install-Eclipse.ps1` (also usable on its own, supports `-WhatIf`, EN/PL messages):
1. Takes the newest ZIP from `Apps\Eclipse` and compares its release with the Uninstall entry (`DisplayVersion` = `2026.09`).
   A new release replaces the folder. If the release is already installed, the script only re-applies the configuration,
   which takes about 1 s. That is why the manifest uses `Detect: Always`.
2. In `eclipse.ini` it sets the default workspace `@user.home/eclipse-workspace` and
   `-Declipse.pluginCustomization`. It can also set `-data` (`-ForceWorkspace`: no workspace prompt, for labs),
   `-Xmx` (`-MaxHeapMB`) and `-vm` (`-Vm`, only for a JDK >= `osgi.requiredJavaVersion`). The original file is kept as `eclipse.ini.orig`.
3. In `plugin_customization.ini` it turns off the automatic update check (`p2.ui.sdk.scheduler`) and the Oomph startup
   tasks and preference recorder. It also turns off Maven index downloads and turns on **JDK detection at startup**
   (`org.eclipse.jdt.launching/detectVMsAtStartup`). Eclipse then finds the JDKs in `%ProgramFiles%\Eclipse Adoptium`
   by itself and lists them under Installed JREs and execution environments **(verify on the first logon)**.
4. It adds a Start menu shortcut for all users and an Uninstall entry (`-Uninstall` removes everything).

Options for `Arguments` in the manifest: `-Package jee` (Enterprise Java and Web), `-ForceWorkspace`, `-MaxHeapMB 3072`,
`-AllowUserUpdates` (not recommended).

### Update cycle
- **JDK** (Adoptium releases quarterly CPUs): put the new MSI in `Apps\Java` or run `-Mode Download`. The MSI upgrades in
  place into the same folder.
- **Eclipse** (releases in March, June, September and December): put the new ZIP in `Apps\Eclipse` or run `-Mode Download`.
  The script replaces `C:\Program Files\Eclipse\java`. Each new release gets its own `%USERPROFILE%\.eclipse\<id>_<version>`
  in the container. The old one stays (a few MB). Plug-ins that users installed themselves must be installed again.
- **Seal**: Eclipse and Temurin have no update service or scheduled task. The update check is off in the
  configuration and the install folder is read-only. Seal needs nothing extra.

## 3. FSLogix

- `redirections.xml` needs no change. Do **not** exclude `eclipse-workspace` or `.eclipse`.
- Container size: the Maven/Gradle cache grows to hundreds of MB, sometimes several GB. 30 GB (University) is usually enough. Check after a semester.
- Optional, only with a nearby Maven mirror (Nexus/Artifactory): exclude the caches. They are then downloaded again in
  every session:
  `Set-FSLogixConfig.ps1 -VHDLocations '\\fs01\Profiles$' -ExtraExcludes '.m2\repository','.gradle\caches'`
- The redirected Documents/Desktop are not in the container (DEM points them to UNC). Do not add them to the excludes.

## 4. DEM – folder redirection to UNC

DEM Management Console → **User Environment → Folder Redirection** (condition: the Java pool or the AD group):

| Folder | Target |
|---|---|
| Documents | `\\fs01\Home$\%USERNAME%\Documents` |
| Desktop | `\\fs01\Home$\%USERNAME%\Desktop` |
| Pictures, Downloads (optional) | `\\fs01\Home$\%USERNAME%\Pictures`, `...\Downloads` |

- Redirect **only** these folders. Never redirect `AppData` and never the whole profile: `user.home` must stay
  `C:\Users\<user>`, which is in the container.
- Turn off Offline Files (CSC) on the pool. GPO Computer: *Network → Offline Files → Allow or Disallow use of the Offline Files feature* = **Disabled**.
  Otherwise Windows keeps a local copy on a clone that is thrown away.
- Share permissions as for standard folder redirection. Share: Authenticated Users – Full Control. NTFS on the root:
  *Users – Create folders / append data* (this folder only), *CREATOR OWNER – Full control* (subfolders and files only),
  admins Full Control. Let DEM create the user folder, or create it with the account **(verify that DEM creates the target folder)**.
- Do **not** use OneDrive Known Folder Move at the same time (see [profiles-gpo.md](profiles-gpo.md), section 2).
- No DEM personalization (Flex config file) for Eclipse. FSLogix already holds `.eclipse` and the workspace, and
  roaming the same data twice breaks the settings.
- Useful in DEM: drive mapping `H:` → `\\fs01\Home$\%USERNAME%` (Import and Open dialogs), clipboard through Horizon Smart Policies.

## 5. Checks on a test clone

1. First logon: Eclipse starts with no update prompt and no Oomph wizard. The workspace prompt suggests
   `C:\Users\<user>\eclipse-workspace` (or there is no prompt with `-ForceWorkspace`).
2. *Window → Preferences → Java → Installed JREs* lists `jdk-21` and `jdk-25` from `C:\Program Files\Eclipse Adoptium`.
   *Execution Environments* maps JavaSE-21 → jdk-21 and JavaSE-25 → jdk-25 **(verify)**.
3. A new Java project (JavaSE-21) builds and runs. Maven project: `.m2` is created in `C:\Users\<user>`.
4. Log off, then log on to another clone: workspace, preferences and projects are there, with no "Workspace in use".
5. *Help → About → Installation Details → Configuration*: `user.home=C:\Users\<user>` (not UNC) **(verify with DEM redirection on)**.
6. `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`: Personal and Desktop point to `\\fs01\Home$\...`.
7. `javac -version` in a new console shows 21 (PATH/JAVA_HOME from the JDK 21 MSI).
8. VHDX size after a Maven build (FSLogix share), compared with `SizeInMBs`.
