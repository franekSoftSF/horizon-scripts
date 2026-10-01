#Requires -Version 5.1
<#
.SYNOPSIS
    vCenter automation for the golden image VM (VMware PowerCLI): create it, snapshot it, release it for the pool.
    English / Polish.

.DESCRIPTION
    -Action New       Creates the golden image VM with the Horizon / Windows 11 settings and starts the installation:
                      Windows 11 guest, EFI + Secure Boot, NO vTPM (KB 85960), PVSCSI, VMXNET3, thin disk, no floppy,
                      devices.hotplug=FALSE (users cannot eject the NIC/disk in a clone), boot order CD -> disk.
                      Uploads the build ISO (New-BuildMedia.ps1) to the datastore and connects it:
                        -Method Setup     CD 1 = Windows ISO (WindowsIso in vcenter.json), CD 2 = VDI-Build.iso;
                                          after power-on Enter is sent for 20 s ("Press any key to boot from CD")
                        -Method OSDCloud  CD 1 = VDI-OSDCloud.iso (no key press needed, the VM needs internet access)
    -Action Snapshot  Snapshot of the VM (default "pre-generalize <date>" - take it before -Mode Generalize).
    -Action Release   For the pool after Seal + shutdown: VM must be powered off; CD drives emptied, a vTPM removed
                      if present, snapshot "Gold <date>". Then select the snapshot in Horizon Console (Push Image).
    -ValidateOnly     Reads vcenter.json and prints the plan - no PowerCLI, no vCenter.

    Settings come from vcenter.json in the install folder (copy vcenter.example.json). No passwords are stored:
    Connect-VIServer uses -Credential, an existing session or asks.

.PARAMETER Action
    New, Snapshot, Release.
.PARAMETER Method
    Setup (default) or OSDCloud - which build ISO New uses (see New-BuildMedia.ps1 -Method).
.PARAMETER ConfigFile
    Default: <install folder>\vcenter.json.
.PARAMETER BuildIso
    Local build ISO (default ..\VDI-Build.iso or ..\VDI-OSDCloud.iso next to the install folder).
.PARAMETER VMName
    Overrides VM.Name from the config.
.PARAMETER SnapshotName
    Name for -Action Snapshot / Release.
.PARAMETER Credential
    vCenter credential (PSCredential). Without it an existing session / Windows SSO / a prompt is used.
.PARAMETER NoPowerOn
    New: create and configure only.
.PARAMETER Language
    auto (UI culture: pl -> Polish, everything else -> English), en, pl.

.EXAMPLE
    .\Invoke-GoldenVm.ps1 -Action New
.EXAMPLE
    .\Invoke-GoldenVm.ps1 -Action New -Method OSDCloud -VMName W11-GOLD-25H2
.EXAMPLE
    .\Invoke-GoldenVm.ps1 -Action Release

.NOTES
    Version 1.0. Needs VMware PowerCLI (Install-Module VCF.PowerCLI or VMware.PowerCLI). Run on an admin PC.
    Sources: Omnissa KB 85960 (no vTPM in the golden image), Omnissa "Prepare a Guest Operating System for
    Remote Desktop Deployment", vSphere API VirtualMachine.PutUsbScanCodes.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('New', 'Snapshot', 'Release')]
    [string]$Action = 'New',
    [ValidateSet('Setup', 'OSDCloud')]
    [string]$Method = 'Setup',
    [string]$InstallDir = '',
    [string]$ConfigFile = '',
    [string]$BuildIso = '',
    [string]$VMName = '',
    [string]$SnapshotName = '',
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$NoPowerOn,
    [switch]$ValidateOnly,
    [ValidateSet('auto', 'en', 'pl')]
    [string]$Language = 'auto'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# =====================================================================
