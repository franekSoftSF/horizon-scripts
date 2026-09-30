# VDI-ImageMaint – project instructions

Golden-image maintenance tooling for Windows 11 VDI on **Omnissa Horizon 2506 Instant Clone**
(FSLogix, DEM, App Volumes, Microsoft 365, new Teams). One cycle: **Update → Optimize → Seal**,
reversible with **Unlock**. Target customers: **university** pools (students/staff, shared
labs) and **business** customers (knowledge workers, Teams-heavy). Both must be first-class.

Current state and next steps: see `status.md` / `status.json` (keep both in sync after each work session).

## Files
- `Win11/VDI-ImageMaint.ps1` – main tool (v1.7.3, ~2200 lines, monolith; module split planned)
- `Win11/Set-FSLogixConfig.ps1` – FSLogix registry, redirections.xml, groups, AV exclusions (v1.0)
- On the VM everything lives in `C:\install` (script, `packages.json`, `OSOT\`, `Office\`, `Patches\`,
  `FSLogix\`, `Horizon\`, `Apps\`, `Scripts\`); logs/state in `C:\ProgramData\VDI-ImageMaint\`.
- `packages.json` and `OSOT\Optimize.json` are NOT in this repo yet – ask the user for them.

## Language (i18n)
- **English is the primary language** (code, comments, default messages, docs). **Polish is the
  second language** – every user-facing string must exist in both.
- User-facing messages go through a string table (planned: `Import-LocalizedData`,
  `en-US\*.psd1` + `pl-PL\*.psd1`), never hard-coded literals in new code.
- Manifest keys, log levels, CSV column names and `seal-state.json` keys are language-neutral (English).
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
- In `-Mode` switches, remember `exit` inside functions ends the whole script (breaks module/tests).

## Verification (run before claiming done)
```powershell
# parse under both engines
powershell.exe -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('<file>',[ref]`$null,[ref]`$e); `$e"
Invoke-ScriptAnalyzer -Path Win11 -Recurse            # PSScriptAnalyzer 1.25 installed
Invoke-Pester                                          # Pester 5.9 installed (tests/ – to be created)
```
Nothing here can be run end-to-end locally (needs admin, VM, Horizon). Say clearly what was only
statically checked vs. tested on the VM.

## VDI specifics to keep in mind
- Instant Clone: no disk compaction/zeroing in OSOT Finalize; no pending reboot at Seal.
- Teams on Horizon: Media Optimization for Microsoft Teams (Horizon Agent feature + GPO),
  new Teams provisioned (MSIX) via `teamsbootstrapper -p`, `disableAutoUpdate`, FSLogix excludes
  only Microsoft-recommended Teams folders.
- VDI infra components (VMware Tools, Horizon Agent, DEM, App Volumes) must match backend versions.
