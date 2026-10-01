#Requires -Version 5.1
<#
.SYNOPSIS
    Creates the build media for a new Windows 11 golden image: a small ISO with autounattend.xml and the
    complete C:\install folder. English / Polish.

.DESCRIPTION
    Attach the Windows 11 ISO (first CD/DVD drive) and VDI-Build.iso (second CD/DVD drive) to a new VM and boot it.
    Windows Setup finds autounattend.xml on the second drive and installs without questions:

      windowsPE    language, disk 0 wiped and partitioned for UEFI (EFI 260 MB, MSR 16 MB, Windows = rest, no
                   recovery partition), edition by name + generic KMS client key (GVLK), no Dynamic Update,
                   TPM check bypassed (the golden image must not have a vTPM - Omnissa KB 85960)
      specialize   computer name, time zone, PreventDeviceEncryption=1, Store automatic updates off
                   (two known Sysprep blockers on 24H2/25H2/26H2)
      oobeSystem   no OOBE: straight to AUDIT MODE (built-in Administrator, needed by OSOT Generalize)
      auditUser    copies \install from the build ISO to C:\install and starts the menu (START.cmd),
                   or -AutoStart Update / None

    No password is stored on the media: audit mode signs in the built-in Administrator without one, and the
    password for after Generalize is asked by -Mode Generalize.
    Windows 11 22H2+ has inbox PVSCSI and VMXNET3 drivers, so no driver injection is needed.
    The ISO is written with the built-in IMAPI2 (no Windows ADK needed). Runs as a normal user.

.PARAMETER InstallDir
    The folder copied to C:\install (default: the folder this script lives in, ..\).
.PARAMETER OutFile
    ISO path (default: VDI-Build.iso next to InstallDir).
.PARAMETER Edition
    Enterprise (default), Education, Pro, ProEducation - selects the image and the generic KMS client key.
.PARAMETER ImageName
    Image name in install.wim when it differs (check: dism /Get-WimInfo /WimFile:D:\sources\install.wim).
.PARAMETER UILanguage
    Windows display language - MUST match the language of the Windows ISO (default: packages.json Build.UILanguage,
    otherwise en-US).
.PARAMETER WithVtpm
    The VM has a vTPM during the build (remove it before creating the pool): no TPM bypass in setup.
.PARAMETER AutoStart
    Menu (default) = START.cmd after the first logon, Update = -Mode Update -AutoReboot, None = only copy.
.PARAMETER ScriptsOnly
    Leave out installers (exe, msi, msu, zip, ...) - copy them to C:\install later (smaller ISO).
.PARAMETER XmlOnly
    Write only autounattend.xml (next to OutFile) - e.g. for your own ISO tooling.
.PARAMETER Language
    auto (UI culture: pl -> Polish, everything else -> English), en, pl.

.EXAMPLE
    .\New-BuildMedia.ps1
.EXAMPLE
    .\New-BuildMedia.ps1 -Edition Education -UILanguage pl-PL -AutoStart Update