#  STRINGS (en = primary, pl = secondary; same keys in both)
# =====================================================================
$Strings = @{
    en = @{
        'title'      = 'VDI-ImageMaint - golden image VM in vCenter ({0})'
        'noConfig'   = 'Config not found: {0} - copy vcenter.example.json to vcenter.json and fill it in'
        'missing'    = 'vcenter.json: required field {0} is empty'
        'badNumber'  = 'vcenter.json: VM.{0} must be a number greater than 0'
        'noIso'      = 'Build ISO not found: {0} - create it first (menu B / O, New-BuildMedia.ps1)'
        'noWinIso'   = 'vcenter.json: WindowsIso is empty (needed for -Method Setup), format "[datastore] folder/file.iso"'
        'plan'       = 'Plan: VM {0} in {1}, datastore {2}, network {3}, {4} vCPU / {5} GB RAM / {6} GB disk, {7}'
        'planIso'    = '  CD {0}: {1}'
        'valid'      = 'Configuration is valid (-ValidateOnly: nothing was changed)'
        'noPowerCli' = 'VMware PowerCLI is missing: Install-Module VCF.PowerCLI -Scope CurrentUser (or VMware.PowerCLI)'
        'connect'    = 'Connecting to {0}...'
        'exists'     = 'A VM named {0} already exists - choose another name (-VMName) or delete it'
        'create'     = 'Creating VM {0}...'
        'upload'     = 'Uploading {0} -> {1}'
        'configure'  = 'EFI + Secure Boot, PVSCSI, VMXNET3, no floppy, devices.hotplug=FALSE, boot order CD -> disk'
        'cd'         = 'CD/DVD {0}: {1}'
        'powerOn'    = 'Powering on {0}'
        'sendKeys'   = 'Sending Enter for {0} s ("Press any key to boot from CD")...'
        'keysFail'   = 'Could not send keys ({0}) - open the VM console and press a key'
        'created'    = 'VM {0} created. Watch the console: Setup -> audit mode -> menu. Next: menu 4-6, then Snapshot before Generalize.'
        'notFound'   = 'VM {0} not found'
        'snapshot'   = 'Snapshot "{0}" created on {1}'
        'mustBeOff'  = 'VM {0} must be powered off for Release (run Seal with -Shutdown first)'
        'eject'      = 'CD/DVD emptied: {0}'
        'vtpm'       = 'vTPM removed from the golden image (Horizon adds one per clone when the pool option is on)'
        'released'   = 'Ready for the pool: {0} / snapshot "{1}". Horizon Console -> pool -> Maintain -> Schedule (Push Image) with this snapshot.'
    }
    pl = @{
        'title'      = 'VDI-ImageMaint - VM złotego obrazu w vCenter ({0})'
        'noConfig'   = 'Nie znaleziono konfiguracji: {0} - skopiuj vcenter.example.json do vcenter.json i uzupełnij'
        'missing'    = 'vcenter.json: wymagane pole {0} jest puste'
        'badNumber'  = 'vcenter.json: VM.{0} musi być liczbą większą od 0'
        'noIso'      = 'Nie znaleziono ISO nośnika: {0} - najpierw je utwórz (menu B / O, New-BuildMedia.ps1)'
        'noWinIso'   = 'vcenter.json: WindowsIso jest puste (potrzebne dla -Method Setup), format "[datastore] folder/plik.iso"'
        'plan'       = 'Plan: VM {0} w {1}, datastore {2}, sieć {3}, {4} vCPU / {5} GB RAM / {6} GB dysk, {7}'
        'planIso'    = '  CD {0}: {1}'
        'valid'      = 'Konfiguracja poprawna (-ValidateOnly: niczego nie zmieniono)'
        'noPowerCli' = 'Brak VMware PowerCLI: Install-Module VCF.PowerCLI -Scope CurrentUser (albo VMware.PowerCLI)'
        'connect'    = 'Łączenie z {0}...'
        'exists'     = 'VM o nazwie {0} już istnieje - wybierz inną nazwę (-VMName) albo ją usuń'
        'create'     = 'Tworzenie VM {0}...'
        'upload'     = 'Wysyłanie {0} -> {1}'
        'configure'  = 'EFI + Secure Boot, PVSCSI, VMXNET3, bez stacji dyskietek, devices.hotplug=FALSE, kolejność startu CD -> dysk'
        'cd'         = 'CD/DVD {0}: {1}'
        'powerOn'    = 'Włączanie {0}'
        'sendKeys'   = 'Wysyłanie Enter przez {0} s ("Press any key to boot from CD")...'
        'keysFail'   = 'Nie udało się wysłać klawiszy ({0}) - otwórz konsolę VM i naciśnij klawisz'
        'created'    = 'VM {0} utworzona. Obserwuj konsolę: instalacja -> tryb audytu -> menu. Dalej: menu 4-6, potem Snapshot przed Generalize.'
        'notFound'   = 'Nie znaleziono VM {0}'
        'snapshot'   = 'Utworzono snapshot "{0}" na {1}'
        'mustBeOff'  = 'VM {0} musi być wyłączona do Release (najpierw Seal z -Shutdown)'
        'eject'      = 'Opróżniono CD/DVD: {0}'
        'vtpm'       = 'Usunięto vTPM ze złotego obrazu (Horizon dodaje go do każdego klona, gdy opcja puli jest włączona)'
        'released'   = 'Gotowe dla puli: {0} / snapshot "{1}". Horizon Console -> pula -> Maintain -> Schedule (Push Image) z tym snapshotem.'
    }
}

