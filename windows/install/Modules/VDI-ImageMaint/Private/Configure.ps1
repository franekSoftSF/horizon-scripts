# -Mode Configure: step-by-step wizard (profile, Microsoft 365, FSLogix, App Volumes, build locale, OSOT, winget).
# Every file is backed up before it is changed (.bak_<date>).

function Read-Choice {
    param([string]$Title, [string[]]$Options, [int]$Default = 0)
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ('  [{0}] {1}{2}' -f ($i + 1), $Options[$i], $(if ($i -eq $Default) { '   <- ' + (T 'cfg.default') } else { '' }))
    }
    while ($true) {
        $a = Read-Host (T 'cfg.choice' $Options.Count ($Default + 1))
        if (-not $a) { return $Default }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return ($n - 1) }
    }
}

function Read-Value {
    param([string]$Prompt, [string]$Default = '')
    $a = Read-Host ('{0} [{1}]' -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    while ($true) {
        $a = Read-Host ('{0} [{1}]' -f $Prompt, $(if ($Default) { T 'cfg.yn' } else { T 'cfg.ny' }))
        if (-not $a) { return $Default }
        if ($a -match '^(t|tak|y|yes)$') { return $true }
        if ($a -match '^(n|nie|no)$') { return $false }
    }
}

function Select-Items {
    # Multi-select: Out-GridView window or (-NoGui / no GUI) a numbered console list.
    # Returns the $Key values of the selected items.
    param([object[]]$Items, [string]$Title, [string]$Key)
    $gui = (-not $NoGui) -and [Environment]::UserInteractive -and (Get-Command Out-GridView -ErrorAction SilentlyContinue)
    if ($gui) {
        try { return @($Items | Out-GridView -Title $Title -PassThru | ForEach-Object { [string]$_.$Key }) }
        catch { Write-Log (T 'cfg.noGrid' $_.Exception.Message) WARN }
    }
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $line = ($Items[$i].PSObject.Properties | ForEach-Object { [string]$_.Value }) -join ' | '
        Write-Host ('  [{0,2}] {1}' -f ($i + 1), $line)
    }
    $a = Read-Host (T 'cfg.numbers')
    if (-not $a) { return @() }
    if ($a.Trim() -eq '*') { return @($Items | ForEach-Object { [string]$_.$Key }) }
    $idx = @()
    foreach ($part in ($a -split '[,; ]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') { $idx += ([int]$Matches[1])..([int]$Matches[2]) }
        elseif ($part -match '^\d+$') { $idx += [int]$part }
    }
    return @($idx | Where-Object { $_ -ge 1 -and $_ -le $Items.Count } | Select-Object -Unique | ForEach-Object { [string]$Items[$_ - 1].$Key })
}

function Find-ManifestPackage {
    param($ManifestObj, [string]$Id)
    return (@(Get-PV $ManifestObj 'Packages' @()) | Where-Object { [string](Get-PV $_ 'Id' '') -eq $Id } | Select-Object -First 1)
}