.NOTES
    Version 1.0. Sources: Microsoft "Answer files (unattend.xml)", "Unattended Windows Setup Reference",
    "KMS client activation keys"; Omnissa KB 85960 (Windows 11 golden image without vTPM).
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [string]$OutFile = '',
    [ValidateSet('Enterprise', 'Education', 'Pro', 'ProEducation')]
    [string]$Edition = 'Enterprise',
    [string]$ImageName = '',
    [string]$UILanguage = '',
    [string]$Organization = 'VDI',
    [switch]$WithVtpm,
    [ValidateSet('Menu', 'Update', 'None')]
    [string]$AutoStart = 'Menu',
    [switch]$ScriptsOnly,
    [switch]$XmlOnly,
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
        'title'     = 'VDI-ImageMaint - build media for a new golden image'
        'noDir'     = 'Folder not found: {0}'
        'noTool'    = '{0} does not look like C:\install (VDI-ImageMaint.ps1 missing)'
        'settings'  = 'Edition {0} ("{1}"), language {2}, input {3}, time zone {4}, computer name {5}'
        'langNote'  = 'The language must match the Windows ISO - otherwise Setup stops with "language not available" (-UILanguage).'
        'vtpm.no'   = 'TPM check bypassed: create the VM WITHOUT a vTPM (Horizon adds one to every clone - KB 85960).'
        'vtpm.yes'  = '-WithVtpm: remove the vTPM from the golden image VM before creating the pool (KB 85960).'
        'stage'     = 'Preparing files: {0}'
        'skipped'   = '{0} installer file(s) left out (-ScriptsOnly) - copy them to C:\install later'
        'xml'       = 'autounattend.xml written: {0}'
        'iso'       = 'Writing ISO ({0:N0} MB): {1}'
        'done'      = 'Build media ready: {0}'
        'next'      = 'Next steps:'
        'next1'     = '  1. New VM: Windows 11 64-bit, EFI + Secure Boot, {0}, VMXNET3, PVSCSI or NVMe, disk 64+ GB, 4 vCPU / 8 GB'
        'next1.vtpm'= 'no vTPM'
        'next1.with'= 'vTPM (remove before the pool)'
        'next2'     = '  2. CD/DVD 1 = Windows 11 ISO, CD/DVD 2 = this ISO (both "Connect at power on"), boot, "Press any key"'
        'next3'     = '  3. Setup runs without questions and ends in audit mode (built-in Administrator); C:\install is copied'
        'next4'     = '  4. Then: {0}'
        'next4.Menu'   = 'the menu opens - continue with steps 4-7 (Update, Optimize, readiness, Generalize)'
        'next4.Update' = 'updates start automatically (with reboots), then continue in the menu with step 5'
        'next4.None'   = 'run C:\install\START.cmd'
        'next5'     = '  5. Snapshot "pre-generalize" before Generalize (the menu asks for it)'
        'isoFail'   = 'Writing the ISO failed: {0}'
    }
    pl = @{
        'title'     = 'VDI-ImageMaint - nośnik do budowy nowego złotego obrazu'
        'noDir'     = 'Nie znaleziono folderu: {0}'
        'noTool'    = '{0} nie wygląda na C:\install (brak VDI-ImageMaint.ps1)'
        'settings'  = 'Edycja {0} ("{1}"), język {2}, klawiatura {3}, strefa czasowa {4}, nazwa komputera {5}'
        'langNote'  = 'Język musi być zgodny z ISO Windows - inaczej instalator zatrzyma się z błędem "język niedostępny" (-UILanguage).'
        'vtpm.no'   = 'Pominięto sprawdzanie TPM: utwórz VM BEZ vTPM (Horizon dodaje go do każdego klona - KB 85960).'
        'vtpm.yes'  = '-WithVtpm: przed utworzeniem puli usuń vTPM z VM złotego obrazu (KB 85960).'
        'stage'     = 'Przygotowanie plików: {0}'
        'skipped'   = 'Pominięto {0} plik(ów) instalatorów (-ScriptsOnly) - skopiuj je później do C:\install'
        'xml'       = 'Zapisano autounattend.xml: {0}'
        'iso'       = 'Zapis ISO ({0:N0} MB): {1}'
        'done'      = 'Nośnik gotowy: {0}'
        'next'      = 'Dalsze kroki:'
        'next1'     = '  1. Nowa VM: Windows 11 64-bit, EFI + Secure Boot, {0}, VMXNET3, PVSCSI lub NVMe, dysk 64+ GB, 4 vCPU / 8 GB'
        'next1.vtpm'= 'bez vTPM'
        'next1.with'= 'vTPM (usuń przed utworzeniem puli)'
        'next2'     = '  2. CD/DVD 1 = ISO Windows 11, CD/DVD 2 = to ISO (oba "Connect at power on"), start, "Press any key"'
        'next3'     = '  3. Instalacja przebiega bez pytań i kończy się w trybie audytu (wbudowany Administrator); C:\install zostaje skopiowany'
        'next4'     = '  4. Potem: {0}'
        'next4.Menu'   = 'otwiera się menu - kontynuuj krokami 4-7 (Update, Optimize, gotowość, Generalize)'
        'next4.Update' = 'aktualizacje startują automatycznie (z restartami), potem w menu krok 5'
        'next4.None'   = 'uruchom C:\install\START.cmd'
        'next5'     = '  5. Przed Generalize zrób snapshot "pre-generalize" (menu o to zapyta)'
        'isoFail'   = 'Zapis ISO nie powiódł się: {0}'
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

# Generic KMS client setup keys (GVLK) - select the edition, activation comes from KMS / ADBA or a MAK later
# (learn.microsoft.com/windows-server/get-started/kms-client-activation-keys)
$Editions = @{
    Enterprise   = @{ Name = 'Windows 11 Enterprise';    Key = 'NPPR9-FWDCX-D2C8J-H872K-2YT43' }
    Education    = @{ Name = 'Windows 11 Education';     Key = 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2' }
    Pro          = @{ Name = 'Windows 11 Pro';           Key = 'W269N-WFGWX-YVC9B-4J6C9-T83GX' }
    ProEducation = @{ Name = 'Windows 11 Pro Education'; Key = '6TP4R-GNPTD-KYYHQ-7B7DP-J447Y' }
}

# Marker file on the build ISO: the auditUser commands find the drive letter by it
$TagName = 'vdi-build.tag'
$InstallerExt = @('.exe', '.msi', '.msu', '.msp', '.cab', '.zip', '.msix', '.msixbundle', '.appx', '.appxbundle', '.iso', '.wim')

function New-AutounattendXml {
    # Builds autounattend.xml from a settings hashtable (values are XML-escaped)
    param([hashtable]$S)
    $e = @{}; foreach ($k in $S.Keys) { $e[$k] = [Security.SecurityElement]::Escape([string]$S[$k]) }
    $comp = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    $intl = @"
      <InputLocale>$($e.InputLocale)</InputLocale>
      <SystemLocale>$($e.SystemLocale)</SystemLocale>
      <UILanguage>$($e.UILanguage)</UILanguage>
      <UserLocale>$($e.UserLocale)</UserLocale>
"@
    $peRun = ''
    if ($S.BypassTpm) {
        $peRun = @"
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg.exe add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
"@
    }
    $letters = 'D E F G H I J K L M N O P Q R S T U V W X Y Z'
    $copy = "cmd.exe /c for %d in ($letters) do @if exist %d:\$TagName robocopy %d:\install C:\install /E /R:1 /W:1 /NP /NFL /NDL /LOG:C:\Windows\Temp\vdi-build-copy.log"
    # "start" returns at once: Setup does not wait for the menu / the update run
    $start = switch ($S.AutoStart) {
        'Menu'   { 'cmd.exe /c start "" "C:\install\START.cmd"' }
        'Update' { 'cmd.exe /c start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\install\VDI-ImageMaint.ps1 -Mode Update -AutoReboot' }
        default  { '' }
    }
    $startCmd = ''
    if ($start) {
        $startCmd = @"
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Start VDI-ImageMaint</Description>
          <Path>$([Security.SecurityElement]::Escape($start))</Path>
        </RunSynchronousCommand>

"@
    }
    return @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by New-BuildMedia.ps1 (VDI-ImageMaint) - $($e.Created). No passwords in this file. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" $comp>
      <SetupUILanguage>
        <UILanguage>$($e.UILanguage)</UILanguage>
      </SetupUILanguage>
$intl    </component>
    <component name="Microsoft-Windows-Setup" $comp>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <DynamicUpdate>
        <Enable>false</Enable>
        <WillShowUI>Never</WillShowUI>
      </DynamicUpdate>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>$($e.ImageName)</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>
$peRun      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>$($e.Organization)</FullName>
        <Organization>$($e.Organization)</Organization>
        <ProductKey>
          <Key>$($e.ProductKey)</Key>
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $comp>
      <ComputerName>$($e.ComputerName)</ComputerName>
      <RegisteredOrganization>$($e.Organization)</RegisteredOrganization>
      <RegisteredOwner>$($e.Organization)</RegisteredOwner>
      <TimeZone>$($e.TimeZone)</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" $comp>
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>No automatic device encryption (Sysprep blocker)</Description>
          <Path>reg.exe add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>No Store automatic updates (per-user AppX = Sysprep 0x80073cf2)</Description>
          <Path>reg.exe add HKLM\SOFTWARE\Policies\Microsoft\WindowsStore /v AutoDownload /t REG_DWORD /d 2 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $comp>
$intl    </component>
    <component name="Microsoft-Windows-Deployment" $comp>
      <Reseal>
        <Mode>Audit</Mode>
      </Reseal>
    </component>
  </settings>
  <settings pass="auditUser">
    <component name="Microsoft-Windows-Deployment" $comp>
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Copy C:\install from the build ISO</Description>
          <Path>$([Security.SecurityElement]::Escape($copy))</Path>
        </RunSynchronousCommand>
$startCmd      </RunSynchronous>
    </component>
  </settings>
</unattend>
"@
}

function Write-IsoFile {
    # ISO (UDF) from a folder with the built-in IMAPI2 file system image COM object - no ADK needed
    param([string]$SourceDir, [string]$Path, [string]$VolumeName)
    if (-not ('VdiIsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class VdiIsoWriter {
    public static void Save(object stream, string path, int blockSize, long blocks) {
        IStream s = (IStream)stream;
        byte[] buf = new byte[blockSize];
        using (FileStream fs = File.Create(path)) {
            for (long i = 0; i < blocks; i++) {
                s.Read(buf, blockSize, IntPtr.Zero);
                fs.Write(buf, 0, blockSize);
            }
        }
    }
}
'@
    }
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 4          # UDF: long names, files > 4 GB; read by WinPE and Windows
    $fsi.UDFRevision = 0x102
    $fsi.FreeMediaBlocks = 0              # no media size limit
    $fsi.VolumeName = $VolumeName
    $fsi.Root.AddTree($SourceDir, $false)
    $img = $fsi.CreateResultImage()
    Write-Host (T 'iso' @(([double]$img.TotalBlocks * $img.BlockSize / 1MB), $Path))
    [VdiIsoWriter]::Save($img.ImageStream, $Path, $img.BlockSize, $img.TotalBlocks)
}

# =====================================================================
#  MAIN
# =====================================================================
Write-Host ''
Write-Host (T 'title') -ForegroundColor Cyan
# $PSScriptRoot is empty in param() defaults in Windows PowerShell 5.1
if (-not $InstallDir) { $InstallDir = Split-Path $PSScriptRoot -Parent }
if (-not (Test-Path -LiteralPath $InstallDir)) { throw (T 'noDir' @($InstallDir)) }
$InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path
if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'VDI-ImageMaint.ps1'))) { throw (T 'noTool' @($InstallDir)) }
if (-not $OutFile) { $OutFile = Join-Path (Split-Path $InstallDir -Parent) 'VDI-Build.iso' }