$Lang = $Language
if ($Lang -eq 'auto') { $Lang = $(if ((Get-UICulture).TwoLetterISOLanguageName -eq 'pl') { 'pl' } else { 'en' }) }

function T {
    param([string]$Key, [object[]]$Arg = @())
    $s = $Strings[$Lang][$Key]
    if (-not $s) { $s = $Strings['en'][$Key] }
    if (-not $s) { return $Key }
    if ($Arg.Count) { return ($s -f $Arg) }
    return $s
}

function Get-P {
    # Safe property read under StrictMode
    param($Obj, [string]$Name, $Default = $null)
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name -and "$($Obj.$Name)" -ne '') { return $Obj.$Name }
    return $Default
}

function Stop-WithError {
    param([string]$Message, [int]$Code = 2)
    Write-Host $Message -ForegroundColor Red
    exit $Code
}

# =====================================================================
#  CONFIG
# =====================================================================
# $PSScriptRoot is empty in param() defaults in Windows PowerShell 5.1
if (-not $InstallDir) { $InstallDir = Split-Path $PSScriptRoot -Parent }
if (-not $ConfigFile) { $ConfigFile = Join-Path $InstallDir 'vcenter.json' }
Write-Host ''
Write-Host (T 'title' @($Action)) -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $ConfigFile)) { Stop-WithError (T 'noConfig' @($ConfigFile)) }
$cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$vmCfg = Get-P $cfg 'VM'
if (-not $VMName) { $VMName = [string](Get-P $vmCfg 'Name' '') }

$required = @('Server')
if ($Action -eq 'New') { $required += @('Datastore', 'Network') }
foreach ($f in $required) { if (-not (Get-P $cfg $f)) { Stop-WithError (T 'missing' @($f)) } }
if (-not $VMName) { Stop-WithError (T 'missing' @('VM.Name')) }
if (-not (Get-P $cfg 'Cluster') -and -not (Get-P $cfg 'VMHost') -and $Action -eq 'New') { Stop-WithError (T 'missing' @('Cluster / VMHost')) }

$spec = [ordered]@{
    NumCpu = [int](Get-P $vmCfg 'NumCpu' 4); CoresPerSocket = [int](Get-P $vmCfg 'CoresPerSocket' 4)
    MemoryGB = [int](Get-P $vmCfg 'MemoryGB' 8); DiskGB = [int](Get-P $vmCfg 'DiskGB' 80)
}
foreach ($k in @($spec.Keys)) { if ($spec[$k] -le 0) { Stop-WithError (T 'badNumber' @($k)) } }
$guestId = [string](Get-P $vmCfg 'GuestId' 'windows11_64Guest')