function New-OdtConfigXml {
    # ODT configuration for shared VDI: SCA, no background updates, silent install
    param(
        [string]$Product, [string]$Channel, [string]$Language,
        [ValidateSet('None', 'Proofing', 'Full')][string]$ExtraMode = 'None', [string]$ExtraLanguage = '',
        [string[]]$ExcludeApps = @(), [string]$AppSettingsXml = '',
        [string]$Comment = "VDI-ImageMaint -Mode Configure, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    )
    $e = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<Configuration>')
    [void]$sb.AppendLine("  <!-- $Comment. Shared Computer Activation (non-persistent VDI). No SourcePath: /download saves next to setup.exe, /configure installs from there. -->")
    [void]$sb.AppendLine(('  <Add OfficeClientEdition="64" Channel="{0}">' -f (& $e $Channel)))
    [void]$sb.AppendLine(('    <Product ID="{0}">' -f (& $e $Product)))
    [void]$sb.AppendLine(('      <Language ID="{0}" />' -f (& $e $Language)))
    if ($ExtraMode -eq 'Full' -and $ExtraLanguage) { [void]$sb.AppendLine(('      <Language ID="{0}" />' -f (& $e $ExtraLanguage))) }
    foreach ($x in ($ExcludeApps | Select-Object -Unique)) { [void]$sb.AppendLine(('      <ExcludeApp ID="{0}" />' -f (& $e $x))) }
    [void]$sb.AppendLine('    </Product>')
    if ($ExtraMode -eq 'Proofing' -and $ExtraLanguage) {
        [void]$sb.AppendLine('    <Product ID="ProofingTools">')
        [void]$sb.AppendLine(('      <Language ID="{0}" />' -f (& $e $ExtraLanguage)))
        [void]$sb.AppendLine('    </Product>')
    }
    [void]$sb.AppendLine('  </Add>')
    [void]$sb.AppendLine('  <Property Name="SharedComputerLicensing" Value="1" />')
    [void]$sb.AppendLine('  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />')
    [void]$sb.AppendLine('  <Property Name="DeviceBasedLicensing" Value="0" />')
    [void]$sb.AppendLine('  <Property Name="PinIconsToTaskbar" Value="FALSE" />')
    [void]$sb.AppendLine('  <Updates Enabled="FALSE" />')
    [void]$sb.AppendLine('  <RemoveMSI />')
    if ($AppSettingsXml) { [void]$sb.AppendLine('  ' + $AppSettingsXml.Trim()) }
    [void]$sb.AppendLine('  <Display Level="None" AcceptEULA="TRUE" />')
    [void]$sb.AppendLine('</Configuration>')
    return $sb.ToString()
}

function Invoke-ConfigureOffice {
    param($ManifestObj, [string]$ImageProfile)
    Write-Log (T 'cfg.step2') STEP
    $pkg = Find-ManifestPackage $ManifestObj 'Office365'
    if (-not $pkg) { Write-Log (T 'cfg.noOffice') WARN; return }
    $cfgName = [string](Get-PV $pkg 'Config' 'Configuration_x64.xml')
    if (-not $cfgName) { $cfgName = 'Configuration_x64.xml' }
    $officeDir = Join-Path $InstallDir 'Office'
    $cfgPath = $(if ([IO.Path]::IsPathRooted($cfgName)) { $cfgName } else { Join-Path $officeDir (Split-Path $cfgName -Leaf) })

    # AppSettings (e.g. default save formats) are carried over from the existing file
    $old = $null; $appSettings = ''
    if (Test-Path $cfgPath) {
        try { [xml]$old = Get-Content -Path $cfgPath -Raw } catch { Write-Log (T 'cfg.oldXmlBad' $cfgPath) WARN }
        if ($old -and $old.SelectSingleNode('/Configuration/AppSettings')) { $appSettings = $old.SelectSingleNode('/Configuration/AppSettings').OuterXml }
    }

    $products = @('O365ProPlusRetail', 'O365BusinessRetail')
    $pi = Read-Choice (T 'cfg.license') @((T 'cfg.license.ent'), (T 'cfg.license.bus')) $(if ($ImageProfile -eq 'Business') { 1 } else { 0 })
    $channels = @('MonthlyEnterprise', 'Current', 'SemiAnnual')
    $ci = Read-Choice (T 'cfg.channel') @((T 'cfg.channel.mec'), (T 'cfg.channel.cc'), (T 'cfg.channel.sac'))
    # The same language variants as Office\Templates; "other" accepts any ODT language code
    $presets = @('pl-pl', 'en-us', 'de-de', 'fr-fr', 'pl-pl+en-us', '')
    $defLang = [Math]::Max(0, [array]::IndexOf($presets, (Get-Culture).Name.ToLower()))
    $li = Read-Choice (T 'cfg.lang') @((T 'cfg.lang.pl'), (T 'cfg.lang.en'), (T 'cfg.lang.de'), (T 'cfg.lang.fr'), (T 'cfg.lang.plen'), (T 'cfg.lang.other')) $defLang
    $extraMode = 'None'; $extraLang = ''
    if ($presets[$li] -eq 'pl-pl+en-us') {
        $lang = 'pl-pl'; $extraMode = 'Full'; $extraLang = 'en-us'
    } else {
        $lang = $(if ($presets[$li]) { $presets[$li] } else { (Read-Value (T 'cfg.lang.code') 'it-it').ToLower() })
        $xi = Read-Choice (T 'cfg.lang2') @((T 'cfg.lang2.none'), (T 'cfg.lang2.proof'), (T 'cfg.lang2.full'))
        $extraMode = @('None', 'Proofing', 'Full')[$xi]
        if ($extraMode -ne 'None') { $extraLang = (Read-Value (T 'cfg.lang2.code') $(if ($lang -eq 'en-us') { 'pl-pl' } else { 'en-us' })).ToLower() }
    }

    # Always excluded: OneDrive (installed per machine separately), Teams (new Teams = MSIX), Skype/Lync, Groove, Bing
    $always = @('Groove', 'Lync', 'OneDrive', 'Teams', 'Bing')
    $optional = @(
        [pscustomobject]@{ App = 'Access';    Description = (T 'cfg.app.access') }
        [pscustomobject]@{ App = 'OneNote';   Description = (T 'cfg.app.onenote') }
        [pscustomobject]@{ App = 'Publisher'; Description = (T 'cfg.app.publisher') }
        [pscustomobject]@{ App = 'Outlook';   Description = (T 'cfg.app.outlook') }
    )
    $prevEx = @()
    if ($old) { $prevEx = @($old.SelectNodes('//ExcludeApp') | ForEach-Object { $_.GetAttribute('ID') }) }
    Write-Host (T 'cfg.excludedNow' $(if ($prevEx.Count) { $prevEx -join ', ' } else { '-' }))
    $ex = @(Select-Items -Items $optional -Title (T 'cfg.excludeTitle') -Key 'App')
    $xml = New-OdtConfigXml -Product $products[$pi] -Channel $channels[$ci] -Language $lang -ExtraMode $extraMode -ExtraLanguage $extraLang `
        -ExcludeApps (@($always) + @($ex)) -AppSettingsXml $appSettings
    [void][xml]$xml   # validation
    if (-not (Test-Path $officeDir)) { New-Item -ItemType Directory -Path $officeDir -Force | Out-Null }
    Save-TextWithBackup -Path $cfgPath -Text $xml
    # Language-independent Uninstall.xml (Test-OdtInstallXml skips it as an install configuration anyway)
    Save-TextWithBackup -Path (Join-Path $officeDir 'Uninstall.xml') -Text ("<Configuration>`r`n  <Remove All=`"TRUE`" />`r`n  <Display Level=`"None`" AcceptEULA=`"TRUE`" />`r`n</Configuration>`r`n")
    Set-PV $pkg 'Config' (Split-Path $cfgPath -Leaf)
}

function Invoke-ConfigureFSLogix {
    param($ManifestObj, $Vars, [string]$ImageProfile)
    Write-Log (T 'cfg.step3') STEP
    $cur = [string](Get-PV $Vars 'FSLogixShare' '')
    if ($cur -match '\\(serwer|server)\\') { $cur = '' }   # sample value
    $share = Read-Value (T 'cfg.fsl.share') $cur
    if (-not $share) { Write-Log (T 'cfg.fsl.none'); return }
    if ($share -notmatch '^\\\\[^\\]+\\[^\\]+') { Write-Log (T 'cfg.fsl.notUnc' $share) WARN; return }
    Set-PV $Vars 'FSLogixShare' $share
    # Graphics: large working files and application caches; Business: Outlook OST and OneDrive
    $defSize = @{ University = '30000'; Business = '50000'; Graphics = '100000' }[$ImageProfile]
    if (-not $defSize) { $defSize = '30000' }
    $size = [int](Read-Value (T 'cfg.fsl.size') $defSize)
    $inc = @((Read-Value (T 'cfg.fsl.include') '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $exc = @((Read-Value (T 'cfg.fsl.exclude') '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $q = { param($list) ($list | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',' }
    $pkg = Find-ManifestPackage $ManifestObj 'FSLogixConfig'
    if (-not $pkg) { Write-Log (T 'cfg.fsl.noPkg') WARN; return }
    $det = Get-PV $pkg 'Detect'
    $ver = 0; [void][int]::TryParse([string](Get-PV $det 'Value' '0'), [ref]$ver)
    $argsNoVer = "-VHDLocations '{FSLogixShare}' -SizeInMBs $size"
    if ($inc.Count) { $argsNoVer += ' -ProfileIncludeGroups ' + (& $q $inc) }
    if ($exc.Count) { $argsNoVer += ' -ProfileExcludeMembers ' + (& $q $exc) }
    # Business/Graphics: Entra ID tokens (M365 SSO, OneDrive, Teams) in the container
    if ($ImageProfile -in 'Business', 'Graphics') { $argsNoVer += ' -RoamIdentity' }
    # Graphics: the Adobe media cache is rebuilt automatically - keep it out of the container
    if ($ImageProfile -eq 'Graphics') {
        $argsNoVer += ' -ExtraExcludes ' + (& $q @('AppData\Roaming\Adobe\Common\Media Cache Files', 'AppData\Roaming\Adobe\Common\Media Cache'))
    }
    $oldArgs = [string](Get-PV $pkg 'Arguments' '')
    # Changed arguments = new configuration version (Registry detection runs the script again)
    if (($oldArgs -replace '\s*-ConfigVersion\s+\d+', '') -ne $argsNoVer) { $ver++ }
    if ($ver -lt 1) { $ver = 1 }
    Set-PV $pkg 'Arguments' "$argsNoVer -ConfigVersion $ver"
    if ($det) { Set-PV $det 'Value' ([string]$ver) }
    Set-PV $pkg 'Enabled' $true
    Write-Log (T 'cfg.fsl.done' "$argsNoVer -ConfigVersion $ver") OK
}

function Invoke-ConfigureOsot {
    param($ManifestObj, [string]$ImageProfile)
    Write-Log (T 'cfg.step6') STEP
    $o = Get-PV $ManifestObj 'Osot'
    if (-not $o) { Write-Log (T 'cfg.osot.none') WARN; return }
    $keepNotif = Read-YesNo (T 'cfg.osot.notif') $true
    $keepOneDrive = Read-YesNo (T 'cfg.osot.onedrive') ($ImageProfile -ne 'University')
    $graphics = ($ImageProfile -eq 'Graphics')

    $co = @(Get-PV $o 'CommonOptions' @())
    $new = @()
    for ($i = 0; $i -lt $co.Count; $i++) {
        # remove the pairs the wizard sets: -notification X, -visualeffect X
        if ($co[$i] -in '-notification', '-visualeffect' -and $i + 1 -lt $co.Count) { $i++; continue }
        $new += $co[$i]
    }
    # Graphics (vGPU): full visual effects; other profiles: balanced (font smoothing and shadows stay)
    $new = @(@('-visualeffect', $(if ($graphics) { 'quality' } else { 'balanced' })) + $new)
    if (-not $keepNotif) { $new += @('-notification', 'disable') }
    Set-PV $o 'CommonOptions' $new
    Write-Log "Osot.CommonOptions: $($new -join ' ')" OK

    $sf = [string](Get-PV $o 'SettingsFile' '')
    $j = $null; $sfPath = ''
    if ($sf) {
        $sfPath = $(if ([IO.Path]::IsPathRooted($sf)) { $sf } else { Join-Path $InstallDir $sf })
        if (Test-Path $sfPath) { $j = Get-Content -Path $sfPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        else { Write-Log (T 'cfg.osot.noFile' $sfPath) WARN }
    }
    $changed = 0
    if ($j) {
        foreach ($it in @(Get-PV $j 'TemplateItemList' @())) {
            $step = [string](Get-PV $it 'Step' '')
            $entity = [string](Get-PV $it 'Entity' '')
            if ($step -match '^Turn off notifications from apps and other senders') {
                $want = -not $keepNotif
                if ([bool]$it.IsSelected -ne $want) { $it.IsSelected = $want; $changed++ }
            }
            if ($entity -eq 'OneDrive' -and $step -match '^(Remove OneDrive|Prevent the usage of OneDrive|Prevent OneDrive network)') {
                if ($keepOneDrive -and [bool]$it.IsSelected) { $it.IsSelected = $false; $changed++ }
            }
            # Graphics: GPU acceleration in Office/Edge/Adobe, image thumbnails, pen input - NOT turned off
            if ($graphics -and [bool]$it.IsSelected -and (
                    $entity -eq 'Hardware Acceleration' -or
                    $step -match '^Turn off (the )?caching of thumbnail' -or
                    $step -match '^Disable Ink Collection')) {
                $it.IsSelected = $false; $changed++
            }
        }
        $co2 = Get-PV $j 'CommonOptions'
        $n = Get-PV $co2 'Notification'
        if ($n -and $null -ne (Get-PV $n 'Disable') -and [bool]$n.Disable -ne (-not $keepNotif)) { $n.Disable = (-not $keepNotif); $changed++ }
        $ve = Get-PV $co2 'VisualEffect'
        if ($ve -and $null -ne (Get-PV $ve 'BestQuality')) {
            $want = @{ BestQuality = $graphics; Balanced = (-not $graphics); BestPerformance = $false; DisableHardwareAcceleration = (-not $graphics) }
            foreach ($k in $want.Keys) {
                if ($null -ne (Get-PV $ve $k) -and [bool]$ve.$k -ne $want[$k]) { $ve.$k = $want[$k]; $changed++ }
            }
            foreach ($k in 'VisualEffectUpdated', 'HardwareAccelerationUpdated') { if ($null -ne (Get-PV $ve $k)) { $ve.$k = $true } }
        }
    }
    # OneDrive per machine (a per-user install on non-persistent clones starts over every time)
    $od = Find-ManifestPackage $ManifestObj 'OneDrive'
    if ($od) { Set-PV $od 'Enabled' $keepOneDrive; Write-Log (T 'cfg.osot.odPkg' $(if ($keepOneDrive) { T 'cfg.on' } else { T 'cfg.off' })) }
    elseif ($keepOneDrive) { Write-Log (T 'cfg.osot.odMissing') WARN }
    if ($changed) {
        Save-TextWithBackup -Path $sfPath -Text ($j | ConvertTo-Json -Depth 20 -Compress)
        Write-Log (T 'cfg.osot.changed' $changed $(if ($keepNotif) { T 'cfg.on' } else { T 'cfg.off' }) $(if ($keepOneDrive) { T 'cfg.kept' } else { T 'cfg.unchanged' }) $(if ($graphics) { 'quality + GPU' } else { 'balanced' })) OK
    } elseif ($j) { Write-Log (T 'cfg.osot.same') }
    Write-Log (T 'cfg.osot.verify') WARN
}

function Invoke-ConfigureWinget {
    param($ManifestObj, [string]$ImageProfile)
    Write-Log (T 'cfg.step7') STEP
    $catPath = Join-Path $InstallDir 'winget-catalog.json'
    if (-not (Test-Path $catPath)) { Write-Log (T 'cfg.wg.noCatalog' $catPath) WARN; return }
    $cat = @(Get-PV (Get-Content -Path $catPath -Raw -Encoding UTF8 | ConvertFrom-Json) 'Packages' @())
    $w = Get-PV $ManifestObj 'Winget'
    if (-not $w) { $w = [pscustomobject]@{ Install = @() }; Set-PV $ManifestObj 'Winget' $w }
    $cur = @(Get-PV $w 'Install' @())
    $yes = T 'cfg.yes'
    $rows = @($cat | ForEach-Object {
        $r = [ordered]@{}
        $r[(T 'cfg.col.name')]     = [string]$_.Name
        $r['Id']                   = [string]$_.Id
        $r[(T 'cfg.col.category')] = [string]$_.Category
        $r[(T 'cfg.col.profile')]  = $(if (@($_.Profiles) -contains $ImageProfile) { $yes } else { '-' })
        $r[(T 'cfg.col.suggest')]  = $(if ([bool](Get-PV $_ 'Default' $false) -and @($_.Profiles) -contains $ImageProfile) { $yes } else { '-' })
        $r[(T 'cfg.col.current')]  = $(if ($cur -contains $_.Id) { $yes } else { '-' })
        $r[(T 'cfg.col.block')]    = [string]$_.UpdateBlock
        [pscustomobject]$r
    })
    $suggested = @($cat | Where-Object { [bool](Get-PV $_ 'Default' $false) -and @($_.Profiles) -contains $ImageProfile } | ForEach-Object { [string]$_.Id })
    Write-Host (T 'cfg.wg.current' $(if ($cur.Count) { $cur -join ', ' } else { '-' }))
    while ($true) {
        $sel = @(Select-Items -Items $rows -Title (T 'cfg.wg.title') -Key 'Id')
        if ($sel.Count -eq 0) {
            $c = Read-Choice (T 'cfg.wg.nothing') @((T 'cfg.wg.keep'), (T 'cfg.wg.suggested' $suggested.Count), (T 'cfg.wg.again'), (T 'cfg.wg.none'))
            if ($c -eq 0) { $sel = $cur } elseif ($c -eq 1) { $sel = $suggested } elseif ($c -eq 2) { continue } else { $sel = @() }
        }
        Write-Host (T 'cfg.wg.selected' $sel.Count ($sel -join ', '))
        if (Read-YesNo (T 'cfg.confirm') $true) { break }
    }
    Set-PV $w 'Install' @($sel)
    Write-Log (T 'cfg.wg.done' $sel.Count) OK
}

function Invoke-Configure {
    Write-Log (T 'cfg.step') STEP
    if ($isSystem) { throw (T 'cfg.notSystem') }
    $mp = Get-ManifestPath
    $m = Get-PackageManifest
    if (-not $m) { return }
    Write-Log (T 'pkg.manifest' $mp)

    Write-Log (T 'cfg.step1') STEP
    $curProfile = [string](Get-PV $m 'Profile' 'University')
    $profiles = @('University', 'Business', 'Graphics')
    $pi = Read-Choice (T 'cfg.profile') @((T 'cfg.profile.uni'), (T 'cfg.profile.bus'), (T 'cfg.profile.gfx')) ([Math]::Max(0, [array]::IndexOf($profiles, $curProfile)))
    $prof = $profiles[$pi]
    Set-PV $m 'Profile' $prof

    Invoke-ConfigureOffice -ManifestObj $m -ImageProfile $prof

    $vars = Get-PV $m 'Variables'
    if (-not $vars) { $vars = [pscustomobject]@{}; Set-PV $m 'Variables' $vars }
    Invoke-ConfigureFSLogix -ManifestObj $m -Vars $vars -ImageProfile $prof

    Write-Log (T 'cfg.step4') STEP
    $avm = Read-Value (T 'cfg.av.manager') ([string](Get-PV $vars 'AppVolumesManager' ''))
    if ($avm) { Set-PV $vars 'AppVolumesManager' $avm }
    Set-PV $vars 'AppVolumesPort' (Read-Value (T 'cfg.av.port') ([string](Get-PV $vars 'AppVolumesPort' '443')))

    Write-Log (T 'cfg.step5') STEP
    $b = Get-PV $m 'Build'
    if (-not $b) { $b = [pscustomobject]@{}; Set-PV $m 'Build' $b }
    $cul = (Get-Culture).Name
    $tz = [string](Get-PV $b 'TimeZone' ''); if (-not $tz) { $tz = (Get-TimeZone).Id }
    Set-PV $b 'TimeZone'     (Read-Value (T 'cfg.bld.tz') $tz)
    foreach ($k in @(@('SystemLocale', 'cfg.bld.system'), @('UserLocale', 'cfg.bld.user'), @('InputLocale', 'cfg.bld.input'))) {
        $v = [string](Get-PV $b $k[0] ''); if (-not $v) { $v = $cul }
        Set-PV $b $k[0] (Read-Value (T $k[1]) $v)
    }
    Write-Host (T 'cfg.bld.ui' ([Globalization.CultureInfo]::InstalledUICulture.Name))

    Invoke-ConfigureOsot -ManifestObj $m -ImageProfile $prof
    Invoke-ConfigureWinget -ManifestObj $m -ImageProfile $prof

    Write-Log (T 'cfg.save') STEP
    Save-TextWithBackup -Path $mp -Text (Format-Json ($m | ConvertTo-Json -Depth 20))
    [void](Get-Content -Path $mp -Raw -Encoding UTF8 | ConvertFrom-Json)   # validation
    Write-Log (T 'cfg.done') OK
}