# Regional settings from the manifest (Configure step 5), then sensible defaults
$build = $null
$manifestPath = Join-Path $InstallDir 'packages.json'
if (Test-Path -LiteralPath $manifestPath) {
    $build = Get-P (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json) 'Build'
}
if (-not $UILanguage) { $UILanguage = [string](Get-P $build 'UILanguage' 'en-US') }
$ed = $Editions[$Edition]
$settings = @{
    UILanguage   = $UILanguage
    InputLocale  = [string](Get-P $build 'InputLocale' $UILanguage)
    SystemLocale = [string](Get-P $build 'SystemLocale' $UILanguage)
    UserLocale   = [string](Get-P $build 'UserLocale' $UILanguage)
    TimeZone     = [string](Get-P $build 'TimeZone' (Get-TimeZone).Id)
    ComputerName = [string](Get-P $build 'ComputerName' '*')
    ImageName    = $(if ($ImageName) { $ImageName } else { $ed.Name })
    ProductKey   = $ed.Key
    Organization = $Organization
    BypassTpm    = -not $WithVtpm
    AutoStart    = $AutoStart
    Created      = (Get-Date -Format 'yyyy-MM-dd HH:mm')
}
Write-Host (T 'settings' @($Edition, $settings.ImageName, $settings.UILanguage, $settings.InputLocale, $settings.TimeZone, $settings.ComputerName))
Write-Host (T 'langNote') -ForegroundColor Yellow
Write-Host $(if ($WithVtpm) { T 'vtpm.yes' } else { T 'vtpm.no' }) -ForegroundColor Yellow

