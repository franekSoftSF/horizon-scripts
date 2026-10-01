# New golden image: vCenter automation and OSDCloud

> Polish version: [pl/vcenter-osdcloud.md](pl/vcenter-osdcloud.md)
> Related: [image-lifecycle.md](image-lifecycle.md) §2 / §2a (build steps), §7 (which Windows release for which Horizon).

Everything runs on your **admin PC** in the prepared `C:\install` (after Configure and Download), from the
START menu or directly. The result is a VM in **audit mode** with `C:\install` and the menu open. Continue with
menu steps 4–7 (Update, Optimize, readiness, Generalize).

```
 admin PC                                   vCenter                       golden VM
 ─────────────────────────────────────      ───────────────────────       ──────────────────────────────
 B  New-BuildMedia.ps1          ─┐
    (Windows ISO + VDI-Build.iso) ├─ ISO ─▶ C  Invoke-GoldenVm -New ─▶ install → audit mode → menu
 O  New-BuildMedia -OSDCloud    ─┘          (upload, create, boot)       4 Update · 5 Optimize · 6 check
                                            Snapshot (pre-generalize) ◀─ 7 Generalize → agents → Seal
                                            R  Invoke-GoldenVm -Release ◀ shut down
                                            Horizon Console: Push Image
```

## 1. Two ways to install Windows

| | **B – Setup** (`New-BuildMedia.ps1`) | **O – OSDCloud** (`New-BuildMedia.ps1 -Method OSDCloud`) |
|---|---|---|
| Windows source | Your ISO (VLSC / Microsoft 365 admin center) on CD 1 | Downloaded from Microsoft in WinPE (`Start-OSDCloud`), the newest monthly ESD |
| Extra media | `VDI-Build.iso` on CD 2 (autounattend.xml + C:\install) | One ISO: WinPE + C:\install + answer file |
| Needs on the admin PC | nothing (built-in IMAPI2) | **Windows ADK + WinPE add-on**, module **OSD** (`Install-Module OSD`), elevated PowerShell |
| Needs on the VM | – | **Internet access** from the build network (Microsoft download servers) |
| Key press at boot | "Press any key" – sent by `Invoke-GoldenVm` (USB scan codes) | none (`OSDCloud_NoPrompt.iso`) |
| TPM | check bypassed in Setup (`-WithVtpm` to keep it) | DISM applies the image – no TPM check |
| Language | must match your ISO (`-UILanguage`) | any of the OSDCloud languages (pl-pl, en-us, de-de, fr-fr, ...) |
| Editions | Enterprise, Education, Pro, Pro Education | Enterprise, Education, Pro (volume) |
| Best for | air-gapped / controlled ISO, exact build | always current image, no ISO handling |

Both use the same answer file for the installed Windows: computer name and time zone from `packages.json` Build,
`PreventDeviceEncryption=1`, Store automatic updates off, **audit mode** (`Reseal Mode=Audit`), then the menu
(`-AutoStart Menu`) or `-Mode Update -AutoReboot` (`-AutoStart Update`). No password on any media.

### OSDCloud details
- OSD module (github.com/OSDeploy/OSD, tested against 26.9.30): `New-OSDCloudTemplate` (once),
  `New-OSDCloudWorkspace` (`C:\OSDCloud\VDI-ImageMaint`), `Edit-OSDCloudWinPE -CloudDriver VMware -StartOSDCloud
  "-OSName 'Windows 11 24H2 x64' -OSEdition Enterprise -OSLanguage pl-pl -OSActivation Volume -ZTI -SkipAutopilot -SkipODT -Restart"`,
  `New-OSDCloudISO`. The script copies `OSDCloud_NoPrompt.iso` to `VDI-OSDCloud.iso` next to `C:\install`.
