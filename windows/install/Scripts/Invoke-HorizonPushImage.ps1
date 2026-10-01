#Requires -Version 5.1
<#
.SYNOPSIS
    Push Image of the golden image snapshot to Horizon instant clone pools through the Horizon REST API.
    English / Polish.

.DESCRIPTION
    -Action Push    Finds the vCenter, the golden VM (VM.Name) and the snapshot (default: the newest "Gold ..." made by
                    Invoke-GoldenVm.ps1 -Action Release) and schedules Push Image on every pool in Horizon.Pools:
                    POST /rest/inventory/v2/desktop-pools/{id}/action/schedule-push-image
                    (logoff policy, start time, stop on first error; the pool's vTPM setting is kept).
    -Action Status  Shows the image state of the pools (current / pending image, operation, errors).
    -Action Cancel  Cancels a scheduled push (before it starts): .../action/cancel-scheduled-push-image.
    -Action List    Lists the snapshots of the golden VM as Horizon sees them.

    Settings: the "Horizon" section in vcenter.json (Server, Pools, LogoffPolicy, ...) and VM.Name / Server (vCenter).
    Credentials: -Credential or a prompt; sent only to the Connection Server login over HTTPS, never stored.

.PARAMETER Action
    Push, Status, Cancel, List.
.PARAMETER SnapshotName
    Snapshot to push (default: the newest snapshot named "Gold*").
.PARAMETER Pool
    Pool name(s) - overrides Horizon.Pools.
.PARAMETER StartTime
    When to start (default: now). Machines with sessions follow LogoffPolicy.
.PARAMETER LogoffPolicy
    WAIT_FOR_LOGOFF (default from config, otherwise WAIT_FOR_LOGOFF) or FORCE_LOGOFF.
.PARAMETER Wait
    Push: watch the pools until the new image is published (or an error), polling every 30 s.
.PARAMETER SkipCertificateCheck
    Accept an untrusted Connection Server certificate (lab only).
.PARAMETER WhatIf
    Push/Cancel: show what would be sent, send nothing.

.EXAMPLE
    .\Invoke-HorizonPushImage.ps1 -Action Push
.EXAMPLE
    .\Invoke-HorizonPushImage.ps1 -Action Push -Pool W11-Lab -StartTime (Get-Date).Date.AddDays(1).AddHours(2) -LogoffPolicy FORCE_LOGOFF
.EXAMPLE
    .\Invoke-HorizonPushImage.ps1 -Action Status

.NOTES
    Version 1.0. Horizon 8 2206+ (schedule-push-image v2). Sources: Horizon Server API reference
    (DesktopPoolPushImageSpecV2, base-vms, base-snapshots), Omnissa "Instant Clone Desktop Pools".
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Push', 'Status', 'Cancel', 'List')]
    [string]$Action = 'Status',
    [string]$InstallDir = '',
    [string]$ConfigFile = '',
    [string]$VMName = '',
    [string]$SnapshotName = '',
    [string[]]$Pool = @(),
    [datetime]$StartTime = [datetime]::MinValue,
    [ValidateSet('', 'WAIT_FOR_LOGOFF', 'FORCE_LOGOFF')]
    [string]$LogoffPolicy = '',
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$Wait,
    [switch]$SkipCertificateCheck,
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
        'title'      = 'VDI-ImageMaint - Horizon Push Image ({0})'
        'noConfig'   = 'Config not found: {0} - copy vcenter.example.json to vcenter.json and fill in the Horizon section'
        'missing'    = 'vcenter.json: required field {0} is empty'
        'login'      = 'Signing in to {0} as {1}...'
        'loginFail'  = 'Sign-in to the Connection Server failed: {0}'
        'credPrompt' = 'Horizon administrator (DOMAIN\user)'
        'badUser'    = 'User name must be DOMAIN\user or user@domain.fqdn'
        'noVc'       = 'vCenter {0} is not registered in Horizon (registered: {1})'
        'noVm'       = 'Golden VM {0} not found in vCenter {1} through Horizon'
        'noSnap'     = 'No snapshot {0} on {1} (snapshots: {2})'
        'noPool'     = 'Pool {0} not found'
        'notIc'      = 'Pool {0} is not an instant clone pool ({1}) - skipped'
        'image'      = 'Image: {0} / snapshot "{1}"'
        'push'       = '{0}: Push Image scheduled ({1}, {2}, vTPM {3})'
        'pushWhatIf' = '{0}: would schedule Push Image with: {1}'
        'pushFail'   = '{0}: Push Image failed: {1}'
        'status'     = '{0}: image {1} | operation {2} | pending {3} {4}'
        'cancel'     = '{0}: scheduled Push Image cancelled'
        'cancelFail' = '{0}: cancel failed: {1}'
        'waiting'    = 'Waiting for the pools (every 30 s, Ctrl+C stops watching - the push continues)...'
        'done'       = 'All pools run the new image'
        'error'      = '{0}: error {1}'
        'snapList'   = 'Snapshots of {0}:'
        'now'        = 'now'
        'logout'     = 'Signed out'
        'certSkip'   = 'Certificate check is OFF (-SkipCertificateCheck) - lab only'
    }
    pl = @{
        'title'      = 'VDI-ImageMaint - Horizon Push Image ({0})'
        'noConfig'   = 'Nie znaleziono konfiguracji: {0} - skopiuj vcenter.example.json do vcenter.json i uzupełnij sekcję Horizon'
        'missing'    = 'vcenter.json: wymagane pole {0} jest puste'
        'login'      = 'Logowanie do {0} jako {1}...'
        'loginFail'  = 'Logowanie do Connection Server nie powiodło się: {0}'
        'credPrompt' = 'Administrator Horizon (DOMENA\użytkownik)'
        'badUser'    = 'Nazwa użytkownika musi mieć postać DOMENA\użytkownik albo użytkownik@domena.fqdn'
        'noVc'       = 'vCenter {0} nie jest zarejestrowany w Horizon (zarejestrowane: {1})'
        'noVm'       = 'Nie znaleziono VM złotego obrazu {0} w vCenter {1} przez Horizon'
        'noSnap'     = 'Brak snapshotu {0} na {1} (snapshoty: {2})'
        'noPool'     = 'Nie znaleziono puli {0}'
        'notIc'      = 'Pula {0} nie jest pulą Instant Clone ({1}) - pominięta'
        'image'      = 'Obraz: {0} / snapshot "{1}"'
        'push'       = '{0}: zaplanowano Push Image ({1}, {2}, vTPM {3})'
        'pushWhatIf' = '{0}: zaplanowałbym Push Image z: {1}'
        'pushFail'   = '{0}: Push Image nie powiódł się: {1}'
        'status'     = '{0}: obraz {1} | operacja {2} | oczekujący {3} {4}'
        'cancel'     = '{0}: anulowano zaplanowany Push Image'
        'cancelFail' = '{0}: anulowanie nie powiodło się: {1}'
        'waiting'    = 'Obserwacja pul (co 30 s, Ctrl+C kończy obserwację - Push Image trwa dalej)...'
        'done'       = 'Wszystkie pule działają na nowym obrazie'
        'error'      = '{0}: błąd {1}'
        'snapList'   = 'Snapshoty {0}:'
        'now'        = 'teraz'
        'logout'     = 'Wylogowano'
        'certSkip'   = 'Sprawdzanie certyfikatu WYŁĄCZONE (-SkipCertificateCheck) - tylko lab'
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

# =====================================================================
#  REST
# =====================================================================
$script:HzBase = ''
$script:HzToken = ''
$script:HzRefresh = ''

function Invoke-HzApi {
    # One place for every Horizon REST call (mocked by the tests)
    param([ValidateSet('GET', 'POST')][string]$Method = 'GET', [string]$Path, $Body = $null)
    $p = @{ Method = $Method; Uri = $script:HzBase + $Path; ContentType = 'application/json' }
    if ($script:HzToken) { $p['Headers'] = @{ Authorization = "Bearer $($script:HzToken)" } }
    if ($null -ne $Body) { $p['Body'] = ($Body | ConvertTo-Json -Depth 6 -Compress) }
    if ($SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -ge 6) { $p['SkipCertificateCheck'] = $true }
    return Invoke-RestMethod @p
}

function Split-HzUser {
    # DOMAIN\user or user@domain.fqdn -> @{ Domain; User }
    param([string]$Name)
    if ($Name -match '^([^\\@]+)\\([^\\@]+)$') { return @{ Domain = $Matches[1]; User = $Matches[2] } }
    if ($Name -match '^([^\\@]+)@([^\\@]+)$') { return @{ Domain = $Matches[2].Split('.')[0]; User = $Matches[1] } }
    throw (T 'badUser')
}

function Connect-Hz {
    param([string]$Server, [System.Management.Automation.PSCredential]$Cred)
    $script:HzBase = "https://$Server/rest"
    $u = Split-HzUser $Cred.UserName
    Write-Host (T 'login' @($Server, $Cred.UserName))
    try {
        $r = Invoke-HzApi -Method POST -Path '/login' -Body @{ domain = $u.Domain; username = $u.User; password = $Cred.GetNetworkCredential().Password }
    } catch { throw (T 'loginFail' @($_.Exception.Message)) }
    $script:HzToken = [string]$r.access_token
    $script:HzRefresh = [string](Get-P $r 'refresh_token' '')
}

function Disconnect-Hz {
    if (-not $script:HzToken) { return }
    try { [void](Invoke-HzApi -Method POST -Path '/logout' -Body @{ refresh_token = $script:HzRefresh }) } catch { Write-Verbose $_.Exception.Message }
    $script:HzToken = ''
    Write-Host (T 'logout') -ForegroundColor DarkGray
}

# =====================================================================
#  LOOKUPS (pure functions over the REST results - unit tested)
# =====================================================================
function Find-HzVCenter {
    param([object[]]$VCenters, [string]$Name)
    $hit = @($VCenters | Where-Object { [string](Get-P $_ 'name' '') -like "*$Name*" -or [string](Get-P $_ 'server_name' '') -eq $Name }) | Select-Object -First 1
    if (-not $hit) { throw (T 'noVc' @($Name, ((@($VCenters | ForEach-Object { Get-P $_ 'name' '?' })) -join ', '))) }
    return $hit
}

function Select-HzSnapshot {
    # By name, or the newest "Gold*" (created_timestamp when Horizon returns it, otherwise the last in the list)
    param([object[]]$Snapshots, [string]$Name, [string]$VmName)
    $list = @($Snapshots)
    if ($Name) { $hit = @($list | Where-Object { $_.name -eq $Name }) | Select-Object -Last 1 }
    else {
        # list position breaks ties (Sort-Object is not stable in Windows PowerShell 5.1)
        $i = 0
        $gold = @($list | ForEach-Object { [pscustomobject]@{ Snap = $_; Pos = $i++ } } | Where-Object { $_.Snap.name -like 'Gold*' })
        $hit = @($gold | Sort-Object @{ Expression = { [long](Get-P $_.Snap 'created_timestamp' 0) } }, Pos) | Select-Object -Last 1 | ForEach-Object Snap
    }
    if (-not $hit) {
        $want = $(if ($Name) { $Name } else { 'Gold*' })
        throw (T 'noSnap' @($want, $VmName, ((@($list | ForEach-Object { $_.name })) -join ', ')))
    }
    return $hit
}

function New-PushImageSpec {
    # DesktopPoolPushImageSpecV2; add_virtual_tpm follows the pool (Windows 11 clones get their own vTPM)
    param([string]$ParentVmId, [string]$SnapshotId, [string]$Logoff, [datetime]$Start, [bool]$Vtpm, [bool]$StopOnError = $true)
    $spec = [ordered]@{
        parent_vm_id        = $ParentVmId
        snapshot_id         = $SnapshotId
        logoff_policy       = $Logoff
        stop_on_first_error = $StopOnError
        add_virtual_tpm     = $Vtpm
    }
    if ($Start -gt (Get-Date)) { $spec['start_time'] = [long]([DateTimeOffset]$Start.ToUniversalTime()).ToUnixTimeMilliseconds() }
    return $spec
}

function Get-HzPoolVtpm {
    param($PoolDetail)
    return [bool](Get-P (Get-P $PoolDetail 'provisioning_settings') 'add_virtual_tpm' $false)
}

function Format-HzPoolState {
    param($PoolDetail)
    $st = Get-P $PoolDetail 'provisioning_status_data'
    return [pscustomobject]@{
        Current   = [string](Get-P $st 'instant_clone_current_image_state' '-')
        Operation = [string](Get-P $st 'instant_clone_operation' '-')
        Pending   = [string](Get-P $st 'instant_clone_pending_image_state' '-')
        Progress  = $(if ($null -ne (Get-P $st 'instant_clone_pending_image_progress')) { "$($st.instant_clone_pending_image_progress)%" } else { '' })
        Error     = [string](Get-P $st 'instant_clone_pending_image_error' (Get-P $st 'last_provisioning_error' ''))
    }
}

# =====================================================================
#  MAIN (skipped when the tests dot-source the file)
# =====================================================================
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Host ''
Write-Host (T 'title' @($Action)) -ForegroundColor Cyan
# $PSScriptRoot is empty in param() defaults in Windows PowerShell 5.1
if (-not $InstallDir) { $InstallDir = Split-Path $PSScriptRoot -Parent }
if (-not $ConfigFile) { $ConfigFile = Join-Path $InstallDir 'vcenter.json' }
if (-not (Test-Path -LiteralPath $ConfigFile)) { Write-Host (T 'noConfig' @($ConfigFile)) -ForegroundColor Red; exit 2 }
$cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$hz = Get-P $cfg 'Horizon'
if (-not $VMName) { $VMName = [string](Get-P (Get-P $cfg 'VM') 'Name' '') }
if (-not $Pool.Count) { $Pool = @(Get-P $hz 'Pools' @()) }
if (-not $LogoffPolicy) { $LogoffPolicy = [string](Get-P $hz 'LogoffPolicy' 'WAIT_FOR_LOGOFF') }
$need = [ordered]@{ 'Horizon.Server' = (Get-P $hz 'Server'); 'Server (vCenter)' = (Get-P $cfg 'Server'); 'VM.Name' = $VMName; 'Horizon.Pools' = ($Pool -join '') }
foreach ($k in $need.Keys) { if (-not $need[$k]) { Write-Host (T 'missing' @($k)) -ForegroundColor Red; exit 2 } }

if ($SkipCertificateCheck) {
    Write-Host (T 'certSkip') -ForegroundColor Yellow
    if ($PSVersionTable.PSVersion.Major -lt 6) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not $Credential) { $Credential = Get-Credential -Message (T 'credPrompt') }

$rc = 0
try {
    Connect-Hz -Server ([string]$hz.Server) -Cred $Credential
    $pools = @(Invoke-HzApi -Path '/inventory/v1/desktop-pools')
    $targets = foreach ($name in $Pool) {
        $p = @($pools | Where-Object { $_.name -eq $name -or (Get-P $_ 'display_name' '') -eq $name }) | Select-Object -First 1
        if (-not $p) { Write-Host (T 'noPool' @($name)) -ForegroundColor Red; $rc = 2; continue }
        $src = [string](Get-P $p 'source' '')
        if ($src -and $src -ne 'INSTANT_CLONE') { Write-Host (T 'notIc' @($name, $src)) -ForegroundColor Yellow; continue }
        $p
    }
    $targets = @($targets)

    if ($Action -in 'Push', 'List') {
        $vc = Find-HzVCenter -VCenters @(Invoke-HzApi -Path '/monitor/v2/virtual-centers') -Name ([string]$cfg.Server)
        $vm = $null
        foreach ($dc in @(Invoke-HzApi -Path "/external/v1/datacenters?vcenter_id=$($vc.id)")) {
            $vm = @(Invoke-HzApi -Path "/external/v1/base-vms?vcenter_id=$($vc.id)&datacenter_id=$($dc.id)&filter_incompatible_vms=false" |
                Where-Object { $_.name -eq $VMName }) | Select-Object -First 1
            if ($vm) { break }
        }
        if (-not $vm) { throw (T 'noVm' @($VMName, $cfg.Server)) }
        $snaps = @(Invoke-HzApi -Path "/external/v1/base-snapshots?vcenter_id=$($vc.id)&base_vm_id=$($vm.id)")
        if ($Action -eq 'List') {
            Write-Host (T 'snapList' @($VMName))
            $snaps | Select-Object name, description, @{ n = 'created'; e = { $t = Get-P $_ 'created_timestamp'; if ($t) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$t).LocalDateTime } } } |
                Format-Table -AutoSize | Out-String | Write-Host
        } else {
            $snap = Select-HzSnapshot -Snapshots $snaps -Name $SnapshotName -VmName $VMName
            Write-Host (T 'image' @($VMName, $snap.name)) -ForegroundColor Cyan
            $when = $(if ($StartTime -gt (Get-Date)) { $StartTime.ToString('yyyy-MM-dd HH:mm') } else { T 'now' })
            foreach ($p in $targets) {
                $detail = Invoke-HzApi -Path "/inventory/v2/desktop-pools/$($p.id)"
                $vtpm = Get-HzPoolVtpm $detail
                $spec = New-PushImageSpec -ParentVmId $vm.id -SnapshotId $snap.id -Logoff $LogoffPolicy -Start $StartTime -Vtpm $vtpm `
                    -StopOnError ([bool](Get-P $hz 'StopOnFirstError' $true))
                if (-not $PSCmdlet.ShouldProcess($p.name, 'schedule-push-image')) {
                    Write-Host (T 'pushWhatIf' @($p.name, ($spec | ConvertTo-Json -Compress)))
                    continue
                }
                try {
                    [void](Invoke-HzApi -Method POST -Path "/inventory/v2/desktop-pools/$($p.id)/action/schedule-push-image" -Body $spec)
                    Write-Host (T 'push' @($p.name, $when, $LogoffPolicy, $vtpm)) -ForegroundColor Green
                } catch { Write-Host (T 'pushFail' @($p.name, $_.Exception.Message)) -ForegroundColor Red; $rc = 1 }
            }
        }
    }

    if ($Action -eq 'Cancel') {
        foreach ($p in $targets) {
            if (-not $PSCmdlet.ShouldProcess($p.name, 'cancel-scheduled-push-image')) { continue }
            try {
                [void](Invoke-HzApi -Method POST -Path "/inventory/v1/desktop-pools/$($p.id)/action/cancel-scheduled-push-image")
                Write-Host (T 'cancel' @($p.name)) -ForegroundColor Green
            } catch { Write-Host (T 'cancelFail' @($p.name, $_.Exception.Message)) -ForegroundColor Red; $rc = 1 }
        }
    }

    if ($Action -eq 'Status' -or ($Action -eq 'Push' -and $Wait -and $rc -eq 0 -and -not $WhatIfPreference)) {
        if ($Action -eq 'Push') { Write-Host (T 'waiting') }
        do {
            $busy = $false
            foreach ($p in $targets) {
                $s = Format-HzPoolState (Invoke-HzApi -Path "/inventory/v2/desktop-pools/$($p.id)")
                Write-Host (T 'status' @($p.name, $s.Current, $s.Operation, $s.Pending, $s.Progress))
                if ($s.Error) { Write-Host (T 'error' @($p.name, $s.Error)) -ForegroundColor Red; $rc = 1 }
                if ($s.Pending -notin '-', '') { $busy = $true }
            }
            if ($Action -eq 'Push' -and $busy -and $rc -eq 0) { Start-Sleep -Seconds 30 }
        } while ($Action -eq 'Push' -and $busy -and $rc -eq 0)
        if ($Action -eq 'Push' -and $rc -eq 0) { Write-Host (T 'done') -ForegroundColor Green }
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $rc = 2
} finally {
    Disconnect-Hz
}
exit $rc
