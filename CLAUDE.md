# VDI-ImageMaint – project instructions

Golden-image maintenance tooling for Windows 11 VDI on **Omnissa Horizon 2506 Instant Clone**
(FSLogix, DEM, App Volumes, Microsoft 365, new Teams). One cycle: **Update → Optimize → Seal**,
reversible with **Unlock**. Target customers: **university** pools (students/staff, shared
labs) and **business** customers (knowledge workers, Teams-heavy). Both must be first-class.

Current state and next steps: see `status.md` / `status.json` (keep both in sync after each work session).

## Repository layout
- `windows/` – the Windows tool (this file's conventions below apply to it); `linux/` – the Linux tool (Debian/Ubuntu,
  Horizon Linux Agent), developed separately: never edit or stage `linux/` from Windows work.
- `status.md` / `status.json` and this file are shared by both.

## Windows files
- `windows/install/` = the complete `C:\install` (copy it to the VM):
  - `windows/install/VDI-ImageMaint.ps1` – thin entry point (same parameters + `-Language auto|en|pl`) → `Invoke-VdiImageMaint`
  - `windows/install/Modules/VDI-ImageMaint/` – the module (v2.0.0): `Private/*.ps1` per area (00-Strings, 01-Config, Common,
    Winget, Seal, Osot, Packages, Discover, Update, Inventory, Configure, Build), `Public/Invoke-VdiImageMaint.ps1`,
    `en-US/*.psd1` + `pl-PL/*.psd1` string tables (one file per area), `Templates/packages.default.json`
  - `windows/install/START.cmd` + `windows/install/Scripts/Start-Menu.ps1` – double-click launcher and EN/PL menu
  - `windows/install/Scripts/Set-FSLogixConfig.ps1` – FSLogix registry, redirections.xml, groups, AV exclusions (v1.0.1)
  - `windows/install/Scripts/Test-SysprepReadiness.ps1` – read-only pre-Generalize checks (EN/PL string table = the i18n pattern to follow)
  - `windows/install/packages.json` (manifest, customer University), `windows/install/winget-catalog.json`, `windows/install/OSOT/Optimize.json`, `windows/install/Office/*.xml`
- Binaries are git-ignored; `windows/docs/` – EN docs, `windows/docs/pl/` – PL docs; `windows/CHANGELOG.md`
- `windows/docs/image-lifecycle.md` – Build (with Generalize, once per feature release) vs Day-2 (no Generalize) – the design basis for OSOT work
- On the VM everything lives in `C:\install` (script, `packages.json`, `OSOT\`, `Office\`, `Patches\`,
  `FSLogix\`, `Horizon\`, `Apps\`, `Scripts\`); logs/state in `C:\ProgramData\VDI-ImageMaint\`.

## Language (i18n)
- **English is the primary language** (code, comments, default messages, docs). **Polish is the
  second language** – every user-facing string must exist in both.
- User-facing messages go through `T 'key' arg0 arg1` (module) – keys in `en-US\<Area>.psd1` and the same keys in
  `pl-PL\<Area>.psd1`; en-US is the fallback. Never hard-coded literals in new code. Standalone scripts
  (Test-SysprepReadiness, Start-Menu) keep an inline EN/PL table.
- Manifest keys, log levels, CSV column names, `seal-state.json` keys, plan actions and inventory statuses are
  language-neutral (English codes); only the display is translated.
- Talk to the user in Polish.

## Code conventions (must follow)
- Target **Windows PowerShell 5.1** (also must run on pwsh 7). Files: **UTF-8 with BOM, CRLF**.
- `Set-StrictMode -Version 2.0` + `$ErrorActionPreference = 'Stop'`.
- Read JSON properties via `Get-PV`, registry via `Get-RegValue` (no exceptions – PS 5.1 writes
  caught exceptions to the transcript).
- Native exes via `Invoke-Winget` / `Start-Process`; local `$ErrorActionPreference='Continue'` around `2>&1`.
- Watch out for `"$var:"` in strings (use `"${var}:"`), `continue` inside `switch`, array unrolling on `return`.
- Operations idempotent; every seal change recorded in `seal-state.json` and reversed by Unlock.
- **OSOT never as SYSTEM** (HKCU → Default User sync); **winget never as SYSTEM**.
- Do not change the `packages.json` format in a backward-incompatible way.
- Logging via `Write-Log` (INFO/OK/WARN/ERR/STEP).
- Never `exit` inside module functions: after scheduling a reboot call `Stop-ForRestart` (throws `RestartSignal`,
  the entry point returns 0). Module functions use `$script:EntryScript` instead of `$PSCommandPath`.
- Mode handlers run inside `$null = switch` – stray pipeline output never reaches the exit code.

## Verification (run before claiming done)
```powershell
# parse under both engines
powershell.exe -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('<file>',[ref]`$null,[ref]`$e); `$e"
Invoke-ScriptAnalyzer -Path windows/install -Recurse         # PSScriptAnalyzer 1.25 installed
Invoke-Pester windows/tests                            # Pester 5.9 installed
```
Nothing here can be run end-to-end locally (needs admin, VM, Horizon). Say clearly what was only
statically checked vs. tested on the VM.

## Roadmap after Windows
- Linux (Debian/Ubuntu) image optimization for Horizon Linux Agent – separate phase, after the Windows tool is done.

## VDI specifics to keep in mind
- Instant Clone: no disk compaction/zeroing in OSOT Finalize; no pending reboot at Seal.
- Teams on Horizon: Media Optimization for Microsoft Teams (Horizon Agent feature + GPO),
  new Teams provisioned (MSIX) via `teamsbootstrapper -p`, `disableAutoUpdate`, FSLogix excludes
  only Microsoft-recommended Teams folders.
- VDI infra components (VMware Tools, Horizon Agent, DEM, App Volumes) must match backend versions.