- `-Release` 24H2 / 25H2 / 26H2 (default `Windows.TargetRelease`, otherwise **24H2** – Horizon 2506 supports only up to 24H2).
- **`-ZTI` wipes disk 0 without asking.** Boot this ISO only in the new golden VM.
- OSDCloud runs `Media\OSDCloud\Config\Scripts\Shutdown\VDI-ImageMaint.ps1` after applying Windows. That script copies
  `install\` to `C:\install` and the answer file to `C:\Windows\Panther\unattend.xml`. OSDCloud skips the recovery
  partition on VMs.
- Rebuild the media after changing `C:\install`: run **O** again. Template and workspace are reused.

## 2. vCenter (`Invoke-GoldenVm.ps1`, VMware PowerCLI)

Install once: `Install-Module VCF.PowerCLI -Scope CurrentUser` (or `VMware.PowerCLI`). Copy `vcenter.example.json`
to `vcenter.json` and fill it in:

| Field | Meaning |
|---|---|
| `Server` | vCenter FQDN. Credentials: existing session, Windows SSO or a prompt (`-Credential`). Never stored |
| `Cluster` / `VMHost` | Where to create the VM (one of them) |
| `Datastore`, `Folder`, `Network` | VM disk, VM folder, port group (standard or distributed) of the build network |
| `IsoDatastore`, `IsoFolder` | Where the build ISO is uploaded (default: `Datastore`, `ISO/VDI-ImageMaint`) |
| `WindowsIso` | Method B only: `[datastore] folder/Win11_24H2_Polish_x64.iso` |
| `VM` | `Name`, `NumCpu`, `CoresPerSocket`, `MemoryGB`, `DiskGB` (thin), `GuestId` (`windows11_64Guest`) |

Actions (menu **C** / **R**, or the script):

| Action | What it does |
|---|---|
| `-Action New [-Method Setup\|OSDCloud]` | Uploads the build ISO. Creates the VM: Windows 11 guest, **EFI + Secure Boot, no vTPM**, **PVSCSI**, **VMXNET3**, thin disk, no floppy, `devices.hotplug=FALSE`, boot order CD → disk. Connects the CD drives, powers on and, for Setup, sends Enter for 20 s |
| `-Action Snapshot` | Snapshot `pre-generalize <date>` – before menu 7 (Generalize) |
| `-Action Release` | VM must be off (after `Seal -Shutdown`): empties the CD drives, removes a vTPM if present, snapshot `Gold <date>`. Then Horizon Console → pool → **Maintain → Schedule** (Push Image) with this snapshot |
| `-ValidateOnly` | Checks `vcenter.json` and prints the plan, without PowerCLI |

The pool gets a vTPM per clone by the pool option ("Add vTPM device to VMs"), not from the golden image (KB 85960).

## 3. Horizon Push Image (`Invoke-HorizonPushImage.ps1`, REST API)

No PowerCLI needed - the Horizon Server REST API (Horizon 8 2206+). Settings: the `Horizon` section in `vcenter.json`:

| Field | Meaning |
|---|---|
| `Server` | Connection Server FQDN (HTTPS). Sign-in: `-Credential` or a prompt (`DOMAIN\user`), never stored |
| `Pools` | Instant clone pools that use this golden VM, e.g. `["W11-Students", "W11-Staff"]` |
| `LogoffPolicy` | `WAIT_FOR_LOGOFF` (default) or `FORCE_LOGOFF` |
| `StopOnFirstError` | `true` (default) – the push stops at the first failing machine |

The golden VM is `VM.Name`, the vCenter is `Server`.

| Action | REST calls |
|---|---|
| `-Action Push` (menu **P**, with `-Wait`) | `POST /rest/login` → `GET /monitor/v2/virtual-centers` → `GET /external/v1/datacenters`, `base-vms`, `base-snapshots` → for every pool `GET /inventory/v2/desktop-pools/{id}` (keeps the pool's vTPM setting) → `POST /inventory/v2/desktop-pools/{id}/action/schedule-push-image` → `POST /rest/logout` |
| `-Action Status` | image state per pool (current / pending / operation / error) |
| `-Action Cancel` | `POST /inventory/v1/desktop-pools/{id}/action/cancel-scheduled-push-image` (before the push starts) |
| `-Action List` | snapshots of the golden VM as Horizon sees them |

- Snapshot: default the newest `Gold*` (made by `Invoke-GoldenVm -Action Release`), or `-SnapshotName`.
- `-StartTime` for a maintenance window (e.g. tonight 02:00), otherwise now. `-WhatIf` prints the JSON and sends nothing.
- **Rollback:** push the previous `Gold` snapshot (`-SnapshotName "Gold 2026-09-02 ..."`). Keep the last 2–3 Gold snapshots.
- The Connection Server certificate is checked. `-SkipCertificateCheck` is for a lab only.
## 4. What was tested

- Push Image lookups, request body and REST call format (mocked), answer files (both methods), Setup ISO writing (PS 5.1 + pwsh 7, mounted: UDF, all files), `-ValidateOnly` and
  the error paths: Pester tests in `windows/tests/BuildMedia.Tests.ps1`.
- **Not tested yet:** Push Image against a Connection Server, the OSDCloud media build (needs ADK), the vCenter actions (need PowerCLI and a vCenter), and the
  installation in a real VM. Test once in a lab and keep the result in `status.md`.