if ($Action -eq 'New') {
    if (-not $BuildIso) {
        $BuildIso = Join-Path (Split-Path $InstallDir -Parent) $(if ($Method -eq 'OSDCloud') { 'VDI-OSDCloud.iso' } else { 'VDI-Build.iso' })
    }
    if (-not (Test-Path -LiteralPath $BuildIso)) { Stop-WithError (T 'noIso' @($BuildIso)) }
    $winIso = [string](Get-P $cfg 'WindowsIso' '')
    if ($Method -eq 'Setup' -and -not $winIso) { Stop-WithError (T 'noWinIso') }
    $isoDs = [string](Get-P $cfg 'IsoDatastore' (Get-P $cfg 'Datastore'))
    $isoFolder = ([string](Get-P $cfg 'IsoFolder' 'ISO/VDI-ImageMaint')).Trim('/').Replace('\', '/')
    $buildIsoDsPath = "[$isoDs] $isoFolder/$(Split-Path $BuildIso -Leaf)"
    $where = $(if (Get-P $cfg 'Cluster') { "cluster $($cfg.Cluster)" } else { "host $($cfg.VMHost)" })
    Write-Host (T 'plan' @($VMName, $where, $cfg.Datastore, $cfg.Network, $spec.NumCpu, $spec.MemoryGB, $spec.DiskGB, $guestId))
    $isos = @()
    if ($Method -eq 'Setup') { $isos += $winIso }
    $isos += $buildIsoDsPath
    for ($i = 0; $i -lt $isos.Count; $i++) { Write-Host (T 'planIso' @(($i + 1), $isos[$i])) }
}
if ($ValidateOnly) { Write-Host (T 'valid') -ForegroundColor Green; exit 0 }

# =====================================================================
#  vCENTER
# =====================================================================
if (-not (Get-Command Connect-VIServer -ErrorAction SilentlyContinue)) {
    Import-Module VMware.VimAutomation.Core -ErrorAction SilentlyContinue
    if (-not (Get-Command Connect-VIServer -ErrorAction SilentlyContinue)) { Stop-WithError (T 'noPowerCli') 3 }
}
$server = [string]$cfg.Server
$session = @(Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $server -and $_.IsConnected }) | Select-Object -First 1
if (-not $session) {
    Write-Host (T 'connect' @($server))
    $cp = @{ Server = $server }
    if ($Credential) { $cp['Credential'] = $Credential }
    $session = Connect-VIServer @cp
}

function Get-GoldenVm {
    $v = Get-VM -Name $VMName -Server $session -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $v) { Stop-WithError (T 'notFound' @($VMName)) }
    return $v
}

function Send-EnterKey {
    # vSphere 6.5+: USB HID scan codes into the VM console - answers "Press any key to boot from CD"
    param($Vm, [int]$Seconds = 20)
    Write-Host (T 'sendKeys' @($Seconds))
    try {
        $ev = New-Object VMware.Vim.UsbScanCodeSpecKeyEvent
        $ev.UsbHidCode = (0x28 -shl 16) -bor 7   # Enter (HID usage 0x28)
        $codes = New-Object VMware.Vim.UsbScanCodeSpec
        $codes.KeyEvents = @($ev)
        for ($i = 0; $i -lt $Seconds; $i++) { [void]$Vm.ExtensionData.PutUsbScanCodes($codes); Start-Sleep -Seconds 1 }
    } catch { Write-Host (T 'keysFail' @($_.Exception.Message)) -ForegroundColor Yellow }
}