$xml = New-AutounattendXml -S $settings
[void]([xml]$xml)   # well-formed

if ($XmlOnly) {
    $xmlPath = Join-Path (Split-Path $OutFile -Parent) 'autounattend.xml'
    [IO.File]::WriteAllText($xmlPath, ($xml -replace "`r?`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    Write-Host (T 'xml' @($xmlPath)) -ForegroundColor Green
    exit 0
}

# Staging folder: \autounattend.xml, \vdi-build.tag, \install\...
$stage = Join-Path ([IO.Path]::GetTempPath()) ('VDI-Build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Write-Host (T 'stage' @($stage))
$null = New-Item -ItemType Directory -Path (Join-Path $stage 'install') -Force
try {
    [IO.File]::WriteAllText((Join-Path $stage 'autounattend.xml'), ($xml -replace "`r?`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $stage $TagName), "VDI-ImageMaint build media $($settings.Created)`r`n")
    $skipped = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $InstallDir -Recurse -File)) {
        if ($f.FullName -eq $OutFile) { continue }
        if ($ScriptsOnly -and $InstallerExt -contains $f.Extension.ToLower()) { $skipped++; continue }
        $rel = $f.FullName.Substring($InstallDir.Length).TrimStart('\')
        $dest = Join-Path (Join-Path $stage 'install') $rel
        $null = New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force
        Copy-Item -LiteralPath $f.FullName -Destination $dest
    }
    if ($skipped) { Write-Host (T 'skipped' @($skipped)) -ForegroundColor Yellow }
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    try { Write-IsoFile -SourceDir $stage -Path $OutFile -VolumeName 'VDIBUILD' }
    catch { throw (T 'isoFail' @($_.Exception.Message)) }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host (T 'done' @($OutFile)) -ForegroundColor Green
Write-Host (T 'next') -ForegroundColor Cyan
Write-Host (T 'next1' @($(if ($WithVtpm) { T 'next1.with' } else { T 'next1.vtpm' })))
Write-Host (T 'next2')
Write-Host (T 'next3')
Write-Host (T 'next4' @((T "next4.$AutoStart")))
Write-Host (T 'next5')
exit 0