function Send-IsoToDatastore {
    param([string]$LocalPath, [string]$DatastoreName, [string]$Folder)
    $ds = Get-Datastore -Name $DatastoreName -Server $session
    $drive = 'vdiiso'
    $null = New-PSDrive -Name $drive -PSProvider VimDatastore -Root '\' -Location $ds
    try {
        $target = "${drive}:\" + $Folder.Replace('/', '\')
        if (-not (Test-Path $target)) { $null = New-Item -Path $target -ItemType Directory }
        Write-Host (T 'upload' @($LocalPath, "[$DatastoreName] $Folder"))
        Copy-DatastoreItem -Item $LocalPath -Destination ($target + '\') -Force
    } finally { Remove-PSDrive -Name $drive -ErrorAction SilentlyContinue }
}

switch ($Action) {
    'New' {
        if (Get-VM -Name $VMName -Server $session -ErrorAction SilentlyContinue) { Stop-WithError (T 'exists' @($VMName)) }
        if (-not $PSCmdlet.ShouldProcess($VMName, 'New-VM')) { break }
        Send-IsoToDatastore -LocalPath $BuildIso -DatastoreName $isoDs -Folder $isoFolder

        Write-Host (T 'create' @($VMName))
        $np = @{
            Name = $VMName; Server = $session; Datastore = (Get-Datastore -Name $cfg.Datastore -Server $session)
            NumCpu = $spec.NumCpu; CoresPerSocket = $spec.CoresPerSocket; MemoryGB = $spec.MemoryGB
            DiskGB = $spec.DiskGB; DiskStorageFormat = 'Thin'; GuestId = $guestId
        }
        if (Get-P $cfg 'Cluster') { $np['ResourcePool'] = Get-Cluster -Name $cfg.Cluster -Server $session }
        else { $np['VMHost'] = Get-VMHost -Name $cfg.VMHost -Server $session }
        if (Get-P $cfg 'Folder') { $np['Location'] = Get-Folder -Name $cfg.Folder -Type VM -Server $session | Select-Object -First 1 }
        $vm = New-VM @np

        Write-Host (T 'configure')
        $pg = Get-VirtualPortGroup -Name $cfg.Network -Server $session | Select-Object -First 1
        $nic = @(Get-NetworkAdapter -VM $vm)
        if ($nic.Count) { $null = $nic[0] | Set-NetworkAdapter -Portgroup $pg -Type Vmxnet3 -StartConnected:$true -Confirm:$false }
        else { $null = New-NetworkAdapter -VM $vm -Portgroup $pg -Type Vmxnet3 -StartConnected }
        $null = Get-ScsiController -VM $vm | Set-ScsiController -Type ParaVirtual -Confirm:$false
        Get-FloppyDrive -VM $vm | Remove-FloppyDrive -Confirm:$false
        $n = 0
        foreach ($iso in $isos) { $n++; $null = New-CDDrive -VM $vm -IsoPath $iso -StartConnected; Write-Host (T 'cd' @($n, $iso)) }

        # EFI + Secure Boot, no hot-plug, boot order: CD first (empty disk), then disk
        $vm = Get-VM -Id $vm.Id -Server $session
        $disk = $vm.ExtensionData.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualDisk] } | Select-Object -First 1
        $cs = New-Object VMware.Vim.VirtualMachineConfigSpec
        $cs.Firmware = 'efi'
        $cs.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions
        $cs.BootOptions.EfiSecureBootEnabled = $true
        $bootDisk = New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice
        $bootDisk.DeviceKey = $disk.Key
        $cs.BootOptions.BootOrder = @((New-Object VMware.Vim.VirtualMachineBootOptionsBootableCdromDevice), $bootDisk)
        $opt = New-Object VMware.Vim.OptionValue
        $opt.Key = 'devices.hotplug'; $opt.Value = 'FALSE'
        $cs.ExtraConfig = @($opt)
        $vm.ExtensionData.ReconfigVM($cs)

        if (-not $NoPowerOn) {
            Write-Host (T 'powerOn' @($VMName))
            $vm = Start-VM -VM $vm -Confirm:$false
            if ($Method -eq 'Setup') { Send-EnterKey -Vm $vm }
        }
        Write-Host (T 'created' @($VMName)) -ForegroundColor Green
    }
    'Snapshot' {
        $vm = Get-GoldenVm
        if (-not $SnapshotName) { $SnapshotName = 'pre-generalize ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
        if ($PSCmdlet.ShouldProcess($VMName, "New-Snapshot $SnapshotName")) {
            $null = New-Snapshot -VM $vm -Name $SnapshotName -Description 'VDI-ImageMaint' -Memory:$false -Confirm:$false
            Write-Host (T 'snapshot' @($SnapshotName, $VMName)) -ForegroundColor Green
        }
    }
    'Release' {
        $vm = Get-GoldenVm
        if ($vm.PowerState -ne 'PoweredOff') { Stop-WithError (T 'mustBeOff' @($VMName)) }
        if (-not $SnapshotName) { $SnapshotName = 'Gold ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
        if (-not $PSCmdlet.ShouldProcess($VMName, "Release / New-Snapshot $SnapshotName")) { break }
        foreach ($cd in @(Get-CDDrive -VM $vm)) {
            if ($cd.IsoPath) { $null = Set-CDDrive -CD $cd -NoMedia -Confirm:$false; Write-Host (T 'eject' @($cd.IsoPath)) }
        }
        $tpm = @($vm.ExtensionData.Config.Hardware.Device | Where-Object { $_.GetType().Name -eq 'VirtualTPM' })
        if ($tpm.Count) {
            $cs = New-Object VMware.Vim.VirtualMachineConfigSpec
            $ch = New-Object VMware.Vim.VirtualDeviceConfigSpec
            $ch.Operation = 'remove'; $ch.Device = $tpm[0]
            $cs.DeviceChange = @($ch)
            $vm.ExtensionData.ReconfigVM($cs)
            Write-Host (T 'vtpm')
        }
        $null = New-Snapshot -VM $vm -Name $SnapshotName -Description 'VDI-ImageMaint: sealed golden image' -Memory:$false -Confirm:$false
        Write-Host (T 'released' @($VMName, $SnapshotName)) -ForegroundColor Green
    }
}
exit 0
